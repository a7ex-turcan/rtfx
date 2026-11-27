<#
  One worker per job, started by runner.ps1. It strips the environment, makes a worktree, runs Copilot
  in it and writes result.json. A read job gets a detached worktree that is thrown away afterwards.
  A write job gets a branch of its own; what it commits comes back as result.bundle, and the worktree
  stays until the bundle has been fetched. The runner owns cancel and timeout: it kills this process
  tree and finishes the job itself.
#>
param(
  [Parameter(Mandatory)][string]$Root,
  [Parameter(Mandatory)][string]$JobDir
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib.ps1')

$log = Join-Path $JobDir 'worker.log'
$worktreeRoot = Join-Path $Root 'wt'
$worktree = Join-Path $worktreeRoot (Split-Path $JobDir -Leaf)
$job = $null
$taskName = $null
$ranCopilot = $false
$extra = @{ warnings = @() }

function Add-Work([hashtable]$Work) {
  foreach ($key in $Work.Keys) {
    if ($key -eq 'warnings') { $extra.warnings += @($Work.warnings) } else { $extra[$key] = $Work[$key] }
  }
}

try {
  # The runner writes our pid into status.json right after starting us. Until it has, the job is not ours.
  $owned = $false
  for ($wait = 0; $wait -lt 150 -and -not $owned; $wait++) {
    $status = Get-JobStatus $JobDir
    $owned = $status -and $status.state -eq 'running' -and [int]$status.pid -eq $PID
    if (-not $owned) { Start-Sleep -Milliseconds 200 }
  }
  if (-not $owned) { Add-LogLine $log 'the runner never handed this job over; exiting'; exit 1 }

  $config = Get-RtfxConfig $Root
  $job = Read-Job $JobDir $config
  $write = $job.mode -eq 'write'

  $extra.envStripped = @(Remove-SecretEnvironment $config)
  $env:GIT_TERMINAL_PROMPT = '0'
  [void](Add-UserToolPaths)
  Add-LogLine $log "environment: removed $($extra.envStripped.Count) variables ($($extra.envStripped -join ', '))"

  if (-not (Test-Path -LiteralPath (Join-Path $job.repoDir '.git'))) { throw "no git checkout at $($job.repoDir)" }

  $fetch = Invoke-Git @('-C', $job.repoDir, 'fetch', '--quiet', 'origin') 180
  if ($fetch.code -ne 0) {
    $extra.warnings += "git fetch failed, using the last fetched origin/$($job.base): $($fetch.output)"
    Add-LogLine $log "git fetch failed ($($fetch.code)): $($fetch.output)"
  }
  if ($job.commit) {
    $head = Invoke-Git @('-C', $job.repoDir, 'rev-parse', '--verify', '--quiet', "$($job.commit)^{commit}")
    if ($head.code -ne 0 -or -not $head.output) { throw "commit $($job.commit) is not in $($job.repo), or is not unique there" }
  }
  else {
    $head = Invoke-Git @('-C', $job.repoDir, 'rev-parse', '--verify', '--quiet', "refs/remotes/origin/$($job.base)^{commit}")
    if ($head.code -ne 0) { throw "origin/$($job.base) does not exist in $($job.repo)" }
  }
  $extra.baseCommit = $head.output
  $startName = if ($job.commit) { "commit $($head.output.Substring(0, 12))" } else { "origin/$($job.base)" }

  New-Item -ItemType Directory -Force $worktreeRoot | Out-Null
  if ($write) {
    $taken = Invoke-Git @('-C', $job.repoDir, 'rev-parse', '--verify', '--quiet', "refs/heads/$($job.branch)")
    if ($taken.code -eq 0) { throw "branch $($job.branch) already exists in $($job.repo); give the job another branch name" }
    $add = Invoke-Git @('-C', $job.repoDir, 'worktree', 'add', '--no-track', '-b', $job.branch, $worktree, $head.output) 300
    if ($add.code -ne 0) { throw "git worktree add failed: $($add.output)" }
    $extra.branch = $job.branch
    $extra.branchCreated = $true
    Add-LogLine $log "worktree at $worktree on new branch $($job.branch) from $startName ($($head.output))"
  }
  else {
    $add = Invoke-Git @('-C', $job.repoDir, 'worktree', 'add', '--detach', $worktree, $head.output) 300
    if ($add.code -ne 0) { throw "git worktree add failed: $($add.output)" }
    Add-LogLine $log "worktree at $worktree on $startName ($($head.output))"
  }

  $feeds = Set-NuGetFeedCredentials $worktree $config
  $extra.feedSources = @($feeds.sources)
  $extra.warnings += @($feeds.warnings)
  Add-LogLine $log "package feeds given credentials: $(@($feeds.sources) -join ', ')"

  # The MCP servers are named before their config files go out of sight.
  $extra.mcpDisabled = @(Get-McpServerNames $worktree)
  $extra.hiddenFiles = Hide-WorktreePaths $worktree @($config.hidePaths)
  Add-LogLine $log "hid $($extra.hiddenFiles) tracked files from the job ($(@($config.hidePaths) -join ', '))"

  # From here on nothing needs the remote, so git loses the means to reach it.
  if ($write) { Set-GitGuards $job.gitName $job.gitEmail } else { Set-GitGuards }
  $extra.guards = Test-GitGuards $worktree
  Add-LogLine $log "guards: push blocked $($extra.guards.pushBlocked), ssh blocked $($extra.guards.sshBlocked)"
  $taskName = Add-TaskFile $worktree $job.taskFile
  # What the runner needs to gather the work itself, should it have to stop this job.
  Write-JsonFile (Join-Path $JobDir 'work.json') @{
    baseCommit = $head.output; branch = $extra.branch; branchCreated = [bool]$extra.branchCreated; taskName = $taskName
  }

  $common = @"
You are running as an unattended job. Nobody can answer a question or approve anything, so do not wait for either: make the best choice you can and say what you chose in your report.
Your brief is the file $taskName in your working directory. Read it first. It is not part of the repository: do not commit, move or delete it.
"@
  if ($write) {
    $commitRule = if ($job.ticket) {
      # Single quotes: the prompt travels as a command-line argument, where a double quote is one more thing to escape.
      "Commit your work in small commits on this branch. Every commit message starts with '$($job.ticket): ' exactly: capital letters, hyphen, colon, one space."
    } else { 'Commit your work in small commits on this branch.' }
    $prompt = @"
$common
Your working directory is a checkout of the repository $($job.repo) on a new branch, $($job.branch), cut from $startName. Work only inside this directory.

Rules:
- Before you change anything, read and follow the repository's conventions: CLAUDE.md at the root and in each folder you touch, plus AGENTS.md and .github/copilot-instructions.md where they exist.
- $commitRule No AI attribution, no Co-authored-by trailer and no em dash anywhere in a commit message.
- Never push. Never change remotes or git config. Stay on this branch: do not create or switch to another.
- Do not talk to remote systems: no HTTP calls, no ssh, no issue tracker, no CI. Restoring packages for a build is fine.
- Build and run the tests for what you changed, and fix what you broke.
- Finish with a report in four sections with these headings: Summary; Changes (file by file, one line each); Verification (the commands you ran and their results); Open points (anything not done, assumptions made, questions).
"@
  }
  else {
    $prompt = @"
$common
Your working directory is a throwaway checkout of the repository $($job.repo) at $startName. Work only inside it.

Rules:
- This is a read-only job: do not create, change or delete any source file, and do not commit. Building and running tests is fine; their output stays in this throwaway checkout.
- Never push, and do not talk to remote systems. Restoring packages for a build is fine.
- Run commands plainly. A command that redirects output (2>&1, > file) or that is not a plain read, build or test needs an approval nobody is there to give, and is refused. Piping into Select-Object, Select-String, Sort-Object or Where-Object is fine.
- Finish with a short report: what you found, how you verified it, and what is left open.
"@
  }

  $copilotArgs = @(
    '-C', $worktree, '-p', $prompt,
    '--output-format', 'json',
    '--reasoning-effort', $job.effort,
    '--max-ai-credits', [string]$job.maxCredits,
    '--usage-output-file', (Join-Path $JobDir 'usage.json'),
    '--disable-builtin-mcps', '--no-ask-user', '--no-auto-update'
  )
  if ($job.model) { $copilotArgs += @('--model', $job.model) }
  if ($write) {
    # Tools only: file access stays limited to the worktree and temp, and URLs stay closed.
    $copilotArgs += '--allow-all-tools'
    $deny = @('memory') + @($config.denyTools)
  }
  else {
    # No --allow-all-tools: under -p anything that would need approval is denied, so a read job runs
    # what Copilot itself recognises as read-only, what the runner allows, and what the job adds.
    foreach ($rule in @($config.readAllowTools) + @($job.allowTools)) { $copilotArgs += "--allow-tool=$rule" }
    $deny = @('write', 'memory') + @($config.denyTools)
  }
  foreach ($rule in $deny) { $copilotArgs += "--deny-tool=$rule" }
  # No MCP server runs in a job: each one is switched off, and its tools are denied in case it starts anyway.
  foreach ($server in $extra.mcpDisabled) { $copilotArgs += @('--disable-mcp-server', $server, "--deny-tool=$server") }
  Add-LogLine $log "MCP servers switched off: $($extra.mcpDisabled -join ', ')"

  # Copilot is a node program; without this its UTF-8 output is decoded with the console code page.
  [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
  Add-LogLine $log "starting copilot ($($job.mode) mode, model '$($job.model)', effort $($job.effort), cap $($job.maxCredits) credits)"
  # Anything Copilot writes to stderr is output to keep, not a reason to stop this script.
  $ErrorActionPreference = 'Continue'
  $ranCopilot = $true
  & $config.copilot @copilotArgs 2> (Join-Path $JobDir 'copilot.err') > (Join-Path $JobDir 'copilot.jsonl')
  $extra.exitCode = $LASTEXITCODE
  $ErrorActionPreference = 'Stop'
  # A script standing in for Copilot runs in this process and may have moved into the worktree.
  Set-Location -LiteralPath $Root
  Add-LogLine $log "copilot exited $($extra.exitCode)"

  if ($write) {
    $work = Save-JobWork $job $JobDir $worktree $extra.baseCommit $taskName
    Add-Work $work
    if (Remove-EmptyJobWork $job $work $worktree $worktreeRoot $true) { $extra.branchCreated = $false }
    Add-LogLine $log "work: $(@($extra.commits).Count) commits on $($job.branch), bundle $(if ($extra.bundle) { "$($extra.bundle.bytes) bytes" } else { 'none' })"
  }
  elseif (-not (Remove-JobWorktree $job.repoDir $worktree $worktreeRoot)) { $extra.warnings += "could not remove the worktree $worktree" }

  if ($extra.exitCode -eq 0) { Complete-Job $JobDir 'done' $null $extra }
  else {
    $tail = ''
    $errFile = Join-Path $JobDir 'copilot.err'
    if (Test-Path -LiteralPath $errFile) { $tail = ((Get-Content -LiteralPath $errFile -Tail 5) -join ' ').Trim() }
    Complete-Job $JobDir 'failed' ("copilot exited $($extra.exitCode). $tail".Trim()) $extra
  }
}
catch {
  $message = $_.Exception.Message
  Add-LogLine $log "failed: $message"
  try {
    if ($job -and $job.mode -eq 'write' -and $ranCopilot) { Add-Work (Save-JobWork $job $JobDir $worktree $extra.baseCommit $taskName) }
    elseif ($job) {
      [void](Remove-JobWorktree $job.repoDir $worktree $worktreeRoot)
      if ($extra.branchCreated) {
        [void](Invoke-Git @('-C', $job.repoDir, 'branch', '-D', $job.branch) 60)
        $extra.branchCreated = $false
      }
    }
  } catch { Add-LogLine $log "cleanup: $($_.Exception.Message)" }
  Complete-Job $JobDir 'failed' $message $extra
  exit 1
}
