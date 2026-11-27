using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using Rtfx.Jobs;

namespace Rtfx.Runner;

/// <summary>
/// Everything the tools do, against the runner's root on the Copilot machine: the protocol is the
/// files described in the README, and this class is the only place that knows their names.
/// </summary>
public sealed partial class RunnerClient(RtfxConfig config, IRunnerTransport transport)
{
    /// <summary>The runner writes a heartbeat every few seconds. Older than this and it is taken for stopped.</summary>
    public static readonly TimeSpan HeartbeatLimit = TimeSpan.FromMinutes(2);

    private static readonly TimeSpan PollEvery = TimeSpan.FromSeconds(5);
    private static readonly UTF8Encoding Utf8 = new(encoderShouldEmitUTF8Identifier: false);

    public RtfxConfig Config => config;

    // ---------- runner health ----------

    /// <summary>The runner's heartbeat with its age, and whether jobs will be picked up.</summary>
    public async Task<JsonObject> HealthAsync(CancellationToken cancellationToken)
    {
        var beat = await ReadJsonAsync("heartbeat.json", cancellationToken).ConfigureAwait(false);
        var health = new JsonObject { ["host"] = config.RemoteHost };
        if (beat is null || ParseTime(beat["at"]) is not { } at)
        {
            health["running"] = false;
            health["problem"] = $"The runner on {config.RemoteHost} has never written a heartbeat under {config.RemoteRoot}: it is not installed there, or RTFX_ROOT points at the wrong folder.";
            return health;
        }

        var age = DateTime.UtcNow - at;
        var alive = age < HeartbeatLimit;
        health["running"] = alive;
        health["heartbeatAgeSec"] = (int)age.TotalSeconds;
        health["version"] = beat["version"]?.DeepClone();
        health["jobsRunning"] = (beat["running"] as JsonArray)?.Count ?? 0;
        health["jobsQueued"] = beat["queued"]?.DeepClone();
        health["maxConcurrent"] = beat["maxConcurrent"]?.DeepClone();
        if (!alive)
        {
            health["problem"] = $"The runner on {config.RemoteHost} is not running: its last heartbeat is {Age(age)} old. "
                + "It runs as the scheduled task \"rtfx runner\" in the logged-on desktop session there, so it stops when nobody is logged on. "
                + $"To start it: pwsh -NoProfile -File {config.RemoteRoot}/install-task.ps1 on that machine.";
        }

        return health;
    }

    private async Task RequireRunnerAsync(CancellationToken cancellationToken)
    {
        var health = await HealthAsync(cancellationToken).ConfigureAwait(false);
        if (health["running"]?.GetValue<bool>() != true)
        {
            throw new RunnerException(Json.Text(health["problem"])!);
        }
    }

    // ---------- submitting ----------

    /// <summary>Submits jobs, all or none as far as validation goes. Returns one entry per job, in order.</summary>
    public async Task<JsonArray> SubmitAsync(IReadOnlyList<JobRequest> requests, CancellationToken cancellationToken)
    {
        // Everything that can be wrong without the runner's help is found before the first job leaves.
        var identities = new Dictionary<string, (string Name, string Email)>();
        foreach (var request in requests)
        {
            request.Validate();
            if (request.IsWrite && !identities.ContainsKey(request.Repo))
            {
                identities[request.Repo] = await IdentityAsync(request.Repo, cancellationToken).ConfigureAwait(false);
            }
        }

        await RequireRunnerAsync(cancellationToken).ConfigureAwait(false);

        // Two copies for the whole batch, however many jobs it holds: every job's folder with its
        // job.json and task.md, then every job's status.json. The status goes last because the runner
        // starts a job once it sees one, and a copy is a new ssh connection each, so one per job
        // would take minutes for a large fan-out.
        var batch = Path.Combine(config.Cache, "outbox", Guid.NewGuid().ToString("N")[..12]);
        var briefs = Directory.CreateDirectory(Path.Combine(batch, "briefs")).FullName;
        var statuses = Directory.CreateDirectory(Path.Combine(batch, "statuses")).FullName;
        var submitted = new JsonArray();
        try
        {
            var ids = new List<string>();
            foreach (var request in requests)
            {
                var id = JobRequest.NewId(DateTime.UtcNow);
                var identity = request.IsWrite ? identities[request.Repo] : default;
                var folder = Directory.CreateDirectory(Path.Combine(briefs, id)).FullName;
                await File.WriteAllTextAsync(Path.Combine(folder, "job.json"), Json.Pretty(request.ToJobJson(id, identity.Name, identity.Email)), Utf8, cancellationToken).ConfigureAwait(false);
                await File.WriteAllTextAsync(Path.Combine(folder, "task.md"), request.Brief, Utf8, cancellationToken).ConfigureAwait(false);
                var status = new JsonObject { ["state"] = "queued", ["queuedAt"] = Stamp(DateTime.UtcNow) };
                await File.WriteAllTextAsync(Path.Combine(Directory.CreateDirectory(Path.Combine(statuses, id)).FullName, "status.json"), Json.Pretty(status), Utf8, cancellationToken).ConfigureAwait(false);
                ids.Add(id);
                submitted.Add((JsonNode)new JsonObject { ["job_id"] = id, ["state"] = "queued", ["repo"] = request.Repo, ["mode"] = request.Mode, ["model"] = request.Model });
            }

            await transport.UploadDirectoriesAsync([.. ids.Select(id => Path.Combine(briefs, id))], "jobs", cancellationToken).ConfigureAwait(false);
            try
            {
                await transport.UploadDirectoriesAsync([.. ids.Select(id => Path.Combine(statuses, id))], "jobs", cancellationToken).ConfigureAwait(false);
            }
            catch (RunnerException ex)
            {
                // The folders are there without a status, so the runner will not start them, and it clears such folders after a day.
                throw new RunnerException($"the jobs were copied but could not be queued, so none will run: {ex.Message}");
            }
        }
        finally
        {
            Directory.Delete(batch, recursive: true);
        }

        return submitted;
    }

