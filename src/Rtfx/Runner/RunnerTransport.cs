using System.Text.RegularExpressions;

namespace Rtfx.Runner;

/// <summary>
/// How files reach the runner's root and come back. A job is a folder of files, so submitting,
/// polling, cancelling and fetching are all copies; the one remote command is a runner script
/// that reads a log's tail, because the alternative is downloading the whole log.
/// </summary>
public interface IRunnerTransport
{
    /// <summary>Copies one file to <paramref name="relative"/> under the runner's root.</summary>
    Task UploadFileAsync(string localPath, string relative, CancellationToken cancellationToken);

    /// <summary>
    /// Copies folders into <paramref name="relativeParent"/> in one go; each keeps its own name. A folder that
    /// is already there is added to, not replaced.
    /// </summary>
    Task UploadDirectoriesAsync(IReadOnlyList<string> localDirectories, string relativeParent, CancellationToken cancellationToken);

    /// <summary>Downloads one file. False when it is not there.</summary>
    Task<bool> DownloadAsync(string relative, string localPath, CancellationToken cancellationToken);

    /// <summary>Runs one of the runner's own scripts and returns what it printed.</summary>
    Task<string> RunScriptAsync(string script, IReadOnlyList<string> arguments, CancellationToken cancellationToken);
}

public static class RunnerTransport
{
    public static IRunnerTransport For(RtfxConfig config) =>
        config.IsLocal ? new LocalTransport(config.RemoteRoot, config.RunnerScripts) : new ScpTransport(config.RemoteHost, config.RemoteRoot);

    /// <summary>Script arguments travel inside one ssh command string, so they are held to characters no shell reads as syntax.</summary>
    internal static void CheckScriptArguments(string script, IReadOnlyList<string> arguments)
    {
        if (!Regex.IsMatch(script, @"^[a-z][a-z0-9-]{0,30}\.ps1$"))
        {
            throw new RunnerException($"'{script}' is not a runner script name.");
        }

        foreach (var argument in arguments)
        {
            if (!Regex.IsMatch(argument, @"^[A-Za-z0-9_.-]{1,80}$"))
            {
                throw new RunnerException($"'{argument}' cannot be passed to a runner script.");
            }
        }
    }
}

/// <summary>The real thing: scp and ssh to the Copilot machine, retried because that connection drops now and then.</summary>
public sealed partial class ScpTransport(string host, string root, int tries = 4) : IRunnerTransport
{
    private static readonly string[] Options = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=20"];
    private static readonly TimeSpan CopyTimeout = TimeSpan.FromMinutes(10);

    private string Remote(string relative) => $"{host}:{root}/{relative.Replace('\\', '/').TrimStart('/')}";

    public async Task UploadFileAsync(string localPath, string relative, CancellationToken cancellationToken)
    {
        if (!await CopyAsync([localPath, Remote(relative)], cancellationToken).ConfigureAwait(false))
        {
            throw new RunnerException($"could not copy to {Remote(relative)}: the folder is not there.");
        }
    }

    public async Task UploadDirectoriesAsync(IReadOnlyList<string> localDirectories, string relativeParent, CancellationToken cancellationToken)
    {
        if (!await CopyAsync(["-r", .. localDirectories, Remote(relativeParent)], cancellationToken).ConfigureAwait(false))
        {
            throw new RunnerException($"could not copy to {Remote(relativeParent)}: the folder is not there.");
        }
    }

