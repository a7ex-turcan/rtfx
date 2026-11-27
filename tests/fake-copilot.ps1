<#
  Stands in for Copilot CLI in tests/smoke.ps1. It takes the same arguments and prints the same kind
  of JSONL. What it does is decided by a keyword in the brief, which it reads from the file the
  prompt names (TASK.md in its working directory), the way the real one would:
    FAKE:sleep <seconds> marker=<text>   start a child process carrying the marker, then sleep
    FAKE:env                             report which variable names are visible and whether a push works
    FAKE:args                            report the arguments it was given, and claim an MCP server connected
    FAKE:fail                            write to stderr and exit 3
    FAKE:write                           commit one file, leave another uncommitted, report the commit identity
    FAKE:worksleep <seconds>             commit one file, leave another uncommitted, then sleep
    FAKE:catalog                         write a model catalog into the debug log (the prompt, not the brief)
  With none of these it reports the first line of README.md in its working directory.
#>
$options = @{}
for ($i = 0; $i -lt $args.Count; $i++) {
  if ($args[$i] -in @('-C', '-p', '--usage-output-file', '--model', '--log-dir')) { $options[$args[$i]] = $args[$i + 1]; $i++ }
}
$prompt = [string]$options['-p']
Set-Location -LiteralPath $options['-C']
$briefFile = if ($prompt -match 'file (\S+\.md) in your working directory') { $Matches[1] } else { $null }
$brief = if ($briefFile -and (Test-Path -LiteralPath $briefFile)) { Get-Content -LiteralPath $briefFile -Raw } else { '' }

function Write-Event([string]$Type, $Data) {
  [ordered]@{ type = $Type; data = $Data; id = [guid]::NewGuid().ToString(); timestamp = [DateTime]::UtcNow.ToString('o') } |
    ConvertTo-Json -Compress -Depth 6
}

Write-Event 'session.start' @{ sessionId = 'fake-session'; selectedModel = $options['--model'] }
Write-Event 'user.message' @{ content = $prompt }

if ($brief -match 'FAKE:fail') {
  # Through a native process, the way the real CLI (a node program behind a .ps1 shim) writes stderr.
  & (Get-Process -Id $PID).Path -NoProfile -Command "[Console]::Error.WriteLine('fake copilot: asked to fail')"
  exit 3
}