    /// <summary>A write job commits as the person who asked for it: whoever this machine's checkout of the repository commits as.</summary>
    private async Task<(string Name, string Email)> IdentityAsync(string repo, CancellationToken cancellationToken)
    {
        var checkout = Path.Combine(config.LocalRepos, repo);
        if (!Directory.Exists(Path.Combine(checkout, ".git")) && !File.Exists(Path.Combine(checkout, ".git")))
        {
            throw new InvalidRequestException($"there is no checkout of {repo} at {checkout} to take the commit identity from. A write job commits as whoever that checkout commits as.");
        }

        var name = (await GitAsync(checkout, ["config", "user.name"], cancellationToken).ConfigureAwait(false)).Output.Trim();
        var email = (await GitAsync(checkout, ["config", "user.email"], cancellationToken).ConfigureAwait(false)).Output.Trim();
        return name.Length > 0 && email.Length > 0
            ? (name, email)
            : throw new InvalidRequestException($"{checkout} has no user.name or user.email in its git config, and a write job needs both for its commits.");
    }

    // ---------- status and waiting ----------

    /// <summary>One job's status.json, or null when the runner has no such job.</summary>
    public Task<JsonObject?> StatusAsync(string id, CancellationToken cancellationToken) => ReadJsonAsync($"jobs/{id}/status.json", cancellationToken);

    /// <summary>The runner's index of jobs, newest first. Empty when the runner has not written one yet.</summary>
    public async Task<JsonArray> IndexAsync(CancellationToken cancellationToken) =>
        (await ReadJsonAsync("index.json", cancellationToken).ConfigureAwait(false))?["jobs"] as JsonArray ?? [];

    /// <summary>Waits until every job has ended or the time is up. Returns each job's state either way.</summary>
    public async Task<JsonObject> WaitAsync(IReadOnlyList<string> ids, TimeSpan timeout, CancellationToken cancellationToken)
    {
        var deadline = DateTime.UtcNow + timeout;
        var states = new Dictionary<string, JsonObject>();
        while (true)
        {
            var pending = ids.Where(id => !states.TryGetValue(id, out var known) || !IsTerminal(known)).ToList();
            if (pending.Count > 0)
            {
                // The index answers for every job in one download. It trails by a few seconds, and a job
                // submitted a moment ago may not be in it yet, so a job it does not list is asked for directly.
                var index = await IndexAsync(cancellationToken).ConfigureAwait(false);
                foreach (var id in pending)
                {
                    var listed = index.OfType<JsonObject>().FirstOrDefault(job => Json.Text(job["id"]) == id);
                    listed ??= await StatusAsync(id, cancellationToken).ConfigureAwait(false);

                    states[id] = listed is null
                        ? new JsonObject { ["job_id"] = id, ["state"] = "unknown", ["error"] = "the runner has no job with this id" }
                        : Summary(id, listed);
                }
            }

            var open = states.Values.Count(state => !IsTerminal(state) && Json.Text(state["state"]) != "unknown");
            if (open == 0 || DateTime.UtcNow >= deadline)
            {
                var result = new JsonObject
                {
                    ["all_done"] = open == 0,
                    ["still_going"] = open,
                    ["jobs"] = Json.Array(ids.Select(id => (JsonNode?)states[id].DeepClone())),
                };
                if (open > 0)
                {
                    var health = await HealthAsync(cancellationToken).ConfigureAwait(false);
                    if (health["running"]?.GetValue<bool>() != true)
                    {
                        result["runner"] = health;
                    }
                }

                return result;
            }

            var left = deadline - DateTime.UtcNow;
            await Task.Delay(left < PollEvery ? left : PollEvery, cancellationToken).ConfigureAwait(false);
        }
    }

