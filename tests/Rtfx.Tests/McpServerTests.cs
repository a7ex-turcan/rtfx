using System.Text.Json.Nodes;
using Rtfx.Mcp;

namespace Rtfx.Tests;

public sealed class McpServerTests : IDisposable
{
    private readonly FakeRunner _runner = new();
    private readonly StringWriter _log = new();
    private static CancellationToken None => TestContext.Current.CancellationToken;

    public void Dispose() => _runner.Dispose();

    private McpServer Server(TextReader? input = null, TextWriter? output = null) =>
        new(_runner.Client, input ?? TextReader.Null, output ?? TextWriter.Null, _log);

    private async Task<JsonObject> Ask(string method, JsonObject? parameters = null, int id = 1)
    {
        var request = new JsonObject { ["jsonrpc"] = "2.0", ["id"] = id, ["method"] = method };
        if (parameters is not null)
        {
            request["params"] = parameters;
        }

        return (await Server().RespondAsync(request.ToJsonString(), None))!;
    }

    private async Task<(string Text, bool IsError)> Call(string tool, JsonObject arguments)
    {
        var response = await Ask("tools/call", new JsonObject { ["name"] = tool, ["arguments"] = arguments });
        var result = (JsonObject)response["result"]!;
        return ((string)result["content"]![0]!["text"]!, result["isError"]?.GetValue<bool>() == true);
    }

    [Fact]
    public async Task Initialize_answers_with_the_version_it_was_asked_for_and_the_instructions()
    {
        var response = await Ask("initialize", new JsonObject { ["protocolVersion"] = "2025-03-26" });

        Assert.Equal("2025-03-26", (string?)response["result"]!["protocolVersion"]);
        Assert.Equal("rtfx", (string?)response["result"]!["serverInfo"]!["name"]);
        Assert.Contains("No job can push", (string)response["result"]!["instructions"]!);
    }

    [Fact]
    public async Task An_unknown_protocol_version_gets_the_default()
    {
        var response = await Ask("initialize", new JsonObject { ["protocolVersion"] = "1999-01-01" });
        Assert.Equal("2025-06-18", (string?)response["result"]!["protocolVersion"]);
    }

    [Fact]
    public async Task The_tools_are_the_eleven_of_the_brief_each_with_a_closed_schema()
    {
        var response = await Ask("tools/list");

        var tools = ((JsonArray)response["result"]!["tools"]!).OfType<JsonObject>().ToList();
        Assert.Equal(
            ["delegate", "fan_out", "wait", "status", "logs", "result", "diff", "fetch", "abort", "discard", "models"],
            tools.Select(tool => (string)tool["name"]!));
        Assert.All(tools, tool =>
        {
            Assert.Equal("object", (string?)tool["inputSchema"]!["type"]);
            Assert.False((bool)tool["inputSchema"]!["additionalProperties"]!);
            Assert.True(((string)tool["description"]!).Length > 40);
            Assert.True(Tools.Exists((string)tool["name"]!));
        });
        var delegateTool = tools[0];
        Assert.Equal(["task", "repo"], ((JsonArray)delegateTool["inputSchema"]!["required"]!).Select(name => (string)name!));
        Assert.True(((JsonObject)delegateTool["inputSchema"]!["properties"]!).ContainsKey("wait_seconds"));
        Assert.False(((JsonObject)tools[1]["inputSchema"]!["properties"]!["jobs"]!["items"]!["properties"]!).ContainsKey("wait_seconds"));
    }

    [Fact]
    public async Task Notifications_get_no_answer_and_unknown_methods_get_an_error()
    {
        Assert.Null(await Server().RespondAsync("""{"jsonrpc":"2.0","method":"notifications/initialized"}""", None));
        Assert.Equal(-32601, (int)(await Ask("no/such"))["error"]!["code"]!);
        Assert.Equal(-32700, (int)(await Server().RespondAsync("{not json", None))!["error"]!["code"]!);
        Assert.Equal(-32602, (int)(await Ask("tools/call", new JsonObject { ["name"] = "format_disk" }))["error"]!["code"]!);
    }

