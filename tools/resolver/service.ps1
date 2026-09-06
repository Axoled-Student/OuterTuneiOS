# Keeps the resolver and its tunnel up, unattended.
#
# `start.ps1` is the version you run in a window and watch. This is the version
# a machine runs: no banner, no console, and it does not give up. Register it
# with `install-autostart.ps1` rather than calling it by hand.
#
# Three things it does that a bare `python server.py` does not:
#
#   * absolute paths for everything. A task started before anyone logs in gets
#     the machine PATH, and yt-dlp lives in a per-user Python's Scripts folder
#     that is not on it. Inheriting the wrong PATH is the difference between a
#     server that streams and one that fails on every track.
#   * a health check, not just a liveness check. A process that is running but
#     no longer answering holds the port and looks fine to Task Scheduler; the
#     phone sees a dead server. Three failed probes and it gets replaced.
#   * it adopts rather than duplicates. If a server or a connector is already
#     up when this starts, it leaves it alone and watches it instead - two
#     processes fighting over port 9099 is worse than neither.

param(
    [int]$Port = 9099,
    [string]$Cookies = "build\ytm_cookies.txt",
    [string]$TunnelName = "outertune",
    # cloudflared keeps its credentials in a user profile. A task running as
    # SYSTEM has a different one, so the path is passed in rather than found.
    [string]$TunnelConfig = "$env:USERPROFILE\.cloudflared\config.yml",
    [string]$Python = "",
    # How long a server may fail its health check before it is replaced.
    [int]$SickProbesBeforeRestart = 3
)

$ErrorActionPreference = "Continue"
$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Set-Location $repo

$logDir = Join-Path $repo "build\logs"
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }
$runLog = Join-Path $logDir "supervisor.log"
$MaxLogBytes = 20MB

function Write-Log([string]$message) {
    $line = "{0}  {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $message
    try {
        if ((Test-Path $runLog) -and (Get-Item $runLog).Length -gt $MaxLogBytes) {
            Move-Item $runLog "$runLog.1" -Force
        }
        Add-Content -Path $runLog -Value $line -Encoding utf8
    } catch { }
}

function Roll([string]$path) {
    # Child stdout is redirected, not appended, so a long uptime would otherwise
    # write one unbounded file.
    if ((Test-Path $path) -and (Get-Item $path).Length -gt $MaxLogBytes) {
        Move-Item $path "$path.1" -Force
    }
}

# -- where the tools are

if ([string]::IsNullOrWhiteSpace($Python)) {
    $found = Get-Command python -ErrorAction SilentlyContinue
    $Python = if ($found) { $found.Source } else { "python" }
}
# yt-dlp is a subprocess, so it is found through PATH rather than a variable.
# Put the interpreter's own Scripts folder in front of whatever PATH we
# inherited, and ffmpeg with it - the DJ voice is levelled through ffmpeg and
# quietly skips the levelling when it is missing.
$pyDir = Split-Path -Parent $Python
$extra = @((Join-Path $pyDir "Scripts"), $pyDir, "C:\FFmpeg\bin") |
         Where-Object { Test-Path $_ }
$env:Path = ($extra -join ";") + ";" + $env:Path
# The server prints track titles in Chinese and Japanese, and the console this
# inherits is cp950.
$env:PYTHONIOENCODING = "utf-8"
$env:PYTHONUTF8 = "1"

$cloudflared = "C:\Program Files (x86)\cloudflared\cloudflared.exe"
if (-not (Test-Path $cloudflared)) {
    $found = Get-Command cloudflared -ErrorAction SilentlyContinue
    $cloudflared = if ($found) { $found.Source } else { $null }
}

Write-Log "supervisor starting: python=$Python cloudflared=$cloudflared port=$Port"

# -- is somebody already doing this job

function Get-Listener {
    try {
        $c = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction Stop |
             Select-Object -First 1
        if ($c) { return Get-Process -Id $c.OwningProcess -ErrorAction SilentlyContinue }
    } catch { }
    return $null
}

function Get-Connector {
    # Only this tunnel's connector. The machine runs others - there is a
    # cloudflared service here for something else entirely - and killing or
    # counting one of those is not this script's business.
    Get-CimInstance Win32_Process -Filter "Name='cloudflared.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine -match [regex]::Escape($TunnelName) } |
        Select-Object -First 1
}

