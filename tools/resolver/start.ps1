# Starts the OuterTune stream resolver and a Cloudflare tunnel.
#
#   powershell -ExecutionPolicy Bypass -File tools\resolver\start.ps1
#
# Prints the public URL and token to enter under
# Settings > 推薦 > 串流伺服器 in the app.

param(
    [int]$Port = 8787,
    [string]$Token = "",
    [string]$Cookies = "build\ytm_cookies.txt"
)

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Set-Location $repo

if ([string]::IsNullOrWhiteSpace($Token)) {
    $bytes = New-Object byte[] 24
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $Token = [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+','-').Replace('/','_')
}

$cookieArgs = @()
if (Test-Path $Cookies) {
    $cookieArgs = @("--cookies", $Cookies)
    Write-Host "using cookies: $Cookies"
} else {
    Write-Host "no cookie file at $Cookies - running anonymously" -ForegroundColor Yellow
}

Write-Host "starting resolver on 127.0.0.1:$Port ..."
$server = Start-Process -PassThru -NoNewWindow python `
    (@("tools\resolver\server.py", "--port", $Port, "--token", $Token) + $cookieArgs)

Start-Sleep -Seconds 3

$cloudflared = "C:\Program Files (x86)\cloudflared\cloudflared.exe"
if (-not (Test-Path $cloudflared)) { $cloudflared = "cloudflared" }

Write-Host "starting cloudflared tunnel ..."
$log = Join-Path $env:TEMP "outertune-tunnel.log"
if (Test-Path $log) { Remove-Item $log -Force }
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

Write-Host ""
Write-Host "======================================================================"
if ($publicUrl) {
    Write-Host "  Server URL : $publicUrl"
} else {
    Write-Host "  Server URL : (not detected - check $log)" -ForegroundColor Yellow
}
Write-Host "  Token      : $Token"
Write-Host "======================================================================"
Write-Host "  Enter both in the app: Settings > 推薦 > 串流伺服器"
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
