# Make the resolver come back by itself after a reboot.
#
#   powershell -ExecutionPolicy Bypass -File tools\resolver\install-autostart.ps1
#
# Registers a scheduled task that runs `service.ps1`, which in turn keeps both
# the Python server and the OuterTune cloudflared connector alive. Idempotent:
# run it again after moving the repo or changing Python and it rewrites the
# task. `-Remove` takes it away again, `-Status` just reports.
#
# Two flavours, chosen by whether this window is elevated:
#
#   elevated      SYSTEM, triggered at boot. The machine can restart unattended
#                 and the phone finds music.598787.xyz already up, with nobody
#                 logged in.
#   not elevated  the current user, triggered at logon. No admin needed, but
#                 nothing runs while the machine sits at the lock screen.
#
# The unelevated one installs cleanly and is a fine answer for a PC that gets
# logged into; re-run this from an admin prompt to upgrade it in place.
#
# Note there is already a Windows service called `cloudflared` on this machine
# running a different tunnel by token. It is left strictly alone - the OuterTune
# connector is a separate process owned by this task.

param(
    [switch]$Remove,
    [switch]$Status,
    [string]$TaskName = "OuterTune Resolver",
    [int]$Port = 9099,
    [string]$TunnelName = "outertune"
)

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$service = Join-Path $repo "tools\resolver\service.ps1"

function Show-Status {
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $task) { Write-Host "not installed"; return }
    $info = Get-ScheduledTaskInfo -TaskName $TaskName
    Write-Host ("task     : {0}  [{1}]" -f $task.TaskName, $task.State)
    Write-Host ("runs as  : {0}" -f $task.Principal.UserId)
    Write-Host ("trigger  : {0}" -f (($task.Triggers | ForEach-Object {
        $_.CimClass.CimClassName -replace "MSFT_Task|Trigger", "" }) -join ", "))
    Write-Host ("last run : {0}  result 0x{1:X}" -f $info.LastRunTime, $info.LastTaskResult)
    try {
        $r = Invoke-WebRequest -Uri "http://127.0.0.1:$Port/health" -TimeoutSec 10 -UseBasicParsing
        Write-Host ("health   : {0}" -f $r.Content)
    } catch {
        Write-Host "health   : not answering"
    }
}

if ($Status) { Show-Status; return }

if ($Remove) {
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Host "removed '$TaskName'. Anything already running is left running."
    } else {
        Write-Host "'$TaskName' was not installed."
    }
    return
}

if (-not (Test-Path $service)) { throw "missing $service" }

# -- resolve everything now, while we are still the user who owns it

$python = (Get-Command python -ErrorAction SilentlyContinue).Source
if (-not $python) { throw "python is not on PATH" }
# SYSTEM has its own profile, so a task that inherits `$env:USERPROFILE` would
# look for the tunnel credentials in the wrong place.
$tunnelConfig = Join-Path $env:USERPROFILE ".cloudflared\config.yml"
if (-not (Test-Path $tunnelConfig)) {
    Write-Warning "no tunnel config at $tunnelConfig - the connector may not start"
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$elevated = (New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

$arguments = @(
    "-NoProfile", "-NonInteractive", "-WindowStyle", "Hidden",
    "-ExecutionPolicy", "Bypass",
    "-File", "`"$service`"",
    "-Port", $Port,
    "-TunnelName", "`"$TunnelName`"",
    "-TunnelConfig", "`"$tunnelConfig`"",
    "-Python", "`"$python`""
) -join " "

$action = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument $arguments -WorkingDirectory $repo

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -DontStopOnIdleEnd `
    -MultipleInstances IgnoreNew `
    -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) `
    -ExecutionTimeLimit ([TimeSpan]::Zero)

if ($elevated) {
    # A boot trigger fires before the network stack has settled. cloudflared
    # would retry anyway, but there is no reason to spend the first minute of
    # every boot failing.
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $trigger.Delay = "PT30S"
    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" `
        -LogonType ServiceAccount -RunLevel Highest
    $flavour = "at boot, as SYSTEM"
} else {
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $identity.Name
    $trigger.Delay = "PT15S"
    $principal = New-ScheduledTaskPrincipal -UserId $identity.Name `
        -LogonType Interactive -RunLevel Limited
    $flavour = "at logon, as $($identity.Name)"
}

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings -Force `
    -Description "Runs the OuterTune stream resolver and its cloudflare tunnel." | Out-Null

Write-Host "installed '$TaskName' - starts $flavour."
if (-not $elevated) {
    Write-Host ""
    Write-Host "For a true boot start (no logon needed), re-run this from an" -ForegroundColor Yellow
    Write-Host "administrator PowerShell:" -ForegroundColor Yellow
    Write-Host "  powershell -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -ForegroundColor Yellow
}
Write-Host ""
Write-Host "  start now : Start-ScheduledTask -TaskName '$TaskName'"
Write-Host "  check     : powershell -File `"$PSCommandPath`" -Status"
Write-Host "  logs      : $repo\build\logs\"
Write-Host "  remove    : powershell -File `"$PSCommandPath`" -Remove"
