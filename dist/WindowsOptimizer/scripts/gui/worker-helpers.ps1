# Shared GUI worker I/O helpers (dot-source from system-optimizer-gui.ps1).
# Keeps Start-Process/poll handshake deterministic across all async workers.

function ConvertTo-StartProcessArgumentList {
    <#
    .SYNOPSIS
      Quote argv for Start-Process. Native Start-Process joins string[] with spaces
      WITHOUT quoting, so paths like C:\Users\Pasquale Lombardi\... break -File.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$Arguments
    )

    $quoted = foreach ($raw in @($Arguments)) {
        $a = [string]$raw
        if ($a.Length -eq 0) {
            '""'
            continue
        }
        if ($a -match '[\s"]') {
            '"' + ($a.Replace('"', '\"')) + '"'
        } else {
            $a
        }
    }
    # Return as single command-line string (Start-Process preserves embedded quotes).
    return [string]($quoted -join ' ')
}

function Start-HubPowerShellProcess {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [Parameter(Mandatory = $true)]
        [string[]]$ArgumentList,

        [string]$RedirectStandardOutput = '',
        [string]$RedirectStandardError = '',
        [switch]$PassThru,
        [switch]$Wait,
        [ValidateSet('Normal', 'Hidden', 'Minimized', 'Maximized')]
        [string]$WindowStyle = 'Hidden'
    )

    $argLine = ConvertTo-StartProcessArgumentList -Arguments $ArgumentList
    $startParams = @{
        FilePath     = $FilePath
        ArgumentList = $argLine
        WindowStyle  = $WindowStyle
    }
    if ($PassThru) { $startParams['PassThru'] = $true }
    if ($Wait) { $startParams['Wait'] = $true }
    if (-not [string]::IsNullOrWhiteSpace($RedirectStandardOutput)) {
        $startParams['RedirectStandardOutput'] = $RedirectStandardOutput
    }
    if (-not [string]::IsNullOrWhiteSpace($RedirectStandardError)) {
        $startParams['RedirectStandardError'] = $RedirectStandardError
    }
    return Start-Process @startParams
}

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
