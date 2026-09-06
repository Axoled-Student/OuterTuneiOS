# Starts the OuterTune stream resolver behind its permanent Cloudflare tunnel.
#
#   powershell -ExecutionPolicy Bypass -File tools\resolver\start.ps1
#
# The app should point at https://music.598787.xyz with no token.
#
# The hostname is a named tunnel (see ~/.cloudflared/config.yml), so unlike a
# quick trycloudflare tunnel it stays the same across restarts.
#
# The only pip dependency is the DJ's voice, and it is optional:
#
#   pip install edge-tts
#
# Without it /djline still writes the line and the app reads it on screen; the
# rest of the server does not touch it. yt-dlp is called as a subprocess, not
# imported, so it only needs to be on PATH.

param(
    [int]$Port = 9099,
    [string]$Token = "",                      # empty = no auth
    [string]$Cookies = "build\ytm_cookies.txt",
    [string]$TunnelName = "outertune",
    [switch]$QuickTunnel                      # fall back to a random URL
)

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Set-Location $repo

$serverArgs = @("tools\resolver\server.py", "--port", $Port, "--host", "0.0.0.0")
if (-not [string]::IsNullOrWhiteSpace($Token)) {
    $serverArgs += @("--token", $Token)
    Write-Host "auth: token required"
} else {
    Write-Host "auth: disabled"
}
if (Test-Path $Cookies) {
    $serverArgs += @("--cookies", $Cookies)
    Write-Host "cookies: $Cookies"
} else {
    Write-Host "no cookie file at $Cookies - running anonymously" -ForegroundColor Yellow
}

Write-Host "starting resolver on 0.0.0.0:$Port ..."
$server = Start-Process -PassThru -NoNewWindow python $serverArgs
Start-Sleep -Seconds 4

$cloudflared = "C:\Program Files (x86)\cloudflared\cloudflared.exe"
if (-not (Test-Path $cloudflared)) { $cloudflared = "cloudflared" }

$log = Join-Path $env:TEMP "outertune-tunnel.log"
if (Test-Path $log) { Remove-Item $log -Force }

if ($QuickTunnel) {
    $tunnel = Start-Process -PassThru -NoNewWindow -RedirectStandardError $log `
        $cloudflared @("tunnel", "--url", "http://127.0.0.1:$Port", "--no-autoupdate")
    $publicUrl = $null
    for ($i = 0; $i -lt 40; $i++) {
        Start-Sleep -Milliseconds 750
        if (Test-Path $log) {
            $m = Select-String -Path $log -Pattern "https://[a-z0-9-]+\.trycloudflare\.com" |
                 Select-Object -First 1
            if ($m) { $publicUrl = $m.Matches[0].Value; break }
        }
    }
} else {
    # Named tunnel: the ingress rule in ~/.cloudflared/config.yml already points
    # at this port, so the hostname never changes.
    $tunnel = Start-Process -PassThru -NoNewWindow -RedirectStandardError $log `
        $cloudflared @("tunnel", "run", $TunnelName)
    $publicUrl = "https://music.598787.xyz"
    Start-Sleep -Seconds 8
}

Write-Host ""
Write-Host "======================================================================"
Write-Host "  Server URL : $publicUrl"
if ([string]::IsNullOrWhiteSpace($Token)) {
    Write-Host "  Token      : (none - leave the field blank)"
} else {
    Write-Host "  Token      : $Token"
}
Write-Host "======================================================================"
Write-Host "  App: 設定 > 推薦 > 串流伺服器"
Write-Host "  Leave this window open while listening. Ctrl+C to stop."
Write-Host ""

try {
    Wait-Process -Id $server.Id
} finally {
    foreach ($p in @($server, $tunnel)) {
        if ($p -and -not $p.HasExited) {
            Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        }
    }
}
