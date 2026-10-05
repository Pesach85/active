# Proves the network-action wrapper and CLI dry-run contract without Reset-NetTCPConnection.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not (Test-Path -LiteralPath (Join-Path $root 'scripts\apply-network-action.ps1'))) {
    $root = $PSScriptRoot
}
$scriptPath = Join-Path $root 'scripts\apply-network-action.ps1'
$text = Get-Content -LiteralPath $scriptPath -Raw
foreach ($denied in @(
    'StateMismatch', 'StateUnverified', 'TargetAbsent', 'TargetAmbiguous', 'SnapshotUnavailable', 'ResetFailed',
    'ReadyToApply', 'BlockFailed', 'TerminateFailed', 'ProcessNotRunning', 'PidIdentityMismatch', 'InvalidPid'
)) {
    if ($text -notmatch [regex]::Escape("'$denied'")) { throw "failure set missing $denied" }
}
if ($text -match "'ConnectionReset'") { throw 'ConnectionReset must stay out of the failure set' }

$out = Join-Path $root 'logs\network-kill-dryrun-verify.json'
if (Test-Path -LiteralPath $out) { Remove-Item -LiteralPath $out -Force }
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath `
    -Action KillConnection -ProcessName dryrun `
    -LocalAddress 127.0.0.1 -LocalPort 8765 `
    -RemoteAddress 127.0.0.1 -RemotePort 8765 `
    -DryRun -IUnderstandRisk -SkipAuth -Quiet `
    -OutputJson $out -HubRoot $root | Out-Null
if ($LASTEXITCODE -ne 0) { throw "dry-run exit $LASTEXITCODE" }
$json = Get-Content -LiteralPath $out -Raw | ConvertFrom-Json
if ([string]$json.Outcome -ne 'DryRunKillConnection') { throw "dry-run outcome $($json.Outcome)" }

$blockOut = Join-Path $root 'logs\network-block-dryrun-verify.json'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath `
    -Action BlockRemoteIp -RemoteAddress 8.8.8.8 -ConfirmPhrase BLOCK-REMOTE-IP `
    -DryRun -IUnderstandRisk -SkipAuth -Quiet `
    -OutputJson $blockOut -HubRoot $root | Out-Null
if ($LASTEXITCODE -ne 0) { throw "block dry-run exit $LASTEXITCODE" }
$blockJson = Get-Content -LiteralPath $blockOut -Raw | ConvertFrom-Json
if ([string]$blockJson.Outcome -ne 'DryRunBlockRemoteIp') { throw "block dry-run outcome $($blockJson.Outcome)" }

$termOut = Join-Path $root 'logs\network-terminate-dryrun-verify.json'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath `
    -Action TerminateProcess -ProcessId 4242 -ProcessName dryrun -ConfirmPhrase TERMINATE-NETWORK-PROCESS `
    -DryRun -IUnderstandRisk -SkipAuth -Quiet `
    -OutputJson $termOut -HubRoot $root | Out-Null
if ($LASTEXITCODE -ne 0) { throw "terminate dry-run exit $LASTEXITCODE" }
$termJson = Get-Content -LiteralPath $termOut -Raw | ConvertFrom-Json
if ([string]$termJson.Outcome -ne 'DryRunTerminateProcess') { throw "terminate dry-run outcome $($termJson.Outcome)" }

Write-Output 'NETWORK POSTSTATE CHECKS PASSED'
