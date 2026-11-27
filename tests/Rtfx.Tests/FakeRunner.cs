using System.Diagnostics;
using System.Globalization;
using System.Text.Json.Nodes;
using Rtfx.Jobs;
using Rtfx.Runner;

namespace Rtfx.Tests;

/// <summary>
/// A runner's root as a temp folder, with the files a runner would have written put there by the
/// test. Nothing runs: these tests are about what the client reads and writes.
/// </summary>
public sealed class FakeRunner : IDisposable
{
    public FakeRunner()
    {
        Home = Path.Combine(Path.GetTempPath(), "rtfx-t", Guid.NewGuid().ToString("N")[..8]);
        Root = Directory.CreateDirectory(Path.Combine(Home, "root")).FullName;
        Repos = Directory.CreateDirectory(Path.Combine(Home, "repos")).FullName;
        Directory.CreateDirectory(Path.Combine(Root, "jobs"));
        Config = new RtfxConfig(".", Root.Replace('\\', '/'), Repos, Path.Combine(Home, "cache"), "test-model");
        Client = new RunnerClient(Config, RunnerTransport.For(Config));
    }

    public string Home { get; }

    public string Root { get; }

    public string Repos { get; }

    public RtfxConfig Config { get; }

    public RunnerClient Client { get; }

    public static string Stamp(DateTime utc) => utc.ToString("yyyy-MM-ddTHH:mm:ssZ", CultureInfo.InvariantCulture);

    public void Write(string relative, JsonNode content)
    {
        var file = Path.Combine(Root, relative.Replace('/', Path.DirectorySeparatorChar));
        Directory.CreateDirectory(Path.GetDirectoryName(file)!);
        File.WriteAllText(file, content.ToJsonString());
    }

    public void WriteText(string relative, string content)
    {
        var file = Path.Combine(Root, relative.Replace('/', Path.DirectorySeparatorChar));
        Directory.CreateDirectory(Path.GetDirectoryName(file)!);
        File.WriteAllText(file, content);
    }

    public string PathOf(string relative) => Path.Combine(Root, relative.Replace('/', Path.DirectorySeparatorChar));

    public JsonObject Read(string relative) => (JsonObject)JsonNode.Parse(File.ReadAllText(PathOf(relative)))!;

    /// <summary>A heartbeat as old as <paramref name="age"/>; none at all when null.</summary>
    public void Heartbeat(TimeSpan? age)
    {
        if (age is { } old)
        {
            Write("heartbeat.json", new JsonObject
            {
                ["at"] = Stamp(DateTime.UtcNow - old), ["pid"] = 1, ["version"] = "9.9.9", ["host"] = "fake",
                ["running"] = new JsonArray("a-job"), ["queued"] = 2, ["maxConcurrent"] = 3,
            });
        }
    }

    public void Status(string id, string state, Action<JsonObject>? more = null)
    {
        var status = new JsonObject { ["state"] = state, ["queuedAt"] = Stamp(DateTime.UtcNow) };
        more?.Invoke(status);
        Write($"jobs/{id}/status.json", status);
    }

    /// <summary>A local checkout with one commit on main and the given identity in its config.</summary>
    public string Checkout(string repo, string name = "Local Person", string email = "local@example.invalid")
    {
        var path = Directory.CreateDirectory(Path.Combine(Repos, repo)).FullName;
        Git(path, "init", "--quiet", "-b", "main");
        Git(path, "config", "user.name", name);
        Git(path, "config", "user.email", email);
        File.WriteAllText(Path.Combine(path, "README.md"), "# demo\n");
        Git(path, "add", "README.md");
        Git(path, "commit", "--quiet", "-m", "initial");
        return path;
    }

    public static string Git(string directory, params string[] arguments)
    {
        var info = new ProcessStartInfo("git") { RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false, CreateNoWindow = true };
        info.ArgumentList.Add("-C");
        info.ArgumentList.Add(directory);
        foreach (var argument in arguments)
        {
            info.ArgumentList.Add(argument);
        }

        using var process = Process.Start(info)!;
        var output = process.StandardOutput.ReadToEnd();
        var error = process.StandardError.ReadToEnd();
        process.WaitForExit();
        return process.ExitCode == 0 ? output.Trim() : throw new InvalidOperationException($"git {string.Join(' ', arguments)} failed: {error}");
    }

    public static JobRequest Request(string repo, string mode = "write") =>
        JobRequest.Parse(new JsonObject { ["task"] = "Do the thing.", ["repo"] = repo, ["mode"] = mode }, new RtfxConfig(".", "x", "x", "x", "test-model"));

    public void Dispose()
    {
        try
        {
            // git marks its object files read-only, which a plain recursive delete trips over on Windows.
            foreach (var file in Directory.EnumerateFiles(Home, "*", SearchOption.AllDirectories))
            {
                File.SetAttributes(file, FileAttributes.Normal);
            }

            Directory.Delete(Home, recursive: true);
        }
        catch (IOException)
        {
        }
        catch (UnauthorizedAccessException)
        {
        }
    }
}
