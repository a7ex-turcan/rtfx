using System.Text;
using Rtfx;

// Claude Code speaks UTF-8 on every pipe. On Windows .NET would use the console's code page
// instead, so a redirected stream is UTF-8 whatever the console says.
var utf8 = new UTF8Encoding(encoderShouldEmitUTF8Identifier: false);
var stdin = Console.IsInputRedirected ? TextReader.Synchronized(new StreamReader(Console.OpenStandardInput(), utf8)) : Console.In;
var stdout = Console.IsOutputRedirected ? Utf8Writer(Console.OpenStandardOutput()) : Console.Out;
var stderr = Console.IsErrorRedirected ? Utf8Writer(Console.OpenStandardError()) : Console.Error;

return await EntryPoint.RunAsync(args, stdin, stdout, stderr);

TextWriter Utf8Writer(Stream stream) => TextWriter.Synchronized(new StreamWriter(stream, utf8) { AutoFlush = true });
