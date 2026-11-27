using System.Text.Json;
using System.Text.Json.Nodes;

namespace Rtfx;

/// <summary>Where the runner is, where this machine keeps its checkouts, and what a job gets when the caller does not say.</summary>
/// <param name="RemoteHost">ssh host of the Copilot machine. "." means <paramref name="RemoteRoot"/> is a local folder (tests).</param>
/// <param name="RemoteRoot">The runner's root there, with forward slashes.</param>
/// <param name="LocalRepos">The folder holding this machine's own checkouts: read for the commit identity, written by fetch.</param>
/// <param name="Cache">Where downloaded results, patches and bundles are kept.</param>
/// <param name="RunnerScripts">Only for "." hosts: where the runner's scripts are, since a local root does not hold them.</param>
public sealed record RtfxConfig(
    string RemoteHost,
    string RemoteRoot,
    string LocalRepos,
    string Cache,
    string DefaultModel,
    string? RunnerScripts = null)
{
    public const string DefaultEffort = "medium";
    public const string DefaultMode = "write";
    public const int DefaultMaxCredits = 60;
    public const double DefaultTimeoutMin = 45;

    /// <summary>The optional settings file, looked for next to the executable.</summary>
    public const string FileName = "config.json";

    /// <summary>The settings a <see cref="FileName"/> may hold, each with the variable that overrides it.</summary>
    private static readonly (string Key, string Variable)[] Settings =
    [
        ("remoteHost", "RTFX_HOST"),
        ("remoteRoot", "RTFX_ROOT"),
        ("localRepos", "RTFX_LOCAL_REPOS"),
        ("cache", "RTFX_CACHE"),
        ("defaultModel", "RTFX_DEFAULT_MODEL"),
    ];

    public bool IsLocal => RemoteHost == ".";

    /// <summary>The environment first, then <paramref name="file"/> (config.json next to the executable when null), then the defaults.</summary>
    /// <exception cref="InvalidOperationException">The file is not a JSON object of known settings.</exception>
    public static RtfxConfig FromEnvironment(Func<string, string?>? read = null, string? file = null)
    {
        read ??= Environment.GetEnvironmentVariable;
        var fromFile = ReadFile(file ?? Path.Combine(AppContext.BaseDirectory, FileName));
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var defaults = new Dictionary<string, string>
        {
            ["remoteHost"] = "rtfx-worker",
            ["remoteRoot"] = "C:/rtfx",
            ["localRepos"] = Path.Combine(home, "source", "repos"),
            ["cache"] = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "rtfx"),
            ["defaultModel"] = "gpt-6-luna",
        };

        string Setting(string key)
        {
            var variable = Settings.First(setting => setting.Key == key).Variable;
            if (read(variable) is { Length: > 0 } value)
            {
                return value;
            }

            return fromFile.TryGetValue(key, out var configured) ? configured : defaults[key];
        }

        return new RtfxConfig(
            RemoteHost: Setting("remoteHost"),
            RemoteRoot: Setting("remoteRoot").Replace('\\', '/').TrimEnd('/'),
            LocalRepos: Setting("localRepos"),
            Cache: Setting("cache"),
            DefaultModel: Setting("defaultModel"),
            RunnerScripts: read("RTFX_RUNNER_SCRIPTS") is { Length: > 0 } scripts ? scripts : null);
    }

    private static Dictionary<string, string> ReadFile(string file)
    {
        var values = new Dictionary<string, string>();
        if (!File.Exists(file))
        {
            return values;
        }

        JsonNode? parsed;
        try
        {
            parsed = JsonNode.Parse(File.ReadAllText(file), documentOptions: new JsonDocumentOptions { CommentHandling = JsonCommentHandling.Skip, AllowTrailingCommas = true });
        }
        catch (JsonException e)
        {
            throw new InvalidOperationException($"{file} is not valid JSON: {e.Message}");
        }

        if (parsed is not JsonObject settings)
        {
            throw new InvalidOperationException($"{file} must hold a JSON object of settings.");
        }

        foreach (var (key, value) in settings)
        {
            if (!Settings.Any(setting => setting.Key == key))
            {
                throw new InvalidOperationException($"{file}: unknown setting '{key}'. Known: {string.Join(", ", Settings.Select(setting => setting.Key))}.");
            }

            if (value is not JsonValue text || !text.TryGetValue<string>(out var configured) || configured.Length == 0)
            {
                throw new InvalidOperationException($"{file}: '{key}' must be a string that is not empty.");
            }

            values[key] = configured;
        }

        return values;
    }
}
