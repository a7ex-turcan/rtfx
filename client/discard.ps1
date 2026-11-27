<#
  Tells the runner that a finished write job's work is not wanted, so it can drop the job's worktree
  and branch now instead of after seven days. The job folder, with its result and its bundle, stays
  until the runner's usual clean-up, so a change of mind can still fetch it.

    pwsh -NoProfile -File client\discard.ps1 -Id 20261127-140000-ab12
#>
param([Parameter(Mandatory)][string]$Id)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib.ps1')
$config = Get-RtfxClientConfig
Assert-JobId $Id

$status = Read-RunnerJson $config "jobs/$Id/status.json"
if (-not $status) { throw "there is no job $Id on the runner" }
if ($status.state -notin $RtfxTerminalStates) { throw "job $Id is $($status.state): abort it first" }
# The same file a fetch leaves: either way the worktree has nothing left to wait for.
Send-RunnerMarker $config "jobs/$Id/fetched" "$(Get-UtcStamp) discarded from $env:COMPUTERNAME"
[ordered]@{ id = $Id; state = [string]$status.state; discarded = $true } | ConvertTo-Json