    [Fact]
    public async Task A_bad_argument_comes_back_as_a_tool_error_that_names_it()
    {
        var (text, isError) = await Call("delegate", new JsonObject { ["task"] = "x", ["repo"] = "demo", ["mode"] = "read", ["max_credits"] = 5 });

        Assert.True(isError);
        Assert.Contains("max_credits 5 must be between 30", text);
    }

    [Fact]
    public async Task Delegate_says_the_runner_is_down_instead_of_queueing_into_nothing()
    {
        _runner.Heartbeat(TimeSpan.FromHours(5));

        var (text, isError) = await Call("delegate", new JsonObject { ["task"] = "x", ["repo"] = "demo", ["mode"] = "read" });

        Assert.True(isError);
        Assert.Contains("is not running", text);
        Assert.Contains("5 hours", text);
    }

    [Fact]
    public async Task Delegate_queues_a_job_and_says_what_to_call_next()
    {
        _runner.Heartbeat(TimeSpan.Zero);

        var (text, isError) = await Call("delegate", new JsonObject { ["task"] = "Read the README.", ["repo"] = "demo", ["mode"] = "read" });

        Assert.False(isError);
        var answer = (JsonObject)JsonNode.Parse(text)!;
        Assert.Equal("queued", (string?)answer["state"]);
        Assert.Equal("test-model", (string?)answer["model"]);
        Assert.Contains("wait", (string)answer["next"]!);
        Assert.True(File.Exists(_runner.PathOf($"jobs/{(string)answer["job_id"]!}/status.json")));
    }

    [Fact]
    public async Task Fan_out_checks_every_job_before_submitting_any()
    {
        _runner.Heartbeat(TimeSpan.Zero);
        var jobs = new JsonArray(
            new JsonObject { ["task"] = "a", ["repo"] = "demo", ["mode"] = "read" },
            new JsonObject { ["task"] = "b", ["repo"] = "demo", ["mode"] = "read", ["effort"] = "ludicrous" });

        var (text, isError) = await Call("fan_out", new JsonObject { ["jobs"] = jobs });

        Assert.True(isError);
        Assert.Contains("jobs[1]", text);
        Assert.Contains("No job was submitted", text);
        Assert.Empty(Directory.GetDirectories(_runner.PathOf("jobs")));
    }

    [Fact]
    public async Task Fan_out_submits_each_job_with_its_own_settings()
    {
        _runner.Heartbeat(TimeSpan.Zero);
        var jobs = new JsonArray(
            new JsonObject { ["task"] = "review", ["repo"] = "demo", ["mode"] = "read", ["model"] = "model-a", ["commit"] = "0123abcd" },
            new JsonObject { ["task"] = "review", ["repo"] = "demo", ["mode"] = "read", ["model"] = "model-b", ["effort"] = "high" });

        var (text, isError) = await Call("fan_out", new JsonObject { ["jobs"] = jobs });

        Assert.False(isError);
        var answer = (JsonObject)JsonNode.Parse(text)!;
        Assert.Equal(2, (int)answer["submitted"]!);
        var ids = ((JsonArray)answer["job_ids"]!).Select(id => (string)id!).ToList();
        Assert.Equal(2, ids.Distinct().Count());
        Assert.Equal("model-a", (string?)_runner.Read($"jobs/{ids[0]}/job.json")["model"]);
        Assert.Equal("0123abcd", (string?)_runner.Read($"jobs/{ids[0]}/job.json")["commit"]);
        Assert.Equal("high", (string?)_runner.Read($"jobs/{ids[1]}/job.json")["effort"]);
        Assert.All(ids, id =>
        {
            Assert.Equal("queued", (string?)_runner.Read($"jobs/{id}/status.json")["state"]);
            Assert.Equal("review", File.ReadAllText(_runner.PathOf($"jobs/{id}/task.md")));
            Assert.Equal(["job.json", "status.json", "task.md"], Directory.GetFiles(_runner.PathOf($"jobs/{id}")).Select(Path.GetFileName).Order());
        });
        Assert.Empty(Directory.GetFileSystemEntries(Path.Combine(_runner.Config.Cache, "outbox")));
    }

