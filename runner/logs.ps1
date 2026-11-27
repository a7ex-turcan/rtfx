<#
  Prints, as JSON, where a job is: the end of its worker.log, Copilot's last few messages and the
  last few commands it ran. A client runs this over ssh, because the alternative is downloading the
  whole of copilot.jsonl to read its last lines.

    pwsh -NoProfile -File C:\rtfx\logs.ps1 -Id 20261127-140000-ab12 -Tail 40
#>
param(
  [Parameter(Mandatory)][string]$Id,
  [int]$Tail = 40,
  [string]$Root = $PSScriptRoot
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib.ps1')
if ($Id -notmatch $RtfxIdPattern) { throw "job id '$Id' is not valid" }
$Tail = [Math]::Max(1, [Math]::Min($Tail, 500))
$jobDir = Join-Path (Join-Path $Root 'jobs') $Id
if (-not (Test-Path -LiteralPath $jobDir)) { throw "there is no job $Id" }

function Limit([string]$Text, [int]$Length) {
  if ($null -eq $Text) { return $null }
  if ($Text.Length -le $Length) { return $Text }
  return $Text.Substring(0, $Length) + " ... ($($Text.Length - $Length) more characters)"
}

$status = Get-JobStatus $jobDir
$workerLog = @()
$logFile = Join-Path $jobDir 'worker.log'
if (Test-Path -LiteralPath $logFile) { $workerLog = @(Get-Content -LiteralPath $logFile -Tail $Tail) }

$messages = [Collections.Generic.List[object]]::new()
$commands = [Collections.Generic.List[object]]::new()
$pending = @{}
$events = 0
$file = Join-Path $jobDir 'copilot.jsonl'
if (Test-Path -LiteralPath $file) {
  # Copilot may still be writing the file, so open it for shared reading.
  $stream = [IO.FileStream]::new($file, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
  $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::UTF8)
  try {
    while ($null -ne ($line = $reader.ReadLine())) {
      if (-not $line.StartsWith('{')) { continue }
      $events++
      $wanted = $line.StartsWith('{"type":"assistant.message"') -and -not $line.StartsWith('{"type":"assistant.message_')
      $wanted = $wanted -or $line.StartsWith('{"type":"tool.execution_start"') -or $line.StartsWith('{"type":"tool.execution_complete"')
      if (-not $wanted) { continue }
      try { $entry = $line | ConvertFrom-Json -AsHashtable } catch { continue }
      $data = $entry.data
      if ($data -isnot [Collections.IDictionary]) { continue }
      switch ([string]$entry.type) {
        'assistant.message' {
          if ($data.content -is [string] -and $data.content.Trim()) {
            $messages.Add([ordered]@{ at = $entry.timestamp; text = (Limit $data.content 4000) })
            if ($messages.Count -gt 5) { $messages.RemoveAt(0) }
          }
        }
        'tool.execution_start' {
          $what = ''
          if ($data.arguments -is [Collections.IDictionary]) {
            $what = if ($data.arguments.command) { [string]$data.arguments.command } else { [string]$data.arguments.path }
          }
          $pending[[string]$data.toolCallId] = [ordered]@{ at = $entry.timestamp; tool = $data.toolName; what = (Limit $what 300); ok = $null }
          $commands.Add($pending[[string]$data.toolCallId])
          if ($commands.Count -gt 12) { $commands.RemoveAt(0) }
        }
        'tool.execution_complete' {
          $call = $pending[[string]$data.toolCallId]
          if ($call) { $call.ok = [bool]$data.success; $pending.Remove([string]$data.toolCallId) }
        }
      }
    }
  }
  finally { $reader.Dispose() }
}

[ordered]@{
  id        = $Id
  state     = if ($status) { $status.state } else { 'unknown' }
  startedAt = if ($status) { $status.startedAt } else { $null }
  events    = $events
  workerLog = @($workerLog)
  messages  = @($messages)
  commands  = @($commands)
} | ConvertTo-Json -Depth 6 -EscapeHandling EscapeNonAscii
# ASCII only, with everything else escaped: over ssh this output passes through the console's code
# page, which turns a typographic quote in a message into a plain one and so breaks the JSON.
