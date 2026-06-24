# fix-wuaueng-sfc.ps1
# Richiede esecuzione come ADMINISTRATOR
# Ripara wuaueng.dll corrotto (MUI stub al posto del DLL reale)

$p = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "NOT ELEVATED - re-launching with UAC" -ForegroundColor Yellow
    Start-Process powershell.exe -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File "{0}" -NoExit' -f $MyInvocation.MyCommand.Path -Verb RunAs
    exit
}

Write-Host "=== wuaueng.dll REPAIR via SFC ===" -ForegroundColor Cyan
Write-Host "Questo richiede 5-15 minuti. Non chiudere la finestra." -ForegroundColor Yellow
Write-Host ""

# Pre-check: confirm the MUI stub problem
$dll = Get-Item "$env:SystemRoot\System32\wuaueng.dll" -ErrorAction SilentlyContinue
if ($dll) {
    $vi = $dll.VersionInfo
    Write-Host "PRE-FIX wuaueng.dll:" -ForegroundColor Yellow
    Write-Host "  OriginalFilename : $($vi.OriginalFilename)"
    Write-Host "  FileVersion      : $($vi.FileVersion)"
    Write-Host "  Size             : $([math]::Round($dll.Length/1KB,0)) KB"
    if ($vi.OriginalFilename -match '\.mui$') {
        Write-Host "  STATUS: CORRUPTED (MUI stub - has no ServiceMain export)" -ForegroundColor Red
    } else {
        Write-Host "  STATUS: OK (real DLL)" -ForegroundColor Green
    }
}

Write-Host ""
Write-Host "--- Running DISM /CheckHealth first ---" -ForegroundColor Cyan
DISM /Online /Cleanup-Image /CheckHealth

Write-Host ""
Write-Host "--- Running SFC /scannow ---" -ForegroundColor Cyan
sfc /scannow

Write-Host ""
Write-Host "--- Post-SFC check ---" -ForegroundColor Cyan
$dll2 = Get-Item "$env:SystemRoot\System32\wuaueng.dll" -ErrorAction SilentlyContinue
if ($dll2) {
    $vi2 = $dll2.VersionInfo
    Write-Host "POST-FIX wuaueng.dll:" -ForegroundColor Yellow
    Write-Host "  OriginalFilename : $($vi2.OriginalFilename)"
    Write-Host "  FileVersion      : $($vi2.FileVersion)"
    Write-Host "  Size             : $([math]::Round($dll2.Length/1KB,0)) KB"
    if ($vi2.OriginalFilename -match '\.mui$') {
        Write-Host "  STATUS: STILL CORRUPTED -> run DISM RestoreHealth" -ForegroundColor Red
        Write-Host ""
        Write-Host "Running DISM /RestoreHealth (requires internet)..." -ForegroundColor Yellow
        DISM /Online /Cleanup-Image /RestoreHealth
        Write-Host "Re-running SFC /scannow after DISM..." -ForegroundColor Yellow
        sfc /scannow
    } else {
        Write-Host "  STATUS: REPAIRED" -ForegroundColor Green
        # Try to start wuauserv
        Write-Host ""
        Write-Host "--- Starting wuauserv ---" -ForegroundColor Cyan
        sc.exe start wuauserv
        Start-Sleep -Seconds 4
        sc.exe query wuauserv
    }
}

Write-Host ""
Write-Host "=== DONE. Press Enter to close ===" -ForegroundColor White
Read-Host
