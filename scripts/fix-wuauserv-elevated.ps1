$p = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
$elevated = $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Write-Host "IsElevated: $elevated"
if (-not $elevated) {
    Write-Host "NOT ELEVATED - need UAC prompt" -ForegroundColor Red
} else {
    Write-Host "ELEVATED - proceeding" -ForegroundColor Green
    # Direct reg.exe writes
    $regBase = 'HKLM\SYSTEM\CurrentControlSet\Services\wuauserv\Parameters'
    reg add $regBase /f
    reg add $regBase /v ServiceDll /t REG_EXPAND_SZ /d "%SystemRoot%\system32\wuaueng.dll" /f
    reg add $regBase /v ServiceDllUnloadOnStop /t REG_DWORD /d 1 /f
    Write-Host "--- VERIFY ---"
    reg query $regBase /v ServiceDll
    Write-Host "--- START wuauserv ---"
    sc.exe start wuauserv
    Start-Sleep -Seconds 3
    sc.exe query wuauserv
}
