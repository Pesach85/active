# fix-store-deterministic.ps1
# Senior Dev Fix - Windows Store SLS failure + wuauserv registry corruption
# Author: diagnostic output 2026-04-23

# Self-elevate via UAC if not already running as elevated admin
$identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]$identity
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host '[UAC] Re-launching with elevation...' -ForegroundColor Yellow
    $args = '-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $MyInvocation.MyCommand.Path
    Start-Process powershell.exe -ArgumentList $args -Verb RunAs
    exit
}

$ErrorActionPreference = 'Stop'

function Write-Step($msg) { Write-Host "`n[STEP] $msg" -ForegroundColor Cyan }
function Write-OK($msg)   { Write-Host "  [OK] $msg" -ForegroundColor Green }
function Write-FAIL($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red }
function Write-INFO($msg) { Write-Host "  [INFO] $msg" -ForegroundColor Yellow }

Write-Host "=== WINDOWS STORE DETERMINISTIC FIX ===" -ForegroundColor White
Write-Host "Date: $(Get-Date)" -ForegroundColor Gray

# =========================================================
# ANTI-REGRESSION: registry backup before changes
# =========================================================
Write-Step "Backup wuauserv registry before changes"
$backupPath = "$env:TEMP\wuauserv-backup-$(Get-Date -Format 'yyyyMMdd-HHmmss').reg"
reg export "HKLM\SYSTEM\CurrentControlSet\Services\wuauserv" $backupPath /y 2>&1 | Out-Null
Write-OK "Backup saved: $backupPath"

# =========================================================
# FIX 1: wuauserv - missing Parameters\ServiceDll
# Root cause: Parameters subkey deleted/corrupted -> svchost
#             cannot find DLL -> ERROR_FILE_NOT_FOUND (exit 2)
# =========================================================
Write-Step "FIX 1: Restore wuauserv Parameters\ServiceDll (registry corruption)"

$wuDll = "$env:SystemRoot\system32\wuaueng.dll"
if (-not (Test-Path $wuDll)) {
    Write-FAIL "wuaueng.dll NOT FOUND at $wuDll — SFC repair needed first"
    Write-INFO "Run: sfc /scannow then re-run this script"
    exit 1
}
Write-OK "wuaueng.dll present: $wuDll"

# Use reg.exe directly — avoids PS provider quirks on SYSTEM hive
$regBase = 'HKLM\SYSTEM\CurrentControlSet\Services\wuauserv\Parameters'

reg add $regBase /f 2>&1 | Out-Null
if ($LASTEXITCODE -eq 0) { Write-OK "Parameters subkey created/confirmed" }
else { Write-FAIL "Could not create Parameters key (exit $LASTEXITCODE) - check elevation"; exit 1 }

reg add $regBase /v ServiceDll /t REG_EXPAND_SZ /d "%SystemRoot%\system32\wuaueng.dll" /f 2>&1 | Out-Null
if ($LASTEXITCODE -eq 0) { Write-OK "Set ServiceDll = %SystemRoot%\system32\wuaueng.dll" }
else { Write-FAIL "ServiceDll write failed (exit $LASTEXITCODE)"; exit 1 }

reg add $regBase /v ServiceDllUnloadOnStop /t REG_DWORD /d 1 /f 2>&1 | Out-Null
if ($LASTEXITCODE -eq 0) { Write-OK "Set ServiceDllUnloadOnStop = 1" }
else { Write-FAIL "ServiceDllUnloadOnStop write failed (exit $LASTEXITCODE)" }

# Verify via reg query (no PS provider — no caching issues)
$verifyOut = (reg query $regBase /v ServiceDll 2>&1) -join ' '
if ($verifyOut -match 'wuaueng') { Write-OK "VERIFIED: ServiceDll correctly written to registry" }
else { Write-FAIL "Verification failed — value not found after write" }

# =========================================================
# FIX 2: ClipSVC — ensure running (was stopped at Store launch)
# Root cause: ClipSVC stopped → COM activation of
#             GUID_StoreFrontServiceID fails with 0x80080005
#             CO_E_SERVER_EXEC_FAILURE → SLS cannot initialize
#             → Store SDK endpoint URL resolution fails
# =========================================================
Write-Step "FIX 2: Ensure ClipSVC is running"
$clip = Get-Service ClipSVC -ErrorAction SilentlyContinue
if ($clip.Status -ne 'Running') {
    Start-Service ClipSVC -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    $clip = Get-Service ClipSVC
    if ($clip.Status -eq 'Running') { Write-OK "ClipSVC started successfully" }
    else { Write-FAIL "ClipSVC failed to start: $($clip.Status)" }
} else {
    Write-OK "ClipSVC already running"
}