$content = $null
if ($options['--log-dir']) {
  # The real CLI logs the catalog it downloads when the log level is debug. One line of it carries a
  # header, which nothing may keep.
  $catalog = @{ data = @(
      @{ id = 'fake-small'; name = 'Fake Small'; vendor = 'fake'; model_picker_category = 'lightweight'
         capabilities = @{ limits = @{ max_context_window_tokens = 128000; max_prompt_tokens = 100000; max_output_tokens = 16000 } }
         billing = @{ restricted_to = @('pro'); token_prices = @{ batch_size = 1000000; default = @{ input_price = 0.25; cache_read_price = 0.025; cache_write_price = 0.3; output_price = 2; max_prompt_tokens = 100000 } } } },
      @{ id = 'fake-large'; name = 'Fake Large'; vendor = 'fake'; model_picker_category = 'powerful'
         capabilities = @{ limits = @{ max_context_window_tokens = 400000; max_prompt_tokens = 300000; max_output_tokens = 64000 } }
         billing = @{ restricted_to = @('pro'); token_prices = @{ batch_size = 1000000; default = @{ input_price = 5; cache_read_price = 0.5; cache_write_price = 6; output_price = 30; max_prompt_tokens = 200000 }
                                              long_context = @{ input_price = 10; cache_read_price = 1; cache_write_price = 12; output_price = 45; max_prompt_tokens = 300000 } } } }
    ) }
  $lines = @(
    '2026-01-01T00:00:00.000Z [DEBUG] request headers: authorization: Bearer fake-secret-header-value',
    ('2026-01-01T00:00:00.100Z [DEBUG] [rust:capi_models] fetched model catalog from CAPI ' +
      (@{ count = 2; models = (ConvertTo-Json -InputObject $catalog.data -Compress -Depth 8) } | ConvertTo-Json -Compress))
  )
  Set-Content -LiteralPath (Join-Path $options['--log-dir'] 'process-fake.log') -Value $lines
  $content = 'ok'
}
elseif ($brief -match 'FAKE:sleep (\d+) marker=(\S+)') {
  $seconds = [int]$Matches[1]
  Start-Process -FilePath (Get-Process -Id $PID).Path -WindowStyle Hidden `
    -ArgumentList "-NoProfile -Command `"Start-Sleep 600 # rtfx-fake-child $($Matches[2])`""
  Write-Event 'assistant.message' @{ content = 'sleeping' }
  Start-Sleep -Seconds $seconds
  $content = "slept $seconds seconds"
}
elseif ($brief -match 'FAKE:args') {
  $shown = for ($i = 0; $i -lt $args.Count; $i++) { if ($args[$i] -eq '-p') { $i++ } else { $args[$i] } }
  Write-Event 'session.mcp_server_status_changed' @{ serverName = 'gamma'; status = 'connected' }
  $content = 'ARGS: ' + ($shown -join ' | ') + "`nPROMPT: $prompt"
}
elseif ($brief -match 'FAKE:env') {
  $names = @([Environment]::GetEnvironmentVariables().Keys | Where-Object {
      $_ -like '*TOKEN*' -or $_ -like '*CRED*' -or $_ -like 'ConnectionStrings*' -or $_ -like 'JF_*' -or $_ -like 'NODE_*' -or $_ -like 'ROVO*'
    } | Sort-Object)
  git push origin HEAD:refs/heads/rtfx-probe *> $null
  $pushExit = $LASTEXITCODE
  # The package feed credentials: which sources got them, and whether each is the kept user and password. Never the values.
  $feeds = @([Environment]::GetEnvironmentVariables().Keys | Where-Object { $_ -like 'NuGetPackageSourceCredentials_*' } | Sort-Object)
  $feedsOk = $feeds.Count -gt 0 -and -not ($feeds | Where-Object { [Environment]::GetEnvironmentVariable($_) -cne "Username=$env:JF_USER;Password=$env:JF_PASS" })
  $content = "VISIBLE: $($names -join ',')`nPUSH_EXIT: $pushExit`nFEEDS: $(($feeds -replace '^NuGetPackageSourceCredentials_', '') -join ',')`nFEEDS_OK: $feedsOk"
}
elseif ($brief -match 'FAKE:(write|worksleep)') {
  $ticket = if ($prompt -match "starts with '([A-Z0-9-]+): '") { "$($Matches[1]): " } else { '' }
  Set-Content -LiteralPath 'added.txt' -Value 'added by the fake agent'
  git add added.txt *> $null
  git commit --quiet -m "${ticket}Add a file" *> $null
  $commitExit = $LASTEXITCODE
  Set-Content -LiteralPath 'leftover.txt' -Value 'left uncommitted by the fake agent'
  git push origin HEAD *> $null
  $pushExit = $LASTEXITCODE
  # A tool result the way the real CLI ends one, with its budget note.
  Write-Event 'tool.execution_complete' @{ success = $true; result = @{ content = "committed`n`n[cost: 41% used - `$0.18 left]" } }
  if ($brief -match 'FAKE:worksleep (\d+)') { Start-Sleep -Seconds ([int]$Matches[1]) }
  $content = "COMMIT_EXIT: $commitExit`nPUSH_EXIT: $pushExit`nAUTHOR: $(git log -1 --format='%an <%ae>')`nBRANCH: $(git symbolic-ref --short HEAD)" +
    "`nALLOW_ALL: $($args -contains '--allow-all-tools')`nDENY_WRITE: $($args -contains '--deny-tool=write')`nDENY_PUSH: $($args -contains '--deny-tool=shell(git push)')" +
    "`nSEES_SKILLS: $(Test-Path -LiteralPath '.claude/skills')`nSEES_MCP_FILE: $(Test-Path -LiteralPath '.mcp.json')`nSEES_RULES: $(Test-Path -LiteralPath '.claude/rules/style.md')`nSTATUS: [$((git status --porcelain) -join ';')]"
}
else {
  $content = 'README says: ' + (Get-Content -LiteralPath 'README.md' -TotalCount 1)
}

Write-Event 'assistant.message' @{ content = $content }
Write-Event 'session.usage_checkpoint' @{ totalNanoAiu = 1000000000 }
if ($options['--usage-output-file']) {
  # A brief can ask for a run that all but used up a 30-credit cap.
  $spent = if ($brief -match 'FAKE:nearcap') { '28000000000' } else { '1234000000' }
  Set-Content -LiteralPath $options['--usage-output-file'] -Value ('{"totalNanoAiu": ' + $spent + ', "tokenDetails": {"input": {"tokenCount": 12}, "output": {"tokenCount": 34}}}')
}
exit 0
