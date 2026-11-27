<#
  Builds what a release ships, into -Out (artifacts/ by default):

    rtfx-server-<version>-win-x64.zip   the MCP server, as `dotnet publish src/Rtfx -c Release` makes it
    rtfx-runner-<version>.zip           the runner's scripts, for the machine that has Copilot CLI

  each with a .sha256 file next to it, in sha256sum's format. The server needs the .NET 10 runtime.

    pwsh -NoProfile -File build/package.ps1
#>
param([string]$Out = (Join-Path (Split-Path $PSScriptRoot) 'artifacts'))

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot
$version = [string](& (Join-Path $PSScriptRoot 'version.ps1'))
$Out = [IO.Path]::GetFullPath($Out)
$stage = Join-Path $Out 'stage'

New-Item -ItemType Directory -Force $Out | Out-Null
if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
Get-ChildItem -LiteralPath $Out -File | Where-Object { $_.Name -like 'rtfx-*.zip' -or $_.Name -like 'rtfx-*.zip.sha256' } | Remove-Item -Force

$server = Join-Path $stage 'server'
& dotnet publish (Join-Path $repo 'src\Rtfx') -c Release -r win-x64 --self-contained false -o $server --nologo -v q
if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed with exit code $LASTEXITCODE" }
$reported = ([string](& (Join-Path $server 'rtfx.exe') version)).Trim()
if ($reported -ne $version) { throw "the published rtfx.exe says it is version '$reported', not $version" }

$runner = Join-Path $stage 'runner'
New-Item -ItemType Directory -Force $runner | Out-Null
Copy-Item -Path (Join-Path $repo 'runner\*.ps1') -Destination $runner

$packages = @(
  @{ name = "rtfx-server-$version-win-x64.zip"; from = $server }
  @{ name = "rtfx-runner-$version.zip"; from = $runner }
)
foreach ($package in $packages) {
  $zip = Join-Path $Out $package.name
  Compress-Archive -Path (Join-Path $package.from '*') -DestinationPath $zip
  $hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
  # sha256sum's format, with a line feed, so `sha256sum -c` accepts the file as it is.
  [IO.File]::WriteAllText("$zip.sha256", "$hash  $($package.name)`n")
  '{0}  {1}  ({2:N0} bytes, {3} files)' -f $hash, $package.name, (Get-Item -LiteralPath $zip).Length, @(Get-ChildItem -LiteralPath $package.from -File).Count
}
Remove-Item -LiteralPath $stage -Recurse -Force
