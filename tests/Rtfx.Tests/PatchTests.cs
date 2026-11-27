using Rtfx.Jobs;
using Rtfx.Mcp;

namespace Rtfx.Tests;

public sealed class PatchTests
{
    private const string Sample =
        "diff --git a/src/One.cs b/src/One.cs\n"
        + "index 1111111..2222222 100644\n"
        + "--- a/src/One.cs\n"
        + "+++ b/src/One.cs\n"
        + "@@ -1,2 +1,3 @@\n"
        + " line\n"
        + "+added in one\n"
        + "diff --git a/src/sub/Two.cs b/src/sub/Two.cs\n"
        + "new file mode 100644\n"
        + "index 0000000..3333333\n"
        + "--- /dev/null\n"
        + "+++ b/src/sub/Two.cs\n"
        + "@@ -0,0 +1 @@\n"
        + "+added in two\n"
        + "diff --git a/docs/Gone.md b/docs/Gone.md\n"
        + "deleted file mode 100644\n"
        + "index 4444444..0000000\n"
        + "--- a/docs/Gone.md\n"
        + "+++ /dev/null\n"
        + "@@ -1 +0,0 @@\n"
        + "-was here\n"
        + "diff --git a/img/logo.png b/img/logo.png\n"
        + "index 5555555..6666666 100644\n"
        + "Binary files a/img/logo.png and b/img/logo.png differ\n";

    [Fact]
    public void The_changed_files_are_listed_including_deleted_and_binary_ones()
    {
        Assert.Equal(["src/One.cs", "src/sub/Two.cs", "docs/Gone.md", "img/logo.png"], Patch.Files(Sample));
    }

    [Fact]
    public void One_file_can_be_cut_out()
    {
        var part = Patch.ForPath(Sample, "src/sub/Two.cs");

        Assert.StartsWith("diff --git a/src/sub/Two.cs", part);
        Assert.Contains("+added in two", part);
        Assert.DoesNotContain("added in one", part);
        Assert.DoesNotContain("Gone.md", part);
    }

    [Theory]
    [InlineData("src")]
    [InlineData("src/")]
    [InlineData(@"SRC\")]
    public void A_folder_takes_every_file_under_it(string path)
    {
        var part = Patch.ForPath(Sample, path);

        Assert.Contains("+added in one", part);
        Assert.Contains("+added in two", part);
        Assert.DoesNotContain("logo.png", part);
    }

    [Fact]
    public void A_folder_name_is_not_matched_as_a_prefix_of_another()
    {
        var error = Assert.Throws<InvalidRequestException>(() => Patch.ForPath(Sample, "sr"));
        Assert.Contains("does not touch 'sr'", error.Message);
        Assert.Contains("src/One.cs", error.Message);
    }

    [Fact]
    public void The_sections_put_back_together_are_the_patch()
    {
        var rebuilt = string.Concat(Patch.Files(Sample).Select(file => Patch.ForPath(Sample, file)));
        Assert.Equal(Sample, rebuilt);
    }

    [Fact]
    public void A_long_patch_is_cut_and_says_which_files_it_holds()
    {
        var big = Sample + "diff --git a/big.txt b/big.txt\n--- a/big.txt\n+++ b/big.txt\n@@ -1 +1 @@\n+" + new string('x', 200_000) + "\n";

        var shown = Tools.Shorten(big);

        Assert.True(shown.Length < big.Length);
        Assert.Contains("stops here", shown);
        Assert.Contains("5 files", shown);
        Assert.Contains("big.txt", shown);
        Assert.Equal(Sample, Tools.Shorten(Sample));
    }
}
