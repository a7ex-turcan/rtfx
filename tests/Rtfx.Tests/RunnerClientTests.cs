using System.Security.Cryptography;
using System.Text.Json.Nodes;
using Rtfx.Runner;

namespace Rtfx.Tests;

public sealed class RunnerClientTests : IDisposable
{
    private readonly FakeRunner _runner = new();
    private static CancellationToken None => TestContext.Current.CancellationToken;

    public void Dispose() => _runner.Dispose();

    // ---------- health ----------

    [Fact]
    public async Task A_fresh_heartbeat_means_the_runner_is_up()
    {
        _runner.Heartbeat(TimeSpan.FromSeconds(4));

        var health = await _runner.Client.HealthAsync(None);

        Assert.True((bool)health["running"]!);
        Assert.Equal("9.9.9", (string?)health["version"]);
        Assert.Equal(1, (int)health["jobsRunning"]!);
        Assert.Equal(2, (int)health["jobsQueued"]!);
        Assert.False(health.ContainsKey("problem"));
    }

    [Fact]
    public async Task A_stale_heartbeat_says_the_runner_is_down_and_how_to_start_it()
    {
        _runner.Heartbeat(TimeSpan.FromHours(3));

        var health = await _runner.Client.HealthAsync(None);

        Assert.False((bool)health["running"]!);
        Assert.Contains("is not running", (string)health["problem"]!);
        Assert.Contains("3 hours", (string)health["problem"]!);
        Assert.Contains("install-task.ps1", (string)health["problem"]!);
    }

    [Fact]
    public async Task No_heartbeat_at_all_says_the_runner_is_not_installed_there()
    {
        var health = await _runner.Client.HealthAsync(None);

        Assert.False((bool)health["running"]!);
        Assert.Contains("never written a heartbeat", (string)health["problem"]!);
    }

    // ---------- submit ----------

    [Fact]
    public async Task A_read_job_is_written_as_job_task_and_status()
    {
        _runner.Heartbeat(TimeSpan.Zero);

        var submitted = await _runner.Client.SubmitAsync([FakeRunner.Request("some-repo", "read")], None);

        var id = (string)submitted[0]!["job_id"]!;
        Assert.Equal("queued", (string?)submitted[0]!["state"]);
        Assert.Equal("some-repo", (string?)_runner.Read($"jobs/{id}/job.json")["repo"]);
        Assert.Equal(id, (string?)_runner.Read($"jobs/{id}/job.json")["id"]);
        Assert.Equal("Do the thing.", File.ReadAllText(_runner.PathOf($"jobs/{id}/task.md")));
        Assert.Equal("queued", (string?)_runner.Read($"jobs/{id}/status.json")["state"]);
        Assert.Empty(Directory.GetFileSystemEntries(Path.Combine(_runner.Config.Cache, "outbox")));
    }

    [Fact]
    public async Task A_write_job_commits_as_the_local_checkout_does()
    {
        _runner.Heartbeat(TimeSpan.Zero);
        _runner.Checkout("demo", "Some One", "some.one@example.invalid");

        var submitted = await _runner.Client.SubmitAsync([FakeRunner.Request("demo")], None);

        var job = _runner.Read($"jobs/{(string)submitted[0]!["job_id"]!}/job.json");
        Assert.Equal("Some One", (string?)job["gitName"]);
        Assert.Equal("some.one@example.invalid", (string?)job["gitEmail"]);
    }

    [Fact]
    public async Task A_write_job_without_a_local_checkout_is_refused_before_anything_is_sent()
    {
        _runner.Heartbeat(TimeSpan.Zero);

        var error = await Assert.ThrowsAsync<InvalidRequestException>(() => _runner.Client.SubmitAsync([FakeRunner.Request("demo")], None));

        Assert.Contains("no checkout of demo", error.Message);
        Assert.Empty(Directory.GetDirectories(_runner.PathOf("jobs")));
    }

    [Fact]
    public async Task Nothing_is_submitted_while_the_runner_is_down()
    {
        _runner.Heartbeat(TimeSpan.FromMinutes(30));

        var error = await Assert.ThrowsAsync<RunnerException>(() => _runner.Client.SubmitAsync([FakeRunner.Request("some-repo", "read")], None));

        Assert.Contains("is not running", error.Message);
        Assert.Empty(Directory.GetDirectories(_runner.PathOf("jobs")));
    }

    // ---------- wait ----------

