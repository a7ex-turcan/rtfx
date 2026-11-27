<#
  Prints the release notes of the current version: the section of CHANGELOG.md headed
  "## [<version>]". Fails when the server and the runner disagree on the version, when -Tag is not
  "v<version>", or when the section is missing or empty, so a release never goes out without notes.

    pwsh -NoProfile -File build/release-notes.ps1                      # the current version's notes
    pwsh -NoProfile -File build/release-notes.ps1 -Tag v0.3.1 -Out notes.md
#>
param(
  [string]$Tag,
  [string]$Out,
  [string]$Changelog = (Join-Path (Split-Path $PSScriptRoot) 'CHANGELOG.md')
)

$ErrorActionPreference = 'Stop'
$version = [string](& (Join-Path $PSScriptRoot 'version.ps1'))
if ($Tag -and $Tag -cne "v$version") {
  throw "the tag $Tag does not match the project version ${version}: expected v$version. Change the version in src/Rtfx/Rtfx.csproj and runner/lib.ps1, or tag v$version."
}
if (-not (Test-Path -LiteralPath $Changelog)) { throw "$Changelog does not exist" }

$lines = @(Get-Content -LiteralPath $Changelog)
$start = -1
for ($i = 0; $i -lt $lines.Count; $i++) {
  if ($lines[$i] -match '^## \[([^\]]+)\]' -and $Matches[1] -eq $version) { $start = $i; break }
}
if ($start -lt 0) { throw "CHANGELOG.md has no section '## [$version]': write the release notes there first" }

# The section runs to the next version's heading, or to the link definitions at the end of the file.
$body = [Collections.Generic.List[string]]::new()
for ($i = $start + 1; $i -lt $lines.Count; $i++) {
  if ($lines[$i] -match '^## ' -or $lines[$i] -match '^\[[^\]]+\]:\s') { break }
  $body.Add($lines[$i])
}
while ($body.Count -gt 0 -and -not $body[0].Trim()) { $body.RemoveAt(0) }
while ($body.Count -gt 0 -and -not $body[$body.Count - 1].Trim()) { $body.RemoveAt($body.Count - 1) }
# Headings alone are not notes.
if (-not @($body | Where-Object { $_.Trim() -and $_ -notmatch '^#' })) {
  throw "the section '## [$version]' of CHANGELOG.md is empty"
}

if ($Out) {
  $folder = Split-Path ([IO.Path]::GetFullPath($Out))
  New-Item -ItemType Directory -Force $folder | Out-Null
  [IO.File]::WriteAllLines([IO.Path]::GetFullPath($Out), $body)
  "release notes for $version written to ${Out}: $($body.Count) lines"
}
else { $body }
