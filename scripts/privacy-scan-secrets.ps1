<#
.SYNOPSIS
    Privacy Scanner — finds likely plaintext credentials and secrets (read-only).

.DESCRIPTION
    Audit-first scan of configured paths. Never writes to scanned files.
    Output JSON uses redacted previews only — no plaintext secrets in reports.

.PARAMETER OutputJson
    Path for PrivacyScanReport v1 JSON output.

.PARAMETER ConfigPath
    Optional path to sys-maintenance.json (reads Privacy block) or standalone overrides.

.PARAMETER ScanPaths
    Optional override of directories to scan.

.PARAMETER MaxFileSizeKb
    Skip files larger than this (default from config or 512).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$OutputJson,
    [string]$ConfigPath,
    [string[]]$ScanPaths,
    [int]$MaxFileSizeKb = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

. (Join-Path $PSScriptRoot 'hub-common.ps1')

$hubRoot = Get-HubRoot -ScriptRoot $PSScriptRoot
$paths = Get-HubPaths -HubRoot $hubRoot

if (-not $ConfigPath) {
    $ConfigPath = $paths.ConfigFile
}

$config = @{}
if (Test-Path -LiteralPath $ConfigPath) {
    $config = Get-MaintenanceConfig -ConfigPath $ConfigPath
}

$privacyCfg = @{}
if ($config.Privacy) {
    $privacyCfg = $config.Privacy
}

if ($MaxFileSizeKb -le 0) {
    $cfgMax = $privacyCfg.MaxFileSizeKb
    $MaxFileSizeKb = if ($null -ne $cfgMax -and [int]$cfgMax -gt 0) { [int]$cfgMax } else { 512 }
}

$defaultScanPaths = @(
    $env:USERPROFILE,
    (Join-Path $hubRoot 'config'),
    (Join-Path $hubRoot 'scripts')
)
if ($privacyCfg.ScanPaths) {
    $defaultScanPaths = @($privacyCfg.ScanPaths | ForEach-Object {
        $p = [string]$_
        if ($p -match '%([^%]+)%') {
            $p = [regex]::Replace($p, '%([^%]+)%', {
                param($m)
                $val = [Environment]::GetEnvironmentVariable($m.Groups[1].Value)
                if ($null -eq $val) { $m.Value } else { $val }
            })
        }
        Resolve-HubPath -HubRoot $hubRoot -Path $p
    })
}
if ($ScanPaths -and $ScanPaths.Count -gt 0) {
    $defaultScanPaths = @($ScanPaths)
}

$excludeDirNames = @(
    '.git', 'node_modules', 'vendor', 'dist', 'build', '__pycache__',
    'ddwrtkey', '.venv', 'venv', 'packages', 'Program Files', 'Program Files (x86)',
    'Windows', '$Recycle.Bin', 'System Volume Information'
)
if ($privacyCfg.ExcludeDirNames) {
    $excludeDirNames = @($privacyCfg.ExcludeDirNames)
}

$extensions = @(
    '.env', '.ini', '.cfg', '.conf', '.config', '.json', '.xml', '.yaml', '.yml',
    '.ps1', '.psm1', '.bat', '.cmd', '.sh', '.sql', '.php', '.txt', '.md', '.csv',
    '.properties', '.toml', '.log'
)
if ($privacyCfg.Extensions) {
    $extensions = @($privacyCfg.Extensions)
}

$patterns = @(
    @{
        Id       = 'PWD_ASSIGN'
        Category = 'Password'
        Severity = 'Critical'
        Regex    = '(?i)(?:password|passwd|pwd|passphrase)\s*[=:]\s*[''"]?([^\s''";#]{4,})'
        Label    = 'Password assignment in config/script'
    },
    @{
        Id       = 'CONN_STRING'
        Category = 'ConnectionString'
        Severity = 'Critical'
        Regex    = '(?i)(?:Password|PWD)\s*=\s*[^;''"\s]{3,}'
        Label    = 'Connection string with password'
    },
    @{
        Id       = 'API_KEY'
        Category = 'ApiKey'
        Severity = 'Important'
        Regex    = '(?i)(?:api[_-]?key|secret[_-]?key|client[_-]?secret|access[_-]?token)\s*[=:]\s*[''"]?([A-Za-z0-9_\-\.]{8,})'
        Label    = 'API or secret key assignment'
    },
    @{
        Id       = 'AWS_KEY'
        Category = 'CloudCredential'
        Severity = 'Critical'
        Regex    = '(AKIA[0-9A-Z]{16})'
        Label    = 'AWS access key id pattern'
    },
    @{
        Id       = 'GITHUB_TOKEN'
        Category = 'CloudCredential'
        Severity = 'Critical'
        Regex    = '(ghp_[A-Za-z0-9]{20,})'
        Label    = 'GitHub personal access token pattern'
    },
    @{
        Id       = 'BASIC_AUTH_URL'
        Category = 'Password'
        Severity = 'Important'
        Regex    = 'https?://[^\s/:]+:[^\s/@]+@'
        Label    = 'Credentials embedded in URL'
    },
    @{
        Id       = 'PRIVATE_KEY'
        Category = 'PrivateKey'
        Severity = 'Critical'
        Regex    = '-----BEGIN (?:RSA |OPENSSH |EC )?PRIVATE KEY-----'
        Label    = 'Private key material in file'
    },
    @{
        Id       = 'WP_CONFIG'
        Category = 'Password'
        Severity = 'Critical'
        Regex    = "define\s*\(\s*'DB_PASSWORD'\s*,\s*'[^']+'"
        Label    = 'WordPress DB password in wp-config style'
    }
)

function Write-ScanProgress {
    param([string]$Msg)
    Write-Host "[PRIVACY] $Msg"
}

