<#
  Brings a write job's branch into a local checkout. It downloads result.bundle, checks it against
  the hash in result.json and against the target repository, and fetches the branch from it. Then it
  tells the runner the work has arrived, which lets the runner drop the job's worktree.

  It only ever adds a branch. It never checks anything out and never touches the working tree, and
  it refuses to move a branch that already exists somewhere the bundle does not continue.

    pwsh -NoProfile -File client\fetch.ps1 -Id 20261127-140000-ab12 -Target C:\scratch\my-repo
#>
param(
  [Parameter(Mandatory)][string]$Id,
  [Parameter(Mandatory)][string]$Target
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib.ps1')
$config = Get-RtfxClientConfig
Assert-JobId $Id

$Target = [IO.Path]::GetFullPath($Target)
$inside = Invoke-LocalGit @('-C', $Target, 'rev-parse', '--git-dir')
if ($inside.code -ne 0) { throw "$Target is not a git repository" }

$cache = Get-JobCache $config $Id
$result = Read-RunnerJson $config "jobs/$Id/result.json" (Join-Path $cache 'result.json')
if (-not $result) { throw "job $Id has no result yet" }
if ($result.bundle -isnot [Collections.IDictionary]) { throw "job $Id ($($result.state)) has no bundle: $(@($result.warnings) -join '; ')" }
$ref = [string]$result.bundle.ref
$base = [string]$result.baseCommit
$head = [string]$result.headCommit
if ($ref -notmatch '^refs/heads/[A-Za-z0-9][A-Za-z0-9._/-]*$' -or $base -notmatch '^[0-9a-f]{40,64}$' -or $head -notmatch '^[0-9a-f]{40,64}$') {
  throw "result.json of job $Id does not describe its bundle properly"
}

$bundle = Join-Path $cache 'result.bundle'
if (-not (Copy-FromRunner $config "jobs/$Id/result.bundle" $bundle)) { throw "result.bundle of job $Id is not on the runner" }
$hash = (Get-FileHash -LiteralPath $bundle -Algorithm SHA256).Hash.ToLowerInvariant()
if ($hash -ne [string]$result.bundle.sha256) { throw "result.bundle arrived damaged: its hash is $hash, result.json says $($result.bundle.sha256)" }

# The bundle holds only what the job added, so the target must already have the commit it started from.
$haveBase = Invoke-LocalGit @('-C', $Target, 'cat-file', '-e', "$base^{commit}")
if ($haveBase.code -ne 0) {
  [void](Invoke-LocalGit @('-C', $Target, 'fetch', '--quiet', 'origin'))
  $haveBase = Invoke-LocalGit @('-C', $Target, 'cat-file', '-e', "$base^{commit}")
  if ($haveBase.code -ne 0) { throw "$Target does not have the commit the job started from ($base), even after fetching origin" }
}
$verify = Invoke-LocalGit @('-C', $Target, 'bundle', 'verify', '--quiet', $bundle)
if ($verify.code -ne 0) { throw "the bundle does not fit $Target`: $($verify.output)" }

$before = Invoke-LocalGit @('-C', $Target, 'rev-parse', '--verify', '--quiet', $ref)
# No leading +, so git refuses anything but a new branch or a fast-forward of an existing one.
$fetch = Invoke-LocalGit @('-C', $Target, 'fetch', '--no-tags', '--quiet', $bundle, "$ref`:$ref")
if ($fetch.code -ne 0) { throw "could not fetch $ref into $Target`: $($fetch.output)" }
$after = Invoke-LocalGit @('-C', $Target, 'rev-parse', '--verify', '--quiet', $ref)
if ($after.output -ne $head) { throw "$ref in $Target is at $($after.output), but the job ended at $head" }

Send-RunnerMarker $config "jobs/$Id/fetched" "$(Get-UtcStamp) fetched into $env:COMPUTERNAME"

[ordered]@{
  id         = $Id
  target     = $Target
  branch     = $ref.Substring('refs/heads/'.Length)
  head       = $head
  base       = $base
  commits    = @($result.commits).Count
  alreadyHad = ($before.code -eq 0 -and $before.output -eq $head)
} | ConvertTo-Json
