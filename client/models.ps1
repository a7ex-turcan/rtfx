<#
  Prints the models Copilot offers, with their prices, from the runner's models.json. When that is
  missing or older than -MaxAgeDays it asks the runner to refresh it first, which costs one tiny
  Copilot call. -Refresh asks regardless of age.

    pwsh -NoProfile -File client\models.ps1
    pwsh -NoProfile -File client\models.ps1 -Refresh
#>
param(
  [switch]$Refresh,
  [double]$MaxAgeDays = 7,
  [double]$TimeoutMin = 12
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib.ps1')
$config = Get-RtfxClientConfig
$file = Join-Path $config.cache 'models.json'

$models = Read-RunnerJson $config 'models.json' $file
$stale = -not $models -or -not $models.fetchedAt -or ([DateTime]::UtcNow - (ConvertTo-UtcTime $models.fetchedAt)).TotalDays -gt $MaxAgeDays
if ($Refresh -or $stale) {
  $before = Read-RunnerJson $config 'models.status.json'
  $beforeStamp = if ($before) { "$($before.state) $($before.finishedAt)" } else { '' }
  Send-RunnerMarker $config 'models.request' "$(Get-UtcStamp) requested from $env:COMPUTERNAME"
  $until = [DateTime]::UtcNow.AddMinutes($TimeoutMin)
  $status = $null
  while ([DateTime]::UtcNow -lt $until) {
    Start-Sleep -Seconds 5
    $status = Read-RunnerJson $config 'models.status.json'
    if ($status -and $status.state -in @('done', 'failed') -and "$($status.state) $($status.finishedAt)" -ne $beforeStamp) { break }
  }
  if (-not $status -or $status.state -notin @('done', 'failed') -or "$($status.state) $($status.finishedAt)" -eq $beforeStamp) { throw "the runner did not refresh the model list within $TimeoutMin minutes; is it running?" }
  if ($status.state -eq 'failed') { throw "the runner could not refresh the model list: $($status.error)" }
  $models = Read-RunnerJson $config 'models.json' $file
  if (-not $models) { throw 'the runner says the model list is refreshed, but models.json is not there' }
}
$models | ConvertTo-Json -Depth 8
