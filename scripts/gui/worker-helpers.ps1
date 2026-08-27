# Shared GUI worker I/O helpers (dot-source from system-optimizer-gui.ps1).
# Keeps Start-Process/poll handshake deterministic across all async workers.

function Wait-ForOutputFile {
    param(
        [string]$Path,
        [int]$TimeoutMs = 3000,
        [int]$PollMs = 150
    )

    $elapsed = 0
    while ($elapsed -lt $TimeoutMs) {
        if (Test-Path -LiteralPath $Path) {
            return $true
        }

        Start-Sleep -Milliseconds $PollMs
        $elapsed += $PollMs
    }

    return (Test-Path -LiteralPath $Path)
}

function Remove-IfExists {
    param([string]$Path)

    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    }
}

function Get-WorkerErrorTail {
    param([string]$ErrorPath)

    if (-not (Test-Path -LiteralPath $ErrorPath)) {
        return ""
    }

    $tail = (Get-Content -LiteralPath $ErrorPath -Tail 6 -ErrorAction SilentlyContinue) -join " | "
    return [string]$tail
}

function Get-ProcessExitCodeSafe {
    param([System.Diagnostics.Process]$Process)

    if ($null -eq $Process) {
        return -1
    }

    try {
        if (-not $Process.HasExited) { return -1 }
        $Process.WaitForExit()
        return [int]$Process.ExitCode
    } catch {
        return -1
    }
}