function Test-ExcludedPath {
    param([string]$FullPath)

    foreach ($part in $excludeDirNames) {
        if ($FullPath -match [regex]::Escape($part)) {
            return $true
        }
    }
    return $false
}

function Get-RedactedPreview {
    param(
        [string]$Value,
        [int]$MaxLen = 12
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return '****'
    }

    $len = $Value.Length
    if ($len -le 4) {
        return ('*' * $len)
    }

    $show = [Math]::Min(2, [Math]::Floor($len / 4))
    $prefix = $Value.Substring(0, $show)
    $suffix = $Value.Substring($len - $show, $show)
    return ("{0}{1}{2} (len={3})" -f $prefix, ('*' * [Math]::Min(6, $len - ($show * 2))), $suffix, $len)
}

function New-Finding {
    param(
        [string]$Id,
        [string]$PatternId,
        [string]$Severity,
        [string]$Category,
        [string]$Title,
        [string]$FilePath,
        [int]$LineNumber,
        [string]$RedactedPreview,
        [string]$Recommendation
    )

    return [ordered]@{
        Id               = $Id
        PatternId        = $PatternId
        Severity         = $Severity
        Category         = $Category
        Title            = $Title
        FilePath         = $FilePath
        LineNumber       = $LineNumber
        RedactedPreview  = $RedactedPreview
        Recommendation   = $Recommendation
        VaultEligible    = $true
    }
}

Write-ScanProgress "Starting privacy scan (read-only)..."

$findings = [System.Collections.Generic.List[object]]::new()
$filesScanned = 0
$filesSkipped = 0
$findingSeq = 0
$maxFindings = 500
if ($privacyCfg.MaxFindings) {
    $maxFindings = [int]$privacyCfg.MaxFindings
}

foreach ($root in $defaultScanPaths) {
    if (-not (Test-Path -LiteralPath $root)) {
        Write-ScanProgress "Skip missing path: $root"
        continue
    }

    Write-ScanProgress "Scanning root: $root"

    Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
        if ($findings.Count -ge $maxFindings) { return }

        $file = $_
        if (Test-ExcludedPath -FullPath $file.FullName) {
            $script:filesSkipped++
            return
        }

        $ext = $file.Extension.ToLowerInvariant()
        if ($extensions -notcontains $ext -and $ext -ne '') {
            $script:filesSkipped++
            return
        }

        if ($file.Length -gt ($MaxFileSizeKb * 1024)) {
            $script:filesSkipped++
            return
        }

        # Skip likely binary
        if ($file.Extension -match '\.(exe|dll|zip|7z|png|jpg|jpeg|gif|pdf|msi|iso)$') {
            $script:filesSkipped++
            return
        }

        if ($file.Name -eq 'privacy-scan-secrets.ps1') {
            $script:filesSkipped++
            return
        }

        $script:filesScanned++

        try {
            $rawLines = Get-Content -LiteralPath $file.FullName -ErrorAction Stop
            $lines = @($rawLines)
        } catch {
            $script:filesSkipped++
            return
        }

        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($findings.Count -ge $maxFindings) { break }

            $line = [string]$lines[$i]
            if ([string]::IsNullOrWhiteSpace($line)) { continue }

            # Skip obvious placeholders
            if ($line -match '(?i)(changeme|your_password|xxx+|placeholder|example\.com|<password>|TODO)') {
                continue
            }

            foreach ($pat in $patterns) {
                if ($line -notmatch $pat.Regex) { continue }

                $findingSeq++
                $capture = $null
                if ($Matches.Count -gt 1) { $capture = $Matches[1] }
                $redacted = Get-RedactedPreview -Value ($(if ($capture) { $capture } else { '****' }))

                $findings.Add((New-Finding `
                    -Id ("PRIV-{0:D4}" -f $findingSeq) `
                    -PatternId $pat.Id `
                    -Severity $pat.Severity `
                    -Category $pat.Category `
                    -Title $pat.Label `
                    -FilePath $file.FullName `
                    -LineNumber ($i + 1) `
                    -RedactedPreview $redacted `
                    -Recommendation 'Review and migrate to Secret Vault (Phase 2). Remove or redact plaintext from source file after backup.'))

                break
            }
        }
    }
}

$severityRank = @{ Critical = 0; Important = 1; Moderate = 2; Info = 3 }
$sorted = @($findings | Sort-Object { $severityRank[$_.Severity] }, FilePath, LineNumber)

$summary = [ordered]@{
    TotalFindings   = $sorted.Count
    Critical        = @($sorted | Where-Object { $_.Severity -eq 'Critical' }).Count
    Important       = @($sorted | Where-Object { $_.Severity -eq 'Important' }).Count
    FilesScanned    = $filesScanned
    FilesSkipped    = $filesSkipped
    ScanRoots       = @($defaultScanPaths)
    ReadOnly        = $true
}

$report = [ordered]@{
    SchemaVersion = 'PrivacyScanReport.v1'
    GeneratedAt   = (Get-Date).ToString('o')
    HubRoot       = $hubRoot
    Summary       = $summary
    Findings      = $sorted
}

$outDir = Split-Path -Parent $OutputJson
if ($outDir -and -not (Test-Path -LiteralPath $outDir)) {
    New-Item -Path $outDir -ItemType Directory -Force | Out-Null
}

$json = $report | ConvertTo-Json -Depth 8
[System.IO.File]::WriteAllText($OutputJson, $json, [System.Text.UTF8Encoding]::new($false))

Write-ScanProgress ("Done. Findings={0} Critical={1} Files={2} -> {3}" -f `
    $summary.TotalFindings, $summary.Critical, $summary.FilesScanned, $OutputJson)
