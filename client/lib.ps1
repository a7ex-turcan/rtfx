# Shared by the scripts in this folder, which run next to Claude Code and drive the runner on the
# Copilot machine. Everything goes over scp: a job is a folder of files, so submitting, polling,
# cancelling and fetching are all file copies, and no command ever has to be quoted through ssh.
Set-StrictMode -Version 1.0

$RtfxTerminalStates = @('done', 'failed', 'cancelled', 'timeout')
$RtfxIdPattern = '^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$'

# Defaults, then client\config.json, then RTFX_* environment variables.
#   remoteHost   ssh host of the Copilot machine; "." means the runner root is a local folder (tests)
#   remoteRoot   the runner's root there
#   localRepos   where this machine keeps its own checkouts, read for the commit identity
#   cache        where downloaded results and bundles are kept
function Get-RtfxClientConfig {
  $config = @{
    remoteHost = 'rtfx-worker'
    remoteRoot = 'C:/rtfx'
    localRepos = Join-Path $HOME 'source\repos'
    cache      = Join-Path $env:LOCALAPPDATA 'rtfx'
    scpRetries = 4
  }
  $file = Join-Path $PSScriptRoot 'config.json'
  if (Test-Path -LiteralPath $file) {
    $overrides = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json -AsHashtable
    foreach ($key in @($overrides.Keys)) {
      if (-not $config.ContainsKey($key)) { throw "config.json: unknown setting '$key'" }
      $config[$key] = $overrides[$key]
    }
  }
  if ($env:RTFX_HOST) { $config.remoteHost = $env:RTFX_HOST }
  if ($env:RTFX_ROOT) { $config.remoteRoot = $env:RTFX_ROOT }
  if ($env:RTFX_LOCAL_REPOS) { $config.localRepos = $env:RTFX_LOCAL_REPOS }
  if ($env:RTFX_CACHE) { $config.cache = $env:RTFX_CACHE }
  $config.remoteRoot = ([string]$config.remoteRoot).Replace('\', '/').TrimEnd('/')
  return $config
}

function Assert-JobId([string]$Id) {
  if ($Id -notmatch $RtfxIdPattern) { throw "job id '$Id' is not valid: letters, digits, - and _ only" }
}

function Get-RemotePath([hashtable]$Config, [string]$Relative) {
  $path = "$($Config.remoteRoot)/$($Relative.Replace('\', '/').TrimStart('/'))"
  if ($Config.remoteHost -eq '.') { return $path.Replace('/', '\') }
  return "$($Config.remoteHost):$path"
}

# One scp, retried: the connection to the Copilot machine drops now and then.
# Returns $true, or $false when the remote file does not exist. Anything else throws.
function Invoke-Scp([hashtable]$Config, [string]$From, [string]$To, [switch]$Recurse) {
  $options = @('-q', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=20')
  if ($Recurse) { $options += '-r' }
  $output = ''
  for ($try = 1; $try -le [int]$Config.scpRetries; $try++) {
    $output = (& scp @options $From $To 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -eq 0) { return $true }
    if ($output -match '(?i)no such file|cannot find|not a regular file') { return $false }
    Start-Sleep -Seconds (2 * $try)
  }
  throw "scp $From -> $To failed after $($Config.scpRetries) tries: $output"
}

function Copy-ToRunner([hashtable]$Config, [string]$LocalPath, [string]$Relative, [switch]$Recurse) {
  $target = Get-RemotePath $Config $Relative
  if ($Config.remoteHost -eq '.') {
    if ($Recurse) { Copy-Item -LiteralPath $LocalPath -Destination $target -Recurse -Force }
    else {
      # Copy then rename, so the runner never reads half a file.
      Copy-Item -LiteralPath $LocalPath -Destination "$target.part" -Force
      Move-Item -LiteralPath "$target.part" -Destination $target -Force
    }
    return
  }
  if (-not (Invoke-Scp $Config $LocalPath $target -Recurse:$Recurse)) { throw "scp to $target failed: no such file or directory" }
}

# Returns $false when the file is not there.
function Copy-FromRunner([hashtable]$Config, [string]$Relative, [string]$LocalPath) {
  $source = Get-RemotePath $Config $Relative
  New-Item -ItemType Directory -Force (Split-Path $LocalPath -Parent) | Out-Null
  if ($Config.remoteHost -eq '.') {
    if (-not (Test-Path -LiteralPath $source)) { return $false }
    Copy-Item -LiteralPath $source -Destination $LocalPath -Force
    return $true
  }
  return (Invoke-Scp $Config $source $LocalPath)
}

function Get-JobCache([hashtable]$Config, [string]$Id) {
  $dir = Join-Path (Join-Path $Config.cache 'jobs') $Id
  New-Item -ItemType Directory -Force $dir | Out-Null
  return $dir
}

# Downloads a JSON file from the runner and reads it. $null when it is not there or not whole yet.
function Read-RunnerJson([hashtable]$Config, [string]$Relative, [string]$LocalPath) {
  $temporary = -not $LocalPath
  if ($temporary) { $LocalPath = Join-Path ([IO.Path]::GetTempPath()) ("rtfx-" + [guid]::NewGuid().ToString('N') + '.json') }
  try {
    if (-not (Copy-FromRunner $Config $Relative $LocalPath)) { return $null }
    try { return (Get-Content -LiteralPath $LocalPath -Raw | ConvertFrom-Json -AsHashtable) } catch { return $null }
  }
  finally { if ($temporary) { Remove-Item -LiteralPath $LocalPath -Force -ErrorAction SilentlyContinue } }
}

# Drops a small file on the runner: a cancel request, a fetched receipt, a models request.
function Send-RunnerMarker([hashtable]$Config, [string]$Relative, [string]$Text) {
  $temp = Join-Path ([IO.Path]::GetTempPath()) ("rtfx-" + [guid]::NewGuid().ToString('N') + '.marker')
  try {
    [IO.File]::WriteAllText($temp, $Text, [Text.UTF8Encoding]::new($false))
    Copy-ToRunner $Config $temp $Relative
  }
  finally { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
}

function Get-UtcStamp { [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ') }

function ConvertTo-UtcTime($Value) {
  if ($null -eq $Value) { return $null }
  if ($Value -is [DateTime]) { return $Value.ToUniversalTime() }
  $styles = [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal
  return [DateTime]::Parse([string]$Value, [Globalization.CultureInfo]::InvariantCulture, $styles)
}

# The runner writes a heartbeat every few seconds. Returns it with ageSec added, or $null.
function Get-RunnerHeartbeat([hashtable]$Config) {
  $beat = Read-RunnerJson $Config 'heartbeat.json'
  if ($beat -is [Collections.IDictionary] -and $beat.at) { $beat['ageSec'] = [int]([DateTime]::UtcNow - (ConvertTo-UtcTime $beat.at)).TotalSeconds }
  return $beat
}

function Invoke-LocalGit([string[]]$GitArgs) {
  $output = (& git @GitArgs 2>&1 | Out-String).Trim()
  return @{ code = $LASTEXITCODE; output = $output }
}
