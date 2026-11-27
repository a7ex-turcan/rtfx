# Shared by runner.ps1 (the supervisor) and job.ps1 (one worker per job).
# Version 1 only: job and status documents are read as hashtables with optional keys, and later
# versions make reading an absent key an error.
Set-StrictMode -Version 1.0

$RtfxVersion = '0.3.1'
$RtfxTerminalStates = @('done', 'failed', 'cancelled', 'timeout')
$RtfxIdPattern = '^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$'
$RtfxEfforts = @('none', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max')

# ---------- config ----------

function Get-RtfxConfig([string]$Root) {
  $config = @{
    reposRoot         = Join-Path $HOME 'source\repos'
    copilot           = 'copilot'
    maxConcurrent     = 3
    pollSeconds       = 3
    defaultEffort     = 'medium'
    defaultMaxCredits = 30
    maxCreditsPerJob  = 200
    defaultTimeoutMin = 45
    maxTimeoutMin     = 240
    worktreeDays      = 7
    jobDays           = 14
    janitorMinutes    = 60
    modelsTimeoutMin  = 10
    # The model the catalog probe talks to. It only has to answer one word, so the cheapest will do.
    probeModel        = 'gpt-6-luna'
    # Names that survive the strip even though a pattern below matches them: the read-only package
    # feeds that builds need, and the CA settings that TLS interception on the box requires.
    keepEnv           = @('JF_USER', 'JF_PASS', 'NPM_TOKEN', 'NODE_EXTRA_CA_CERTS', 'NODE_USE_SYSTEM_CA')
    # The private package feeds: a NuGet source whose host matches one of these gets the kept feed
    # user and password, handed to NuGet the one way it reads them from the environment.
    feedHosts         = @('*.jfrog.io')
    feedUserVar       = 'JF_USER'
    feedPassVar       = 'JF_PASS'
    # Wildcards, matched case-insensitively against every variable name in the worker's environment.
    stripEnv          = @('*TOKEN*', '*SECRET*', '*PASSWORD*', '*PASSWD*', '*CRED*', '*_PAT', '*_PASS',
                          '*APIKEY*', '*API_KEY*', 'ConnectionStrings__*', 'ROVO_MCP_BASIC', 'RTFQ_*')
    # Copilot permission rules, kind(argument). For git, gh, npm, dotnet and similar only the first
    # subcommand is part of the name; ":*" matches the command and anything after it.
    denyTools         = @(
      'shell(git push)', 'shell(git remote)', 'shell(git config)', 'shell(git worktree)', 'shell(git stash)',
      'shell(git rebase)', 'shell(git filter-branch)', 'shell(git update-ref)', 'shell(git reflog)',
      'shell(git gc)', 'shell(git submodule)',
      'shell(gh:*)', 'shell(bb:*)',
      'shell(curl:*)', 'shell(wget:*)', 'shell(Invoke-RestMethod)', 'shell(Invoke-WebRequest)', 'shell(irm)', 'shell(iwr)',
      'shell(ssh:*)', 'shell(scp:*)', 'shell(sftp:*)',
      'shell(docker:*)', 'shell(podman:*)',
      'shell(npm publish)', 'shell(pnpm publish)', 'shell(yarn npm)', 'shell(yarn publish)',
      'shell(dotnet nuget)', 'shell(nuget:*)', 'shell(twine:*)', 'shell(jf:*)', 'shell(jfrog:*)',
      'shell(schtasks:*)', 'shell(Register-ScheduledTask)', 'shell(Unregister-ScheduledTask)', 'shell(Set-ScheduledTask)'
    )
    # Tracked files a job never sees: the repository's skills, commands, agents, hooks and settings
    # for coding agents, which are someone else's workflows, and its MCP server lists. CLAUDE.md and
    # .claude/rules stay, because those are the repository's conventions.
    hidePaths         = @('.claude/skills', '.claude/commands', '.claude/agents', '.claude/settings.json',
                          '.claude/settings.local.json', '.mcp.json', '.github/mcp.json', '.github/skills',
                          '.github/agents', '.github/hooks', '.github/copilot', '.agents')
    # What a read job may run without anyone approving it; a job adds to this with allowTools.
    # Builds and tests are here because they only write inside the throwaway worktree, and a job
    # that cannot build cannot verify anything. A pipeline runs only if every command in it is allowed.
    readAllowTools    = @(
      'shell(git log)', 'shell(git diff)', 'shell(git show)', 'shell(git status)', 'shell(git blame)',
      'shell(git grep)', 'shell(git ls-files)', 'shell(git rev-parse)',
      'shell(git describe)', 'shell(git merge-base)',
      'shell(Get-ChildItem)', 'shell(Get-Content)', 'shell(Select-String)', 'shell(Test-Path)',
      'shell(rg:*)', 'shell(cat)', 'shell(ls)', 'shell(type)', 'shell(findstr:*)',
      'shell(Select-Object)', 'shell(Sort-Object)', 'shell(Where-Object)', 'shell(Measure-Object)',
      'shell(Group-Object)', 'shell(Out-String)', 'shell(Format-Table)', 'shell(Format-List)',
      'shell(Get-Item)', 'shell(Get-Location)', 'shell(Resolve-Path)', 'shell(Join-Path)', 'shell(Split-Path)',
      'shell(dotnet build)', 'shell(dotnet test)', 'shell(dotnet restore)',
      'shell(pnpm install)', 'shell(pnpm test)', 'shell(pnpm run)',
      'shell(node:*)', 'shell(python:*)', 'shell(pytest:*)', 'shell(uv:*)'
    )
  }
  $file = Join-Path $Root 'config.json'
  if (Test-Path -LiteralPath $file) {
    $overrides = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json -AsHashtable
    foreach ($key in @($overrides.Keys)) {
      if (-not $config.ContainsKey($key)) { throw "config.json: unknown setting '$key'" }
      $config[$key] = $overrides[$key]
    }
  }
  return $config
}

# ---------- small helpers ----------

function Get-UtcStamp { [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ') }

# ConvertFrom-Json turns ISO strings into DateTime, so a stored timestamp can come back as either.
function ConvertTo-UtcTime($Value) {
  if ($null -eq $Value) { return $null }
  if ($Value -is [DateTime]) { return $Value.ToUniversalTime() }
  $styles = [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal
  return [DateTime]::Parse([string]$Value, [Globalization.CultureInfo]::InvariantCulture, $styles)
}

function Read-JsonFile([string]$Path) {
  for ($try = 0; $try -lt 3; $try++) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try { return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable) } catch { Start-Sleep -Milliseconds 60 }
  }
  return $null
}

# Write to a temp file and rename, so a reader never sees half a document.
function Write-JsonFile([string]$Path, $Value) {
  $temp = "$Path.$PID.tmp"
  [IO.File]::WriteAllText($temp, ($Value | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
  for ($try = 0; ; $try++) {
    try { Move-Item -LiteralPath $temp -Destination $Path -Force; return }
    catch { if ($try -ge 5) { throw }; Start-Sleep -Milliseconds 80 }
  }
}

function Add-LogLine([string]$Path, [string]$Message) {
  $line = '{0} {1}' -f (Get-UtcStamp), $Message
  for ($try = 0; $try -lt 3; $try++) {
    try { Add-Content -LiteralPath $Path -Value $line -Encoding utf8; return } catch { Start-Sleep -Milliseconds 60 }
  }
}

# ---------- processes ----------

# A pid alone can be reused; the pid plus its start time identifies one process.
function Get-ProcessStamp([int]$ProcessId) {
  $process = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
  if (-not $process) { return $null }
  try { return $process.StartTime.ToUniversalTime().Ticks.ToString() } catch { return $null }
}

function Test-JobProcess($Status) {
  if (-not $Status -or -not $Status.pid) { return $false }
  $stamp = Get-ProcessStamp ([int]$Status.pid)
  return ($null -ne $stamp -and $stamp -eq [string]$Status.pidStart)
}

function Stop-ProcessTree([int]$ProcessId) {
  & taskkill.exe /PID $ProcessId /T /F *> $null
  for ($wait = 0; $wait -lt 50; $wait++) {
    if (-not (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)) { return }
    Start-Sleep -Milliseconds 200
  }
}

# Runs git with a time limit and without a console prompt to hang on.
function Invoke-Git([string[]]$GitArgs, [int]$TimeoutSec = 120, [hashtable]$Environment) {
  $info = [Diagnostics.ProcessStartInfo]::new('git')
  foreach ($arg in $GitArgs) { $info.ArgumentList.Add($arg) }
  if ($Environment) { foreach ($name in $Environment.Keys) { $info.Environment[$name] = [string]$Environment[$name] } }
  $info.RedirectStandardOutput = $true
  $info.RedirectStandardError = $true
  $info.UseShellExecute = $false
  $info.CreateNoWindow = $true
  $process = [Diagnostics.Process]::Start($info)
  $stdout = $process.StandardOutput.ReadToEndAsync()
  $stderr = $process.StandardError.ReadToEndAsync()
  if (-not $process.WaitForExit($TimeoutSec * 1000)) {
    try { $process.Kill($true) } catch { }
    return @{ code = -1; output = "git $($GitArgs[0]) timed out after $TimeoutSec s" }
  }
  $process.WaitForExit()
  return @{ code = $process.ExitCode; output = (($stdout.Result + "`n" + $stderr.Result).Trim()) }
}

# ---------- job protocol ----------

function Get-JobStatus([string]$JobDir) { Read-JsonFile (Join-Path $JobDir 'status.json') }

function Set-JobStatus([string]$JobDir, [hashtable]$Changes) {
  $status = Get-JobStatus $JobDir
  if (-not $status) { $status = [ordered]@{} }
  foreach ($key in $Changes.Keys) { $status[$key] = $Changes[$key] }
  $status['updatedAt'] = Get-UtcStamp
  Write-JsonFile (Join-Path $JobDir 'status.json') $status
}

# Reads and validates job.json. Everything that later reaches a command line or a path is checked here.
function Read-Job([string]$JobDir, [hashtable]$Config) {
  $id = Split-Path $JobDir -Leaf
  if ($id -notmatch $RtfxIdPattern) { throw "job id '$id' is not valid" }
  $raw = Read-JsonFile (Join-Path $JobDir 'job.json')
  if ($raw -isnot [Collections.IDictionary]) { throw 'job.json is missing or is not a JSON object' }
  if ($raw.id -and [string]$raw.id -ne $id) { throw "job.json id '$($raw.id)' does not match its folder '$id'" }

  $repo = [string]$raw.repo
  if ($repo -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$' -or $repo -like '*..*') { throw "repo '$repo' is not a plain folder name" }

  $base = if ($raw.base) { [string]$raw.base } else { 'main' }
  if ($base -notmatch '^[A-Za-z0-9][A-Za-z0-9._/-]{0,199}$' -or $base -like '*..*') { throw "base '$base' is not a valid branch name" }

  # An exact commit to start from, for work pinned to one: a pull request's head, say.
  $commit = [string]$raw.commit
  if ($commit -and $commit -cnotmatch '^[0-9a-f]{7,64}$') { throw "commit '$commit' is not a commit hash" }

  $mode = if ($raw.mode) { [string]$raw.mode } else { 'write' }
  if ($mode -notin @('read', 'write')) { throw "mode '$mode' must be read or write" }

  $model = [string]$raw.model
  if ($model -and $model -notmatch '^[A-Za-z0-9][A-Za-z0-9._:-]{0,79}$') { throw "model '$model' is not a valid model id" }

  $effort = if ($raw.effort) { [string]$raw.effort } else { [string]$Config.defaultEffort }
  if ($effort -notin $RtfxEfforts) { throw "effort '$effort' must be one of $($RtfxEfforts -join ', ')" }

  $maxCredits = if ($null -ne $raw.maxCredits) { [int]$raw.maxCredits } else { [int]$Config.defaultMaxCredits }
  if ($maxCredits -lt 30) { throw "maxCredits $maxCredits is below Copilot's minimum of 30" }
  if ($maxCredits -gt [int]$Config.maxCreditsPerJob) { throw "maxCredits $maxCredits is above this runner's ceiling of $($Config.maxCreditsPerJob)" }

  $timeoutMin = if ($null -ne $raw.timeoutMin) { [double]$raw.timeoutMin } else { [double]$Config.defaultTimeoutMin }
  if ($timeoutMin -le 0 -or $timeoutMin -gt [double]$Config.maxTimeoutMin) { throw "timeoutMin $timeoutMin must be above 0 and at most $($Config.maxTimeoutMin)" }

  # Extra Copilot allow rules for this job, such as shell(dotnet test). Deny rules still win over them.
  $allowTools = @()
  foreach ($rule in @($raw.allowTools)) {
    if ($null -eq $rule) { continue }
    if ($rule -isnot [string] -or $rule -notmatch '^[A-Za-z0-9_.-]{1,60}(\([A-Za-z0-9 _.:*/-]{1,80}\))?$') { throw "allowTools entry '$rule' is not a rule of the form kind or kind(argument)" }
    $allowTools += $rule
  }

  $ticket = [string]$raw.ticket
  if ($ticket -and $ticket -cnotmatch '^[A-Z][A-Z0-9]{1,9}-[0-9]{1,7}$') { throw "ticket '$ticket' is not a ticket key such as ABC-123" }

  # A write job commits as the person who asked for it, so it has to say who that is.
  $gitName = ([string]$raw.gitName).Trim()
  $gitEmail = ([string]$raw.gitEmail).Trim()
  $branch = if ($raw.branch) { [string]$raw.branch } else { "rtfx/$id" }
  if ($mode -eq 'write') {
    if ($gitName -notmatch '^[^<>"\p{Cc}]{1,100}$') { throw 'a write job needs gitName, the name its commits are made under' }
    if ($gitEmail -notmatch '^[A-Za-z0-9._%+-]{1,64}@[A-Za-z0-9.-]{1,190}$') { throw 'a write job needs gitEmail, the address its commits are made under' }
    if ($branch -notmatch '^[A-Za-z0-9][A-Za-z0-9._/-]{0,199}$' -or $branch -like '*..*' -or $branch -like '*//*' -or
        $branch -like '*/' -or $branch -like '*.lock' -or $branch -like '*/.*') { throw "branch '$branch' is not a valid branch name" }
    if ($branch -eq $base) { throw "branch '$branch' is the base branch; a job works on a branch of its own" }
  }

  $taskFile = Join-Path $JobDir 'task.md'
  if (-not (Test-Path -LiteralPath $taskFile) -or -not (Get-Content -LiteralPath $taskFile -Raw).Trim()) { throw 'task.md is missing or empty' }

  return @{
    id = $id; repo = $repo; base = $base; mode = $mode; model = $model; effort = $effort
    maxCredits = $maxCredits; timeoutMin = $timeoutMin; taskFile = $taskFile; allowTools = $allowTools
    ticket = $ticket; gitName = $gitName; gitEmail = $gitEmail; branch = $branch; commit = $commit
    repoDir = Join-Path ([string]$Config.reposRoot) $repo
  }
}

# ---------- environment ----------

# Tools installed for the user alone with "pip install --user" (uv is one) land in a Scripts folder
# that is on nobody's PATH. A job gets it on its own.
function Add-UserToolPaths {
  $base = Join-Path $env:APPDATA 'Python'
  if (-not (Test-Path -LiteralPath $base)) { return @() }
  $added = @()
  foreach ($dir in Get-ChildItem -LiteralPath $base -Directory -Filter 'Python3*') {
    $scripts = Join-Path $dir.FullName 'Scripts'
    if ((Test-Path -LiteralPath $scripts) -and ($env:PATH -split ';') -notcontains $scripts) { $env:PATH = "$scripts;$env:PATH"; $added += $scripts }
  }
  return $added
}

# Removes from this process every variable a stripEnv pattern matches, unless keepEnv names it.
# Returns the names removed, never the values.
function Remove-SecretEnvironment([hashtable]$Config) {
  $removed = [Collections.Generic.List[string]]::new()
  foreach ($name in @([Environment]::GetEnvironmentVariables().Keys)) {
    if ($name -in $Config.keepEnv) { continue }
    foreach ($pattern in $Config.stripEnv) {
      if ($name -like $pattern) {
        # Not [Environment]::SetEnvironmentVariable($name, $null): PowerShell passes "" for the null,
        # and since .NET 9 that leaves the variable defined with an empty value.
        Remove-Item -LiteralPath "Env:\$name" -ErrorAction SilentlyContinue
        $removed.Add($name)
        break
      }
    }
  }
  return @($removed | Sort-Object)
}

# Guards under the deny rules, for every git started from this process tree. None of them touches
# the repository's own config.
#   - origin's push URL, and any URL a push could be given, is rewritten to one that cannot work;
#   - git has no ssh to talk through (the remotes here are ssh), and no prompt to wait on;
#   - commits are made as the person named in the job, whatever the checkout's config says.
# Call it after the worker's own fetch: nothing after that needs the remote.
function Set-GitGuards([string]$GitName, [string]$GitEmail) {
  $pairs = @(
    @('remote.origin.pushurl', 'rtfx-push-disabled://no'),
    @('url.rtfx-push-disabled://no/.pushInsteadOf', 'git@'),
    @('url.rtfx-push-disabled://no/.pushInsteadOf', 'ssh://'),
    @('url.rtfx-push-disabled://no/.pushInsteadOf', 'https://'),
    @('url.rtfx-push-disabled://no/.pushInsteadOf', 'http://')
  )
  if ($GitName -and $GitEmail) {
    $pairs += , @('user.name', $GitName)
    $pairs += , @('user.email', $GitEmail)
    $env:GIT_AUTHOR_NAME = $GitName
    $env:GIT_AUTHOR_EMAIL = $GitEmail
    $env:GIT_COMMITTER_NAME = $GitName
    $env:GIT_COMMITTER_EMAIL = $GitEmail
  }
  $env:GIT_CONFIG_COUNT = [string]$pairs.Count
  for ($i = 0; $i -lt $pairs.Count; $i++) {
    [Environment]::SetEnvironmentVariable("GIT_CONFIG_KEY_$i", $pairs[$i][0])
    [Environment]::SetEnvironmentVariable("GIT_CONFIG_VALUE_$i", $pairs[$i][1])
  }
  $env:GIT_TERMINAL_PROMPT = '0'
  $env:GIT_SSH_COMMAND = 'rtfx-ssh-disabled'
  Remove-Item -LiteralPath Env:\GIT_SSH -ErrorAction SilentlyContinue
}

# Proves, for this job, that the guards hold before Copilot is let near the worktree: a push must
# fail. Both tries are dry runs, so a guard that is not holding still publishes nothing. Returns
# what it found for result.json and throws when a push would have gone through.
function Test-GitGuards([string]$Worktree) {
  $target = 'HEAD:refs/heads/rtfx-guard-check'
  $found = [ordered]@{ pushBlocked = $false; sshBlocked = $null }
  $push = Invoke-Git @('-C', $Worktree, 'push', '--dry-run', 'origin', $target) 60
  $found.pushBlocked = $push.code -ne 0
  if (-not $found.pushBlocked) { throw 'the push guard is not holding: a dry-run push to origin went through. Copilot was not started.' }
  # The second guard only means something for an ssh remote. It is tried with the first one taken away.
  $url = (Invoke-Git @('-C', $Worktree, 'config', '--get', 'remote.origin.url')).output
  if ($url -match '^(ssh://|[^/@\s]+@[^:/\s]+:)') {
    $ssh = Invoke-Git @('-C', $Worktree, 'push', '--dry-run', 'origin', $target) 60 @{ GIT_CONFIG_COUNT = '0' }
    $found.sshBlocked = $ssh.code -ne 0
    if (-not $found.sshBlocked) { throw 'the ssh guard is not holding: with the push URL guard taken away, a dry-run push to origin went through. Copilot was not started.' }
  }
  return $found
}

# Takes files out of a job's sight without the job, or its commits, noticing: the repository's
# skills, commands and settings for another agent, and its MCP server lists. Each tracked file under
# the given paths is marked skip-worktree and then deleted from the worktree. The index is the
# worktree's own, so the real checkout is untouched, and since git no longer compares those files
# with the worktree, neither "git status" nor "git add -A" sees them as deleted.
# Returns how many files it hid.
function Hide-WorktreePaths([string]$Worktree, [string[]]$Paths) {
  foreach ($path in $Paths) {
    if (-not $path -or $path -like '*..*' -or [IO.Path]::IsPathRooted($path)) { throw "hidePaths entry '$path' is not a path inside the repository" }
  }
  if (-not $Paths) { return 0 }
  # One listing for all of them: every git call costs a process start, and a job should not wait on a dozen.
  $listed = Invoke-Git (@('-C', $Worktree, '-c', 'core.quotePath=false', 'ls-files', '--') + $Paths)
  if ($listed.code -ne 0) { throw "git ls-files failed: $($listed.output)" }
  $files = @($listed.output -split "`n" | ForEach-Object { $_.TrimEnd("`r") } | Where-Object { $_ })
  for ($start = 0; $start -lt $files.Count; $start += 200) {
    $batch = @($files[$start..([Math]::Min($start + 199, $files.Count - 1))])
    $marked = Invoke-Git (@('-C', $Worktree, 'update-index', '--skip-worktree', '--') + $batch)
    if ($marked.code -ne 0) { throw "git update-index --skip-worktree failed: $($marked.output)" }
    foreach ($file in $batch) { Remove-Item -LiteralPath (Join-Path $Worktree $file) -Force -ErrorAction SilentlyContinue }
  }
  # Whatever is left at those paths is empty folders, or nothing.
  if ($files.Count -gt 0) {
    foreach ($path in $Paths) {
      $full = Join-Path $Worktree $path
      if ((Test-Path -LiteralPath $full -PathType Container) -and -not (Get-ChildItem -LiteralPath $full -Recurse -File -Force | Select-Object -First 1)) {
        Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction SilentlyContinue
      }
    }
  }
  return $files.Count
}

# ---------- package feeds ----------

# A repository's Nuget.config names its private feeds but carries no credentials, and NuGet does not
# read the feed user and password from the variables builds are given. It does read
# NuGetPackageSourceCredentials_<source name>. So for every source in the repository's config whose
# host is one of the private feeds, that variable is set in this process, for the job to inherit.
# The values exist in the environment only: nothing here writes or logs them.
# Returns @{ sources = names given credentials; warnings = what could not be done }.
function Set-NuGetFeedCredentials([string]$Worktree, [hashtable]$Config) {
  $found = @{ sources = @(); warnings = @() }
  $listed = Invoke-Git @('-C', $Worktree, '-c', 'core.quotePath=false', 'ls-files', '--', ':(icase,glob)**/nuget.config')
  $files = @($listed.output -split "`n" | ForEach-Object { $_.TrimEnd("`r") } | Where-Object { $_ })
  if (-not $files) { return $found }
  $user = [Environment]::GetEnvironmentVariable([string]$Config.feedUserVar)
  $pass = [Environment]::GetEnvironmentVariable([string]$Config.feedPassVar)
  $names = [Collections.Generic.List[string]]::new()
  foreach ($file in $files) {
    try { $document = [xml](Get-Content -LiteralPath (Join-Path $Worktree $file) -Raw) }
    catch { $found.warnings += "cannot read $file to find its private package feeds: $($_.Exception.Message)"; continue }
    foreach ($source in @($document.SelectNodes('/configuration/packageSources/add'))) {
      $name = [string]$source.GetAttribute('key')
      $hostName = $null
      try { $hostName = ([Uri][string]$source.GetAttribute('value')).Host } catch { }
      if (-not $name -or -not $hostName -or $name -in $names) { continue }
      if (-not (@($Config.feedHosts) | Where-Object { $hostName -like $_ })) { continue }
      $names.Add($name)
    }
  }
  if ($names.Count -eq 0) { return $found }
  if (-not $user -or -not $pass) {
    $found.warnings += "the private package feeds ($($names -join ', ')) need $($Config.feedUserVar) and $($Config.feedPassVar), which the runner's environment does not have; restore will be refused by them"
    return $found
  }
  if ($user.Contains(';') -or $pass.Contains(';')) {
    $found.warnings += "the feed user or password contains a semicolon, which the NuGet credential variable cannot carry; no credentials were supplied for $($names -join ', ')"
    return $found
  }
  foreach ($name in $names) {
    # A variable name cannot hold an equals sign or a control character. The source keeps its name:
    # renaming it is the repository's business, so such a source goes without and is reported.
    if ($name -match '[=\p{Cc}]') { $found.warnings += "the package source '$name' has a name no environment variable can carry, so it was given no credentials"; continue }
    [Environment]::SetEnvironmentVariable("NuGetPackageSourceCredentials_$name", "Username=$user;Password=$pass")
    $found.sources += $name
  }
  return $found
}

# ---------- MCP servers ----------

# Names of the MCP servers Copilot would start for a job: the user's own, and the ones the
# repository declares (.mcp.json or .github/mcp.json, which Copilot loads for a worktree of a trusted
# checkout). The worker turns every one of them off, because they can reach shared systems.
# A file that is there but cannot be read fails the job rather than letting its servers through.
function Get-McpServerNames([string]$Worktree) {
  $copilotHome = if ($env:COPILOT_HOME) { $env:COPILOT_HOME } else { Join-Path $HOME '.copilot' }
  $files = @(
    (Join-Path $copilotHome 'mcp-config.json'),
    (Join-Path $Worktree '.mcp.json'),
    (Join-Path $Worktree '.github\mcp.json')
  )
  $names = [Collections.Generic.List[string]]::new()
  foreach ($file in $files) {
    if (-not (Test-Path -LiteralPath $file)) { continue }
    try { $document = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json -AsHashtable }
    catch { throw "cannot read $file to turn its MCP servers off: $($_.Exception.Message)" }
    if ($document -is [Collections.IDictionary] -and $document.mcpServers -is [Collections.IDictionary]) {
      foreach ($name in $document.mcpServers.Keys) { if ($name -notin $names) { $names.Add([string]$name) } }
    }
  }
  return @($names)
}

# One line of the job index the runner keeps for clients: what "status" needs, without opening each job.
function Get-JobSummary([string]$JobDir, $Status) {
  $job = Read-JsonFile (Join-Path $JobDir 'job.json')
  if ($job -isnot [Collections.IDictionary]) { $job = @{} }
  return [ordered]@{
    id = Split-Path $JobDir -Leaf; state = $Status.state; repo = $job.repo; mode = $(if ($job.mode) { $job.mode } else { 'write' })
    model = $job.model; ticket = $job.ticket; queuedAt = $Status.queuedAt; startedAt = $Status.startedAt
    finishedAt = $Status.finishedAt; credits = $Status.credits; nearCreditCap = [bool]$Status.nearCreditCap; error = $Status.error
  }
}

# ---------- results ----------

# Pulls the final assistant message and the credit count out of Copilot's JSONL output.
function Get-CopilotOutcome([string]$JobDir) {
  $outcome = @{
    finalMessage = $null; credits = $null; model = $null; sessionId = $null; events = 0; mcpConnected = @()
    tokens = $null; budgetPercent = $null; budgetUsed = $null
  }
  $nano = $null
  $file = Join-Path $JobDir 'copilot.jsonl'
  if (Test-Path -LiteralPath $file) {
    try {
      foreach ($line in [IO.File]::ReadLines($file)) {
        if (-not $line.StartsWith('{')) { continue }
        $outcome.events++
        # The streaming deltas are most of the file and carry nothing wanted here.
        if ($line.StartsWith('{"type":"assistant.message_delta"') -or $line.StartsWith('{"type":"assistant.reasoning_delta"') -or
            $line.StartsWith('{"type":"assistant.tool_call_delta"')) { continue }
        # Copilot reports cost only when a run ends. Until then the one trace of it is the budget
        # note it appends to tool results, in whole percent of the cap.
        if ($line.Contains('% used') -and $line -match '\[cost: (\d{1,3})% used') { $outcome.budgetPercent = [int]$Matches[1] }
        if ($line.Contains('Session limits:') -and $line -match 'Session limits: ([\d.]+)/[\d.]+ AI credits used') { $outcome.budgetUsed = [double]$Matches[1] }
        try { $entry = $line | ConvertFrom-Json -AsHashtable } catch { continue }
        if ($entry -isnot [Collections.IDictionary]) { continue }
        $data = $entry.data
        if ($data -isnot [Collections.IDictionary]) { continue }
        switch ([string]$entry.type) {
          'assistant.message' { if ($data.content -is [string] -and $data.content.Trim()) { $outcome.finalMessage = $data.content } }
          'session.start' { $outcome.sessionId = $data.sessionId; if ($data.selectedModel) { $outcome.model = $data.selectedModel } }
          'session.usage_checkpoint' { if ($null -ne $data.totalNanoAiu) { $nano = $data.totalNanoAiu } }
          'session.shutdown' { if ($null -ne $data.totalNanoAiu) { $nano = $data.totalNanoAiu } }
          'session.mcp_server_status_changed' {
            if ($data.status -eq 'connected' -and $data.serverName -notin $outcome.mcpConnected) { $outcome.mcpConnected += [string]$data.serverName }
          }
        }
      }
    } catch { }
  }
  $usage = Read-JsonFile (Join-Path $JobDir 'usage.json')
  if ($usage -is [Collections.IDictionary]) {
    if ($null -ne $usage.totalNanoAiu) { $nano = $usage.totalNanoAiu }
    $details = $usage.tokenDetails
    if ($details -is [Collections.IDictionary]) {
      $outcome.tokens = [ordered]@{}
      foreach ($kind in 'input', 'cache_read', 'cache_write', 'output') {
        if ($details[$kind] -is [Collections.IDictionary]) { $outcome.tokens[$kind] = $details[$kind].tokenCount }
      }
    }
  }
  if ($null -ne $nano) { $outcome.credits = [Math]::Round([double]$nano / 1e9, 4) }
  return $outcome
}

# Writes result.json, then the terminal status. In that order, so whoever sees a terminal state
# finds the result already there.
function Complete-Job([string]$JobDir, [string]$State, [string]$ErrorText, [hashtable]$Extra) {
  $status = Get-JobStatus $JobDir
  $job = Read-JsonFile (Join-Path $JobDir 'job.json')
  if ($job -isnot [Collections.IDictionary]) { $job = @{} }
  $outcome = Get-CopilotOutcome $JobDir
  $finished = Get-UtcStamp
  $started = if ($status) { $status.startedAt } else { $null }
  $duration = $null
  if ($started) { $duration = [int]((ConvertTo-UtcTime $finished) - (ConvertTo-UtcTime $started)).TotalSeconds }

  # A run that was killed never reports its cost. What can be said is a floor: the budget note is
  # rounded to a whole percent, so one percent less than it shows has certainly been spent.
  $cap = 0.0
  if ($null -ne $job.maxCredits) { try { $cap = [double]$job.maxCredits } catch { } }
  if ($cap -le 0) { $cap = 30.0 }
  $floor = $null
  if ($null -eq $outcome.credits) {
    if ($outcome.budgetPercent -gt 1) { $floor = [Math]::Round(($outcome.budgetPercent - 1) / 100.0 * $cap, 2) }
    if ($null -ne $outcome.budgetUsed -and ($null -eq $floor -or $outcome.budgetUsed -gt $floor)) { $floor = $outcome.budgetUsed }
  }

  # Copilot's cap is soft, and it does not wait for it: once nine tenths are spent it makes the
  # next model call the last and takes the tools away. A job that ends up there may have been
  # wound down rather than finished, and must not read like any other finished job.
  $nearCap = $null -ne $outcome.credits -and $outcome.credits -ge 0.9 * $cap

  $result = [ordered]@{
    id                = Split-Path $JobDir -Leaf
    state             = $State
    error             = if ($ErrorText) { $ErrorText } else { $null }
    repo              = $job.repo
    mode              = $job.mode
    ticket            = $job.ticket
    model             = $outcome.model
    sessionId         = $outcome.sessionId
    finalMessage      = $outcome.finalMessage
    credits           = $outcome.credits
    creditsLowerBound = $floor
    creditCap         = $cap
    nearCreditCap     = $nearCap
    tokens            = $outcome.tokens
    startedAt         = $started
    finishedAt        = $finished
    durationSec       = $duration
  }
  if ($Extra) { foreach ($key in $Extra.Keys) { $result[$key] = $Extra[$key] } }
  $warnings = @()
  if ($result.Contains('warnings')) { $warnings = @($result['warnings'] | Where-Object { $_ }) }
  if ($outcome.mcpConnected.Count -gt 0) { $warnings += "MCP servers connected during the run: $($outcome.mcpConnected -join ', ')" }
  if ($nearCap) { $warnings += "spent $($outcome.credits) of its $cap credit cap: past nine tenths Copilot makes the next model call the last and disables tools, so the work may have been cut short" }
  $result['warnings'] = $warnings
  Write-JsonFile (Join-Path $JobDir 'result.json') $result
  Set-JobStatus $JobDir @{ state = $State; finishedAt = $finished; error = $result.error; credits = $outcome.credits; nearCreditCap = $nearCap }
}

# ---------- worktrees ----------

function Remove-JobWorktree([string]$RepoDir, [string]$Worktree, [string]$WorktreeRoot) {
  if (-not (Test-Path -LiteralPath $Worktree)) { return $true }
  # Only ever delete a direct child of the runner's own worktree folder.
  $parent = [IO.Path]::GetFullPath((Split-Path $Worktree -Parent)).TrimEnd('\')
  if ($parent -ne [IO.Path]::GetFullPath($WorktreeRoot).TrimEnd('\')) { throw "refusing to remove '$Worktree': it is not under '$WorktreeRoot'" }
  $haveRepo = $RepoDir -and (Test-Path -LiteralPath $RepoDir)
  for ($try = 0; $try -lt 3; $try++) {
    if ($haveRepo) { [void](Invoke-Git @('-C', $RepoDir, 'worktree', 'remove', '--force', $Worktree) 60) }
    if (-not (Test-Path -LiteralPath $Worktree)) { break }
    try { Remove-Item -LiteralPath $Worktree -Recurse -Force -ErrorAction Stop } catch { Start-Sleep -Seconds 2 }
  }
  if ($haveRepo) { [void](Invoke-Git @('-C', $RepoDir, 'worktree', 'prune') 60) }
  return (-not (Test-Path -LiteralPath $Worktree))
}

# Puts the brief in the worktree as a file, so its length is not bound by the command line, and
# tells git to ignore it. The ignore entry goes in the checkout's info/exclude, which every worktree
# of it shares: one line, added once, for a file name the checkout does not use.
function Add-TaskFile([string]$Worktree, [string]$TaskFile) {
  $name = 'TASK.md'
  $tracked = Invoke-Git @('-C', $Worktree, 'ls-files', '--', ':(top,icase)TASK.md')
  if ($tracked.output) { $name = 'RTFX-TASK.md' }
  Copy-Item -LiteralPath $TaskFile -Destination (Join-Path $Worktree $name) -Force
  $where = Invoke-Git @('-C', $Worktree, 'rev-parse', '--git-path', 'info/exclude')
  if ($where.code -ne 0 -or -not $where.output) { throw "cannot find the checkout's info/exclude: $($where.output)" }
  $exclude = [IO.Path]::GetFullPath($where.output, $Worktree)
  New-Item -ItemType Directory -Force (Split-Path $exclude -Parent) | Out-Null
  $entry = "/$name"
  $have = @()
  if (Test-Path -LiteralPath $exclude) { $have = @(Get-Content -LiteralPath $exclude) }
  if ($entry -notin $have) {
    for ($try = 0; ; $try++) {
      try { Add-Content -LiteralPath $exclude -Value $entry -Encoding utf8 -ErrorAction Stop; break }
      catch { if ($try -ge 5) { throw }; Start-Sleep -Milliseconds 100 }
    }
  }
  return $name
}

# ---------- what a write job leaves behind ----------

# Gathers a write job's work once Copilot is out of the way, whether it finished or was stopped:
# commits anything left uncommitted, lists what is on the branch, and packs the branch into
# result.bundle. Returns the fields for result.json; 'warnings' in it is for the caller to merge.
function Save-JobWork([hashtable]$Job, [string]$JobDir, [string]$Worktree, [string]$BaseCommit, [string]$TaskName) {
  $work = @{
    branch = $Job.branch; baseCommit = $BaseCommit; headCommit = $null; commits = @(); filesChanged = @(); diffStat = $null
    cleanBeforeAutoCommit = $null; autoCommit = $null; bundle = $null; patch = $null; warnings = @()
  }
  $git = @('-C', $Worktree)
  $ref = "refs/heads/$($Job.branch)"
  if ($TaskName) { Remove-Item -LiteralPath (Join-Path $Worktree $TaskName) -Force -ErrorAction SilentlyContinue }

  # The work is whatever the branch holds. If the agent wandered off it, follow when that loses nothing.
  $onBranch = $true
  $current = Invoke-Git ($git + @('symbolic-ref', '--quiet', '--short', 'HEAD'))
  if ($current.code -ne 0 -or $current.output -ne $Job.branch) {
    $where = if ($current.code -eq 0) { "branch $($current.output)" } else { 'a detached HEAD' }
    $ahead = Invoke-Git ($git + @('merge-base', '--is-ancestor', $ref, 'HEAD'))
    $moved = if ($ahead.code -eq 0) { Invoke-Git ($git + @('checkout', '--quiet', '-B', $Job.branch)) } else { @{ code = 1 } }
    if ($moved.code -eq 0) { $work.warnings += "the agent left the worktree on $where; $($Job.branch) was moved up to it" }
    else {
      $onBranch = $false
      $work.warnings += "the agent left the worktree on $where, which does not continue $($Job.branch); what is there is not in the bundle"
    }
  }

  $dirty = Invoke-Git ($git + @('status', '--porcelain'))
  if ($dirty.code -eq 0) { $work.cleanBeforeAutoCommit = -not $dirty.output }
  if ($dirty.code -eq 0 -and $dirty.output -and $onBranch) {
    $prefix = if ($Job.ticket) { "$($Job.ticket): " } else { '' }
    $identity = @('-c', "user.name=$($Job.gitName)", '-c', "user.email=$($Job.gitEmail)")
    $staged = Invoke-Git ($git + @('add', '-A')) 300
    # No hooks: this commit exists to carry the leftovers back, not to pass review.
    $commit = Invoke-Git ($git + $identity + @('commit', '--quiet', '--no-verify', '-m', "${prefix}uncommitted changes left by the agent")) 300
    if ($staged.code -eq 0 -and $commit.code -eq 0) { $work.autoCommit = (Invoke-Git ($git + @('rev-parse', 'HEAD'))).output }
    else { $work.warnings += "could not commit the uncommitted changes: $($staged.output) $($commit.output)".Trim() }
  }

  $head = Invoke-Git ($git + @('rev-parse', '--verify', '--quiet', "$ref^{commit}"))
  if ($head.code -ne 0) { $work.warnings += "branch $($Job.branch) is gone"; return $work }
  $work.headCommit = $head.output
  $range = "$BaseCommit..$ref"

  $log = Invoke-Git ($git + @('log', '--reverse', '--format=%H%x09%an <%ae>%x09%s', $range))
  $unprefixed = @(); $strangers = @()
  $expected = "$($Job.gitName) <$($Job.gitEmail)>"
  foreach ($line in @($log.output -split "`n" | Where-Object { $_.Trim() })) {
    $parts = $line.TrimEnd("`r") -split "`t", 3
    if ($parts.Count -lt 3) { continue }
    $work.commits += , ([ordered]@{ hash = $parts[0]; author = $parts[1]; subject = $parts[2] })
    $short = $parts[0].Substring(0, 8)
    if ($Job.ticket -and -not $parts[2].StartsWith("$($Job.ticket): ", [StringComparison]::Ordinal)) { $unprefixed += $short }
    if ($parts[1] -ne $expected) { $strangers += $short }
  }
  if ($unprefixed) { $work.warnings += "commit subjects that do not start with '$($Job.ticket): ': $($unprefixed -join ', ')" }
  if ($strangers) { $work.warnings += "commits not authored as $($expected): $($strangers -join ', ')" }
  $bodies = (Invoke-Git ($git + @('log', '--format=%B', $range))).output
  if ($bodies -match '(?im)^\s*co-authored-by:') { $work.warnings += 'a commit message carries a Co-authored-by trailer' }
  if ($bodies.Contains([string][char]0x2014)) { $work.warnings += 'a commit message contains an em dash' }

  $names = Invoke-Git ($git + @('diff', '--name-status', $BaseCommit, $ref))
  foreach ($line in @($names.output -split "`n" | Where-Object { $_.Trim() })) {
    $parts = $line.TrimEnd("`r") -split "`t"
    $work.filesChanged += , ([ordered]@{ status = $parts[0]; path = $parts[-1] })
    if ($TaskName -and $parts[-1] -eq $TaskName) { $work.warnings += "the agent committed the brief file $TaskName" }
  }
  $work.diffStat = (Invoke-Git ($git + @('diff', '--stat=160', $BaseCommit, $ref))).output

  if ($work.commits.Count -eq 0) { $work.warnings += 'the branch has no commits beyond its base, so there is no bundle'; return $work }
  # The same change as text, so it can be read before anyone fetches the bundle.
  $patchFile = Join-Path $JobDir 'result.patch'
  $patch = Invoke-Git ($git + @('diff', '--no-color', "--output=$patchFile", $BaseCommit, $ref)) 300
  if ($patch.code -eq 0 -and (Test-Path -LiteralPath $patchFile)) { $work.patch = [ordered]@{ file = 'result.patch'; bytes = (Get-Item -LiteralPath $patchFile).Length } }
  else { $work.warnings += "could not write result.patch: $($patch.output)" }
  $bundleFile = Join-Path $JobDir 'result.bundle'
  Remove-Item -LiteralPath $bundleFile -Force -ErrorAction SilentlyContinue
  $bundle = Invoke-Git ($git + @('bundle', 'create', $bundleFile, $range)) 600
  if ($bundle.code -ne 0 -or -not (Test-Path -LiteralPath $bundleFile)) { $work.warnings += "git bundle create failed: $($bundle.output)"; return $work }
  $work.bundle = [ordered]@{
    file   = 'result.bundle'
    ref    = $ref
    bytes  = (Get-Item -LiteralPath $bundleFile).Length
    sha256 = (Get-FileHash -LiteralPath $bundleFile -Algorithm SHA256).Hash.ToLowerInvariant()
  }
  return $work
}

# A write job that committed nothing has nothing to wait for a fetch with: its worktree and the
# branch it made go at once. Returns $true when it removed them.
function Remove-EmptyJobWork([hashtable]$Job, [hashtable]$Work, [string]$Worktree, [string]$WorktreeRoot, [bool]$BranchCreated) {
  if (@($Work.commits).Count -gt 0 -or -not $Work.headCommit) { return $false }
  if (-not (Remove-JobWorktree $Job.repoDir $Worktree $WorktreeRoot)) { return $false }
  if ($BranchCreated) { [void](Invoke-Git @('-C', $Job.repoDir, 'branch', '-D', $Job.branch) 60) }
  return $true
}

# Removes a finished job's worktree, and the branch the job made for itself: once the bundle has
# been fetched (or has aged out) the branch is only clutter in the checkout.
function Remove-JobWork([string]$JobDir, [hashtable]$Config, [string]$WorktreeRoot) {
  $worktree = Join-Path $WorktreeRoot (Split-Path $JobDir -Leaf)
  $repoDir = $null
  try { $repoDir = (Read-Job $JobDir $Config).repoDir } catch { }
  if (-not (Remove-JobWorktree $repoDir $worktree $WorktreeRoot)) { return $false }
  $result = Read-JsonFile (Join-Path $JobDir 'result.json')
  if ($repoDir -and $result -is [Collections.IDictionary] -and $result.branchCreated -and $result.branch) {
    [void](Invoke-Git @('-C', $repoDir, 'branch', '-D', [string]$result.branch) 60)
  }
  return $true
}
