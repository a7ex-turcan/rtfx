<#
  End-to-end test of the runner against tests/fake-copilot.ps1. It builds a throwaway root, a demo
  repository with a local bare remote, starts a real runner on it and drops jobs the way a submitter
  would. Nothing outside the temp folder is touched. Exits 1 if any check fails.

    pwsh -NoProfile -File tests/smoke.ps1          # run and clean up
    pwsh -NoProfile -File tests/smoke.ps1 -Keep    # leave the temp folder for a look
#>
param([switch]$Keep)

$ErrorActionPreference = 'Stop'
$runnerDir = Join-Path (Split-Path $PSScriptRoot) 'runner'
$clientDir = Join-Path (Split-Path $PSScriptRoot) 'client'
$work = Join-Path ([IO.Path]::GetTempPath()) ('rtfx-smoke-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$root = Join-Path $work 'root'
$repos = Join-Path $work 'repos'
$demo = Join-Path $repos 'demo'
$remote = Join-Path $work 'remote\demo.git'
$jobs = Join-Path $root 'jobs'
$pwsh = (Get-Process -Id $PID).Path
$failures = 0

function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
  if ($Ok) { "PASS  $Name" } else { $script:failures++; "FAIL  $Name  $Detail" }
}
function Read-Json([string]$Path) { if (Test-Path -LiteralPath $Path) { try { Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable } catch { } } }
function Submit([string]$Id, [string]$Task, [hashtable]$Props = @{}) {
  $dir = Join-Path $jobs $Id
  New-Item -ItemType Directory -Force $dir | Out-Null
  $job = @{ id = $Id; repo = 'demo'; mode = 'read'; model = 'fake-model' }
  foreach ($key in $Props.Keys) { $job[$key] = $Props[$key] }
  $job | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $dir 'job.json')
  Set-Content -LiteralPath (Join-Path $dir 'task.md') -Value $Task
  @{ state = 'queued'; queuedAt = [DateTime]::UtcNow.ToString('o') } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $dir 'status.json')
}
function State([string]$Id) { $status = Read-Json (Join-Path $jobs "$Id\status.json"); if ($status) { $status.state } }
function Wait-State([string]$Id, [string[]]$States, [int]$Seconds = 40) {
  $until = (Get-Date).AddSeconds($Seconds)
  while ((Get-Date) -lt $until) { if ((State $Id) -in $States) { return $true }; Start-Sleep -Milliseconds 300 }
  return $false
}
function Result([string]$Id) { Read-Json (Join-Path $jobs "$Id\result.json") }
function Marked([string]$Marker) {
  @(Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" | Where-Object { $_.CommandLine -like "*rtfx-fake-child $Marker*" })
}
function Wait-Until([scriptblock]$Test, [int]$Seconds = 20) {
  $until = (Get-Date).AddSeconds($Seconds)
  while ((Get-Date) -lt $until) { if (& $Test) { return $true }; Start-Sleep -Milliseconds 300 }
  return $false
}
# Runs one of the client scripts the way the MCP server will: as its own process, reading its JSON.
function Client([string]$Script, [string[]]$Arguments) {
  $text = (& $pwsh -NoProfile -File (Join-Path $clientDir "$Script.ps1") @Arguments 2>$null | Out-String)
  $code = $LASTEXITCODE
  $json = $null
  try { $json = $text | ConvertFrom-Json -AsHashtable } catch { }
  return @{ code = $code; text = $text; json = $json }
}
function Start-Runner {
  Start-Process -FilePath $pwsh -WindowStyle Hidden -PassThru `
    -ArgumentList "-NoProfile -File `"$runnerDir\runner.ps1`" -Root `"$root`""
}

$secretNames = @('BB_TOKEN', 'SONAR_TOKEN', 'JIRA_CRED', 'ConnectionStrings__Smoke', 'ROVO_MCP_BASIC', 'RTFQ_SERVER', 'JF_USER', 'JF_PASS', 'NPM_TOKEN', 'NODE_USE_SYSTEM_CA')
$runner = $null
try {
  New-Item -ItemType Directory -Force $root, $repos, (Split-Path $remote) | Out-Null
  git init --quiet --bare -b main $remote
  git init --quiet -b main $demo
  git -C $demo config user.name 'rtfx smoke'
  git -C $demo config user.email 'smoke@example.invalid'
  Set-Content -LiteralPath (Join-Path $demo 'README.md') -Value '# demo repo for the smoke test'
  Set-Content -LiteralPath (Join-Path $demo '.mcp.json') -Value '{ "mcpServers": { "alpha": { "command": "x" }, /* jsonc */ "beta": { "command": "y" }, } }'
  # Another agent's skills and settings, which a job must not see, and a rules file, which it must.
  New-Item -ItemType Directory -Force (Join-Path $demo '.claude\skills\demo'), (Join-Path $demo '.claude\rules') | Out-Null
  Set-Content -LiteralPath (Join-Path $demo '.claude\skills\demo\SKILL.md') -Value 'a skill for another agent'
  Set-Content -LiteralPath (Join-Path $demo '.claude\settings.json') -Value '{ "hooks": {} }'
  Set-Content -LiteralPath (Join-Path $demo '.claude\rules\style.md') -Value 'a convention of this repository'
  # Package sources: a public one, and two on a private feed host, which a job must be given credentials for.
  Set-Content -LiteralPath (Join-Path $demo 'Nuget.config') -Value @'
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <packageSources>
    <add key="nuget.org" value="https://api.nuget.org/v3/index.json" />
    <add key="PRIVATE" value="https://example.jfrog.io/artifactory/api/nuget/v3/a/index.json" />
    <add key="Other Feed" value="https://feeds.example.jfrog.io/artifactory/api/nuget/v3/b/index.json" />
  </packageSources>
</configuration>
'@
  git -C $demo add README.md .mcp.json .claude Nuget.config
  git -C $demo commit --quiet -m 'initial'
  git -C $demo remote add origin $remote
  git -C $demo push --quiet -u origin main 2>$null

  @{ reposRoot = $repos; copilot = (Join-Path $PSScriptRoot 'fake-copilot.ps1'); pollSeconds = 1; maxConcurrent = 2; janitorMinutes = 0.05 } |
    ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root 'config.json')

  foreach ($name in $secretNames) { [Environment]::SetEnvironmentVariable($name, 'smoke-value') }
  # A value of its own, so that anything that wrote it down can be found afterwards.
  $feedPassword = 'smoke-feed-pass-7391'
  $env:JF_PASS = $feedPassword
  # A Copilot home of our own, so the test never reads the real user's MCP configuration.
  $env:COPILOT_HOME = Join-Path $work 'copilot-home'
  New-Item -ItemType Directory -Force $env:COPILOT_HOME | Out-Null
  Set-Content -LiteralPath (Join-Path $env:COPILOT_HOME 'mcp-config.json') -Value '{ "mcpServers": { "mine": { "command": "z" } } }'
  # The client scripts talk to this runner root as a local folder instead of over scp.
  $env:RTFX_HOST = '.'
  $env:RTFX_ROOT = $root
  $env:RTFX_CACHE = Join-Path $work 'cache'
  $env:RTFX_LOCAL_REPOS = $repos
  $runner = Start-Runner

  # --- runner health
  Check 'heartbeat appears' (Wait-Until { Test-Path -LiteralPath (Join-Path $root 'heartbeat.json') })
  $second = Start-Runner
  Check 'a second runner on the same root exits' ($second.WaitForExit(15000) -and $second.ExitCode -eq 0)

  # --- a read job
  Submit 'read1' 'Summarise the README.'
  Check 'read job finishes' (Wait-State 'read1' @('done', 'failed', 'cancelled', 'timeout')) (State 'read1')
  $result = Result 'read1'
  Check 'read job is done' ($result.state -eq 'done') "$($result.state) $($result.error)"
  Check 'result carries the final message' ($result.finalMessage -like '*# demo repo for the smoke test*') $result.finalMessage
  Check 'result carries the credits from the usage file' ($result.credits -eq 1.234) "$($result.credits)"
  Check 'result carries the model' ($result.model -eq 'fake-model') "$($result.model)"
  Check 'worktree removed after a read job' (-not (Test-Path -LiteralPath (Join-Path $root 'wt\read1')))
  Check 'git no longer lists the worktree' (@(git -C $demo worktree list).Count -eq 1)
  Check 'result names the stripped variables' ('BB_TOKEN' -in $result.envStripped -and 'RTFQ_SERVER' -in $result.envStripped -and 'JF_USER' -notin $result.envStripped) ($result.envStripped -join ',')

  Check 'a job records that its push guard held' ($result.guards.pushBlocked -eq $true) ($result.guards | ConvertTo-Json -Compress)
  # The same check without the guards in place: here a dry-run push to the demo remote goes through.
  $unguarded = & $pwsh -NoProfile -Command ". '$runnerDir\lib.ps1'; try { [void](Test-GitGuards '$demo'); 'NOT REFUSED' } catch { 'REFUSED: ' + `$_.Exception.Message }"
  Check 'a job would refuse to start if a push could go through' ("$unguarded" -like 'REFUSED*push guard is not holding*') "$unguarded"

  # --- environment and push guard
  Submit 'env1' 'FAKE:env'
  [void](Wait-State 'env1' @('done', 'failed', 'cancelled', 'timeout'))
  $message = [string](Result 'env1').finalMessage
  $visible = @((($message -split "`n")[0] -replace '^VISIBLE: ', '') -split ',')
  foreach ($name in @('BB_TOKEN', 'SONAR_TOKEN', 'JIRA_CRED', 'ConnectionStrings__Smoke', 'ROVO_MCP_BASIC')) {
    Check "job cannot see $name" ($name -notin $visible) $message
  }
  $kept = @('JF_USER', 'JF_PASS', 'NPM_TOKEN', 'NODE_USE_SYSTEM_CA', 'NODE_EXTRA_CA_CERTS')
  $extra = @($visible | Where-Object { $_ -and $_ -notin $kept -and $_ -notlike 'NuGetPackageSourceCredentials_*' })
  Check 'job sees no secret-looking name beyond the keep list' ($extra.Count -eq 0) ($extra -join ',')
  foreach ($name in @('JF_USER', 'JF_PASS', 'NPM_TOKEN', 'NODE_USE_SYSTEM_CA')) {
    Check "job can still see $name" ($name -in $visible) $message
  }
  Check 'git push fails inside a job' ($message -match 'PUSH_EXIT: [1-9]') $message
  Check 'nothing reached the remote' (-not (git -C $remote branch --list 'rtfx-probe'))

  # --- package feed credentials
  $feedResult = Result 'env1'
  Check 'the private package sources get the feed credentials, the public one does not' ($message -like '*FEEDS: Other Feed,PRIVATE*' -and $message -like '*FEEDS_OK: True*') $message
  Check 'the result names the sources, not the credentials' ((@($feedResult.feedSources) -join ',') -eq 'PRIVATE,Other Feed' -and ($feedResult | ConvertTo-Json -Depth 6) -notlike "*$feedPassword*") (@($feedResult.feedSources) -join ',')
  $feedRepo = Join-Path $work 'feedrepo'
  git init --quiet -b main $feedRepo
  Set-Content -LiteralPath (Join-Path $feedRepo 'NuGet.Config') -Value '<configuration><packageSources><add key="fine" value="https://x.jfrog.io/a" /><add key="bad=name" value="https://x.jfrog.io/b" /></packageSources></configuration>'
  git -C $feedRepo add NuGet.Config
  $call = ". '$runnerDir\lib.ps1'; `$found = Set-NuGetFeedCredentials '$feedRepo' (Get-RtfxConfig '$root'); (`$found.sources -join ',') + ' | ' + (`$found.warnings -join ' ; ')"
  $named = "$(& $pwsh -NoProfile -Command $call)"
  Check 'a source whose name no variable can carry is reported, not renamed' ($named -like 'fine | *bad=name*no environment variable can carry*') $named
  $without = "$(& $pwsh -NoProfile -Command "Remove-Item Env:\JF_PASS; $call")"
  Check 'missing feed credentials are a warning that names the sources' ($without -like ' | *fine, bad=name*JF_USER and JF_PASS*') $without

  # --- a run that all but used up its credits
  Submit 'nearcap1' 'FAKE:nearcap'
  [void](Wait-State 'nearcap1' @('done', 'failed', 'cancelled', 'timeout'))
  $capped = Result 'nearcap1'
  Check 'a job that spent nine tenths of its cap is flagged in its result' ($capped.nearCreditCap -eq $true -and $capped.creditCap -eq 30 -and (@($capped.warnings) -join ' ') -like '*spent 28 of its 30 credit cap*') (@($capped.warnings) -join ' | ')
  Check 'and in its status, where wait and status read it' ((Read-Json (Join-Path $jobs 'nearcap1\status.json')).nearCreditCap -eq $true)
  Check 'a job well inside its cap is not flagged' ((Result 'read1').nearCreditCap -eq $false -and (Read-Json (Join-Path $jobs 'read1\status.json')).nearCreditCap -eq $false)

  # --- the Copilot command line
  Submit 'args1' 'FAKE:args' @{ allowTools = @('shell(cargo test)') }
  [void](Wait-State 'args1' @('done', 'failed', 'cancelled', 'timeout'))
  $result = Result 'args1'
  $line = ([string]$result.finalMessage -split "`nPROMPT: ")[0]
  $sent = ([string]$result.finalMessage -split "`nPROMPT: ")[1]
  Check 'a job can carry its own allow rules' ($line -like '*--allow-tool=shell(cargo test)*') $line
  Check 'a read job gets the default allow list' ($line -like '*--allow-tool=shell(git log)*' -and $line -like '*--allow-tool=shell(dotnet test)*') $line
  Check 'read mode does not allow all tools' ($line -notlike '*--allow-all*' -and $line -notlike '*--yolo*') $line
  Check 'a read job cannot run git branch, which also deletes branches' ($line -notlike '*--allow-tool=shell(git branch)*') $line
  Check 'deny rules are passed' ($line -like '*--deny-tool=shell(git push)*' -and $line -like '*--deny-tool=write*') $line
  foreach ($server in 'alpha', 'beta', 'mine') {
    Check "MCP server $server is switched off and denied" ($line -like "*--disable-mcp-server | $server | --deny-tool=$server*") $line
  }
  Check 'an MCP server that connects anyway is reported' (($result.warnings -join ' ') -like '*gamma*') ($result.warnings -join ' ')
  Check 'the prompt names the brief file instead of carrying the brief' ($sent -like '*TASK.md*' -and $sent -notlike '*FAKE:args*') $sent

  # --- the brief travels as a file
  Submit 'long1' ('Summarise the README. ' + ('x' * 60000))
  [void](Wait-State 'long1' @('done', 'failed', 'cancelled', 'timeout'))
  Check 'a brief longer than a command line can be is accepted' ((Result 'long1').state -eq 'done') (Result 'long1').error
  Check 'the brief file is ignored by git in the checkout' ((Get-Content -LiteralPath (Join-Path $demo '.git\info\exclude')) -contains '/TASK.md')
  Check 'the checkout itself stays clean' (-not (git -C $demo status --porcelain))

  # --- cancel mid-run
  Submit 'cancel1' 'FAKE:sleep 120 marker=cancel1'
  Check 'cancel: job starts' (Wait-State 'cancel1' @('running'))
  Check 'cancel: its child process is up' (Wait-Until { (Marked 'cancel1').Count -gt 0 })
  $workerPid = (Read-Json (Join-Path $jobs 'cancel1\status.json')).pid
  New-Item -ItemType File (Join-Path $jobs 'cancel1\cancel') | Out-Null
  Check 'cancel: state becomes cancelled' (Wait-State 'cancel1' @('cancelled') 25) (State 'cancel1')
  Check 'cancel: worker process is gone' (-not (Get-Process -Id $workerPid -ErrorAction SilentlyContinue))
  Check 'cancel: the whole process tree is gone' ((Marked 'cancel1').Count -eq 0)
  Check 'cancel: worktree removed' (-not (Test-Path -LiteralPath (Join-Path $root 'wt\cancel1')))
  Check 'cancel: result.json says cancelled' ((Result 'cancel1').state -eq 'cancelled')

  # --- timeout
  Submit 'timeout1' 'FAKE:sleep 120 marker=timeout1' @{ timeoutMin = 0.05 }
  Check 'timeout: state becomes timeout' (Wait-State 'timeout1' @('timeout') 40) (State 'timeout1')
  Check 'timeout: the process tree is gone' ((Marked 'timeout1').Count -eq 0)

  # --- concurrency limit, and cancelling a job that is still queued
  foreach ($n in 1..3) { Submit "conc$n" "FAKE:sleep 6 marker=conc$n" }
  Submit 'conc4' 'FAKE:sleep 6 marker=conc4'
  New-Item -ItemType File (Join-Path $jobs 'conc4\cancel') | Out-Null
  $peak = 0
  $until = (Get-Date).AddSeconds(60)
  while ((Get-Date) -lt $until) {
    $states = @(1..3 | ForEach-Object { State "conc$_" })
    $peak = [Math]::Max($peak, @($states | Where-Object { $_ -eq 'running' }).Count)
    if (@($states | Where-Object { $_ -eq 'done' }).Count -eq 3) { break }
    Start-Sleep -Milliseconds 250
  }
  Check 'concurrency: all three jobs finish' (@(1..3 | Where-Object { (State "conc$_") -eq 'done' }).Count -eq 3)
  Check 'concurrency: never more than two at once' ($peak -eq 2) "peak $peak"
  Check 'a queued job can be cancelled' ((State 'conc4') -eq 'cancelled') (State 'conc4')
  foreach ($n in 1..3) { Marked "conc$n" | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } }

  # --- a job pinned to a commit
  $pinned = (git -C $demo rev-parse HEAD)
  Submit 'commit1' 'Summarise the README.' @{ commit = $pinned.Substring(0, 10); base = 'no-such-branch' }
  Submit 'commit2' 'Summarise the README.' @{ commit = '0123456789abcdef' }
  [void](Wait-State 'commit1' @('done', 'failed', 'cancelled', 'timeout'))
  [void](Wait-State 'commit2' @('done', 'failed', 'cancelled', 'timeout'))
  Check 'a job can start from an exact commit' ((Result 'commit1').state -eq 'done' -and (Result 'commit1').baseCommit -eq $pinned) (Result 'commit1').error
  Check 'a commit the checkout does not have fails the job' ((Result 'commit2').error -like '*is not in demo*') (Result 'commit2').error

  # --- jobs the runner must refuse
  $who = @{ mode = 'write'; gitName = 'Job Person'; gitEmail = 'job@example.invalid' }
  Submit 'bad-repo' 'x' @{ repo = '..' }
  Submit 'bad-identity' 'x' @{ mode = 'write' }
  Submit 'bad-ticket' 'x' ($who + @{ ticket = 'smk-1' })
  Submit 'bad-branch' 'x' ($who + @{ branch = 'main' })
  Submit 'bad-commit' 'x' @{ commit = 'not-a-hash' }
  Submit 'bad-credits' 'x' @{ maxCredits = 10 }
  Submit 'bad-missing' 'x' @{ repo = 'no-such-repo' }
  Submit 'bad-allow' 'x' @{ allowTools = @('shell(git status) --allow-all-tools') }
  foreach ($id in 'bad-repo', 'bad-identity', 'bad-ticket', 'bad-branch', 'bad-commit', 'bad-credits', 'bad-missing', 'bad-allow') {
    [void](Wait-State $id @('done', 'failed', 'cancelled', 'timeout'))
    $result = Result $id
    Check "$id is refused with a reason" ($result.state -eq 'failed' -and $result.error) "$($result.state) $($result.error)"
  }
  Check 'a refused write job leaves no branch behind' (-not (git -C $demo branch --list 'rtfx/bad-*'))

  # --- copilot failing, and a worker dying
  Submit 'fail1' 'FAKE:fail'
  [void](Wait-State 'fail1' @('done', 'failed', 'cancelled', 'timeout'))
  Check 'a failing copilot run is reported' ((Result 'fail1').error -like '*exited 3*asked to fail*') (Result 'fail1').error

  Submit 'orphan1' 'FAKE:sleep 120 marker=orphan1'
  [void](Wait-State 'orphan1' @('running'))
  [void](Wait-Until { (Marked 'orphan1').Count -gt 0 })
  taskkill.exe /PID (Read-Json (Join-Path $jobs 'orphan1\status.json')).pid /T /F *> $null
  Check 'a dead worker is noticed' (Wait-State 'orphan1' @('failed') 25) (State 'orphan1')

  # --- the runner coming back while a job is running
  Submit 'adopt1' 'FAKE:sleep 12 marker=adopt1'
  [void](Wait-State 'adopt1' @('running'))
  Stop-Process -Id $runner.Id -Force
  $runner.WaitForExit()
  $runner = Start-Runner
  Check 'a restarted runner lets the running job finish' (Wait-State 'adopt1' @('done') 40) (State 'adopt1')
  Marked 'adopt1' | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

  # --- a write job, driven through the client scripts
  $baseCommit = (git -C $demo rev-parse origin/main)
  $sent = Client 'submit' @('-Repo', 'demo', '-Task', 'FAKE:write', '-Ticket', 'SMK-1', '-Model', 'fake-model', '-Id', 'write1',
    '-GitName', 'Job Person', '-GitEmail', 'job@example.invalid')
  Check 'submit: accepts a write job' ($sent.code -eq 0 -and $sent.json.id -eq 'write1') $sent.text
  $again = Client 'submit' @('-Repo', 'demo', '-Task', 'FAKE:write', '-Mode', 'read', '-Id', 'write1')
  Check 'submit: refuses an id that is taken' ($again.code -ne 0)
  $waited = Client 'wait' @('-Id', 'write1', '-PollSeconds', '1', '-TimeoutMin', '2')
  Check 'wait: returns 0 once the job is done' ($waited.code -eq 0 -and $waited.json.state -eq 'done') "$($waited.code) $($waited.text)"
  $result = (Client 'result' @('-Id', 'write1')).json
  $message = [string]$result.finalMessage
  Check 'write: runs with all tools allowed, minus the deny list' ($message -like '*ALLOW_ALL: True*' -and $message -like '*DENY_WRITE: False*' -and $message -like '*DENY_PUSH: True*') $message
  Check 'write: the agent works on the job branch' ($message -like '*BRANCH: rtfx/write1*') $message
  Check 'write: commits carry the identity the job named' ($message -like '*AUTHOR: Job Person <job@example.invalid>*') $message
  Check 'write: git push fails inside the job' ($message -match 'PUSH_EXIT: [1-9]') $message
  Check 'write: nothing reached the remote' (-not (git -C $remote branch --list 'rtfx/*'))
  Check 'write: two commits, the agent''s and the leftovers' (@($result.commits).Count -eq 2) (@($result.commits).Count)
  Check 'write: every subject starts with the ticket' (@($result.commits | Where-Object { $_.subject -cnotlike 'SMK-1: *' }).Count -eq 0) (($result.commits | ForEach-Object { $_.subject }) -join ' | ')
  Check 'write: the leftovers were committed by the runner' ($result.cleanBeforeAutoCommit -eq $false -and $result.autoCommit -and $result.commits[1].subject -ceq 'SMK-1: uncommitted changes left by the agent') $result.commits[1].subject
  Check 'write: every commit is authored as the job''s person' (@($result.commits | Where-Object { $_.author -ne 'Job Person <job@example.invalid>' }).Count -eq 0)
  $paths = @($result.filesChanged | ForEach-Object { $_.path })
  Check 'write: the changed files are listed, without the brief' ('added.txt' -in $paths -and 'leftover.txt' -in $paths -and 'TASK.md' -notin $paths) ($paths -join ',')
  Check 'write: the diffstat is there' ([string]$result.diffStat -like '*2 files changed*') $result.diffStat
  Check 'write: the base commit is recorded' ($result.baseCommit -eq $baseCommit) $result.baseCommit
  Check 'write: no warnings on a clean run' (@($result.warnings).Count -eq 0) (@($result.warnings) -join ' | ')
  Check 'write: the job sees neither the skills nor the MCP file, and does see the rules' ($message -like '*SEES_SKILLS: False*' -and $message -like '*SEES_MCP_FILE: False*' -and $message -like '*SEES_RULES: True*') $message
  Check 'write: git does not report the hidden files as deleted' ($message -like '*STATUS: `[`]*' -or $message -like '*STATUS: `[?? leftover.txt`]*') $message
  Check 'write: the hidden files are counted, and not among the changes' ($result.hiddenFiles -eq 3 -and -not ($paths | Where-Object { $_ -like '.claude*' -or $_ -eq '.mcp.json' })) "$($result.hiddenFiles) $($paths -join ',')"
  $patchFile = Join-Path $jobs 'write1\result.patch'
  Check 'write: the change is also there as a patch' ($result.patch.bytes -gt 0 -and (Test-Path -LiteralPath $patchFile) -and (Get-Content -LiteralPath $patchFile -Raw) -like '*+added by the fake agent*')
  Check 'the runner keeps an index of jobs' (Wait-Until { @((Read-Json (Join-Path $root 'index.json')).jobs | Where-Object { $_.id -eq 'write1' -and $_.state -eq 'done' -and $_.repo -eq 'demo' }).Count -eq 1 } 15)
  $tail = & $pwsh -NoProfile -File (Join-Path $runnerDir 'logs.ps1') -Id write1 -Tail 5 -Root $root | ConvertFrom-Json -AsHashtable
  Check 'logs: the worker log tail and the last messages come back' ($tail.state -eq 'done' -and @($tail.workerLog).Count -eq 5 -and @($tail.messages)[-1].text -like '*COMMIT_EXIT: 0*') ($tail | ConvertTo-Json -Depth 4 -Compress)
  Check 'write: the bundle is described' ($result.bundle.ref -eq 'refs/heads/rtfx/write1' -and $result.bundle.bytes -gt 0 -and (Test-Path -LiteralPath (Join-Path $jobs 'write1\result.bundle')))
  Check 'write: the worktree waits for the fetch' (Test-Path -LiteralPath (Join-Path $root 'wt\write1'))

  Submit 'write-taken' 'FAKE:write' ($who + @{ branch = 'rtfx/write1' })
  [void](Wait-State 'write-taken' @('done', 'failed', 'cancelled', 'timeout'))
  Check 'write: a branch that already exists is refused' ((Result 'write-taken').error -like '*already exists*') (Result 'write-taken').error
  Check 'write: and the existing branch is left alone' ((git -C $demo rev-parse 'rtfx/write1') -eq $result.headCommit)

  # --- fetching the work back
  $scratch = Join-Path $work 'scratch'
  git clone --quiet $remote $scratch 2>$null
  $fetched = Client 'fetch' @('-Id', 'write1', '-Target', $scratch)
  Check 'fetch: succeeds' ($fetched.code -eq 0 -and $fetched.json.commits -eq 2 -and $fetched.json.alreadyHad -eq $false) $fetched.text
  Check 'fetch: the branch is in the target at the job''s head' ((git -C $scratch rev-parse 'rtfx/write1') -eq $result.headCommit)
  Check 'fetch: the target''s working tree and branch are untouched' ((git -C $scratch symbolic-ref --short HEAD) -eq 'main' -and -not (git -C $scratch status --porcelain) -and -not (Test-Path -LiteralPath (Join-Path $scratch 'added.txt')))
  $tree = @(git -C $scratch ls-tree -r --name-only 'rtfx/write1')
  Check 'fetch: the files hidden from the job are still in the branch' ('.claude/skills/demo/SKILL.md' -in $tree -and '.mcp.json' -in $tree -and '.claude/settings.json' -in $tree) ($tree -join ',')
  Check 'fetch: the brief never travelled' (-not (git -C $scratch ls-tree -r --name-only 'rtfx/write1' | Where-Object { $_ -like '*TASK.md' }))
  Check 'fetch: the runner drops the worktree once told' (Wait-Until { -not (Test-Path -LiteralPath (Join-Path $root 'wt\write1')) } 30)
  Check 'fetch: and the job branch with it' (Wait-Until { -not (git -C $demo branch --list 'rtfx/write1') } 15)
  $twice = Client 'fetch' @('-Id', 'write1', '-Target', $scratch)
  Check 'fetch: a second fetch is harmless' ($twice.code -eq 0 -and $twice.json.alreadyHad -eq $true) $twice.text

  $diverged = Join-Path $work 'diverged'
  git clone --quiet $remote $diverged 2>$null
  git -C $diverged -c user.name=x -c user.email=x@example.invalid checkout --quiet -b other
  git -C $diverged -c user.name=x -c user.email=x@example.invalid commit --quiet --allow-empty -m 'elsewhere'
  git -C $diverged checkout --quiet main
  git -C $diverged branch --quiet -m other 'rtfx/write1'
  $refused = Client 'fetch' @('-Id', 'write1', '-Target', $diverged)
  Check 'fetch: refuses to move a branch that went elsewhere' ($refused.code -ne 0)

  # --- write jobs that end differently
  [void](Client 'submit' @('-Repo', 'demo', '-Task', 'FAKE:write', '-Model', 'fake-model', '-Id', 'write2'))
  [void](Client 'wait' @('-Id', 'write2', '-PollSeconds', '1', '-TimeoutMin', '2'))
  $result = Result 'write2'
  Check 'write: the identity defaults to the local checkout''s' ($result.commits[0].author -eq 'rtfx smoke <smoke@example.invalid>') $result.commits[0].author
  Check 'write: without a ticket the leftover commit has no prefix' ($result.commits[1].subject -ceq 'uncommitted changes left by the agent') $result.commits[1].subject

  [void](Client 'submit' @('-Repo', 'demo', '-Task', 'Summarise the README.', '-Model', 'fake-model', '-Id', 'write-none'))
  [void](Client 'wait' @('-Id', 'write-none', '-PollSeconds', '1', '-TimeoutMin', '2'))
  $result = Result 'write-none'
  Check 'write: a job that commits nothing is done, with no bundle and a warning' ($result.state -eq 'done' -and -not $result.bundle -and @($result.commits).Count -eq 0 -and (@($result.warnings) -join ' ') -like '*no commits*') (@($result.warnings) -join ' | ')

  Check 'write: and neither its worktree nor its branch is kept' (-not (Test-Path -LiteralPath (Join-Path $root 'wt\write-none')) -and -not (git -C $demo branch --list 'rtfx/write-none'))

  Check 'discard: the unwanted job still has its worktree' (Test-Path -LiteralPath (Join-Path $root 'wt\write2'))
  $dropped = Client 'discard' @('-Id', 'write2')
  Check 'discard: the runner drops the worktree and the branch' ($dropped.code -eq 0 -and (Wait-Until { -not (Test-Path -LiteralPath (Join-Path $root 'wt\write2')) -and -not (git -C $demo branch --list 'rtfx/write2') } 30))
  Check 'discard: the bundle stays in the job folder' (Test-Path -LiteralPath (Join-Path $jobs 'write2\result.bundle'))

  [void](Client 'submit' @('-Repo', 'demo', '-Task', 'FAKE:worksleep 120', '-Ticket', 'SMK-2', '-Model', 'fake-model', '-Id', 'write3'))
  Check 'abort: the write job gets going' (Wait-Until { (git -C $demo rev-list --count 'main..rtfx/write3' 2>$null) -ge 1 -and (Test-Path -LiteralPath (Join-Path $root 'wt\write3\leftover.txt')) } 40)
  $aborted = Client 'abort' @('-Id', 'write3')
  Check 'abort: the job ends cancelled' ($aborted.json.state -eq 'cancelled') $aborted.text
  $result = Result 'write3'
  Check 'abort: the work done so far is kept and bundled' (@($result.commits).Count -eq 2 -and $result.bundle.bytes -gt 0 -and $result.commits[1].subject -ceq 'SMK-2: uncommitted changes left by the agent') (@($result.warnings) -join ' | ')
  Check 'abort: a stopped run reports a floor for its credits' ($null -eq $result.credits -and $result.creditsLowerBound -eq 12) "$($result.credits) / $($result.creditsLowerBound)"

  # --- the MCP server, driving this same runner through its real protocol
  $serverExe = Join-Path (Split-Path $PSScriptRoot) 'src\Rtfx\bin\Debug\net10.0\rtfx.exe'
  if (-not (Test-Path -LiteralPath $serverExe)) { 'SKIP  the MCP server is not built (dotnet build), so its checks are skipped' }
  else {
    $env:RTFX_RUNNER_SCRIPTS = $runnerDir
    $env:RTFX_DEFAULT_MODEL = 'fake-model'
    function Mcp([string]$Tool, [hashtable]$Arguments = @{}) {
      $file = Join-Path $work ("mcp-" + [guid]::NewGuid().ToString('N') + '.json')
      $Arguments | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $file
      $text = (& $pwsh -NoProfile -File (Join-Path $PSScriptRoot 'mcp-call.ps1') -Tool $Tool -ArgumentsFile $file -Exe $serverExe 2>&1 | Out-String)
      $code = $LASTEXITCODE
      $json = $null
      try { $json = $text | ConvertFrom-Json -AsHashtable } catch { }
      return @{ code = $code; text = $text; json = $json }
    }

    $health = Mcp 'status'
    Check 'mcp: status shows the runner up and lists jobs' ($health.code -eq 0 -and $health.json.runner.running -eq $true -and $health.json.jobs_known -gt 5) $health.text

    $started = Mcp 'delegate' @{ task = 'FAKE:write'; repo = 'demo'; ticket = 'SMK-9'; wait_seconds = 60 }
    $mcpId = $started.json.job_id
    Check 'mcp: delegate runs a write job to the end within its wait' ($started.code -eq 0 -and $started.json.state -eq 'done' -and @($started.json.result.commits).Count -eq 2) $started.text
    Check 'mcp: the job committed as the local checkout does' ($started.json.result.commits[0].author -eq 'rtfx smoke <smoke@example.invalid>') $started.text
    Check 'mcp: the result carries the report and the guard check' ($started.json.result.report -like '*COMMIT_EXIT: 0*' -and $started.json.result.guards.pushBlocked -eq $true)

    $patch = Mcp 'diff' @{ job_id = $mcpId; path = 'added.txt' }
    Check 'mcp: diff shows one file of the change before any fetch' ($patch.code -eq 0 -and $patch.text -like '*+added by the fake agent*' -and $patch.text -notlike '*leftover*') $patch.text
    $tailed = Mcp 'logs' @{ job_id = $mcpId; tail = 3 }
    Check 'mcp: logs returns the worker log tail' ($tailed.code -eq 0 -and @($tailed.json.workerLog).Count -eq 3) $tailed.text

    $before = (git -C $demo rev-parse HEAD)
    $landed = Mcp 'fetch' @{ job_id = $mcpId; branch = 'from-copilot' }
    Check 'mcp: fetch adds the branch to the local checkout' ($landed.code -eq 0 -and (git -C $demo rev-parse 'from-copilot') -eq $started.json.result.headCommit) $landed.text
    Check 'mcp: fetch leaves the checkout where it was' ((git -C $demo rev-parse HEAD) -eq $before -and (git -C $demo symbolic-ref --short HEAD) -eq 'main' -and -not (git -C $demo status --porcelain))
    $clash = Mcp 'fetch' @{ job_id = 'write3'; branch = 'from-copilot' }
    Check 'mcp: fetch refuses a branch name that is taken' ($clash.code -eq 1 -and $clash.text -like '*already has a branch from-copilot*') $clash.text
    Check 'mcp: the runner drops the fetched job''s worktree' (Wait-Until { -not (Test-Path -LiteralPath (Join-Path $root "wt\$mcpId")) } 30)

    $many = Mcp 'fan_out' @{ jobs = @(@{ task = 'Summarise the README.'; repo = 'demo'; mode = 'read' }, @{ task = 'FAKE:sleep 120 marker=mcp1'; repo = 'demo'; mode = 'read' }) }
    Check 'mcp: fan_out submits both jobs' ($many.code -eq 0 -and $many.json.submitted -eq 2) $many.text
    $slow = $many.json.job_ids[1]
    $waited = Mcp 'wait' @{ job_ids = @($many.json.job_ids); timeout_s = 40 }
    Check 'mcp: wait reports what is still going when its time is up' ($waited.json.all_done -eq $false -and $waited.json.still_going -eq 1 -and $waited.json.jobs[0].state -eq 'done') $waited.text
    $stopped = Mcp 'abort' @{ job_id = $slow }
    Check 'mcp: abort stops the running job' ($stopped.json.state -eq 'cancelled') $stopped.text
    Marked 'mcp1' | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

    $flagged = Mcp 'wait' @{ job_ids = @('nearcap1', 'read1'); timeout_s = 5 }
    Check 'mcp: wait shows which job ended near its credit cap' ($flagged.json.jobs[0].nearCreditCap -eq $true -and $flagged.json.jobs[1].nearCreditCap -eq $false) $flagged.text
    $capResult = Mcp 'result' @{ job_id = 'nearcap1' }
    Check 'mcp: result carries the cap, the flag and the warning' ($capResult.json.nearCreditCap -eq $true -and $capResult.json.creditCap -eq 30 -and (@($capResult.json.warnings) -join ' ') -like '*cut short*') $capResult.text
    $refused = Mcp 'delegate' @{ task = 'x'; repo = 'demo'; mode = 'read'; max_credits = 5 }
    Check 'mcp: a bad argument is a tool error that names it' ($refused.code -eq 1 -and $refused.text -like '*max_credits 5*') $refused.text
    $dropped = Mcp 'discard' @{ job_id = 'write3' }
    Check 'mcp: discard has the runner drop an unwanted job''s worktree' ($dropped.code -eq 0 -and (Wait-Until { -not (Test-Path -LiteralPath (Join-Path $root 'wt\write3')) } 30)) $dropped.text
    $catalog = Mcp 'models'
    Check 'mcp: models lists what Copilot offers, cheapest first' ($catalog.code -eq 0 -and $catalog.json.models[0].id -eq 'fake-small' -and $catalog.json.defaultModel -eq 'fake-model') $catalog.text
  }

  # --- the model list
  $listed = Client 'models' @('-TimeoutMin', '2')
  $small = @($listed.json.models | Where-Object { $_.id -eq 'fake-small' })[0]
  Check 'models: the catalog comes back' ($listed.code -eq 0 -and $listed.json.count -eq 2) $listed.text
  Check 'models: with context window and prices' ($small.contextWindow -eq 128000 -and $small.prices.input -eq 0.25 -and $small.prices.cachedInput -eq 0.025 -and $small.prices.output -eq 2 -and $small.perTokens -eq 1000000) ($small | ConvertTo-Json -Depth 5 -Compress)
  $large = @($listed.json.models | Where-Object { $_.id -eq 'fake-large' })[0]
  Check 'models: long-context prices where a model has them' ($large.longContextPrices.input -eq 10 -and $null -eq $small.longContextPrices)
  Check 'models: and what looks like a tier' ($small.category -eq 'lightweight')
  Check 'models: the debug log is gone' (-not (Get-ChildItem -LiteralPath $root -Directory -Filter 'models-run-*'))
  $leaked = @(Get-ChildItem -LiteralPath $root -File -Recurse | Where-Object { $_.Length -lt 5MB } | Select-String -Pattern 'fake-secret-header-value' -List)
  Check 'models: nothing kept the header the log carried' ($leaked.Count -eq 0) ($leaked.Path -join ',')
  $written = @(Get-ChildItem -LiteralPath $root -File -Recurse | Where-Object { $_.Length -lt 5MB } | Select-String -Pattern $feedPassword -SimpleMatch -List)
  Check 'no file the runner or a job wrote holds the feed password' ($written.Count -eq 0) ($written.Path -join ',')

  # --- janitor
  $statusFile = Join-Path $jobs 'read1\status.json'
  $status = Read-Json $statusFile
  $status.finishedAt = [DateTime]::UtcNow.AddDays(-20).ToString('yyyy-MM-ddTHH:mm:ssZ')
  $status | ConvertTo-Json | Set-Content -LiteralPath $statusFile
  Check 'janitor removes a job after jobDays' (Wait-Until { -not (Test-Path -LiteralPath (Join-Path $jobs 'read1')) } 30)
  Check 'janitor keeps a recent job' (Test-Path -LiteralPath (Join-Path $jobs 'env1'))
  # A submission that broke off before its status.json: never started, and cleared once it is a day old.
  foreach ($name in 'never-queued-old', 'never-queued-new') {
    New-Item -ItemType Directory -Force (Join-Path $jobs $name) | Out-Null
    Set-Content -LiteralPath (Join-Path $jobs "$name\job.json") -Value '{ "repo": "demo" }'
  }
  (Get-Item -LiteralPath (Join-Path $jobs 'never-queued-old')).CreationTimeUtc = [DateTime]::UtcNow.AddDays(-2)
  Check 'janitor removes a folder that was never queued, after a day' (Wait-Until { -not (Test-Path -LiteralPath (Join-Path $jobs 'never-queued-old')) } 30)
  Check 'and leaves one that may still be arriving' (Test-Path -LiteralPath (Join-Path $jobs 'never-queued-new'))
}
finally {
  if ($runner -and -not $runner.HasExited) { taskkill.exe /PID $runner.Id /T /F *> $null }
  Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" | Where-Object { $_.CommandLine -like '*rtfx-fake-child*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
  foreach ($name in $secretNames + 'COPILOT_HOME', 'RTFX_HOST', 'RTFX_ROOT', 'RTFX_CACHE', 'RTFX_LOCAL_REPOS', 'RTFX_RUNNER_SCRIPTS', 'RTFX_DEFAULT_MODEL') { Remove-Item -LiteralPath "Env:\$name" -ErrorAction SilentlyContinue }
  if ($Keep) { "kept $work" }
  else { Start-Sleep -Seconds 1; Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
}

''
if ($failures) { "$failures check(s) failed"; exit 1 }
'all checks passed'
