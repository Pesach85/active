# Shared async worker registry for System Optimizer Hub GUI.
# Dot-sourced after worker-helpers.ps1. Pure PowerShell (5.1 + 7+); no WinForms.

if (-not $script:HubWorkers) {
    $script:HubWorkers = @{}
}

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

        $script:HubWorkers[$Name] = @{
            Process            = $proc
            StartedAt          = Get-Date
            TimeoutSec         = [math]::Max(1, [int]$TimeoutSec)
            SoftTimeoutWarned  = $false
            StdErrPath         = $StdErrPath
            StdOutPath         = $StdOutPath
            OutputPaths        = @($OutputPaths)
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

    if (-not $script:HubWorkers -or -not $script:HubWorkers.ContainsKey($Name)) {
        return $null
    }
    return $script:HubWorkers[$Name]
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
        $script:HubWorkers[$Name] = $w
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

    if ($script:HubWorkers -and $script:HubWorkers.ContainsKey($Name)) {
        $script:HubWorkers.Remove($Name)
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

    if ($script:HubWorkers.ContainsKey($Name)) {
        $script:HubWorkers.Remove($Name)
    }

    return $result
}

function Test-AnyHubAsyncWorkerRunning {
    if (-not $script:HubWorkers -or $script:HubWorkers.Count -eq 0) {
        return $false
    }

    foreach ($key in @($script:HubWorkers.Keys)) {
        if (Test-HubAsyncWorkerRunning -Name $key) {
            return $true
        }
    }
    return $false
}
