<#
  Calls one tool of the rtfx MCP server the way Claude Code does: it starts `rtfx mcp`, speaks
  JSON-RPC to it over its pipes (initialize, then tools/call), and prints the text the tool
  returned. Exit code 1 when the tool answered with an error.

    pwsh -NoProfile -File tests\mcp-call.ps1 -Tool status
    pwsh -NoProfile -File tests\mcp-call.ps1 -Tool wait -Arguments '{"job_ids":["20261127-140000-ab12"],"timeout_s":900}'
    pwsh -NoProfile -File tests\mcp-call.ps1 -Tool fan_out -ArgumentsFile jobs.json

  The server is the Debug build unless -Exe says otherwise. It reads its settings from the
  environment (RTFX_HOST and the rest), like any MCP server Claude Code starts.
#>
param(
  [Parameter(Mandatory)][string]$Tool,
  [string]$Arguments = '{}',
  [string]$ArgumentsFile,
  [string]$Exe = (Join-Path (Split-Path $PSScriptRoot) 'src\Rtfx\bin\Debug\net10.0\rtfx.exe'),
  [int]$TimeoutSec = 4000
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $Exe)) { throw "the server is not built: $Exe is missing. Run dotnet build first." }
if ($ArgumentsFile) { $Arguments = Get-Content -LiteralPath $ArgumentsFile -Raw }
$parsed = $Arguments | ConvertFrom-Json -AsHashtable
if ($parsed -isnot [Collections.IDictionary]) { throw 'the arguments must be a JSON object' }

$info = [Diagnostics.ProcessStartInfo]::new($Exe)
$info.ArgumentList.Add('mcp')
$info.RedirectStandardInput = $true
$info.RedirectStandardOutput = $true
$info.RedirectStandardError = $true
$info.StandardInputEncoding = [Text.UTF8Encoding]::new($false)
$info.StandardOutputEncoding = [Text.Encoding]::UTF8
$info.StandardErrorEncoding = [Text.Encoding]::UTF8
$info.UseShellExecute = $false
$info.CreateNoWindow = $true
$server = [Diagnostics.Process]::Start($info)
$errors = $server.StandardError.ReadToEndAsync()

function Send($Message) { $server.StandardInput.WriteLine(($Message | ConvertTo-Json -Depth 30 -Compress)); $server.StandardInput.Flush() }
function Receive([int]$Id, [int]$Seconds) {
  $until = [DateTime]::UtcNow.AddSeconds($Seconds)
  while ($true) {
    $pending = $server.StandardOutput.ReadLineAsync()
    $left = [int][Math]::Max(1, ($until - [DateTime]::UtcNow).TotalMilliseconds)
    if (-not $pending.Wait($left)) { throw "no answer from the server within $Seconds seconds" }
    if ($null -eq $pending.Result) { throw "the server closed its output. stderr: $($errors.Result)" }
    $message = $pending.Result | ConvertFrom-Json -AsHashtable
    if ($message.id -eq $Id) { return $message }
  }
}

try {
  Send @{ jsonrpc = '2.0'; id = 1; method = 'initialize'; params = @{ protocolVersion = '2025-06-18'; capabilities = @{}; clientInfo = @{ name = 'mcp-call'; version = '1' } } }
  [void](Receive 1 30)
  Send @{ jsonrpc = '2.0'; method = 'notifications/initialized' }
  Send @{ jsonrpc = '2.0'; id = 2; method = 'tools/call'; params = @{ name = $Tool; arguments = $parsed } }
  $answer = Receive 2 $TimeoutSec
  if ($answer.error) { [Console]::Error.WriteLine("protocol error $($answer.error.code): $($answer.error.message)"); exit 2 }
  $answer.result.content | ForEach-Object { $_.text }
  if ($answer.result.isError) { exit 1 }
  exit 0
}
finally {
  try { $server.StandardInput.Close() } catch { }
  if (-not $server.WaitForExit(5000)) { $server.Kill($true) }
}