function Test-Healthy {
    try {
        $r = Invoke-WebRequest -Uri "http://127.0.0.1:$Port/health" `
                               -TimeoutSec 10 -UseBasicParsing
        return $r.StatusCode -eq 200
    } catch { return $false }
}

# -- starting things

function Start-Server {
    $out = Join-Path $logDir "resolver.log"
    $err = Join-Path $logDir "resolver.err.log"
    Roll $out; Roll $err
    $serverArgs = @("-u", (Join-Path $repo "tools\resolver\server.py"),
                    "--port", $Port, "--host", "0.0.0.0")
    $cookiePath = if ([System.IO.Path]::IsPathRooted($Cookies)) { $Cookies }
                  else { Join-Path $repo $Cookies }
    if (Test-Path $cookiePath) {
        $serverArgs += @("--cookies", $cookiePath)
    } else {
        Write-Log "no cookie file at $cookiePath - running anonymously"
    }
    # No --token: the app is told to expect no auth.
    $p = Start-Process -PassThru -WindowStyle Hidden -FilePath $Python `
            -ArgumentList $serverArgs -WorkingDirectory $repo `
            -RedirectStandardOutput $out -RedirectStandardError $err
    Write-Log "server started, pid $($p.Id)"
    return $p
}

function Start-Connector {
    if (-not $cloudflared) { Write-Log "cloudflared not installed"; return $null }
    $out = Join-Path $logDir "tunnel.log"
    $err = Join-Path $logDir "tunnel.err.log"
    Roll $out; Roll $err
    $tunnelArgs = @("--no-autoupdate")
    if (Test-Path $TunnelConfig) { $tunnelArgs += @("--config", $TunnelConfig) }
    else { Write-Log "no tunnel config at $TunnelConfig - trying defaults" }
    $tunnelArgs += @("tunnel", "run", $TunnelName)
    $p = Start-Process -PassThru -WindowStyle Hidden -FilePath $cloudflared `
            -ArgumentList $tunnelArgs -WorkingDirectory $repo `
            -RedirectStandardOutput $out -RedirectStandardError $err
    Write-Log "connector started, pid $($p.Id)"
    return $p
}

# -- the loop

$server = $null
$tunnel = $null
$sick = 0
# The first build of the home shelves and the DJ standby set are tens of
# seconds of network round trips, and at boot the network itself may not be up
# yet. Do not judge the server until it has had a chance to answer.
$graceUntil = (Get-Date).AddSeconds(90)

$existing = Get-Listener
if ($existing) {
    Write-Log "port $Port already served by pid $($existing.Id) - adopting it"
    $server = $existing
}
$existingTunnel = Get-Connector
if ($existingTunnel) {
    Write-Log "connector already up, pid $($existingTunnel.ProcessId) - adopting it"
    $tunnel = Get-Process -Id $existingTunnel.ProcessId -ErrorAction SilentlyContinue
}

while ($true) {
    if (-not $server -or $server.HasExited) {
        if ($server) { Write-Log "server exited - restarting" }
        $adopt = Get-Listener
        $server = if ($adopt) { $adopt } else { Start-Server }
        $sick = 0
        $graceUntil = (Get-Date).AddSeconds(90)
    } elseif ((Get-Date) -gt $graceUntil) {
        # Running is not the same as working: a wedged server keeps the port.
        if (Test-Healthy) {
            $sick = 0
        } else {
            $sick++
            Write-Log "health check failed ($sick/$SickProbesBeforeRestart)"
            if ($sick -ge $SickProbesBeforeRestart) {
                Write-Log "server is not answering - replacing pid $($server.Id)"
                try { Stop-Process -Id $server.Id -Force -ErrorAction Stop } catch { }
                Start-Sleep -Seconds 2
                $server = Start-Server
                $sick = 0
                $graceUntil = (Get-Date).AddSeconds(90)
            }
        }
    }

    if (-not $tunnel -or $tunnel.HasExited) {
        if ($tunnel) { Write-Log "connector exited - restarting" }
        $adopt = Get-Connector
        $tunnel = if ($adopt) { Get-Process -Id $adopt.ProcessId -ErrorAction SilentlyContinue }
                  else { Start-Connector }
    }

    Start-Sleep -Seconds 15
}
