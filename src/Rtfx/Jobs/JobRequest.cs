using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace Rtfx.Jobs;

/// <summary>
/// One job as a caller asks for it. <see cref="Parse"/> reads it from a tool's arguments and
/// applies the defaults; <see cref="Validate"/> holds it to the same rules the runner applies,
/// so a mistake is reported here in a sentence instead of as a failed job on the other machine.
/// </summary>
public sealed partial record JobRequest(
    string Brief,
    string Repo,
    string Mode,
    string Model,
    string Effort,
    int MaxCredits,
    double TimeoutMin,
    string? Base = null,
    string? Commit = null,
    string? Ticket = null,
    string? Branch = null,
    IReadOnlyList<string>? AllowTools = null)
{
    public const int MinCredits = 30;
    public const int MaxCreditsCeiling = 200;
    public const double MaxTimeoutMin = 240;

    public static readonly string[] Efforts = ["none", "minimal", "low", "medium", "high", "xhigh", "max"];
    public static readonly string[] TerminalStates = ["done", "failed", "cancelled", "timeout"];

    public bool IsWrite => Mode == "write";

    public static JobRequest Parse(JsonObject arguments, RtfxConfig config)
    {
        var request = new JobRequest(
            Brief: Arguments.String(arguments, "task") ?? "",
            Repo: Arguments.String(arguments, "repo") ?? "",
            Mode: Arguments.String(arguments, "mode") ?? RtfxConfig.DefaultMode,
            Model: Arguments.String(arguments, "model") ?? config.DefaultModel,
            Effort: Arguments.String(arguments, "effort") ?? RtfxConfig.DefaultEffort,
            MaxCredits: Arguments.Integer(arguments, "max_credits") ?? RtfxConfig.DefaultMaxCredits,
            TimeoutMin: Arguments.Number(arguments, "timeout_min") ?? RtfxConfig.DefaultTimeoutMin,
            Base: Arguments.String(arguments, "base"),
            Commit: Arguments.String(arguments, "commit"),
            Ticket: Arguments.String(arguments, "ticket"),
            Branch: Arguments.String(arguments, "branch"),
            AllowTools: Arguments.Strings(arguments, "allow_tools"));
        request.Validate();
        return request;
    }

    public void Validate()
    {
        if (string.IsNullOrWhiteSpace(Brief))
        {
            throw new InvalidRequestException("task is empty: it is the brief the job works from.");
        }

        if (!RepoName().IsMatch(Repo) || Repo.Contains("..", StringComparison.Ordinal))
        {
            throw new InvalidRequestException($"repo '{Repo}' is not a plain folder name such as my-repo.");
        }

        if (Mode is not ("read" or "write"))
        {
            throw new InvalidRequestException($"mode '{Mode}' must be read or write.");
        }

        if (Base is not null && (!BranchName().IsMatch(Base) || Base.Contains("..", StringComparison.Ordinal)))
        {
            throw new InvalidRequestException($"base '{Base}' is not a valid branch name.");
        }

        if (Commit is not null && !CommitHash().IsMatch(Commit))
        {
            throw new InvalidRequestException($"commit '{Commit}' is not a commit hash: 7 to 64 lowercase hex digits.");
        }

        if (!ModelId().IsMatch(Model))
        {
            throw new InvalidRequestException($"model '{Model}' is not a model id. The models tool lists them.");
        }

        if (!Efforts.Contains(Effort))
        {
            throw new InvalidRequestException($"effort '{Effort}' must be one of {string.Join(", ", Efforts)}.");
        }

        if (MaxCredits is < MinCredits or > MaxCreditsCeiling)
        {
            throw new InvalidRequestException($"max_credits {MaxCredits} must be between {MinCredits} (Copilot's minimum) and {MaxCreditsCeiling} (the runner's ceiling).");
        }

        if (TimeoutMin is not (> 0 and <= MaxTimeoutMin))
        {
            throw new InvalidRequestException($"timeout_min {TimeoutMin} must be above 0 and at most {MaxTimeoutMin}.");
        }

        if (Ticket is not null && !TicketKey().IsMatch(Ticket))
        {
            throw new InvalidRequestException($"ticket '{Ticket}' is not a ticket key such as ABC-123.");
        }

        if (Branch is not null)
        {
            if (!BranchName().IsMatch(Branch) || Branch.Contains("..", StringComparison.Ordinal) || Branch.Contains("//", StringComparison.Ordinal)
                || Branch.EndsWith('/') || Branch.EndsWith(".lock", StringComparison.Ordinal) || Branch.Contains("/.", StringComparison.Ordinal))
            {
                throw new InvalidRequestException($"branch '{Branch}' is not a valid branch name.");
            }

            if (Branch == (Base ?? "main"))
            {
                throw new InvalidRequestException($"branch '{Branch}' is the base branch; a job works on a branch of its own.");
            }
        }

        foreach (var rule in AllowTools ?? [])
        {
            if (!AllowRule().IsMatch(rule))
            {
                throw new InvalidRequestException($"allow_tools entry '{rule}' is not a rule of the form kind or kind(argument), such as shell(cargo test).");
            }
        }
    }

    /// <summary>The job.json the runner reads. A write job carries the identity its commits are made under.</summary>
    public JsonObject ToJobJson(string id, string? gitName, string? gitEmail)
    {
        var job = new JsonObject
        {
            ["id"] = id,
            ["repo"] = Repo,
            ["mode"] = Mode,
            ["model"] = Model,
            ["effort"] = Effort,
            ["maxCredits"] = MaxCredits,
            ["timeoutMin"] = TimeoutMin,
        };
        if (Base is not null)
        {
            job["base"] = Base;
        }

        if (Commit is not null)
        {
            job["commit"] = Commit;
        }

        if (AllowTools is { Count: > 0 })
        {
            job["allowTools"] = Json.Array(AllowTools);
        }

        if (IsWrite)
        {
            job["gitName"] = gitName;
            job["gitEmail"] = gitEmail;
            if (Ticket is not null)
            {
                job["ticket"] = Ticket;
            }

            if (Branch is not null)
            {
                job["branch"] = Branch;
            }
        }

        return job;
    }

    public static bool IsValidId(string id) => JobId().IsMatch(id);

    public static string NewId(DateTime utcNow) => $"{utcNow:yyyyMMdd-HHmmss}-{Guid.NewGuid().ToString("N")[..4]}";

    [GeneratedRegex(@"^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$")]
    private static partial Regex JobId();

    [GeneratedRegex(@"^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$")]
    private static partial Regex RepoName();

    [GeneratedRegex(@"^[A-Za-z0-9][A-Za-z0-9._/-]{0,199}$")]
    private static partial Regex BranchName();

    [GeneratedRegex(@"^[0-9a-f]{7,64}$")]
    private static partial Regex CommitHash();

    [GeneratedRegex(@"^[A-Za-z0-9][A-Za-z0-9._:-]{0,79}$")]
    private static partial Regex ModelId();

    [GeneratedRegex(@"^[A-Z][A-Z0-9]{1,9}-[0-9]{1,7}$")]
    private static partial Regex TicketKey();

    [GeneratedRegex(@"^[A-Za-z0-9_.-]{1,60}(\([A-Za-z0-9 _.:*/-]{1,80}\))?$")]
    private static partial Regex AllowRule();
}