    [Fact]
    public async Task Wait_returns_at_once_when_every_job_has_ended()
    {
        _runner.Status("one", "done", status => status["credits"] = 1.5);
        _runner.Status("two", "failed", status => status["error"] = "it broke");

        var waited = await _runner.Client.WaitAsync(["one", "two"], TimeSpan.FromSeconds(30), None);

        Assert.True((bool)waited["all_done"]!);
        Assert.Equal("done", (string?)waited["jobs"]![0]!["state"]);
        Assert.Equal(1.5, (double)waited["jobs"]![0]!["credits"]!);
        Assert.Equal("it broke", (string?)waited["jobs"]![1]!["error"]);
    }

    [Fact]
    public async Task Wait_reads_the_index_before_asking_for_each_job()
    {
        _runner.Write("index.json", new JsonObject { ["jobs"] = new JsonArray(new JsonObject { ["id"] = "listed", ["state"] = "done", ["repo"] = "demo" }) });

        var waited = await _runner.Client.WaitAsync(["listed"], TimeSpan.FromSeconds(30), None);

        Assert.True((bool)waited["all_done"]!);
        Assert.Equal("demo", (string?)waited["jobs"]![0]!["repo"]);
    }

    [Fact]
    public async Task Wait_gives_up_at_the_timeout_and_says_what_is_still_going()
    {
        _runner.Heartbeat(TimeSpan.Zero);
        _runner.Status("slow", "running");
        _runner.Status("quick", "done");

        var waited = await _runner.Client.WaitAsync(["slow", "quick"], TimeSpan.FromMilliseconds(200), None);

        Assert.False((bool)waited["all_done"]!);
        Assert.Equal(1, (int)waited["still_going"]!);
        Assert.Equal("running", (string?)waited["jobs"]![0]!["state"]);
        Assert.False(waited.ContainsKey("runner"));
    }

    [Fact]
    public async Task Wait_points_at_a_stopped_runner_when_jobs_are_left()
    {
        _runner.Heartbeat(TimeSpan.FromHours(1));
        _runner.Status("stuck", "queued");

        var waited = await _runner.Client.WaitAsync(["stuck"], TimeSpan.Zero, None);

        Assert.Contains("is not running", (string)waited["runner"]!["problem"]!);
    }

    [Fact]
    public async Task Wait_sees_a_job_end_while_it_waits()
    {
        _runner.Status("soon", "running");
        var finishing = Task.Run(async () =>
        {
            await Task.Delay(700);
            _runner.Status("soon", "done");
        }, None);

        var waited = await _runner.Client.WaitAsync(["soon"], TimeSpan.FromSeconds(30), None);
        await finishing;

        Assert.True((bool)waited["all_done"]!);
    }

    [Fact]
    public async Task An_unknown_job_is_reported_not_waited_for()
    {
        var waited = await _runner.Client.WaitAsync(["nope"], TimeSpan.FromSeconds(30), None);

        Assert.Equal("unknown", (string?)waited["jobs"]![0]!["state"]);
        Assert.True((bool)waited["all_done"]!);
    }

    // ---------- result and diff ----------

    [Fact]
    public async Task A_result_is_digested_with_the_report_and_without_the_bookkeeping()
    {
        _runner.Write("jobs/j1/result.json", new JsonObject
        {
            ["id"] = "j1", ["state"] = "done", ["repo"] = "demo", ["mode"] = "write", ["credits"] = 1.13, ["finalMessage"] = "## Summary\nDone.",
            ["envStripped"] = new JsonArray("BB_TOKEN"), ["sessionId"] = "abc", ["exitCode"] = 0,
            ["commits"] = new JsonArray(new JsonObject { ["hash"] = "h", ["subject"] = "s" }), ["warnings"] = new JsonArray(),
            ["guards"] = new JsonObject { ["pushBlocked"] = true },
        });

        var digest = RunnerClient.Digest(await _runner.Client.ResultAsync("j1", None));

        Assert.Equal("j1", (string?)digest["job_id"]);
        Assert.Equal("## Summary\nDone.", (string?)digest["report"]);
        Assert.Equal(1.13, (double)digest["credits"]!);
        Assert.True((bool)digest["guards"]!["pushBlocked"]!);
        Assert.False(digest.ContainsKey("envStripped"));
        Assert.False(digest.ContainsKey("sessionId"));
        Assert.False(digest.ContainsKey("finalMessage"));
    }

    [Fact]
    public async Task Asking_for_the_result_of_a_running_job_says_it_is_running()
    {
        _runner.Status("busy", "running");

        var error = await Assert.ThrowsAsync<RunnerException>(() => _runner.Client.ResultAsync("busy", None));

        Assert.Contains("has no result yet: it is running", error.Message);
    }

    [Fact]
    public async Task Asking_for_a_job_that_does_not_exist_says_so()
    {
        var error = await Assert.ThrowsAsync<RunnerException>(() => _runner.Client.ResultAsync("nope", None));
        Assert.Contains("has no job nope", error.Message);
    }

