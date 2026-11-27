<#
  Prints a finished job's result.json: the final report, the credits, and for a write job the
  commits, the changed files and the bundle. A copy stays in the local cache.

    pwsh -NoProfile -File client\result.ps1 -Id 20261127-140000-ab12
    pwsh -NoProfile -File client\result.ps1 -Id 20261127-140000-ab12 -Report    # just the final message
#>
param(
  [Parameter(Mandatory)][string]$Id,
  [switch]$Report
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib.ps1')
$config = Get-RtfxClientConfig
Assert-JobId $Id

$file = Join-Path (Get-JobCache $config $Id) 'result.json'
$result = Read-RunnerJson $config "jobs/$Id/result.json" $file
if (-not $result) {
  $status = Read-RunnerJson $config "jobs/$Id/status.json"
  if (-not $status) { throw "there is no job $Id on the runner" }
  throw "job $Id has no result yet: it is $($status.state)"
}
if ($Report) { $result.finalMessage } else { $result | ConvertTo-Json -Depth 8 }
