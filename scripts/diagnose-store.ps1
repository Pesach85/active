# Store Deep Diagnosis Script - Senior Dev Reverse Engineering
# Run as: powershell.exe -ExecutionPolicy Bypass -File diagnose-store.ps1

Write-Host "=== WINDOWS STORE DEEP DIAGNOSIS ===" -ForegroundColor Cyan

# ---- 1. Group Policy / Registry blocks ----
Write-Host "`n--- [GP/Registry Blocks] ---" -ForegroundColor Yellow
$gp1 = Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore" -ErrorAction SilentlyContinue
$gp2 = Get-ItemProperty "HKCU:\SOFTWARE\Policies\Microsoft\WindowsStore" -ErrorAction SilentlyContinue
$gp3 = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -ErrorAction SilentlyContinue

if ($gp1) { Write-Host "HKLM WindowsStore Policy:"; $gp1 | Format-List }
else       { Write-Host "HKLM WindowsStore Policy: NOT SET" }

if ($gp2) { Write-Host "HKCU WindowsStore Policy:"; $gp2 | Format-List }
else       { Write-Host "HKCU WindowsStore Policy: NOT SET" }

$removeStore = Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore" -Name "RemoveWindowsStore" -ErrorAction SilentlyContinue
if ($removeStore) { Write-Host "CRITICAL: RemoveWindowsStore = $($removeStore.RemoveWindowsStore)" -ForegroundColor Red }

# ---- 2. SLS COM Server registration ----
Write-Host "`n--- [SLS COM / CLSID for StoreFront] ---" -ForegroundColor Yellow
# GUID_StoreFrontServiceID - search CLSID registry
$storeCLSIDs = @(
    "{00000000-0000-0000-0000-000000000000}", # placeholder
    "{9DA0E0AB-E9D7-4F5B-B8E9-4A86AB7A0F7E}"  # known SLS CLSID
)
# Look for wsappx-hosted COM servers
$wsappxCLSID = Get-ChildItem "HKLM:\SOFTWARE\Classes\CLSID" -ErrorAction SilentlyContinue | 
    Where-Object { 
        try { (Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).'(default)' -match 'Store|SLS|License' } catch { $false }
    } | Select-Object -First 10
if ($wsappxCLSID) { $wsappxCLSID | ForEach-Object { Write-Host $_.Name } }
else { Write-Host "No Store/SLS CLSID found via display name search" }

# ---- 3. wuauserv stopped despite AUTO - check failure actions ----
Write-Host "`n--- [wuauserv failure/start reason] ---" -ForegroundColor Yellow
sc.exe qfailure wuauserv
Write-Host ""
$wuEvent = Get-WinEvent -LogName System -MaxEvents 500 -ErrorAction SilentlyContinue | 
    Where-Object { $_.Id -eq 7034 -or $_.Id -eq 7031 -or $_.Id -eq 7023 } |
    Where-Object { $_.Message -match "wuauserv|Update|wsappx|ClipSVC|AppXSvc" } |
    Select-Object -First 5
if ($wuEvent) { $wuEvent | Format-List TimeCreated, Id, Message }
else { Write-Host "No service failure events for wuauserv/ClipSVC in System log" }

# ---- 4. ClipSVC start attempt ----
Write-Host "`n--- [ClipSVC start test] ---" -ForegroundColor Yellow
Start-Service ClipSVC -ErrorAction SilentlyContinue
$clip = Get-Service ClipSVC -ErrorAction SilentlyContinue
Write-Host "ClipSVC after start attempt: $($clip.Status)"

# ---- 5. wuauserv start attempt ----
Write-Host "`n--- [wuauserv start test] ---" -ForegroundColor Yellow
Start-Service wuauserv -ErrorAction SilentlyContinue
$wu = Get-Service wuauserv -ErrorAction SilentlyContinue
Write-Host "wuauserv after start attempt: $($wu.Status)"

# ---- 6. SFC quick check on wsappx dll ----
Write-Host "`n--- [wsappx / AppxDeployment DLL check] ---" -ForegroundColor Yellow
$dlls = @(
    "C:\Windows\System32\AppxDeploymentServer.dll",
    "C:\Windows\System32\ClipSVC.dll",
    "C:\Windows\System32\storewuauth.dll",
    "C:\Windows\System32\Windows.ApplicationModel.Store.dll"
)
foreach ($dll in $dlls) {
    if (Test-Path $dll) {
        $fi = Get-Item $dll
        Write-Host "PRESENT: $dll ($([math]::Round($fi.Length/1KB,0)) KB, $($fi.LastWriteTime))"
    } else {
        Write-Host "MISSING: $dll" -ForegroundColor Red
    }
}

# ---- 7. Store registry configuration ----
Write-Host "`n--- [Store Registry Config] ---" -ForegroundColor Yellow
$storeReg = Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Store" -ErrorAction SilentlyContinue
if ($storeReg) { $storeReg | Format-List }
else { Write-Host "HKCU Store config: not found" }

# ---- 8. Last Store error events ----
Write-Host "`n--- [Store Event Log - Errors/Warnings only] ---" -ForegroundColor Yellow
$storeEvents = Get-WinEvent -LogName "Microsoft-Windows-Store/Operational" -MaxEvents 100 -ErrorAction SilentlyContinue |
    Where-Object { $_.Level -le 3 } |
    Select-Object -First 10
if ($storeEvents) { $storeEvents | Format-List TimeCreated, Id, LevelDisplayName, Message }
else { Write-Host "No errors/warnings in Store event log" }

# ---- 9. Network connectivity to Store endpoints ----
Write-Host "`n--- [Store Network Endpoints] ---" -ForegroundColor Yellow
$endpoints = @("login.microsoftonline.com","storeedgefd.dsx.mp.microsoft.com","displaycatalog.mp.microsoft.com")
foreach ($ep in $endpoints) {
    $result = Test-NetConnection -ComputerName $ep -Port 443 -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
    $status = if ($result.TcpTestSucceeded) { "REACHABLE" } else { "UNREACHABLE" }
    Write-Host "$ep : $status"
}

# ---- 10. Microsoft account token / WAM ----
Write-Host "`n--- [WAM / MSA Token state] ---" -ForegroundColor Yellow
$wamEvents = Get-WinEvent -LogName "Microsoft-Windows-AAD/Operational" -MaxEvents 20 -ErrorAction SilentlyContinue |
    Where-Object { $_.Level -le 3 } | Select-Object -First 5
if ($wamEvents) { $wamEvents | Format-List TimeCreated, Id, LevelDisplayName, Message }
else { Write-Host "No AAD/WAM errors found" }

Write-Host "`n=== DIAGNOSIS COMPLETE ===" -ForegroundColor Cyan