    [Fact]
    public async Task The_diff_comes_from_the_patch_file_whole_or_by_path()
    {
        const string patch = "diff --git a/a.txt b/a.txt\n--- a/a.txt\n+++ b/a.txt\n@@ -1 +1 @@\n+a\ndiff --git a/dir/b.txt b/dir/b.txt\n--- a/dir/b.txt\n+++ b/dir/b.txt\n@@ -1 +1 @@\n+b\n";
        _runner.WriteText("jobs/j2/result.patch", patch);

        Assert.Equal(patch, await _runner.Client.DiffAsync("j2", null, None));
        Assert.StartsWith("diff --git a/dir/b.txt", await _runner.Client.DiffAsync("j2", "dir", None));
    }

    [Fact]
    public async Task A_read_job_has_no_diff_and_the_message_says_why()
    {
        _runner.Write("jobs/j3/result.json", new JsonObject { ["id"] = "j3", ["state"] = "done", ["mode"] = "read" });

        var error = await Assert.ThrowsAsync<RunnerException>(() => _runner.Client.DiffAsync("j3", null, None));

        Assert.Contains("it was a read job", error.Message);
    }

    // ---------- abort and discard ----------

    [Fact]
    public async Task Discard_leaves_the_marker_the_runner_looks_for()
    {
        _runner.Status("old", "done");

        var outcome = await _runner.Client.DiscardAsync("old", None);

        Assert.True((bool)outcome["discarded"]!);
        Assert.Contains("discarded", File.ReadAllText(_runner.PathOf("jobs/old/fetched")));
    }

    [Fact]
    public async Task A_running_job_cannot_be_discarded()
    {
        _runner.Status("busy", "running");

        var error = await Assert.ThrowsAsync<RunnerException>(() => _runner.Client.DiscardAsync("busy", None));

        Assert.Contains("abort it first", error.Message);
        Assert.False(File.Exists(_runner.PathOf("jobs/busy/fetched")));
    }

    [Fact]
    public async Task Abort_of_a_job_that_has_ended_changes_nothing()
    {
        _runner.Status("over", "done");

        var outcome = await _runner.Client.AbortAsync("over", None);

        Assert.Contains("already ended", (string)outcome["note"]!);
        Assert.False(File.Exists(_runner.PathOf("jobs/over/cancel")));
    }

    // ---------- fetch ----------

    /// <summary>A finished write job as the runner leaves it: a bundle of one commit on rtfx/job, and the result describing it.</summary>
    private (string Checkout, string Head) FinishedWriteJob(string id)
    {
        var checkout = _runner.Checkout("demo");
        var baseCommit = FakeRunner.Git(checkout, "rev-parse", "HEAD");
        // The job's work is made in a second clone, standing in for the worktree on the other machine.
        var elsewhere = Path.Combine(_runner.Home, "elsewhere");
        FakeRunner.Git(_runner.Home, "clone", "--quiet", checkout, elsewhere);
        FakeRunner.Git(elsewhere, "checkout", "--quiet", "-b", $"rtfx/{id}");
        File.WriteAllText(Path.Combine(elsewhere, "added.txt"), "added by the job\n");
        FakeRunner.Git(elsewhere, "add", "added.txt");
        FakeRunner.Git(elsewhere, "-c", "user.name=Job", "-c", "user.email=job@example.invalid", "commit", "--quiet", "-m", "Add a file");
        var head = FakeRunner.Git(elsewhere, "rev-parse", "HEAD");
        var bundle = _runner.PathOf($"jobs/{id}/result.bundle");
        Directory.CreateDirectory(Path.GetDirectoryName(bundle)!);
        FakeRunner.Git(elsewhere, "bundle", "create", bundle, $"{baseCommit}..refs/heads/rtfx/{id}");

        _runner.Status(id, "done");
        _runner.Write($"jobs/{id}/result.json", new JsonObject
        {
            ["id"] = id, ["state"] = "done", ["repo"] = "demo", ["mode"] = "write", ["baseCommit"] = baseCommit, ["headCommit"] = head,
            ["commits"] = new JsonArray(new JsonObject { ["hash"] = head, ["subject"] = "Add a file" }),
            ["bundle"] = new JsonObject
            {
                ["file"] = "result.bundle", ["ref"] = $"refs/heads/rtfx/{id}",
                ["sha256"] = Convert.ToHexStringLower(SHA256.HashData(File.ReadAllBytes(bundle))),
            },
        });
        return (checkout, head);
    }

