using System.Text.Json.Nodes;
using Rtfx.Jobs;

namespace Rtfx.Tests;

public sealed class JobRequestTests
{
    private static readonly RtfxConfig Config = new("host", "D:/root", @"C:\repos", @"C:\cache", "default-model");

    private static JsonObject Job(Action<JsonObject>? change = null)
    {
        var job = new JsonObject { ["task"] = "Do the thing.", ["repo"] = "some-repo" };
        change?.Invoke(job);
        return job;
    }

    [Fact]
    public void A_job_with_only_task_and_repo_gets_the_defaults()
    {
        var request = JobRequest.Parse(Job(), Config);

        Assert.Equal("write", request.Mode);
        Assert.Equal("default-model", request.Model);
        Assert.Equal("medium", request.Effort);
        Assert.Equal(60, request.MaxCredits);
        Assert.Equal(45, request.TimeoutMin);
        Assert.Null(request.Base);
        Assert.Null(request.Commit);
    }

    [Fact]
    public void Every_field_is_read_from_the_arguments()
    {
        var request = JobRequest.Parse(Job(job =>
        {
            job["mode"] = "read";
            job["base"] = "release/1.2";
            job["commit"] = "0123abc";
            job["model"] = "gpt-6.2-sol";
            job["effort"] = "high";
            job["max_credits"] = 150;
            job["timeout_min"] = 12.5;
            job["allow_tools"] = new JsonArray("shell(cargo test)", "shell(make)");
        }), Config);

        Assert.Equal("read", request.Mode);
        Assert.Equal("release/1.2", request.Base);
        Assert.Equal("0123abc", request.Commit);
        Assert.Equal("gpt-6.2-sol", request.Model);
        Assert.Equal("high", request.Effort);
        Assert.Equal(150, request.MaxCredits);
        Assert.Equal(12.5, request.TimeoutMin);
        Assert.Equal(["shell(cargo test)", "shell(make)"], request.AllowTools);
    }

    [Theory]
    [InlineData("task", "", "task is empty")]
    [InlineData("repo", "..", "not a plain folder name")]
    [InlineData("repo", "a/b", "not a plain folder name")]
    [InlineData("mode", "yolo", "must be read or write")]
    [InlineData("base", "feature/..", "not a valid branch name")]
    [InlineData("commit", "HEAD", "not a commit hash")]
    [InlineData("commit", "abc", "not a commit hash")]
    [InlineData("model", "gpt 6", "not a model id")]
    [InlineData("effort", "extreme", "must be one of")]
    [InlineData("ticket", "abc-123", "not a ticket key")]
    [InlineData("branch", "main", "is the base branch")]
    [InlineData("branch", "feature/x.lock", "not a valid branch name")]
    public void A_bad_text_field_is_refused_with_a_reason(string field, string value, string reason)
    {
        var error = Assert.Throws<InvalidRequestException>(() => JobRequest.Parse(Job(job => job[field] = value), Config));
        Assert.Contains(reason, error.Message);
    }

    [Theory]
    [InlineData("max_credits", 29, "between 30")]
    [InlineData("max_credits", 201, "between 30")]
    [InlineData("timeout_min", 0, "above 0")]
    [InlineData("timeout_min", 241, "at most 240")]
    public void A_number_out_of_range_is_refused_with_a_reason(string field, double value, string reason)
    {
        var error = Assert.Throws<InvalidRequestException>(() => JobRequest.Parse(Job(job => job[field] = value), Config));
        Assert.Contains(reason, error.Message);
    }

    [Fact]
    public void An_allow_rule_cannot_smuggle_another_option()
    {
        var error = Assert.Throws<InvalidRequestException>(() =>
            JobRequest.Parse(Job(job => job["allow_tools"] = new JsonArray("shell(git status) --allow-all-tools")), Config));
        Assert.Contains("not a rule", error.Message);
    }

    [Theory]
    [InlineData("max_credits", "\"sixty\"", "must be a number")]
    [InlineData("max_credits", "60.5", "must be a whole number")]
    [InlineData("repo", "42", "must be a string")]
    [InlineData("allow_tools", "\"shell(x)\"", "must be a list of strings")]
    [InlineData("allow_tools", "[1]", "must be a list of strings")]
    public void A_field_of_the_wrong_type_is_named(string field, string json, string reason)
    {
        var error = Assert.Throws<InvalidRequestException>(() => JobRequest.Parse(Job(job => job[field] = JsonNode.Parse(json)), Config));
        Assert.Contains(field, error.Message);
        Assert.Contains(reason, error.Message);
    }

    [Fact]
    public void A_number_given_as_text_is_accepted()
    {
        Assert.Equal(90, JobRequest.Parse(Job(job => job["max_credits"] = "90"), Config).MaxCredits);
    }

    [Fact]
    public void A_write_job_carries_the_identity_the_ticket_and_the_branch()
    {
        var request = JobRequest.Parse(Job(job =>
        {
            job["ticket"] = "ABC-123";
            job["branch"] = "feature/x";
        }), Config);

        var json = request.ToJobJson("id-1", "Some One", "some.one@example.invalid");

        Assert.Equal("id-1", (string?)json["id"]);
        Assert.Equal("write", (string?)json["mode"]);
        Assert.Equal("Some One", (string?)json["gitName"]);
        Assert.Equal("some.one@example.invalid", (string?)json["gitEmail"]);
        Assert.Equal("ABC-123", (string?)json["ticket"]);
        Assert.Equal("feature/x", (string?)json["branch"]);
        Assert.Equal(60, (int?)json["maxCredits"]);
    }

    [Fact]
    public void A_read_job_carries_no_identity_and_no_ticket()
    {
        var request = JobRequest.Parse(Job(job =>
        {
            job["mode"] = "read";
            job["ticket"] = "ABC-123";
            job["commit"] = "0123abcd";
            job["allow_tools"] = new JsonArray("shell(make)");
        }), Config);

        var json = request.ToJobJson("id-2", null, null);

        Assert.False(json.ContainsKey("gitName"));
        Assert.False(json.ContainsKey("ticket"));
        Assert.Equal("0123abcd", (string?)json["commit"]);
        Assert.Equal("shell(make)", (string?)json["allowTools"]![0]);
    }

    [Fact]
    public void New_ids_are_valid_and_differ()
    {
        var now = new DateTime(2026, 11, 27, 14, 0, 0, DateTimeKind.Utc);
        var first = JobRequest.NewId(now);
        var second = JobRequest.NewId(now);

        Assert.StartsWith("20261127-140000-", first);
        Assert.True(JobRequest.IsValidId(first));
        Assert.NotEqual(first, second);
        Assert.False(JobRequest.IsValidId("../x"));
        Assert.False(JobRequest.IsValidId("a b"));
    }
}
