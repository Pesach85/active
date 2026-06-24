$p = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "NOT ELEVATED" -ForegroundColor Red; exit 1
}

Write-Host "=== wuauserv START + VERIFY ===" -ForegroundColor Cyan

# Start wuauserv
sc.exe start wuauserv 2>&1
Start-Sleep -Seconds 4
sc.exe query wuauserv

Write-Host ""
Write-Host "--- wuauserv Event Log (last 3 errors) ---" -ForegroundColor Yellow
Get-WinEvent -LogName System -MaxEvents 300 -ErrorAction SilentlyContinue | 
    Where-Object { $_.Id -in @(7000,7001,7009,7023,7031,7034,7038) -and $_.Message -match 'wuauserv|wuau' } |
    Select-Object -First 3 |
    Format-List TimeCreated, Id, Message
