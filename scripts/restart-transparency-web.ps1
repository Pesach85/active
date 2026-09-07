Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$hubRoot = 'D:\SystemOptimizerHub\active'
$pidFile = Join-Path $hubRoot 'logs\transparency-web.pid'

if (Test-Path -LiteralPath $pidFile) {
    $p = [int](Get-Content -LiteralPath $pidFile -Raw).Trim()
    if ($p -gt 0) {
        Stop-Process -Id $p -Force -ErrorAction SilentlyContinue
        Write-Host "Stopped PID $p"
    }
    Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
}

Start-Sleep -Seconds 1
& (Join-Path $hubRoot 'scripts\run-transparency-web.ps1') -Quiet
