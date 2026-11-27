using System.ComponentModel;
using System.Diagnostics;
using System.Text;

namespace Rtfx;

public sealed record ProcessResult(int ExitCode, string Output, string Error)
{
    /// <summary>What the program said went wrong: its stderr, or its stdout when stderr is empty.</summary>
    public string Message => (Error.Trim() is { Length: > 0 } error ? error : Output.Trim());
}

/// <summary>Runs scp, ssh, git and pwsh. Nothing here goes through a shell, so arguments are never re-parsed.</summary>
public static class ProcessRunner
{
    public static async Task<ProcessResult> RunAsync(
        string file, IEnumerable<string> arguments, TimeSpan timeout, CancellationToken cancellationToken, string? workingDirectory = null)
    {
        var info = new ProcessStartInfo(file)
        {
            // Redirected and closed at once: in `rtfx mcp` this process's own stdin is the MCP protocol,
            // and a child that inherited it (ssh reads stdin) would swallow requests meant for the server.
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
            UseShellExecute = false,
            CreateNoWindow = true,
        };
        if (workingDirectory is not null)
        {
            info.WorkingDirectory = workingDirectory;
        }

        foreach (var argument in arguments)
        {
            info.ArgumentList.Add(argument);
        }

        using var process = new Process { StartInfo = info };
        try
        {
            process.Start();
        }
        catch (Win32Exception ex)
        {
            throw new RunnerException($"cannot start {file}: {ex.Message}. Is it installed and on PATH?");
        }

        process.StandardInput.Close();
        var output = process.StandardOutput.ReadToEndAsync(CancellationToken.None);
        var error = process.StandardError.ReadToEndAsync(CancellationToken.None);

        using var limit = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        limit.CancelAfter(timeout);
        try
        {
            await process.WaitForExitAsync(limit.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            try
            {
                process.Kill(entireProcessTree: true);
            }
            catch (InvalidOperationException)
            {
                // It exited between the timeout and the kill.
            }

            cancellationToken.ThrowIfCancellationRequested();
            throw new RunnerException($"{file} did not finish within {timeout.TotalSeconds:0} seconds.");
        }

        return new ProcessResult(process.ExitCode, await output.ConfigureAwait(false), await error.ConfigureAwait(false));
    }
}

/// <summary>Something went wrong that the caller should read as a sentence: the message is shown to Claude as it is.</summary>
public class RunnerException(string message) : Exception(message);

/// <summary>The Copilot machine did not answer over ssh.</summary>
public sealed class RunnerUnreachableException(string message) : RunnerException(message);

/// <summary>What the caller asked for is not valid. Nothing was sent to the runner.</summary>
public sealed class InvalidRequestException(string message) : RunnerException(message);
