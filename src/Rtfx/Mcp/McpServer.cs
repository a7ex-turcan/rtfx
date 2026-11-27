using System.Collections.Concurrent;
using System.Text.Json;
using System.Text.Json.Nodes;
using Rtfx.Jobs;
using Rtfx.Runner;

namespace Rtfx.Mcp;

/// <summary>
/// <c>rtfx mcp</c>: JSON-RPC 2.0 over stdio, one message per line. Hand-rolled, as in rtfc and
/// rtfq: the protocol is small, and reflection-based tool discovery would not survive Native AOT.
/// </summary>
/// <remarks>
/// stdout is the protocol. Diagnostics go to <c>log</c> (stderr), never to <c>output</c>.
/// Tool calls run side by side, because one of them, wait, is long by design and must not hold up
/// a status or an abort; a cancelled request stops its call.
/// </remarks>
public sealed class McpServer(RunnerClient client, TextReader input, TextWriter output, TextWriter log)
{
    private const string DefaultProtocolVersion = "2025-06-18";
    private static readonly string[] KnownProtocolVersions = ["2024-11-05", "2025-03-26", "2025-06-18"];

    private readonly SemaphoreSlim _writeLock = new(1, 1);
    private readonly ConcurrentDictionary<string, CancellationTokenSource> _calls = new();
    private readonly ConcurrentDictionary<Task, bool> _running = new();

    public async Task RunAsync(CancellationToken cancellationToken)
    {
        try
        {
            while (await input.ReadLineAsync(cancellationToken).ConfigureAwait(false) is { } line)
            {
                if (string.IsNullOrWhiteSpace(line))
                {
                    continue;
                }

                var task = HandleLineAsync(line, cancellationToken);
                _running[task] = true;
                _ = task.ContinueWith(done => _running.TryRemove(done, out _), TaskScheduler.Default);
            }
        }
        finally
        {
            // The client closed the pipe: nobody is left to read an answer, so the calls in flight stop.
            foreach (var call in _calls.Values)
            {
                await call.CancelAsync().ConfigureAwait(false);
            }

            await Task.WhenAll(_running.Keys).ConfigureAwait(false);
        }
    }

    private async Task HandleLineAsync(string line, CancellationToken cancellationToken)
    {
        try
        {
            if (await RespondAsync(line, cancellationToken).ConfigureAwait(false) is { } response)
            {
                await WriteAsync(response).ConfigureAwait(false);
            }
        }
        catch (Exception ex) when (ex is IOException or ObjectDisposedException or OperationCanceledException)
        {
            log.WriteLine($"rtfx mcp: {ex.Message}");
        }
    }

    internal async Task<JsonObject?> RespondAsync(string line, CancellationToken cancellationToken)
    {
        JsonNode? node;
        try
        {
            node = JsonNode.Parse(line);
        }
        catch (JsonException)
        {
            return Error(null, -32700, "Parse error");
        }

        if (node is not JsonObject request)
        {
            return Error(null, -32600, "Invalid request: batches are not supported.");
        }

        var id = request["id"];
        var method = Json.Text(request["method"]);
        var parameters = request["params"] as JsonObject;
        if (method is null)
        {
            return id is null ? null : Error(id, -32600, "Invalid request: no method.");
        }

        if (id is null)
        {
            // A notification. The one that matters says the client gave up on a call.
            if (method == "notifications/cancelled" && parameters?["requestId"] is { } cancelled && _calls.TryGetValue(cancelled.ToJsonString(), out var call))
            {
                await call.CancelAsync().ConfigureAwait(false);
            }

            return null;
        }

        return method switch
        {
            "initialize" => Result(id, Initialize(parameters)),
            "ping" => Result(id, new JsonObject()),
            "tools/list" => Result(id, new JsonObject { ["tools"] = Tools.List() }),
            "tools/call" => await CallToolAsync(id, parameters, cancellationToken).ConfigureAwait(false),
            "prompts/list" => Result(id, new JsonObject { ["prompts"] = new JsonArray() }),
            "resources/list" => Result(id, new JsonObject { ["resources"] = new JsonArray() }),
            _ => Error(id, -32601, $"Method not found: {method}"),
        };
    }

    private static JsonObject Initialize(JsonObject? parameters)
    {
        var requested = Json.Text(parameters?["protocolVersion"]);
        return new JsonObject
        {
            ["protocolVersion"] = requested is not null && KnownProtocolVersions.Contains(requested) ? requested : DefaultProtocolVersion,
            ["capabilities"] = new JsonObject { ["tools"] = new JsonObject() },
            ["serverInfo"] = new JsonObject { ["name"] = "rtfx", ["version"] = EntryPoint.Version },
            ["instructions"] = Tools.Instructions,
        };
    }

    private async Task<JsonObject> CallToolAsync(JsonNode id, JsonObject? parameters, CancellationToken cancellationToken)
    {
        var name = Json.Text(parameters?["name"]);
        if (name is null || !Tools.Exists(name))
        {
            return Error(id, -32602, name is null ? "tools/call needs a name." : $"Unknown tool: {name}");
        }

        var arguments = parameters!["arguments"] as JsonObject ?? [];
        var key = id.ToJsonString();
        using var call = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        _calls[key] = call;
        try
        {
            return Result(id, ToolText(await Tools.CallAsync(client, name, arguments, call.Token).ConfigureAwait(false)));
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            return Result(id, ToolError($"{name} was cancelled."));
        }
        catch (RunnerException ex)
        {
            // Said as a sentence for Claude to act on: a bad argument, the runner down, the machine unreachable.
            return Result(id, ToolError(ex.Message));
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or JsonException or InvalidOperationException)
        {
            log.WriteLine($"rtfx mcp: {name} failed: {ex}");
            return Result(id, ToolError($"{name} failed: {ex.Message}"));
        }
        finally
        {
            _calls.TryRemove(key, out _);
        }
    }

    private async Task WriteAsync(JsonObject message)
    {
        await _writeLock.WaitAsync().ConfigureAwait(false);
        try
        {
            await output.WriteAsync(message.ToJsonString()).ConfigureAwait(false);
            await output.WriteAsync('\n').ConfigureAwait(false);
            await output.FlushAsync().ConfigureAwait(false);
        }
        finally
        {
            _writeLock.Release();
        }
    }

    private static JsonObject Result(JsonNode id, JsonObject result) =>
        new() { ["jsonrpc"] = "2.0", ["id"] = id.DeepClone(), ["result"] = result };

    private static JsonObject Error(JsonNode? id, int code, string message) =>
        new() { ["jsonrpc"] = "2.0", ["id"] = id?.DeepClone(), ["error"] = new JsonObject { ["code"] = code, ["message"] = message } };

    private static JsonObject ToolText(string text) =>
        new() { ["content"] = new JsonArray(new JsonObject { ["type"] = "text", ["text"] = text }) };

    private static JsonObject ToolError(string text) =>
        new() { ["content"] = new JsonArray(new JsonObject { ["type"] = "text", ["text"] = text }), ["isError"] = true };
}
