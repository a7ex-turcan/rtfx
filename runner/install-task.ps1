<#
  Registers the rtfx runner as a scheduled task in the given user's interactive session and starts it.
  Run it on the box that has Copilot CLI, from the folder the runner scripts were copied to.

  Two triggers: at logon, and every five minutes. Task Scheduler's restart-on-failure does not fire
  when a script simply exits, so the repeating trigger is what brings a dead runner back; while the
  runner is alive, MultipleInstances IgnoreNew makes it a no-op.

  -Remove unregisters the task and stops the runner.
#>
param(
  [string]$Root = $PSScriptRoot,
  [string]$User = "$env:USERDOMAIN\$env:USERNAME",
  [switch]$Remove
)

$ErrorActionPreference = 'Stop'
$taskPath = '\rtfx\'
$taskName = 'rtfx runner'
$Root = [IO.Path]::GetFullPath($Root).TrimEnd('\')

if ($Remove) {
  $task = Get-ScheduledTask -TaskPath $taskPath -TaskName $taskName -ErrorAction SilentlyContinue
  if ($task) {
    Stop-ScheduledTask -TaskPath $taskPath -TaskName $taskName
    Unregister-ScheduledTask -TaskPath $taskPath -TaskName $taskName -Confirm:$false
    "removed $taskPath$taskName"
  } else { "no task $taskPath$taskName" }
  return
}

$script = Join-Path $Root 'runner.ps1'
if (-not (Test-Path -LiteralPath $script)) { throw "runner.ps1 is not in $Root" }
# Re-installing: stop the runner that is up, so the new scripts are the ones running.
if (Get-ScheduledTask -TaskPath $taskPath -TaskName $taskName -ErrorAction SilentlyContinue) {
  Stop-ScheduledTask -TaskPath $taskPath -TaskName $taskName
  Start-Sleep -Seconds 2
}
$pwsh = (Get-Process -Id $PID).Path

$action = New-ScheduledTaskAction -Execute $pwsh -WorkingDirectory $Root `
  -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$script`" -Root `"$Root`""
$atLogon = New-ScheduledTaskTrigger -AtLogOn -User $User
$repeat = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(5) -RepetitionInterval (New-TimeSpan -Minutes 5)
$principal = New-ScheduledTaskPrincipal -UserId $User -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew `
  -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable

Register-ScheduledTask -TaskPath $taskPath -TaskName $taskName -Action $action -Trigger @($atLogon, $repeat) `
  -Principal $principal -Settings $settings -Force | Out-Null
Start-ScheduledTask -TaskPath $taskPath -TaskName $taskName

Start-Sleep -Seconds 6
$task = Get-ScheduledTask -TaskPath $taskPath -TaskName $taskName
$info = $task | Get-ScheduledTaskInfo
'{0}{1}  state={2}  lastResult={3}' -f $taskPath, $taskName, $task.State, $info.LastTaskResult
$heartbeat = Join-Path $Root 'heartbeat.json'
if (Test-Path -LiteralPath $heartbeat) { "heartbeat: $(Get-Content -LiteralPath $heartbeat -Raw)" } else { 'no heartbeat yet' }