    [Fact]
    public async Task Fetch_adds_the_branch_and_touches_nothing_else()
    {
        var (checkout, head) = FinishedWriteJob("w1");

        var outcome = await _runner.Client.FetchAsync("w1", null, None);

        Assert.Equal("rtfx/w1", (string?)outcome["branch"]);
        Assert.False((bool)outcome["already_there"]!);
        Assert.Equal(head, FakeRunner.Git(checkout, "rev-parse", "rtfx/w1"));
        Assert.Equal("main", FakeRunner.Git(checkout, "symbolic-ref", "--short", "HEAD"));
        Assert.Equal("", FakeRunner.Git(checkout, "status", "--porcelain"));
        Assert.False(File.Exists(Path.Combine(checkout, "added.txt")));
        Assert.Contains("fetched", File.ReadAllText(_runner.PathOf("jobs/w1/fetched")));
    }

    [Fact]
    public async Task Fetch_can_give_the_branch_another_name()
    {
        var (checkout, head) = FinishedWriteJob("w2");

        var outcome = await _runner.Client.FetchAsync("w2", "feature/from-copilot", None);

        Assert.Equal("feature/from-copilot", (string?)outcome["branch"]);
        Assert.Equal(head, FakeRunner.Git(checkout, "rev-parse", "feature/from-copilot"));
        Assert.Throws<InvalidOperationException>(() => FakeRunner.Git(checkout, "rev-parse", "--verify", "--quiet", "refs/heads/rtfx/w2"));
    }

    [Fact]
    public async Task Fetch_refuses_a_branch_that_already_exists_elsewhere()
    {
        var (checkout, _) = FinishedWriteJob("w3");
        FakeRunner.Git(checkout, "branch", "rtfx/w3", "main");
        var before = FakeRunner.Git(checkout, "rev-parse", "rtfx/w3");

        var error = await Assert.ThrowsAsync<RunnerException>(() => _runner.Client.FetchAsync("w3", null, None));

        Assert.Contains("already has a branch rtfx/w3", error.Message);
        Assert.Equal(before, FakeRunner.Git(checkout, "rev-parse", "rtfx/w3"));
        Assert.False(File.Exists(_runner.PathOf("jobs/w3/fetched")));
    }

    [Fact]
    public async Task Fetching_twice_is_harmless()
    {
        FinishedWriteJob("w4");
        await _runner.Client.FetchAsync("w4", null, None);

        var again = await _runner.Client.FetchAsync("w4", null, None);

        Assert.True((bool)again["already_there"]!);
    }

    [Fact]
    public async Task A_damaged_bundle_is_not_fetched()
    {
        var (checkout, _) = FinishedWriteJob("w5");
        File.AppendAllText(_runner.PathOf("jobs/w5/result.bundle"), "garbage");

        var error = await Assert.ThrowsAsync<RunnerException>(() => _runner.Client.FetchAsync("w5", null, None));

        Assert.Contains("arrived damaged", error.Message);
        Assert.Throws<InvalidOperationException>(() => FakeRunner.Git(checkout, "rev-parse", "--verify", "--quiet", "refs/heads/rtfx/w5"));
    }

    [Fact]
    public async Task A_job_without_a_bundle_says_why_there_is_nothing_to_fetch()
    {
        _runner.Write("jobs/w6/result.json", new JsonObject
        {
            ["id"] = "w6", ["state"] = "done", ["repo"] = "demo", ["warnings"] = new JsonArray("the branch has no commits beyond its base, so there is no bundle"),
        });

        var error = await Assert.ThrowsAsync<RunnerException>(() => _runner.Client.FetchAsync("w6", null, None));

        Assert.Contains("nothing to fetch", error.Message);
        Assert.Contains("no commits", error.Message);
    }

    // ---------- transport ----------

    [Theory]
    [InlineData("scp: C:/rtfx/jobs/x/result.json: No such file or directory", true)]
    [InlineData("The system cannot find the file specified.", true)]
    [InlineData("ssh: connect to host rtfx-worker port 22: Connection timed out", false)]
    public void A_missing_file_is_told_apart_from_a_failed_connection(string stderr, bool missing)
    {
        Assert.Equal(missing, ScpTransport.Missing().IsMatch(stderr));
        Assert.Equal(!missing, ScpTransport.ConnectionTrouble().IsMatch(stderr));
    }

    [Theory]
    [InlineData("logs.ps1", "-Id", true)]
    [InlineData("logs.ps1", "x; Remove-Item y", false)]
    [InlineData("logs.ps1", "$(whoami)", false)]
    [InlineData("../logs.ps1", "-Id", false)]
    [InlineData("logs.sh", "-Id", false)]
    public void Only_plain_arguments_reach_a_runner_script(string script, string argument, bool allowed)
    {
        if (allowed)
        {
            RunnerTransport.CheckScriptArguments(script, [argument]);
        }
        else
        {
            Assert.Throws<RunnerException>(() => RunnerTransport.CheckScriptArguments(script, [argument]));
        }
    }
}