    private static JsonObject Summary(string id, JsonObject status)
    {
        var summary = new JsonObject { ["job_id"] = id };
        foreach (var name in (string[])["state", "repo", "mode", "model", "ticket", "startedAt", "finishedAt", "credits", "nearCreditCap", "error"])
        {
            if (status[name] is { } value)
            {
                summary[name] = value.DeepClone();
            }
        }

        return summary;
    }

    public static bool IsTerminal(JsonObject status) => JobRequest.TerminalStates.Contains(Json.Text(status["state"]));

    // ---------- results ----------

    /// <summary>A finished job's result.json. Throws with the job's state when there is none yet.</summary>
    public async Task<JsonObject> ResultAsync(string id, CancellationToken cancellationToken)
    {
        var file = Path.Combine(JobCache(id), "result.json");
        if (await transport.DownloadAsync($"jobs/{id}/result.json", file, cancellationToken).ConfigureAwait(false)
            && Parse(await File.ReadAllTextAsync(file, cancellationToken).ConfigureAwait(false)) is { } result)
        {
            return result;
        }

        var status = await StatusAsync(id, cancellationToken).ConfigureAwait(false);
        throw status is null
            ? new RunnerException($"the runner has no job {id}.")
            : new RunnerException($"job {id} has no result yet: it is {Json.Text(status["state"])}. Use wait, or logs to see what it is doing.");
    }

    /// <summary>What a caller wants from a result, the report first; the bookkeeping the runner also records is left out.</summary>
    public static JsonObject Digest(JsonObject result)
    {
        var digest = new JsonObject { ["job_id"] = result["id"]?.DeepClone() };
        foreach (var (name, value) in Json.Pick(result, "state", "error", "repo", "mode", "ticket", "model", "credits", "creditCap", "nearCreditCap", "creditsLowerBound", "durationSec").ToList())
        {
            if (value is not null)
            {
                digest[name] = value.DeepClone();
            }
        }

        digest["report"] = result["finalMessage"]?.DeepClone();
        foreach (var (name, value) in Json.Pick(result, "branch", "baseCommit", "headCommit", "commits", "filesChanged", "diffStat",
            "cleanBeforeAutoCommit", "autoCommit", "bundle", "patch", "guards", "warnings", "tokens").ToList())
        {
            if (value is not null)
            {
                digest[name] = value.DeepClone();
            }
        }

        return digest;
    }

    /// <summary>The end of the worker's log, Copilot's last messages and the last commands it ran.</summary>
    public async Task<JsonObject> LogsAsync(string id, int tail, CancellationToken cancellationToken)
    {
        var output = await transport.RunScriptAsync("logs.ps1", ["-Id", id, "-Tail", Math.Clamp(tail, 1, 500).ToString(CultureInfo.InvariantCulture)], cancellationToken).ConfigureAwait(false);
        return Parse(output) ?? throw new RunnerException($"logs.ps1 on {config.RemoteHost} did not print JSON: {output.Trim()}");
    }

    /// <summary>A write job's change as a patch, whole or for one path. Available as soon as the job has ended, before any fetch.</summary>
    public async Task<string> DiffAsync(string id, string? path, CancellationToken cancellationToken)
    {
        var file = Path.Combine(JobCache(id), "result.patch");
        if (!await transport.DownloadAsync($"jobs/{id}/result.patch", file, cancellationToken).ConfigureAwait(false))
        {
            var result = await ResultAsync(id, cancellationToken).ConfigureAwait(false);
            var why = Json.Text(result["mode"]) == "read" ? "it was a read job" : $"it is {Json.Text(result["state"])} with {(result["commits"] as JsonArray)?.Count ?? 0} commits";
            throw new RunnerException($"job {id} has no patch: {why}.");
        }

        var patch = await File.ReadAllTextAsync(file, cancellationToken).ConfigureAwait(false);
        return path is null ? patch : Patch.ForPath(patch, path);
    }