/// <summary>Reads a tool's arguments, and says which one is wrong when one is.</summary>
public static class Arguments
{
    public static string? String(JsonObject arguments, string name) => arguments[name] switch
    {
        null => null,
        JsonValue value when value.TryGetValue<string>(out var text) => text.Length == 0 ? null : text,
        _ => throw new InvalidRequestException($"{name} must be a string."),
    };

    public static string RequiredString(JsonObject arguments, string name) =>
        String(arguments, name) ?? throw new InvalidRequestException($"{name} is required.");

    public static double? Number(JsonObject arguments, string name) => arguments[name] switch
    {
        null => null,
        JsonValue value when Json.TryNumber(value, out var number) => number,
        JsonValue value when value.TryGetValue<string>(out var text) && double.TryParse(text, System.Globalization.CultureInfo.InvariantCulture, out var parsed) => parsed,
        _ => throw new InvalidRequestException($"{name} must be a number."),
    };

    public static int? Integer(JsonObject arguments, string name) => Number(arguments, name) switch
    {
        null => null,
        { } number when number == Math.Floor(number) && Math.Abs(number) < int.MaxValue => (int)number,
        _ => throw new InvalidRequestException($"{name} must be a whole number."),
    };

    public static bool? Boolean(JsonObject arguments, string name) => arguments[name] switch
    {
        null => null,
        JsonValue value when value.TryGetValue<bool>(out var flag) => flag,
        _ => throw new InvalidRequestException($"{name} must be true or false."),
    };

    public static IReadOnlyList<string>? Strings(JsonObject arguments, string name)
    {
        if (arguments[name] is null)
        {
            return null;
        }

        if (arguments[name] is not JsonArray array)
        {
            throw new InvalidRequestException($"{name} must be a list of strings.");
        }

        var items = new List<string>();
        foreach (var item in array)
        {
            items.Add(item is JsonValue value && value.TryGetValue<string>(out var text) ? text : throw new InvalidRequestException($"{name} must be a list of strings."));
        }

        return items;
    }

    public static string JobId(JsonObject arguments, string name = "job_id")
    {
        var id = RequiredString(arguments, name);
        return JobRequest.IsValidId(id) ? id : throw new InvalidRequestException($"{name} '{id}' is not a job id: letters, digits, - and _ only.");
    }
}

/// <summary>JsonNode without the generic overloads, which need runtime code generation and fail a Native AOT build.</summary>
public static class Json
{
    public static readonly System.Text.Json.JsonSerializerOptions Indented = new() { WriteIndented = true };

    public static JsonArray Array(IEnumerable<string> items) => new([.. items.Select(item => (JsonNode?)JsonValue.Create(item))]);

    public static JsonArray Array(IEnumerable<JsonNode?> items) => new([.. items]);

    /// <summary>A copy of the named properties of <paramref name="source"/>, in the order given, leaving out the ones it does not have.</summary>
    public static JsonObject Pick(JsonObject source, params string[] names)
    {
        var picked = new JsonObject();
        foreach (var name in names)
        {
            if (source.TryGetPropertyValue(name, out var value))
            {
                picked[name] = value?.DeepClone();
            }
        }

        return picked;
    }

    /// <summary>A JSON number as a double, whether it was parsed from text or made in memory from an int, a long or a double.</summary>
    public static bool TryNumber(JsonNode? node, out double number)
    {
        number = 0;
        if (node is not JsonValue value)
        {
            return false;
        }

        if (value.TryGetValue(out number))
        {
            return true;
        }

        if (value.TryGetValue<long>(out var whole))
        {
            number = whole;
            return true;
        }

        if (value.TryGetValue<int>(out var small))
        {
            number = small;
            return true;
        }

        return false;
    }

    public static string? Text(JsonNode? node) => node is JsonValue value && value.TryGetValue<string>(out var text) ? text : node?.ToString();

    public static string Pretty(JsonNode node) => node.ToJsonString(Indented);
}
