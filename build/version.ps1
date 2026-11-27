<#
  Prints the version of rtfx. The server (src/Rtfx/Rtfx.csproj) and the runner (runner/lib.ps1) each
  carry it, and they are released together, so this fails when the two differ.

    pwsh -NoProfile -File build/version.ps1
#>
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot

$project = [xml](Get-Content -LiteralPath (Join-Path $repo 'src\Rtfx\Rtfx.csproj') -Raw)
$server = [string](@($project.Project.PropertyGroup.Version) | Where-Object { $_ } | Select-Object -First 1)
if (-not $server) { throw 'src/Rtfx/Rtfx.csproj has no <Version>' }

$line = Select-String -LiteralPath (Join-Path $repo 'runner\lib.ps1') -Pattern "^\`$RtfxVersion = '([^']+)'" | Select-Object -First 1
if (-not $line) { throw 'runner/lib.ps1 has no $RtfxVersion' }
$runner = $line.Matches[0].Groups[1].Value

if ($server -ne $runner) {
  throw "the server is $server (src/Rtfx/Rtfx.csproj) and the runner is $runner (runner/lib.ps1): they are released together and must carry one version"
}
$server
