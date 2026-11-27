<#
  Asks the runner to stop a job, queued or running, and by default waits until it has. A write job
  that is stopped keeps the work it had done: it is committed and bundled like a finished one.

    pwsh -NoProfile -File client\abort.ps1 -Id 20261127-140000-ab12
#>
param(
  [Parameter(Mandatory)][string]$Id,
  [switch]$NoWait
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib.ps1')
$config = Get-RtfxClientConfig
Assert-JobId $Id

$status = Read-RunnerJson $config "jobs/$Id/status.json"
if (-not $status) { throw "there is no job $Id on the runner" }
if ($status.state -notin $RtfxTerminalStates) {
  Send-RunnerMarker $config "jobs/$Id/cancel" "$(Get-UtcStamp) cancel requested from $env:COMPUTERNAME"
  $until = [DateTime]::UtcNow.AddMinutes(2)
  while (-not $NoWait -and $status.state -notin $RtfxTerminalStates -and [DateTime]::UtcNow -lt $until) {
    Start-Sleep -Seconds 3
    $now = Read-RunnerJson $config "jobs/$Id/status.json"
    if ($now) { $status = $now }
  }
}
$status['id'] = $Id
$status | ConvertTo-Json -Depth 6
