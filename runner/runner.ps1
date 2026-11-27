<#
  The rtfx job runner. Lives in the logged-on desktop session of the box that has Copilot CLI, because
  that is the only place Copilot is signed in. It polls jobs\<id>\ folders under -Root, starts one
  worker (job.ps1) per queued job, and enforces the concurrency limit, cancel markers and timeouts.

  A job is picked up once its status.json says "queued", so the submitter writes job.json and task.md
  first and status.json last. Dropping a file named "cancel" into the job folder stops it.
#>
param([string]$Root = $PSScriptRoot)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib.ps1')

$Root = [IO.Path]::GetFullPath($Root).TrimEnd('\')
$jobsRoot = Join-Path $Root 'jobs'
$worktreeRoot = Join-Path $Root 'wt'
$runnerLog = Join-Path $Root 'runner.log'
$jobScript = Join-Path $PSScriptRoot 'job.ps1'
$modelsScript = Join-Path $PSScriptRoot 'models.ps1'
New-Item -ItemType Directory -Force $jobsRoot, $worktreeRoot | Out-Null

# One runner per root, whoever starts it (the scheduled task, its repeat trigger, or a person).
$rootHash = [BitConverter]::ToString([Security.Cryptography.SHA1]::HashData([Text.Encoding]::UTF8.GetBytes($Root.ToLowerInvariant()))).Replace('-', '').Substring(0, 16)
$mutex = [Threading.Mutex]::new($false, "Global\rtfx-runner-$rootHash")
try { $held = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $held = $true }
if (-not $held) { exit 0 }

$config = Get-RtfxConfig $Root
$pwsh = (Get-Process -Id $PID).Path
$finished = @{}
$started = $false
$lastJanitor = [DateTime]::UtcNow
$cleanupRetry = @{}
$lastListing = $null
$modelsProcess = $null
$modelsStarted = $null

function Write-RunnerLog([string]$Message) {
  if ((Test-Path -LiteralPath $runnerLog) -and (Get-Item -LiteralPath $runnerLog).Length -gt 5MB) {
    Move-Item -LiteralPath $runnerLog -Destination "$runnerLog.1" -Force
  }
  Add-LogLine $runnerLog $Message
}

# Ends a job from the outside: kill its process tree, then write the result. A write job that was
# stopped keeps what it had done: its work is gathered the same way as when it finishes on its own.
function Stop-RtfxJob([string]$JobDir, $Status, [string]$State, [string]$Reason) {
  if (Test-JobProcess $Status) { Stop-ProcessTree ([int]$Status.pid) }
  $now = Get-JobStatus $JobDir
  if ($now -and $now.state -in $RtfxTerminalStates) { return }   # the worker finished on its own first
  $id = Split-Path $JobDir -Leaf
  $worktree = Join-Path $worktreeRoot $id
  $extra = @{ warnings = @() }
  try {
    $job = Read-Job $JobDir $config
    $work = Read-JsonFile (Join-Path $JobDir 'work.json')
    $haveWork = $work -is [Collections.IDictionary] -and $work.baseCommit
    if ($job.mode -eq 'write' -and $haveWork -and (Test-Path -LiteralPath $worktree)) {
      $saved = Save-JobWork $job $JobDir $worktree ([string]$work.baseCommit) ([string]$work.taskName)
      foreach ($key in $saved.Keys) {
        if ($key -eq 'warnings') { $extra.warnings += @($saved.warnings) } else { $extra[$key] = $saved[$key] }
      }
      $extra.branchCreated = [bool]$work.branchCreated
      if (Remove-EmptyJobWork $job $saved $worktree $worktreeRoot $extra.branchCreated) { $extra.branchCreated = $false }
    }
    else {
      if (-not (Remove-JobWorktree $job.repoDir $worktree $worktreeRoot)) { $extra.warnings += 'could not remove the worktree' }
      if ($haveWork -and $work.branchCreated -and $work.branch) { [void](Invoke-Git @('-C', $job.repoDir, 'branch', '-D', [string]$work.branch) 60) }
    }
  } catch { $extra.warnings += "cleanup: $($_.Exception.Message)" }
  Complete-Job $JobDir $State $Reason $extra
  Write-RunnerLog "job $id $State ($Reason)"
}

function Start-RtfxJob([string]$JobDir) {
  $id = Split-Path $JobDir -Leaf
  try { $job = Read-Job $JobDir $config }
  catch {
    Complete-Job $JobDir 'failed' $_.Exception.Message $null
    Write-RunnerLog "job $id rejected: $($_.Exception.Message)"
    return $false
  }
  $arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$jobScript`" -Root `"$Root`" -JobDir `"$JobDir`""
  $process = Start-Process -FilePath $pwsh -ArgumentList $arguments -WindowStyle Hidden -PassThru
  $stamp = $null
  try { $stamp = $process.StartTime.ToUniversalTime().Ticks.ToString() } catch { }
  Set-JobStatus $JobDir @{ state = 'running'; startedAt = Get-UtcStamp; pid = $process.Id; pidStart = $stamp; timeoutMin = $job.timeoutMin }
  Write-RunnerLog "job $id started (worker pid $($process.Id), $($job.repo), mode $($job.mode))"
  return $true
}

# A write job's worktree stays until its bundle has been fetched, which the fetcher says with a
# file named "fetched" in the job folder. Checked on every pass; a removal that fails is retried
# every few minutes rather than every pass.
function Remove-FetchedWork {
  foreach ($dir in Get-ChildItem -LiteralPath $worktreeRoot -Directory) {
    $jobDir = Join-Path $jobsRoot $dir.Name
    if (-not (Test-Path -LiteralPath (Join-Path $jobDir 'fetched'))) { continue }
    if ($cleanupRetry.ContainsKey($dir.Name) -and [DateTime]::UtcNow -lt $cleanupRetry[$dir.Name]) { continue }
    $status = Get-JobStatus $jobDir
    if (-not $status -or $status.state -notin $RtfxTerminalStates) { continue }
    if (Remove-JobWork $jobDir $config $worktreeRoot) { $cleanupRetry.Remove($dir.Name); Write-RunnerLog "job $($dir.Name) was fetched; removed its worktree" }
    else { $cleanupRetry[$dir.Name] = [DateTime]::UtcNow.AddMinutes(5) }
  }
}

# Without a fetch, worktrees go after worktreeDays. Whole job folders go after jobDays. Both are
# counted from the finish.
function Invoke-Janitor {
  foreach ($dir in Get-ChildItem -LiteralPath $jobsRoot -Directory) {
    if ($dir.Name -notmatch $RtfxIdPattern) { continue }
    $status = Get-JobStatus $dir.FullName
    # A folder that never got its status.json is a submission that broke off half way. Nothing will
    # ever start it, so after a day it goes.
    if (-not $status -and -not (Test-Path -LiteralPath (Join-Path $dir.FullName 'status.json')) -and
        ([DateTime]::UtcNow - $dir.CreationTimeUtc).TotalDays -ge 1) {
      Remove-Item -LiteralPath $dir.FullName -Recurse -Force
      Write-RunnerLog "janitor: removed $($dir.Name), which was never queued"
      continue
    }
    if (-not $status -or $status.state -notin $RtfxTerminalStates -or -not $status.finishedAt) { continue }
    $ageDays = ([DateTime]::UtcNow - (ConvertTo-UtcTime $status.finishedAt)).TotalDays
    $worktree = Join-Path $worktreeRoot $dir.Name
    if ($ageDays -ge [double]$config.worktreeDays -and (Test-Path -LiteralPath $worktree)) {
      if (Remove-JobWork $dir.FullName $config $worktreeRoot) { Write-RunnerLog "janitor: removed worktree of $($dir.Name)" }
    }
    if ($ageDays -ge [double]$config.jobDays -and -not (Test-Path -LiteralPath $worktree)) {
      Remove-Item -LiteralPath $dir.FullName -Recurse -Force
      $finished.Remove($dir.Name)
      Write-RunnerLog "janitor: removed job $($dir.Name)"
    }
  }
}

# The model catalog is refreshed on request: whoever wants it drops a models.request file.
# One refresh at a time; one that hangs is killed, and its debug log with it.
function Invoke-ModelsRequest {
  if ($script:modelsProcess -and $script:modelsProcess.HasExited) { $script:modelsProcess = $null }
  if ($script:modelsProcess -and ([DateTime]::UtcNow - $script:modelsStarted).TotalMinutes -gt [double]$config.modelsTimeoutMin) {
    Stop-ProcessTree $script:modelsProcess.Id
    $script:modelsProcess = $null
    Remove-ModelsScratch 0
    Write-JsonFile (Join-Path $Root 'models.status.json') @{ state = 'failed'; finishedAt = Get-UtcStamp; error = "stopped after $($config.modelsTimeoutMin) minutes" }
    Write-RunnerLog 'models: refresh timed out'
  }
  $request = Join-Path $Root 'models.request'
  if (-not $script:modelsProcess -and (Test-Path -LiteralPath $request)) {
    Remove-Item -LiteralPath $request -Force
    $arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$modelsScript`" -Root `"$Root`""
    $script:modelsProcess = Start-Process -FilePath $pwsh -ArgumentList $arguments -WindowStyle Hidden -PassThru
    $script:modelsStarted = [DateTime]::UtcNow
    Write-RunnerLog "models: refresh started (pid $($script:modelsProcess.Id))"
  }
}

# A refresh that died leaves its scratch folder, debug log included. Nothing keeps those.
function Remove-ModelsScratch([double]$OlderThanMinutes) {
  foreach ($dir in Get-ChildItem -LiteralPath $Root -Directory -Filter 'models-run-*') {
    if (([DateTime]::UtcNow - $dir.CreationTimeUtc).TotalMinutes -ge $OlderThanMinutes) {
      Remove-Item -LiteralPath $dir.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}

Remove-ModelsScratch ([double]$config.modelsTimeoutMin)
Write-RunnerLog "runner $RtfxVersion started (pid $PID, root $Root, up to $($config.maxConcurrent) jobs)"

while ($true) {
  try {
    $running = @()
    $queued = @()
    $open = @()
    foreach ($dir in Get-ChildItem -LiteralPath $jobsRoot -Directory) {
      if ($finished.ContainsKey($dir.Name)) { continue }
      $status = Get-JobStatus $dir.FullName
      if (-not $status) { continue }   # still being uploaded
      $item = [pscustomobject]@{ Id = $dir.Name; Dir = $dir.FullName; Status = $status; Created = $dir.CreationTimeUtc }
      if ($status.state -in @('queued', 'running')) { $open += , (Get-JobSummary $dir.FullName $status) }
      if ($status.state -eq 'queued') { $queued += $item }
      elseif ($status.state -eq 'running') { $running += $item }
      elseif ($status.state -in $RtfxTerminalStates) {
        $finished[$dir.Name] = Get-JobSummary $dir.FullName $status
        if ($started) { Write-RunnerLog "job $($dir.Name) is $($status.state) ($($status.credits) credits)" }
      }
    }
    $started = $true   # jobs already finished when the runner came up are not news

    $active = @()
    foreach ($item in $running) {
      $elapsedMin = ([DateTime]::UtcNow - (ConvertTo-UtcTime $item.Status.startedAt)).TotalMinutes
      if (Test-Path -LiteralPath (Join-Path $item.Dir 'cancel')) { Stop-RtfxJob $item.Dir $item.Status 'cancelled' 'cancelled on request' }
      elseif (-not (Test-JobProcess $item.Status)) { Stop-RtfxJob $item.Dir $item.Status 'failed' 'the worker process ended without writing a result' }
      elseif ($elapsedMin -gt [double]$item.Status.timeoutMin) { Stop-RtfxJob $item.Dir $item.Status 'timeout' "stopped after $($item.Status.timeoutMin) minutes" }
      else { $active += $item.Id }
    }

    $waiting = 0
    foreach ($item in ($queued | Sort-Object Created)) {
      if (Test-Path -LiteralPath (Join-Path $item.Dir 'cancel')) {
        Complete-Job $item.Dir 'cancelled' 'cancelled before it started' $null
        Write-RunnerLog "job $($item.Id) cancelled before it started"
      }
      elseif ($active.Count -ge [int]$config.maxConcurrent) { $waiting++ }
      elseif (Start-RtfxJob $item.Dir) { $active += $item.Id }
    }

    Write-JsonFile (Join-Path $Root 'heartbeat.json') ([ordered]@{
      at = Get-UtcStamp; pid = $PID; version = $RtfxVersion; host = $env:COMPUTERNAME
      running = @($active); queued = $waiting; maxConcurrent = [int]$config.maxConcurrent
    })

    # The index: every job's state in one file, newest first, rewritten only when something changed.
    # It trails a job that started or stopped in this pass by one pass.
    $all = @($open) + @($finished.Values | Where-Object { $_ -is [Collections.IDictionary] })
    $all = @($all | Sort-Object { [string]$(if ($_.startedAt) { ConvertTo-UtcTime $_.startedAt } elseif ($_.queuedAt) { ConvertTo-UtcTime $_.queuedAt } else { [DateTime]::MinValue }).ToString('o') } -Descending | Select-Object -First 300)
    $listing = ConvertTo-Json -InputObject $all -Depth 4 -Compress
    if ($listing -ne $lastListing) {
      Write-JsonFile (Join-Path $Root 'index.json') ([ordered]@{ at = Get-UtcStamp; jobs = $all })
      $lastListing = $listing
    }

    Remove-FetchedWork
    Invoke-ModelsRequest

    if (([DateTime]::UtcNow - $lastJanitor).TotalMinutes -ge [double]$config.janitorMinutes) {
      $lastJanitor = [DateTime]::UtcNow
      Invoke-Janitor
    }
  }
  catch {
    Write-RunnerLog "error: $($_.Exception.Message) at $($_.InvocationInfo.ScriptLineNumber)"
  }
  Start-Sleep -Seconds ([double]$config.pollSeconds)
}
