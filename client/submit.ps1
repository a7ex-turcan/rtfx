<#
  Submits a job to the runner and prints its id. The brief comes from -TaskFile or -Task.

    pwsh -NoProfile -File client\submit.ps1 -Repo my-repo -Mode read -Task 'What does the README cover?'
    pwsh -NoProfile -File client\submit.ps1 -Repo my-repo -TaskFile brief.md -Ticket ABC-123 -MaxCredits 60

  A write job commits as the person who asked for it. That identity is -GitName and -GitEmail, or
  what this machine's own checkout of the repository has in its git config.
#>
param(
  [Parameter(Mandatory)][string]$Repo,
  [string]$TaskFile,
  [string]$Task,
  [ValidateSet('read', 'write')][string]$Mode = 'write',
  [string]$Base,
  [string]$Model,
  [string]$Effort,
  [int]$MaxCredits,
  [double]$TimeoutMin,
  [string]$Ticket,
  [string]$Branch,
  [string[]]$AllowTools,
  [string]$GitName,
  [string]$GitEmail,
  [string]$Id
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib.ps1')
$config = Get-RtfxClientConfig

if (-not $Id) { $Id = '{0}-{1}' -f [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'), [guid]::NewGuid().ToString('N').Substring(0, 4) }
Assert-JobId $Id
if ($TaskFile -and $Task) { throw 'give -TaskFile or -Task, not both' }
$brief = if ($TaskFile) { Get-Content -LiteralPath $TaskFile -Raw } else { $Task }
if (-not $brief -or -not $brief.Trim()) { throw 'the brief is empty: give -TaskFile or -Task' }

$job = [ordered]@{ id = $Id; repo = $Repo; mode = $Mode }
if ($Base) { $job.base = $Base }
if ($Model) { $job.model = $Model }
if ($Effort) { $job.effort = $Effort }
if ($MaxCredits) { $job.maxCredits = $MaxCredits }
if ($TimeoutMin) { $job.timeoutMin = $TimeoutMin }
if ($AllowTools) { $job.allowTools = @($AllowTools) }
if ($Mode -eq 'write') {
  if (-not $GitName -or -not $GitEmail) {
    $checkout = Join-Path $config.localRepos $Repo
    if (Test-Path -LiteralPath (Join-Path $checkout '.git')) {
      if (-not $GitName) { $GitName = (Invoke-LocalGit @('-C', $checkout, 'config', 'user.name')).output }
      if (-not $GitEmail) { $GitEmail = (Invoke-LocalGit @('-C', $checkout, 'config', 'user.email')).output }
    }
  }
  if (-not $GitName -or -not $GitEmail) { throw "a write job needs a commit identity: give -GitName and -GitEmail, or set user.name and user.email in $(Join-Path $config.localRepos $Repo)" }
  $job.gitName = $GitName
  $job.gitEmail = $GitEmail
  if ($Ticket) { $job.ticket = $Ticket }
  if ($Branch) { $job.branch = $Branch }
}

if (Read-RunnerJson $config "jobs/$Id/job.json") { throw "job $Id already exists on the runner" }

# job.json and task.md go first and status.json last: the runner starts a job once it sees the status.
$outbox = Join-Path (Join-Path $config.cache 'outbox') $Id
if (Test-Path -LiteralPath $outbox) { Remove-Item -LiteralPath $outbox -Recurse -Force }
New-Item -ItemType Directory -Force $outbox | Out-Null
$utf8 = [Text.UTF8Encoding]::new($false)
[IO.File]::WriteAllText((Join-Path $outbox 'job.json'), ($job | ConvertTo-Json -Depth 5), $utf8)
[IO.File]::WriteAllText((Join-Path $outbox 'task.md'), $brief, $utf8)
Copy-ToRunner $config $outbox 'jobs' -Recurse
$status = Join-Path $config.cache "outbox\$Id.status.json"
[IO.File]::WriteAllText($status, (@{ state = 'queued'; queuedAt = Get-UtcStamp } | ConvertTo-Json), $utf8)
Copy-ToRunner $config $status "jobs/$Id/status.json"
Remove-Item -LiteralPath $status, $outbox -Recurse -Force -ErrorAction SilentlyContinue

$beat = Get-RunnerHeartbeat $config
if (-not $beat) { Write-Warning 'the runner has no heartbeat: the job is queued, but nothing will pick it up until the runner is started' }
elseif ($beat.ageSec -gt 120) { Write-Warning "the runner's last heartbeat is $($beat.ageSec) s old: the job is queued, but the runner looks stopped" }

[ordered]@{ id = $Id; repo = $Repo; mode = $Mode; state = 'queued' } | ConvertTo-Json
