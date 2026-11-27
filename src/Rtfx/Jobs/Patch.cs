using System.Text;

namespace Rtfx.Jobs;

/// <summary>Reads the text <c>git diff</c> wrote: which files it touches, and the part for one of them.</summary>
public static class Patch
{
    private const string Header = "diff --git ";

    /// <summary>The paths the patch changes, as git names them after the change.</summary>
    public static IReadOnlyList<string> Files(string patch) => [.. Sections(patch).Select(section => section.Path)];

    /// <summary>
    /// The sections of the patch for <paramref name="path"/>: that file, or every file under that
    /// folder. Forward or back slashes, with or without a trailing one.
    /// </summary>
    public static string ForPath(string patch, string path)
    {
        var wanted = path.Replace('\\', '/').Trim('/');
        var kept = new StringBuilder();
        var all = Sections(patch).ToList();
        foreach (var section in all)
        {
            if (section.Path.Equals(wanted, StringComparison.OrdinalIgnoreCase) || section.Path.StartsWith(wanted + "/", StringComparison.OrdinalIgnoreCase))
            {
                kept.Append(section.Text);
            }
        }

        return kept.Length > 0
            ? kept.ToString()
            : throw new InvalidRequestException($"the patch does not touch '{path}'. It changes: {string.Join(", ", all.Select(section => section.Path))}.");
    }

    private static IEnumerable<(string Path, string Text)> Sections(string patch)
    {
        var start = patch.StartsWith(Header, StringComparison.Ordinal) ? 0 : Next(patch, 0);
        while (start >= 0)
        {
            var end = Next(patch, start + 1);
            var text = end < 0 ? patch[start..] : patch[start..end];
            yield return (PathOf(text), text);
            start = end;
        }
    }

    /// <summary>The index of the next line that opens a file's section, or -1.</summary>
    private static int Next(string patch, int from)
    {
        var at = patch.IndexOf("\n" + Header, Math.Max(from - 1, 0), StringComparison.Ordinal);
        return at < 0 ? -1 : at + 1;
    }

    /// <summary>The path after the change: the "+++ b/..." line, or for a deletion or a binary file the header's own.</summary>
    private static string PathOf(string section)
    {
        string? fromHeader = null;
        foreach (var line in section.Split('\n'))
        {
            var text = line.TrimEnd('\r');
            if (text.StartsWith("+++ b/", StringComparison.Ordinal))
            {
                return Unquote(text["+++ b/".Length..]);
            }

            if (text.StartsWith(Header, StringComparison.Ordinal))
            {
                var split = text.LastIndexOf(" b/", StringComparison.Ordinal);
                fromHeader = split < 0 ? text[Header.Length..] : Unquote(text[(split + 3)..]);
            }
            else if (text.StartsWith("@@", StringComparison.Ordinal))
            {
                break;
            }
        }

        return fromHeader ?? "";
    }

    private static string Unquote(string path) => path.Trim('"').TrimEnd('\t');
}
