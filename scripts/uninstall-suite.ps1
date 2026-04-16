[CmdletBinding()]
param(
    [string]$InstallRoot = "C:\\SystemOptimizer",
    [switch]$RemoveInstallRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$taskNames = @("SystemResourceMonitor", "StorageCleanupSafe")
foreach ($task in $taskNames) {
    try {
        Unregister-ScheduledTask -TaskName $task -Confirm:$false -ErrorAction Stop
        Write-Host "Removed task: $task"
    } catch {
        Write-Host "Task not removed ($task): $($_.Exception.Message)"
    }
}

if ($RemoveInstallRoot -and (Test-Path -LiteralPath $InstallRoot)) {
    Remove-Item -LiteralPath $InstallRoot -Recurse -Force
    Write-Host "Removed install root: $InstallRoot"
}