    // ---------- fetching ----------

    /// <summary>
    /// Brings a write job's branch into this machine's checkout of the repository. It only adds a
    /// branch: nothing is checked out, the working tree is not touched, and a branch that already
    /// exists is left alone.
    /// </summary>
    public async Task<JsonObject> FetchAsync(string id, string? branch, CancellationToken cancellationToken)
    {
        var result = await ResultAsync(id, cancellationToken).ConfigureAwait(false);
        if (result["bundle"] is not JsonObject bundle)
        {
            var warnings = string.Join("; ", (result["warnings"] as JsonArray ?? []).Select(Json.Text));
            throw new RunnerException($"job {id} ({Json.Text(result["state"])}) has nothing to fetch: {(warnings.Length > 0 ? warnings : "it made no bundle")}.");
        }

        var jobRef = Json.Text(bundle["ref"]) ?? "";
        var baseCommit = Json.Text(result["baseCommit"]) ?? "";
        var head = Json.Text(result["headCommit"]) ?? "";
        var repo = Json.Text(result["repo"]) ?? "";
        if (!JobRef().IsMatch(jobRef) || !FullHash().IsMatch(baseCommit) || !FullHash().IsMatch(head) || !RepoName().IsMatch(repo))
        {
            throw new RunnerException($"result.json of job {id} does not describe its bundle properly.");
        }

        var localBranch = branch ?? jobRef["refs/heads/".Length..];
        if (!JobRef().IsMatch("refs/heads/" + localBranch) || localBranch.Contains("..", StringComparison.Ordinal))
        {
            throw new InvalidRequestException($"branch '{localBranch}' is not a valid branch name.");
        }

        var target = Path.Combine(config.LocalRepos, repo);
        if ((await GitAsync(target, ["rev-parse", "--git-dir"], cancellationToken).ConfigureAwait(false)).ExitCode != 0)
        {
            throw new RunnerException($"there is no git checkout of {repo} at {target} to fetch into.");
        }

        var localRef = "refs/heads/" + localBranch;
        var existing = await GitAsync(target, ["rev-parse", "--verify", "--quiet", localRef], cancellationToken).ConfigureAwait(false);
        if (existing.ExitCode == 0)
        {
            if (existing.Output.Trim() != head)
            {
                throw new RunnerException($"{target} already has a branch {localBranch}, at {Short(existing.Output.Trim())}, and the job ended at {Short(head)}. "
                    + "Nothing was changed. Pass another name as branch, or delete that branch first.");
            }

            await MarkFetchedAsync(id, "fetched", cancellationToken).ConfigureAwait(false);
            return FetchOutcome(id, target, localBranch, head, baseCommit, result, alreadyThere: true);
        }

        var file = Path.Combine(JobCache(id), "result.bundle");
        if (!await transport.DownloadAsync($"jobs/{id}/result.bundle", file, cancellationToken).ConfigureAwait(false))
        {
            throw new RunnerException($"result.bundle of job {id} is no longer on the runner.");
        }

        string hash;
        await using (var stream = File.OpenRead(file))
        {
            hash = Convert.ToHexStringLower(await SHA256.HashDataAsync(stream, cancellationToken).ConfigureAwait(false));
        }

        if (hash != Json.Text(bundle["sha256"]))
        {
            throw new RunnerException($"result.bundle of job {id} arrived damaged: its hash is {hash}, result.json says {Json.Text(bundle["sha256"])}.");
        }

        // The bundle holds only what the job added, so the checkout must already have the commit the job started from.
        if ((await GitAsync(target, ["cat-file", "-e", baseCommit + "^{commit}"], cancellationToken).ConfigureAwait(false)).ExitCode != 0)
        {
            await GitAsync(target, ["fetch", "--quiet", "origin"], cancellationToken).ConfigureAwait(false);
            if ((await GitAsync(target, ["cat-file", "-e", baseCommit + "^{commit}"], cancellationToken).ConfigureAwait(false)).ExitCode != 0)
            {
                throw new RunnerException($"{target} does not have the commit the job started from ({Short(baseCommit)}), even after fetching origin.");
            }
        }

        var verify = await GitAsync(target, ["bundle", "verify", "--quiet", file], cancellationToken).ConfigureAwait(false);
        if (verify.ExitCode != 0)
        {
            throw new RunnerException($"the bundle of job {id} does not fit {target}: {verify.Message}");
        }

        var fetch = await GitAsync(target, ["fetch", "--no-tags", "--quiet", file, $"{jobRef}:{localRef}"], cancellationToken).ConfigureAwait(false);
        var arrived = await GitAsync(target, ["rev-parse", "--verify", "--quiet", localRef], cancellationToken).ConfigureAwait(false);
        if (fetch.ExitCode != 0 || arrived.Output.Trim() != head)
        {
            throw new RunnerException($"could not fetch {localBranch} into {target}: {fetch.Message}");
        }

        await MarkFetchedAsync(id, "fetched", cancellationToken).ConfigureAwait(false);
        return FetchOutcome(id, target, localBranch, head, baseCommit, result, alreadyThere: false);
    }

