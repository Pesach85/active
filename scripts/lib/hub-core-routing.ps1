# HUB_USE_CORE=1 routing to hub CLI (C#) for parity-verified read-only domains.

function Test-HubUseCore {
    $v = [string]$env:HUB_USE_CORE
    return ($v -eq '1' -or $v -eq 'true' -or $v -eq 'yes')
}

function Get-HubCliProjectPath {
    param([string]$HubRoot)
    return Join-Path $HubRoot 'src\SystemOptimizerHub.Cli\SystemOptimizerHub.Cli.csproj'
}

function Invoke-HubCoreCli {
    param(
        [string]$HubRoot,
        [Parameter(Mandatory = $true)][string[]]$CliArgs,
        [string]$OutFile = '',
        [switch]$BuildFirst
    )

    $cliProject = Get-HubCliProjectPath -HubRoot $HubRoot
    if (-not (Test-Path -LiteralPath $cliProject)) {
        throw "Hub CLI project not found: $cliProject"
    }

    if ($BuildFirst) {
        $b = Start-Process -FilePath 'dotnet' -ArgumentList @('build', $cliProject, '-v', 'q', '--nologo') `
            -Wait -PassThru -WindowStyle Hidden
        if ($b.ExitCode -ne 0) { return $b.ExitCode }
    }

    $errFile = Join-Path $HubRoot 'logs\hub-core-routing.err'
    $allArgs = @('run', '--project', $cliProject, '--no-build', '-v', 'q', '--') + $CliArgs
    if ($OutFile) {
        $p = Start-Process -FilePath 'dotnet' -ArgumentList $allArgs -Wait -PassThru -WindowStyle Hidden `
            -RedirectStandardOutput $OutFile -RedirectStandardError $errFile
        return $p.ExitCode
    }

    $p2 = Start-Process -FilePath 'dotnet' -ArgumentList $allArgs -Wait -PassThru -WindowStyle Hidden `
        -RedirectStandardError $errFile
    return $p2.ExitCode
}

function Invoke-HubCoreDefenderEvaluate {
    param(
        [string]$HubRoot,
        [string]$InputJson = '',
        [string]$OutputJson = '',
        [string]$CatalogPath = ''
    )

    if (-not (Test-HubUseCore)) { return $false }

    $args = @('defender', 'evaluate')
    if ($InputJson) { $args += @('--input', $InputJson) }
    if ($CatalogPath) { $args += @('--catalog', $CatalogPath) }

    $ec = Invoke-HubCoreCli -HubRoot $HubRoot -CliArgs $args -OutFile $OutputJson -BuildFirst
    if ($ec -ne 0) { return $false }
    return (Test-Path -LiteralPath $OutputJson)
}

function Invoke-HubCoreNetworkDeepScan {
    param(
        [string]$HubRoot,
        [string]$OutputJson = '',
        [string]$CatalogPath = '',
        [switch]$IncludeMemoryScan
    )

    if (-not (Test-HubUseCore)) { return $false }

    $args = @('network', 'deep-scan')
    if ($CatalogPath) { $args += @('--catalog', $CatalogPath) }
    if ($OutputJson) { $args += @('--output', $OutputJson) }
    if ($IncludeMemoryScan) { $args += '--include-memory' }

    $ec = Invoke-HubCoreCli -HubRoot $HubRoot -CliArgs $args -OutFile $OutputJson -BuildFirst
    if ($ec -ne 0) { return $false }
    return (Test-Path -LiteralPath $OutputJson)
}
