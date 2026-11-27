using System.Text.Json.Nodes;
using Rtfx.Mcp;
using Rtfx.Runner;

namespace Rtfx.Tests;

/// <summary>
/// Real jobs on the Copilot machine, through the MCP server's own request handling. They spend
/// credits (about one per run in all) and take a few minutes, so they run only when asked for:
///
///     $env:RTFX_INTEGRATION = '1'
///     $env:RTFX_INTEGRATION_REPO = 'my-repo'    # a repository both machines have
///     $env:RTFX_LOCAL_REPOS = 'C:\scratch\repos'       # where fetch may add a branch
///     dotnet test
///
/// RTFX_LOCAL_REPOS must be a scratch folder, never the real checkouts: the write test fetches a
/// branch into it and deletes that branch again.
/// </summary>
public sealed class IntegrationTests
{
    private static readonly string Repo = Environment.GetEnvironmentVariable("RTFX_INTEGRATION_REPO") ?? "";
    private static readonly bool Enabled = Environment.GetEnvironmentVariable("RTFX_INTEGRATION") == "1" && Repo.Length > 0;
    private static CancellationToken None => TestContext.Current.CancellationToken;

    private readonly RtfxConfig _config = RtfxConfig.FromEnvironment();
    private readonly McpServer _server;

    public IntegrationTests()
    {
        _server = new McpServer(new RunnerClient(_config, RunnerTransport.For(_config)), TextReader.Null, TextWriter.Null, TextWriter.Null);
    }

    private async Task<JsonObject> Call(string tool, JsonObject arguments)
    {
        var request = new JsonObject { ["jsonrpc"] = "2.0", ["id"] = 1, ["method"] = "tools/call", ["params"] = new JsonObject { ["name"] = tool, ["arguments"] = arguments } };
        var result = (JsonObject)(await _server.RespondAsync(request.ToJsonString(), None))!["result"]!;
        var text = (string)result["content"]![0]!["text"]!;
        Assert.False(result["isError"]?.GetValue<bool>() == true, $"{tool} failed: {text}");
        return tool == "diff" ? new JsonObject { ["text"] = text } : (JsonObject)JsonNode.Parse(text)!;
    }

    [Fact]
    public async Task The_runner_is_up()
    {
        Assert.SkipUnless(Enabled, "set RTFX_INTEGRATION=1 and RTFX_INTEGRATION_REPO to run real jobs");

        var status = await Call("status", []);

        Assert.True((bool)status["runner"]!["running"]!, status["runner"]!.ToJsonString());
    }

    [Fact]
    public async Task A_read_job_runs_and_reports()
    {
        Assert.SkipUnless(Enabled, "set RTFX_INTEGRATION=1 and RTFX_INTEGRATION_REPO to run real jobs");

        var started = await Call("delegate", new JsonObject
        {
            ["task"] = "Run `git log --oneline -1` and report the commit subject. Do nothing else.",
            ["repo"] = Repo, ["mode"] = "read", ["effort"] = "low", ["max_credits"] = 30, ["timeout_min"] = 10, ["wait_seconds"] = 540,
        });

        Assert.Equal("done", (string?)started["state"]);
        var result = (JsonObject)started["result"]!;
        Assert.False(string.IsNullOrWhiteSpace((string?)result["report"]));
        Assert.True((bool)result["guards"]!["pushBlocked"]!);
        Assert.True((double)result["credits"]! > 0);

        var logs = await Call("logs", new JsonObject { ["job_id"] = (string)started["job_id"]!, ["tail"] = 5 });
        Assert.Equal("done", (string?)logs["state"]);
        Assert.NotEmpty((JsonArray)logs["workerLog"]!);
    }

    [Fact]
    public async Task A_write_job_comes_back_as_a_branch()
    {
        Assert.SkipUnless(Enabled, "set RTFX_INTEGRATION=1 and RTFX_INTEGRATION_REPO to run real jobs");
        var checkout = Path.Combine(_config.LocalRepos, Repo);
        Assert.SkipUnless(_config.LocalRepos.Contains("scratch", StringComparison.OrdinalIgnoreCase),
            "RTFX_LOCAL_REPOS must point at a scratch folder: this test fetches a branch into it");

        var marker = "rtfx-integration-" + Guid.NewGuid().ToString("N")[..8];
        var started = await Call("delegate", new JsonObject
        {
            ["task"] = $"Create a file named {marker}.txt in the repository root containing the single line `{marker}`, and commit it. Do nothing else: no build, no tests.",
            ["repo"] = Repo, ["ticket"] = "RTFX-1", ["effort"] = "low", ["max_credits"] = 30, ["timeout_min"] = 10,
        });
        var id = (string)started["job_id"]!;

        var waited = await Call("wait", new JsonObject { ["job_ids"] = new JsonArray(id), ["timeout_s"] = 540 });
        Assert.True((bool)waited["all_done"]!, waited.ToJsonString());

        var result = await Call("result", new JsonObject { ["job_id"] = id });
        Assert.Equal("done", (string?)result["state"]);
        var commits = (JsonArray)result["commits"]!;
        Assert.NotEmpty(commits);
        Assert.All(commits, commit => Assert.StartsWith("RTFX-1: ", (string)commit!["subject"]!));
        Assert.Contains((JsonArray)result["filesChanged"]!, file => (string?)file!["path"] == $"{marker}.txt");

        var diff = await Call("diff", new JsonObject { ["job_id"] = id });
        Assert.Contains($"+{marker}", (string)diff["text"]!);

        var branch = "rtfx-test/" + marker;
        try
        {
            var fetched = await Call("fetch", new JsonObject { ["job_id"] = id, ["branch"] = branch });
            Assert.Equal((string?)result["headCommit"], (string?)fetched["head"]);
            Assert.Equal((string?)result["headCommit"], FakeRunner.Git(checkout, "rev-parse", branch));
            Assert.Equal("", FakeRunner.Git(checkout, "status", "--porcelain"));
        }
        finally
        {
            try
            {
                FakeRunner.Git(checkout, "branch", "-D", branch);
            }
            catch (InvalidOperationException)
            {
                // The fetch never got that far.
            }
        }
    }
}