# =========================================================
# FIX 3: Start wuauserv
# =========================================================
Write-Step "FIX 3: Start wuauserv (Windows Update)"
try {
    Start-Service wuauserv -ErrorAction Stop
    Start-Sleep -Seconds 2
    $wu = Get-Service wuauserv
    Write-OK "wuauserv status: $($wu.Status)"
} catch {
    Write-FAIL "Could not start wuauserv: $_"
    Write-INFO "Check System event log for service control errors"
}

# =========================================================
# FIX 4: Flush Store / SLS cache
# Clears SLS cached endpoint data so next Store launch
# re-fetches via GetSLSDataChunk (now that ClipSVC is up)
# =========================================================
Write-Step "FIX 4: Flush Store SLS and token cache"
$storeCachePaths = @(
    "$env:LOCALAPPDATA\Packages\Microsoft.WindowsStore_8wekyb3d8bbwe\LocalCache",
    "$env:LOCALAPPDATA\Packages\Microsoft.WindowsStore_8wekyb3d8bbwe\TempState",
    "$env:LOCALAPPDATA\Packages\Microsoft.StorePurchaseApp_8wekyb3d8bbwe\LocalCache"
)
foreach ($path in $storeCachePaths) {
    if (Test-Path $path) {
        try {
            Remove-Item "$path\*" -Recurse -Force -ErrorAction SilentlyContinue
            Write-OK "Cleared: $path"
        } catch {
            Write-INFO "Could not clear (in use): $path"
        }
    } else {
        Write-INFO "Not found (skip): $path"
    }
}

# =========================================================
# FIX 5: Re-register Store AppX manifest
# Ensures AppX deployment cache matches current package state
# =========================================================
Write-Step "FIX 5: Re-register Store AppxManifest"
$storePkg = Get-AppxPackage -Name "Microsoft.WindowsStore" -ErrorAction SilentlyContinue
if ($storePkg) {
    $manifest = "$($storePkg.InstallLocation)\AppxManifest.xml"
    if (Test-Path $manifest) {
        try {
            Add-AppxPackage -DisableDevelopmentMode -Register $manifest -ErrorAction Stop
            Write-OK "Store AppxManifest re-registered: $($storePkg.Version)"
        } catch {
            Write-INFO "Re-register returned: $($_.Exception.Message)"
            Write-INFO "This is often non-fatal if package is already current"
        }
    } else {
        Write-FAIL "AppxManifest.xml not found at: $manifest"
    }
} else {
    Write-FAIL "Microsoft.WindowsStore package not found"
}

# =========================================================
# VERIFICATION
# =========================================================
Write-Step "POST-FIX VERIFICATION"

$clipStatus = (Get-Service ClipSVC -ErrorAction SilentlyContinue).Status
$wuStatus   = (Get-Service wuauserv -ErrorAction SilentlyContinue).Status
# Use reg query — bypasses PS registry provider caching
$paramDllOut = (reg query "HKLM\SYSTEM\CurrentControlSet\Services\wuauserv\Parameters" /v ServiceDll 2>&1) -join ' '
$paramDll    = if ($paramDllOut -match 'wuaueng') { 'wuaueng.dll SET' } else { 'MISSING' }
$storePkgOk = (Get-AppxPackage -Name "Microsoft.WindowsStore" -ErrorAction SilentlyContinue).Status

Write-Host ""
Write-Host "  ClipSVC          : $clipStatus    (expected: Running)"   -ForegroundColor $(if ($clipStatus -eq 'Running') {'Green'} else {'Red'})
Write-Host "  wuauserv         : $wuStatus      (expected: Running)"   -ForegroundColor $(if ($wuStatus -eq 'Running') {'Green'} else {'Red'})
Write-Host "  wuauserv DLL     : $paramDll      (expected: wuaueng.dll SET)" -ForegroundColor $(if ($paramDll -like '*SET*') {'Green'} else {'Red'})
Write-Host "  Store pkg status : $storePkgOk    (expected: Ok)"        -ForegroundColor $(if ($storePkgOk -eq 'Ok') {'Green'} else {'Red'})

Write-Host ""
Write-Host "=== COMPLETE. Launch Windows Store to verify. ===" -ForegroundColor White
Write-Host "If Store still shows errors, run: wsreset.exe" -ForegroundColor Gray
Write-Host "Registry backup: $backupPath" -ForegroundColor Gray
