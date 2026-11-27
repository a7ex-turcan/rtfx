using System.Reflection;
using Rtfx.Mcp;
using Rtfx.Runner;

namespace Rtfx;

/// <summary>Dispatches to a mode of the single <c>rtfx</c> executable, by hand, as rtfc and rtfq do.</summary>
/// <remarks>In <c>rtfx mcp</c> stdout is the MCP protocol, so diagnostics only ever go to stderr.</remarks>
public static class EntryPoint
{
    public const int Ok = 0;
    public const int Failure = 1;
    public const int Usage = 2;

    public static string Version { get; } =
        typeof(EntryPoint).Assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion.Split('+')[0] ?? "0.0.0";

    private const string UsageText = """
        rtfx: hands coding jobs from Claude Code to GitHub Copilot CLI on another machine.

          rtfx mcp        run the MCP server on stdin and stdout (what Claude Code starts)
          rtfx version    print the version

        Settings come from the environment (RTFX_HOST, RTFX_ROOT, RTFX_LOCAL_REPOS, RTFX_CACHE,
        RTFX_DEFAULT_MODEL), then from config.json next to the executable. See the README.
        """;

    public static async Task<int> RunAsync(string[] args, TextReader stdin, TextWriter stdout, TextWriter stderr)
    {
        if (args is ["--version" or "version"])
        {
            stdout.WriteLine(Version);
            return Ok;
        }

        if (args is not ["mcp"])
        {
            stderr.WriteLine(UsageText);
            return Usage;
        }

        using var cancellation = new CancellationTokenSource();
        Console.CancelKeyPress += (_, e) =>
        {
            e.Cancel = true;
            cancellation.Cancel();
        };

        RtfxConfig config;
        try
        {
            config = RtfxConfig.FromEnvironment();
        }
        catch (InvalidOperationException e)
        {
            stderr.WriteLine($"rtfx: {e.Message}");
            return Failure;
        }

        var client = new RunnerClient(config, RunnerTransport.For(config));
        try
        {
            await new McpServer(client, stdin, stdout, stderr).RunAsync(cancellation.Token).ConfigureAwait(false);
            return Ok;
        }
        catch (OperationCanceledException)
        {
            return Ok;
        }
    }
}
