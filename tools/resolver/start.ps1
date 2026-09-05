# Starts the OuterTune stream resolver and a Cloudflare tunnel.
#
#   powershell -ExecutionPolicy Bypass -File tools\resolver\start.ps1
#
# Prints the public URL to enter under Settings > 推薦 > 串流伺服器 in the app.
# Token authentication is optional and disabled by default.

param(
    [int]$Port = 8787,
    [string]$Token = "",
    [string]$Cookies = "build\ytm_cookies.txt",
    [switch]$SkipPremiumProvider
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Set-Location $repo

if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) {
    throw "ffmpeg is required for fast progressive M4A playback"
}

$cookieArgs = @()
if (Test-Path $Cookies) {
    $cookieArgs = @("--cookies", $Cookies)
    Write-Host "using cookies: $Cookies"
} else {
    Write-Host "no cookie file at $Cookies - running anonymously" -ForegroundColor Yellow
}

$premiumProvider = $null
$premiumProviderStartedHere = $false
if ($cookieArgs.Count -gt 0 -and -not $SkipPremiumProvider) {
    $providerVersion = "1.3.2"
    $providerRoot = Join-Path $repo "build\bgutil-ytdlp-pot-provider-$providerVersion"
    $providerServer = Join-Path $providerRoot "server"
    $providerEntryPoint = Join-Path $providerServer "build\main.js"

    Write-Host "checking Premium audio provider ..."
    python -c "import importlib.metadata,sys; sys.exit(0 if importlib.metadata.version('bgutil-ytdlp-pot-provider') == '$providerVersion' else 1)" 2>$null
    if ($LASTEXITCODE -ne 0) {
        python -m pip install --upgrade "bgutil-ytdlp-pot-provider==$providerVersion"
        if ($LASTEXITCODE -ne 0) { throw "failed to install bgutil yt-dlp plugin" }
    }

    if (-not (Test-Path -LiteralPath $providerEntryPoint)) {
        if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
            throw "git is required for the one-time Premium provider setup"
        }
        if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
            throw "Node.js/npm is required for the one-time Premium provider setup"
        }

        Write-Host "installing Premium audio provider (one time) ..."
        if (-not (Test-Path -LiteralPath $providerRoot)) {
            git clone --depth 1 --branch $providerVersion `
                https://github.com/Brainicism/bgutil-ytdlp-pot-provider.git $providerRoot
            if ($LASTEXITCODE -ne 0) { throw "failed to download Premium provider" }
        }

        Push-Location $providerServer
        try {
            npm ci
            if ($LASTEXITCODE -ne 0) { throw "failed to install Premium provider dependencies" }
            npx tsc
            if ($LASTEXITCODE -ne 0) { throw "failed to compile Premium provider" }
        } finally {
            Pop-Location
        }
    }

    $providerReady = $false
    try {
        $ping = Invoke-WebRequest -UseBasicParsing -TimeoutSec 2 `
            -Uri "http://127.0.0.1:4416/ping"
        $providerReady = $ping.StatusCode -eq 200
    } catch {}

    if (-not $providerReady) {
        $premiumProvider = Start-Process -PassThru -WindowStyle Hidden `
            -WorkingDirectory $providerServer node @($providerEntryPoint)
        $premiumProviderStartedHere = $true
        for ($i = 0; $i -lt 20; $i++) {
            Start-Sleep -Milliseconds 500
            try {
                $ping = Invoke-WebRequest -UseBasicParsing -TimeoutSec 2 `
                    -Uri "http://127.0.0.1:4416/ping"
                if ($ping.StatusCode -eq 200) { $providerReady = $true; break }
            } catch {}
        }
    }

    if (-not $providerReady) {
        throw "Premium audio provider did not start on 127.0.0.1:4416"
    }
    Write-Host "Premium audio provider ready (itag 141 eligible)"
}

Write-Host "starting resolver on 127.0.0.1:$Port ..."
$serverArgs = @("tools\resolver\server.py", "--port", $Port) + $cookieArgs
if (-not [string]::IsNullOrWhiteSpace($Token)) {
    $serverArgs += @("--token", $Token)
}
$server = Start-Process -PassThru -NoNewWindow python $serverArgs

Start-Sleep -Seconds 3

$cloudflared = "C:\Program Files (x86)\cloudflared\cloudflared.exe"
if (-not (Test-Path $cloudflared)) { $cloudflared = "cloudflared" }

Write-Host "starting cloudflared tunnel ..."
$log = Join-Path $env:TEMP "outertune-tunnel-$Port.log"
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
    Set-Content -LiteralPath (Join-Path $repo "build\resolver_url.txt") `
        -Value $publicUrl -NoNewline -Encoding Ascii
} else {
    Write-Host "  Server URL : (not detected - check $log)" -ForegroundColor Yellow
}
if ([string]::IsNullOrWhiteSpace($Token)) {
    Write-Host "  Token      : (not required)"
} else {
    Write-Host "  Token      : $Token"
}
Write-Host "======================================================================"
Write-Host "  Enter the Server URL in: Settings > 推薦 > 串流伺服器"
Write-Host "  Quick-tunnel URLs change after this script is restarted."
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
    if ($premiumProviderStartedHere -and $premiumProvider -and -not $premiumProvider.HasExited) {
        Stop-Process -Id $premiumProvider.Id -Force -ErrorAction SilentlyContinue
    }
}