    public Task<bool> DownloadAsync(string relative, string localPath, CancellationToken cancellationToken)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(localPath)!);
        return CopyAsync([Remote(relative), localPath], cancellationToken);
    }

    public async Task<string> RunScriptAsync(string script, IReadOnlyList<string> arguments, CancellationToken cancellationToken)
    {
        RunnerTransport.CheckScriptArguments(script, arguments);
        var command = $"pwsh -NoProfile -File {root}/{script} {string.Join(' ', arguments)}".TrimEnd();
        ProcessResult result = new(255, "", "");
        for (var attempt = 1; attempt <= tries; attempt++)
        {
            result = await ProcessRunner.RunAsync("ssh", [.. Options, host, command], TimeSpan.FromMinutes(2), cancellationToken).ConfigureAwait(false);
            if (result.ExitCode == 0)
            {
                return result.Output;
            }

            // 255 is ssh's own failure; anything else is the script saying no, which a retry will not change.
            if (result.ExitCode != 255)
            {
                throw new RunnerException($"{script} on {host} failed: {FirstLine(result.Message)}");
            }

            await Task.Delay(TimeSpan.FromSeconds(2 * attempt), cancellationToken).ConfigureAwait(false);
        }

        throw Unreachable(result);
    }

    /// <summary>One scp, retried. False when the remote file does not exist; anything else that fails throws.</summary>
    private async Task<bool> CopyAsync(string[] fromTo, CancellationToken cancellationToken)
    {
        ProcessResult result = new(1, "", "");
        for (var attempt = 1; attempt <= tries; attempt++)
        {
            result = await ProcessRunner.RunAsync("scp", ["-q", .. Options, .. fromTo], CopyTimeout, cancellationToken).ConfigureAwait(false);
            if (result.ExitCode == 0)
            {
                return true;
            }

            if (Missing().IsMatch(result.Message))
            {
                return false;
            }

            await Task.Delay(TimeSpan.FromSeconds(2 * attempt), cancellationToken).ConfigureAwait(false);
        }

        throw Unreachable(result);
    }

    private RunnerException Unreachable(ProcessResult result)
    {
        var said = FirstLine(result.Message);
        return ConnectionTrouble().IsMatch(result.Message) || said.Length == 0
            ? new RunnerUnreachableException($"cannot reach {host} over ssh after {tries} tries ({(said.Length == 0 ? "no error text" : said)}). Is the machine on and on the network?")
            : new RunnerException($"copying to or from {host} failed after {tries} tries: {said}");
    }

    private static string FirstLine(string text) => text.Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries).FirstOrDefault() ?? "";

    [GeneratedRegex("no such file|cannot find|not a regular file", RegexOptions.IgnoreCase)]
    internal static partial Regex Missing();

    [GeneratedRegex("timed out|could not resolve|connection refused|no route to host|connection closed|connection reset|permission denied|host key|network is unreachable", RegexOptions.IgnoreCase)]
    internal static partial Regex ConnectionTrouble();
}

/// <summary>The runner's root as a local folder, for tests: the same operations as file copies.</summary>
public sealed class LocalTransport(string root, string? scripts) : IRunnerTransport
{
    private string Local(string relative) => Path.Combine(root.Replace('/', Path.DirectorySeparatorChar), relative.Replace('/', Path.DirectorySeparatorChar));

    public Task UploadFileAsync(string localPath, string relative, CancellationToken cancellationToken)
    {
        // Copy then rename, so the runner never reads half a file.
        var target = Local(relative);
        File.Copy(localPath, target + ".part", overwrite: true);
        File.Move(target + ".part", target, overwrite: true);
        return Task.CompletedTask;
    }

    public Task UploadDirectoriesAsync(IReadOnlyList<string> localDirectories, string relativeParent, CancellationToken cancellationToken)
    {
        foreach (var localDirectory in localDirectories)
        {
            var target = Path.Combine(Local(relativeParent), Path.GetFileName(localDirectory.TrimEnd(Path.DirectorySeparatorChar)));
            Directory.CreateDirectory(target);
            foreach (var file in Directory.GetFiles(localDirectory))
            {
                // Copy then rename, so the runner never reads half a status.
                var destination = Path.Combine(target, Path.GetFileName(file));
                File.Copy(file, destination + ".part", overwrite: true);
                File.Move(destination + ".part", destination, overwrite: true);
            }
        }

        return Task.CompletedTask;
    }

    public Task<bool> DownloadAsync(string relative, string localPath, CancellationToken cancellationToken)
    {
        var source = Local(relative);
        if (!File.Exists(source))
        {
            return Task.FromResult(false);
        }

        Directory.CreateDirectory(Path.GetDirectoryName(localPath)!);
        // The runner may be rewriting the file this instant.
        for (var attempt = 0; ; attempt++)
        {
            try
            {
                File.Copy(source, localPath, overwrite: true);
                return Task.FromResult(true);
            }
            catch (IOException) when (attempt < 5)
            {
                Thread.Sleep(50);
            }
        }
    }

    public async Task<string> RunScriptAsync(string script, IReadOnlyList<string> arguments, CancellationToken cancellationToken)
    {
        RunnerTransport.CheckScriptArguments(script, arguments);
        if (scripts is null)
        {
            throw new RunnerException("RTFX_RUNNER_SCRIPTS is not set, so a local runner root has no scripts to run.");
        }

        var result = await ProcessRunner.RunAsync(
            "pwsh", ["-NoProfile", "-File", Path.Combine(scripts, script), .. arguments, "-Root", Local("")], TimeSpan.FromMinutes(2), cancellationToken).ConfigureAwait(false);
        return result.ExitCode == 0 ? result.Output : throw new RunnerException($"{script} failed: {result.Message}");
    }
}
