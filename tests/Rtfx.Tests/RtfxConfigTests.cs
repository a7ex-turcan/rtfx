namespace Rtfx.Tests;

public sealed class RtfxConfigTests : IDisposable
{
    private readonly string _folder = Path.Combine(Path.GetTempPath(), "rtfx-config-" + Guid.NewGuid().ToString("N")[..8]);

    public RtfxConfigTests() => Directory.CreateDirectory(_folder);

    public void Dispose() => Directory.Delete(_folder, recursive: true);

    private string File(string content)
    {
        var file = Path.Combine(_folder, RtfxConfig.FileName);
        System.IO.File.WriteAllText(file, content);
        return file;
    }

    private static Func<string, string?> Environment(params (string Name, string Value)[] variables) =>
        name => variables.FirstOrDefault(variable => variable.Name == name).Value;

    [Fact]
    public void Without_a_file_or_variables_the_defaults_name_no_real_machine()
    {
        var config = RtfxConfig.FromEnvironment(Environment(), Path.Combine(_folder, "absent.json"));

        Assert.Equal("rtfx-worker", config.RemoteHost);
        Assert.Equal("C:/rtfx", config.RemoteRoot);
        Assert.EndsWith(Path.Combine("source", "repos"), config.LocalRepos);
        Assert.Equal("gpt-6-luna", config.DefaultModel);
        Assert.Null(config.RunnerScripts);
    }

    [Fact]
    public void The_file_overrides_the_defaults()
    {
        var file = File("""
            {
              // where the runner is
              "remoteHost": "box",
              "remoteRoot": "E:\\runner\\root\\",
              "localRepos": "D:\\Repos",
              "cache": "D:\\Cache",
              "defaultModel": "some-model",
            }
            """);

        var config = RtfxConfig.FromEnvironment(Environment(), file);

        Assert.Equal("box", config.RemoteHost);
        Assert.Equal("E:/runner/root", config.RemoteRoot);
        Assert.Equal(@"D:\Repos", config.LocalRepos);
        Assert.Equal(@"D:\Cache", config.Cache);
        Assert.Equal("some-model", config.DefaultModel);
    }

    [Fact]
    public void A_variable_overrides_the_file()
    {
        var file = File("""{ "remoteHost": "box", "localRepos": "D:\\Repos" }""");

        var config = RtfxConfig.FromEnvironment(Environment(("RTFX_HOST", "other"), ("RTFX_ROOT", "E:/r")), file);

        Assert.Equal("other", config.RemoteHost);
        Assert.Equal("E:/r", config.RemoteRoot);
        Assert.Equal(@"D:\Repos", config.LocalRepos);
    }

    [Theory]
    [InlineData("""{ "remoteHots": "box" }""", "unknown setting 'remoteHots'")]
    [InlineData("""{ "remoteHost": 5 }""", "'remoteHost' must be a string")]
    [InlineData("""{ "remoteHost": "" }""", "'remoteHost' must be a string")]
    [InlineData("""["box"]""", "must hold a JSON object")]
    [InlineData("""{ "remoteHost": """, "is not valid JSON")]
    public void A_file_that_is_wrong_is_refused_with_the_reason(string content, string expected)
    {
        var file = File(content);

        var error = Assert.Throws<InvalidOperationException>(() => RtfxConfig.FromEnvironment(Environment(), file));

        Assert.Contains(expected, error.Message);
    }
}
