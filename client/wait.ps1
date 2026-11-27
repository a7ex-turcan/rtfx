<#
  Waits until a job reaches a terminal state and prints its status. -TimeoutMin 0 prints the status
  as it is now and returns at once. Exit code 0 when the job is done, 2 when it ended any other way,
  3 when the wait ran out first.

    pwsh -NoProfile -File client\wait.ps1 -Id 20261127-140000-ab12
#>
param(
  [Parameter(Mandatory)][string]$Id,
  [double]$TimeoutMin = 60,
  [int]$PollSeconds = 10
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib.ps1')
$config = Get-RtfxClientConfig
Assert-JobId $Id

$until = [DateTime]::UtcNow.AddMinutes($TimeoutMin)
$last = $null
$status = $null
while ($true) {
  $status = Read-RunnerJson $config "jobs/$Id/status.json"
  $state = if ($status) { [string]$status.state } else { 'unknown' }
  if ($state -ne $last) { [Console]::Error.WriteLine("$(Get-UtcStamp) $Id is $state"); $last = $state }
  if ($state -in $RtfxTerminalStates -or [DateTime]::UtcNow -ge $until) { break }
  if ($state -in @('queued', 'unknown')) {
    $beat = Get-RunnerHeartbeat $config
    if (-not $beat -or $beat.ageSec -gt 120) { [Console]::Error.WriteLine("$(Get-UtcStamp) the runner has no fresh heartbeat; is it running?") }
  }
  Start-Sleep -Seconds $PollSeconds
}

if (-not $status) { $status = @{ state = 'unknown' } }
$status['id'] = $Id
$status | ConvertTo-Json -Depth 6
if ($status.state -eq 'done') { exit 0 }
if ($status.state -in $RtfxTerminalStates) { exit 2 }
exit 3