    private static JsonObject FetchOutcome(string id, string target, string branch, string head, string baseCommit, JsonObject result, bool alreadyThere) => new()
    {
        ["job_id"] = id,
        ["checkout"] = target,
        ["branch"] = branch,
        ["head"] = head,
        ["base"] = baseCommit,
        ["commits"] = (result["commits"] as JsonArray)?.Count ?? 0,
        ["already_there"] = alreadyThere,
        ["note"] = "The branch was added and nothing was checked out. The runner will now drop the job's worktree.",
    };

    // ---------- ending and clearing ----------

    /// <summary>Asks the runner to stop a job and waits a little for it to say it has.</summary>
    public async Task<JsonObject> AbortAsync(string id, CancellationToken cancellationToken)
    {
        var status = await StatusAsync(id, cancellationToken).ConfigureAwait(false) ?? throw new RunnerException($"the runner has no job {id}.");
        if (!IsTerminal(status))
        {
            await MarkAsync($"jobs/{id}/cancel", "cancel requested", cancellationToken).ConfigureAwait(false);
            var waited = await WaitAsync([id], TimeSpan.FromSeconds(90), cancellationToken).ConfigureAwait(false);
            var after = (JsonObject)((JsonArray)waited["jobs"]!)[0]!.DeepClone();
            after["note"] = IsTerminal(after)
                ? "Stopped. A write job keeps the work it had done: result shows its commits and bundle."
                : "The cancel request is with the runner, which has not acted on it yet.";
            return after;
        }

        var ended = Summary(id, status);
        ended["note"] = "The job had already ended, so there was nothing to stop.";
        return ended;
    }

    /// <summary>Tells the runner a finished job's work is not wanted, so it drops the worktree and branch now.</summary>
    public async Task<JsonObject> DiscardAsync(string id, CancellationToken cancellationToken)
    {
        var status = await StatusAsync(id, cancellationToken).ConfigureAwait(false) ?? throw new RunnerException($"the runner has no job {id}.");
        if (!IsTerminal(status))
        {
            throw new RunnerException($"job {id} is {Json.Text(status["state"])}: abort it first.");
        }

        await MarkFetchedAsync(id, "discarded", cancellationToken).ConfigureAwait(false);
        return new JsonObject
        {
            ["job_id"] = id,
            ["discarded"] = true,
            ["note"] = "The runner drops the worktree and the job's branch. The result and the bundle stay in the job folder for two weeks.",
        };
    }

    /// <summary>The same file for a fetch and a discard: either way the worktree has nothing left to wait for.</summary>
    private Task MarkFetchedAsync(string id, string what, CancellationToken cancellationToken) =>
        MarkAsync($"jobs/{id}/fetched", what, cancellationToken);

