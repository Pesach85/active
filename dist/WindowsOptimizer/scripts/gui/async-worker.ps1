# Shared async worker registry for System Optimizer Hub GUI.
# Dot-sourced after worker-helpers.ps1. Pure PowerShell (5.1 + 7+); no WinForms.
#
# Uses $global:HubWorkers (not $script:) so the registry survives:
# - Set-StrictMode from hub-common / i18n
# - ps2exe host where dot-sourced files have a separate script scope

function Initialize-HubWorkerRegistry {
    $var = Get-Variable -Name HubWorkers -Scope Global -ErrorAction SilentlyContinue
    if ($null -eq $var -or $null -eq $var.Value) {
        Set-Variable -Name HubWorkers -Scope Global -Value (@{}) -Force
    }
    elseif ($var.Value -isnot [hashtable] -and $var.Value -isnot [System.Collections.IDictionary]) {
        Set-Variable -Name HubWorkers -Scope Global -Value (@{}) -Force
    }
}

function Get-HubWorkersTable {
    Initialize-HubWorkerRegistry
    return $global:HubWorkers
}

Initialize-HubWorkerRegistry

function Start-HubAsyncWorker {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$PsHost,

        [string]$ScriptPath,

        [string[]]$ArgumentList,

        [string[]]$ExtraArgs,

        [string[]]$OutputPaths,

        [string]$StdOutPath,

        [string]$StdErrPath,

        [int]$TimeoutSec = 120
    )

    Initialize-HubWorkerRegistry

    if ([string]::IsNullOrWhiteSpace($PsHost)) {
        throw "PsHost is required."
    }
    if (-not (Test-Path -LiteralPath $PsHost)) {
        throw ("PowerShell host not found: {0}" -f $PsHost)
    }

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $false
    }

    $argv = $null
    if ($null -ne $ArgumentList -and $ArgumentList.Count -gt 0) {
        $argv = [string[]]@($ArgumentList)
    }
    elseif (-not [string]::IsNullOrWhiteSpace($ScriptPath)) {
        $argv = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath)
        if ($null -ne $ExtraArgs -and $ExtraArgs.Count -gt 0) {
            $argv = $argv + @($ExtraArgs)
        }
    }
    else {
        return $false
    }

    if ($null -ne $OutputPaths) {
        foreach ($p in $OutputPaths) {
            if ([string]::IsNullOrWhiteSpace($p)) { continue }
            if (Get-Command Remove-IfExists -ErrorAction SilentlyContinue) {
                Remove-IfExists -Path $p
            }
            elseif (Test-Path -LiteralPath $p) {
                Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
            }
        }
    }

    try {
        $startParams = @{
            FilePath     = $PsHost
            ArgumentList = $argv
            WindowStyle  = 'Hidden'
            PassThru     = $true
        }
        if (-not [string]::IsNullOrWhiteSpace($StdOutPath)) {
            $startParams['RedirectStandardOutput'] = $StdOutPath
        }
        if (-not [string]::IsNullOrWhiteSpace($StdErrPath)) {
            $startParams['RedirectStandardError'] = $StdErrPath
        }

        $proc = Start-Process @startParams
        if (-not $proc) {
            return $false
        }

        $table = Get-HubWorkersTable
        $table[$Name] = @{
            Process           = $proc
            StartedAt         = Get-Date
            TimeoutSec        = [math]::Max(1, [int]$TimeoutSec)
            SoftTimeoutWarned = $false
            StdErrPath        = $StdErrPath
            StdOutPath        = $StdOutPath
            OutputPaths       = @($OutputPaths)
        }
        return $true
    }
    catch {
        return $false
    }
}

function Get-HubAsyncWorker {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $table = Get-HubWorkersTable
    if (-not $table.ContainsKey($Name)) {
        return $null
    }
    return $table[$Name]
}

function Test-HubAsyncWorkerRunning {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $w = Get-HubAsyncWorker -Name $Name
    if (-not $w -or $null -eq $w.Process) {
        return $false
    }

    try {
        return (-not $w.Process.HasExited)
    }
    catch {
        return $false
    }
}

function Update-HubAsyncWorkerSoftTimeout {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [scriptblock]$OnWarn
    )

    $w = Get-HubAsyncWorker -Name $Name
    if (-not $w -or $null -eq $w.StartedAt) {
        return $null
    }

    $timeoutSec = [math]::Max(1, [int]$w.TimeoutSec)
    $elapsedSec = [math]::Round(((Get-Date) - [datetime]$w.StartedAt).TotalSeconds, 0)
    $timedOut = ($elapsedSec -gt $timeoutSec)
    $shouldWarn = $timedOut -and (-not [bool]$w.SoftTimeoutWarned)

    if ($shouldWarn) {
        $w.SoftTimeoutWarned = $true
        $table = Get-HubWorkersTable
        $table[$Name] = $w
        if ($null -ne $OnWarn) {
            & $OnWarn $elapsedSec $timeoutSec
        }
    }

    return @{
        ElapsedSec = $elapsedSec
        TimedOut   = $timedOut
        ShouldWarn = $shouldWarn
    }
}

function Stop-HubAsyncWorker {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [switch]$Force
    )

    $w = Get-HubAsyncWorker -Name $Name
    if ($Force -and $w -and $w.Process) {
        try {
            if (-not $w.Process.HasExited) {
                Stop-Process -Id $w.Process.Id -Force -ErrorAction Stop
            }
        }
        catch {
            try { $w.Process.Kill() } catch {}
        }
    }

    $table = Get-HubWorkersTable
    if ($table.ContainsKey($Name)) {
        $table.Remove($Name)
    }
}

function Complete-HubAsyncWorker {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $w = Get-HubAsyncWorker -Name $Name
    if (-not $w -or $null -eq $w.Process) {
        return $null
    }

    try {
        if (-not $w.Process.HasExited) {
            return $null
        }
    }
    catch {
        return $null
    }

    $exitCode = -1
    if (Get-Command Get-ProcessExitCodeSafe -ErrorAction SilentlyContinue) {
        $exitCode = Get-ProcessExitCodeSafe -Process $w.Process
    }
    else {
        try {
            $w.Process.WaitForExit()
            $exitCode = [int]$w.Process.ExitCode
        }
        catch {
            $exitCode = -1
        }
    }

    $durationSec = 0
    if ($null -ne $w.StartedAt) {
        $durationSec = [math]::Round(((Get-Date) - [datetime]$w.StartedAt).TotalSeconds, 1)
    }

    $result = @{
        Name        = $Name
        ExitCode    = $exitCode
        DurationSec = $durationSec
        StdErrPath  = $w.StdErrPath
        StdOutPath  = $w.StdOutPath
        OutputPaths = @($w.OutputPaths)
    }

    $table = Get-HubWorkersTable
    if ($table.ContainsKey($Name)) {
        $table.Remove($Name)
    }

    return $result
}

function Test-AnyHubAsyncWorkerRunning {
    $table = Get-HubWorkersTable
    if ($table.Count -eq 0) {
        return $false
    }

    foreach ($key in @($table.Keys)) {
        if (Test-HubAsyncWorkerRunning -Name $key) {
            return $true
        }
    }
    return $false
}