    [Fact]
    public async Task Status_without_a_job_shows_the_runner_and_the_recent_jobs()
    {
        _runner.Heartbeat(TimeSpan.FromSeconds(3));
        _runner.Write("index.json", new JsonObject
        {
            ["jobs"] = new JsonArray(new JsonObject { ["id"] = "newest", ["state"] = "running" }, new JsonObject { ["id"] = "older", ["state"] = "done" }),
        });

        var (text, _) = await Call("status", []);

        var answer = (JsonObject)JsonNode.Parse(text)!;
        Assert.True((bool)answer["runner"]!["running"]!);
        Assert.Equal(2, (int)answer["jobs_known"]!);
        Assert.Equal("newest", (string?)answer["jobs"]![0]!["id"]);
    }

    [Fact]
    public async Task Status_of_one_job_leaves_out_the_runners_own_bookkeeping()
    {
        _runner.Status("j1", "done", status =>
        {
            status["pid"] = 1234;
            status["credits"] = 0.4;
        });

        var (text, _) = await Call("status", new JsonObject { ["job_id"] = "j1" });

        var answer = (JsonObject)JsonNode.Parse(text)!;
        Assert.Equal("done", (string?)answer["state"]);
        Assert.Equal(0.4, (double)answer["credits"]!);
        Assert.False(answer.ContainsKey("pid"));
    }

    [Fact]
    public async Task A_job_id_that_could_be_a_path_is_refused()
    {
        var (text, isError) = await Call("result", new JsonObject { ["job_id"] = "../../secrets" });

        Assert.True(isError);
        Assert.Contains("is not a job id", text);
    }

    [Fact]
    public void The_model_list_offers_the_priced_models_cheapest_first()
    {
        var models = new JsonObject
        {
            ["fetchedAt"] = "2026-11-27T14:34:43Z",
            ["priceUnit"] = "AI credits per perTokens tokens",
            ["models"] = new JsonArray(
                new JsonObject { ["id"] = "big", ["category"] = "powerful", ["prices"] = new JsonObject { ["input"] = 400, ["output"] = 2000 }, ["plans"] = new JsonArray("pro") },
                new JsonObject { ["id"] = "embedding", ["category"] = null },
                new JsonObject { ["id"] = "small", ["category"] = "lightweight", ["prices"] = new JsonObject { ["input"] = 10, ["output"] = 50 } }),
        };

        var list = Tools.ModelList(models, _runner.Config);

        Assert.Equal(["small", "big"], ((JsonArray)list["models"]!).Select(model => (string)model!["id"]!));
        Assert.Equal(["embedding"], ((JsonArray)list["otherIds"]!).Select(id => (string)id!));
        Assert.Equal("test-model", (string?)list["defaultModel"]);
        Assert.False(((JsonObject)list["models"]![1]!).ContainsKey("plans"));
    }

    [Fact]
    public async Task The_server_answers_over_its_pipes_one_line_per_message()
    {
        var input = new StringReader(
            """{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}""" + "\n"
            + """{"jsonrpc":"2.0","method":"notifications/initialized"}""" + "\n\n"
            + """{"jsonrpc":"2.0","id":"two","method":"ping"}""" + "\n");
        var output = new StringWriter();

        await Server(input, TextWriter.Synchronized(output)).RunAsync(None);

        var lines = output.ToString().Split('\n', StringSplitOptions.RemoveEmptyEntries).Select(line => (JsonObject)JsonNode.Parse(line)!).ToList();
        Assert.Equal(2, lines.Count);
        Assert.Contains(lines, line => line["id"]!.ToJsonString() == "1" && line["result"]!["serverInfo"] is not null);
        Assert.Contains(lines, line => line["id"]!.ToJsonString() == "\"two\"");
    }
}