    private async Task MarkAsync(string relative, string what, CancellationToken cancellationToken)
    {
        var temp = Path.Combine(config.Cache, "outbox", Guid.NewGuid().ToString("N") + ".marker");
        Directory.CreateDirectory(Path.GetDirectoryName(temp)!);
        await File.WriteAllTextAsync(temp, $"{Stamp(DateTime.UtcNow)} {what} from {Environment.MachineName}", Utf8, cancellationToken).ConfigureAwait(false);
        try
        {
            await transport.UploadFileAsync(temp, relative, cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            File.Delete(temp);
        }
    }

    // ---------- models ----------

    /// <summary>The models Copilot offers, with prices. Asks the runner to refresh the list when it is old or on request.</summary>
    public async Task<JsonObject> ModelsAsync(bool refresh, CancellationToken cancellationToken)
    {
        var models = await ReadJsonAsync("models.json", cancellationToken).ConfigureAwait(false);
        var stale = models is null || ParseTime(models["fetchedAt"]) is not { } fetched || DateTime.UtcNow - fetched > TimeSpan.FromDays(7);
        if (refresh || stale)
        {
            await RequireRunnerAsync(cancellationToken).ConfigureAwait(false);
            var before = Marker(await ReadJsonAsync("models.status.json", cancellationToken).ConfigureAwait(false));
            await MarkAsync("models.request", "requested", cancellationToken).ConfigureAwait(false);
            var deadline = DateTime.UtcNow + TimeSpan.FromMinutes(10);
            JsonObject? status = null;
            while (DateTime.UtcNow < deadline)
            {
                await Task.Delay(PollEvery, cancellationToken).ConfigureAwait(false);
                status = await ReadJsonAsync("models.status.json", cancellationToken).ConfigureAwait(false);
                if (Json.Text(status?["state"]) is "done" or "failed" && Marker(status) != before)
                {
                    break;
                }
            }

            if (Json.Text(status?["state"]) is not ("done" or "failed") || Marker(status) == before)
            {
                throw new RunnerException("the runner did not refresh the model list within 10 minutes.");
            }

            if (Json.Text(status!["state"]) == "failed")
            {
                throw new RunnerException($"the runner could not refresh the model list: {Json.Text(status["error"])}");
            }

            models = await ReadJsonAsync("models.json", cancellationToken).ConfigureAwait(false);
        }

        return models ?? throw new RunnerException("the runner has no model list.");

        static string Marker(JsonObject? status) => $"{Json.Text(status?["state"])} {Json.Text(status?["finishedAt"])}";
    }

    // ---------- plumbing ----------

    private string JobCache(string id) => Directory.CreateDirectory(Path.Combine(config.Cache, "jobs", id)).FullName;

    /// <summary>Downloads a JSON file from the runner. Null when it is not there, or not whole yet.</summary>
    private async Task<JsonObject?> ReadJsonAsync(string relative, CancellationToken cancellationToken)
    {
        var temp = Path.Combine(Directory.CreateDirectory(Path.Combine(config.Cache, "tmp")).FullName, Guid.NewGuid().ToString("N") + ".json");
        try
        {
            return await transport.DownloadAsync(relative, temp, cancellationToken).ConfigureAwait(false)
                ? Parse(await File.ReadAllTextAsync(temp, cancellationToken).ConfigureAwait(false))
                : null;
        }
        finally
        {
            File.Delete(temp);
        }
    }

    private static JsonObject? Parse(string text)
    {
        try
        {
            return JsonNode.Parse(text) as JsonObject;
        }
        catch (JsonException)
        {
            return null;
        }
    }

    private Task<ProcessResult> GitAsync(string checkout, string[] arguments, CancellationToken cancellationToken) =>
        ProcessRunner.RunAsync("git", ["-C", checkout, .. arguments], TimeSpan.FromMinutes(5), cancellationToken);

    internal static DateTime? ParseTime(JsonNode? node) =>
        DateTime.TryParse(Json.Text(node), CultureInfo.InvariantCulture, DateTimeStyles.AdjustToUniversal | DateTimeStyles.AssumeUniversal, out var time) ? time : null;

    private static string Stamp(DateTime utc) => utc.ToString("yyyy-MM-ddTHH:mm:ssZ", CultureInfo.InvariantCulture);

    private static string Short(string hash) => hash.Length > 10 ? hash[..10] : hash;

    internal static string Age(TimeSpan age) => age.TotalHours >= 48 ? $"{(int)age.TotalDays} days"
        : age.TotalMinutes >= 120 ? $"{(int)age.TotalHours} hours"
        : age.TotalSeconds >= 120 ? $"{(int)age.TotalMinutes} minutes"
        : $"{(int)age.TotalSeconds} seconds";

    [GeneratedRegex(@"^refs/heads/[A-Za-z0-9][A-Za-z0-9._/-]*$")]
    private static partial Regex JobRef();

    [GeneratedRegex(@"^[0-9a-f]{40,64}$")]
    private static partial Regex FullHash();

    [GeneratedRegex(@"^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$")]
    private static partial Regex RepoName();
}
