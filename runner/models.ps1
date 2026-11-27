<#
  Refreshes models.json, the list of models Copilot offers with their prices. Started by runner.ps1
  when a models.request file appears, inside the desktop session like every job.

  Copilot has no command that prints the catalog, but it logs the one it downloads at debug level.
  So this runs one tiny prompt with a debug log, takes the catalog out of the log, and deletes the
  log in the same step: a debug log can hold request headers.
#>
param([Parameter(Mandatory)][string]$Root)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib.ps1')

$statusFile = Join-Path $Root 'models.status.json'
$scratch = Join-Path $Root "models-run-$PID"
$logDir = Join-Path $scratch 'log'
$workDir = Join-Path $scratch 'cwd'

# Reads the JSON value that starts at $Start in $Text (an object or an array).
# Returns @{ value; end } or $null when what starts there is not JSON.
function Read-JsonAt([string]$Text, [int]$Start) {
  $depth = 0; $inString = $false; $escaped = $false
  for ($i = $Start; $i -lt $Text.Length; $i++) {
    $c = $Text[$i]
    if ($inString) {
      if ($escaped) { $escaped = $false } elseif ($c -eq '\') { $escaped = $true } elseif ($c -eq '"') { $inString = $false }
      continue
    }
    if ($c -eq '"') { $inString = $true }
    elseif ($c -eq '{' -or $c -eq '[') { $depth++ }
    elseif ($c -eq '}' -or $c -eq ']') {
      $depth--
      if ($depth -eq 0) {
        try { return @{ value = ($Text.Substring($Start, $i - $Start + 1) | ConvertFrom-Json -AsHashtable -Depth 64); end = $i } } catch { return $null }
      }
    }
  }
  return $null
}

function Get-ModelList($Value) {
  $list = $null
  if ($Value -is [Collections.IDictionary] -and $Value.data -is [Array]) { $list = $Value.data }
  elseif ($Value -is [Collections.IDictionary] -and $Value.models -is [Array]) { $list = $Value.models }
  elseif ($Value -is [Collections.IDictionary] -and $Value.models -is [string]) {
    # Copilot 1.0.116 logs the list as a JSON string inside the log line's own JSON.
    try { $list = @($Value.models | ConvertFrom-Json -AsHashtable -Depth 64) } catch { }
  }
  elseif ($Value -is [Array]) { $list = $Value }
  if (-not $list) { return @() }
  return @($list | Where-Object { $_ -is [Collections.IDictionary] -and $_.id -and $_.Contains('capabilities') })
}

# The catalog is the longest list in the log whose items have an id and capabilities. Finding it by
# shape survives a change in what the log line around it says.
function Find-Catalog([string]$Text) {
  $best = @()
  # First where Copilot 1.0.116 puts it: a line tagged capi_models, ending in one JSON object.
  $at = 0
  while (($at = $Text.IndexOf('capi_models', $at)) -ge 0) {
    $lineEnd = $Text.IndexOf("`n", $at)
    if ($lineEnd -lt 0) { $lineEnd = $Text.Length }
    $start = $Text.IndexOf('{', $at)
    if ($start -ge 0 -and $start -lt $lineEnd) {
      $read = Read-JsonAt $Text $start
      if ($read) { $models = Get-ModelList $read.value; if ($models.Count -gt $best.Count) { $best = $models } }
    }
    $at = $lineEnd
  }
  if ($best.Count -gt 0) { return $best }
  # Otherwise by shape, wherever it is.
  $at = 0
  while ($at -lt $Text.Length -and ($at = $Text.IndexOf('"capabilities"', $at)) -ge 0) {
    $next = $at + 14
    # The list starts at one of the few brackets before this model's capabilities.
    :search foreach ($opener in '[', '{') {
      $start = $Text.LastIndexOf($opener, $at)
      for ($hop = 0; $hop -lt 8 -and $start -ge 0; $hop++) {
        $read = Read-JsonAt $Text $start
        if ($read) {
          $models = Get-ModelList $read.value
          if ($models.Count -gt 1) {
            if ($models.Count -gt $best.Count) { $best = $models }
            $next = [Math]::Max($next, $read.end)
            break search
          }
        }
        if ($start -eq 0) { break }
        $start = $Text.LastIndexOf($opener, $start - 1)
      }
    }
    $at = $next
  }
  return $best
}

# What to look at when no catalog was found: the start of each line that mentions one, with anything
# long enough to be a credential blanked out and any line that names one left out altogether.
function Get-LogExcerpt([string[]]$Files) {
  $lines = [Collections.Generic.List[string]]::new()
  foreach ($file in $Files) {
    $number = 0
    foreach ($line in [IO.File]::ReadLines($file)) {
      $number++
      if ($lines.Count -ge 60) { break }
      if ($line -notlike '*capi_models*' -and $line -notlike '*capabilities*' -and $line -notlike '*/models*') { continue }
      if ($line -match '(?i)authorization|bearer|cookie|secret|password') { $lines.Add("$number`: <line withheld>"); continue }
      $masked = $line -replace '[A-Za-z0-9+/_=-]{20,}', '<masked>'
      $lines.Add("$number ($($line.Length) chars): " + $masked.Substring(0, [Math]::Min(400, $masked.Length)))
    }
  }
  return $lines
}

# One price band of a model: AI credits per batch of tokens (a million of them so far).
function Get-PriceBand($Band) {
  if ($Band -isnot [Collections.IDictionary]) { return $null }
  return [ordered]@{
    input = $Band.input_price; cachedInput = $Band.cache_read_price; cacheWrite = $Band.cache_write_price
    output = $Band.output_price; upToPromptTokens = $Band.max_prompt_tokens
  }
}

try {
  Write-JsonFile $statusFile @{ state = 'running'; startedAt = Get-UtcStamp; pid = $PID }
  $config = Get-RtfxConfig $Root
  [void](Remove-SecretEnvironment $config)
  Set-GitGuards
  New-Item -ItemType Directory -Force $logDir, $workDir | Out-Null

  $copilotArgs = @(
    '-C', $workDir, '-p', 'Reply with the single word ok. Do not use any tool.',
    '--output-format', 'json', '--reasoning-effort', 'low', '--max-ai-credits', '30',
    '--usage-output-file', (Join-Path $scratch 'usage.json'),
    '--log-level', 'all', '--log-dir', $logDir,
    '--disable-builtin-mcps', '--no-ask-user', '--no-auto-update', '--no-custom-instructions',
    '--deny-tool=shell', '--deny-tool=write', '--deny-tool=memory'
  )
  if ($config.probeModel) { $copilotArgs += @('--model', [string]$config.probeModel) }
  foreach ($server in @(Get-McpServerNames $workDir)) { $copilotArgs += @('--disable-mcp-server', $server, "--deny-tool=$server") }

  [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
  $ErrorActionPreference = 'Continue'
  & $config.copilot @copilotArgs 2> (Join-Path $scratch 'copilot.err') > (Join-Path $scratch 'copilot.jsonl')
  $exitCode = $LASTEXITCODE
  $ErrorActionPreference = 'Stop'
  # A script standing in for Copilot runs in this process and may have moved into the folder that is about to go.
  Set-Location -LiteralPath $Root

  $catalog = @()
  $excerpt = @()
  $logFiles = @(Get-ChildItem -LiteralPath $logDir -File -Recurse)
  try {
    foreach ($file in $logFiles) {
      $found = @(Find-Catalog ([IO.File]::ReadAllText($file.FullName)))
      if ($found.Count -gt $catalog.Count) { $catalog = $found }
    }
    if ($catalog.Count -eq 0) { $excerpt = @(Get-LogExcerpt @($logFiles.FullName)) }
  }
  finally {
    # The log goes in the same step it was read in, whatever reading it did.
    Remove-Item -LiteralPath $logDir -Recurse -Force -ErrorAction SilentlyContinue
  }
  $usage = Read-JsonFile (Join-Path $scratch 'usage.json')
  $credits = if ($usage -is [Collections.IDictionary] -and $null -ne $usage.totalNanoAiu) { [Math]::Round([double]$usage.totalNanoAiu / 1e9, 4) } else { $null }

  if ($catalog.Count -eq 0) {
    Set-Content -LiteralPath (Join-Path $Root 'models.excerpt.txt') -Value $excerpt -Encoding utf8
    $errFile = Join-Path $scratch 'copilot.err'
    $tail = if (Test-Path -LiteralPath $errFile) { ((Get-Content -LiteralPath $errFile -Tail 3) -join ' ').Trim() } else { '' }
    throw "no model catalog in the debug log ($($logFiles.Count) log files, copilot exited $exitCode); see models.excerpt.txt. $tail".Trim()
  }

  $models = foreach ($model in $catalog) {
    $limits = $null
    if ($model.capabilities -is [Collections.IDictionary]) { $limits = $model.capabilities.limits }
    if ($limits -isnot [Collections.IDictionary]) { $limits = @{} }
    $billing = if ($model.billing -is [Collections.IDictionary]) { $model.billing } else { @{} }
    $tokenPrices = if ($billing.token_prices -is [Collections.IDictionary]) { $billing.token_prices } else { @{} }
    [ordered]@{
      id                = [string]$model.id
      name              = [string]$model.name
      vendor            = $model.vendor
      contextWindow     = $limits.max_context_window_tokens
      maxPrompt         = $limits.max_prompt_tokens
      maxOutput         = $limits.max_output_tokens
      prices            = Get-PriceBand $tokenPrices.default
      longContextPrices = Get-PriceBand $tokenPrices.long_context
      perTokens         = $tokenPrices.batch_size
      category          = $model.model_picker_category
      priceCategory     = $model.model_picker_price_category
      inPicker          = $model.model_picker_enabled
      preview           = $model.preview
      plans             = $billing.restricted_to
    }
  }
  Write-JsonFile (Join-Path $Root 'models.json') ([ordered]@{
    fetchedAt = Get-UtcStamp; host = $env:COMPUTERNAME; probeCredits = $credits; count = @($models).Count
    priceUnit = 'AI credits per perTokens tokens; one AI credit is 0.01 USD'
    models = @($models | Sort-Object { $_.id })
  })
  # The catalog as Copilot sent it, for whoever needs a field the summary above leaves out.
  Write-JsonFile (Join-Path $Root 'models.raw.json') @($catalog)
  Remove-Item -LiteralPath (Join-Path $Root 'models.excerpt.txt') -Force -ErrorAction SilentlyContinue
  # Before the status says done: whoever waits on it should find nothing of the run left.
  Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
  Write-JsonFile $statusFile @{ state = 'done'; finishedAt = Get-UtcStamp; count = @($models).Count; credits = $credits }
}
catch {
  Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
  Write-JsonFile $statusFile @{ state = 'failed'; finishedAt = Get-UtcStamp; error = $_.Exception.Message }
  exit 1
}
finally {
  Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
}
