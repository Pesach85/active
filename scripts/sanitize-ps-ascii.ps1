# Sanitize PowerShell scripts: smart punctuation -> ASCII for Windows PowerShell 5.1 parser (EXE/GUI).
[CmdletBinding()]
param(
    [string[]]$Paths = @(),
    [switch]$Recurse
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $Paths -or @($Paths).Count -eq 0) {
    $Paths = @(
        (Join-Path $scriptDir 'gui'),
        (Join-Path $scriptDir 'lib')
    )
}

$utf8bom = New-Object System.Text.UTF8Encoding $true
$files = [System.Collections.Generic.List[string]]::new()

foreach ($root in @($Paths)) {
    if (-not (Test-Path -LiteralPath $root)) { continue }
    if ((Get-Item -LiteralPath $root).PSIsContainer) {
        $glob = if ($Recurse) {
            Get-ChildItem -LiteralPath $root -Filter '*.ps1' -File -Recurse
        } else {
            Get-ChildItem -LiteralPath $root -Filter '*.ps1' -File
        }
        foreach ($f in $glob) { [void]$files.Add($f.FullName) }
    } elseif ($root -like '*.ps1') {
        [void]$files.Add((Resolve-Path -LiteralPath $root).Path)
    }
}

function Convert-SmartPunctuationToAscii {
    param([string]$Text)
    $t = $Text
    $t = $t.Replace([char]0x2014, '-')
    $t = $t.Replace([char]0x2013, '-')
    $t = $t -replace [char]0x2026, '...'
    $t = $t.Replace([char]0x2022, '*')
    $t = $t -replace [char]0x2192, '->'
    $t = $t.Replace([char]0x26A0, '!')
    $t = $t -replace [char]0xFE0F, ''
    return $t
}

$sanitized = 0
foreach ($path in ($files | Sort-Object -Unique)) {
    $raw = [System.IO.File]::ReadAllText($path)
    $clean = Convert-SmartPunctuationToAscii -Text $raw
    if ($clean -cne $raw) {
        [System.IO.File]::WriteAllText($path, $clean, $utf8bom)
        Write-Host ("Sanitized: {0}" -f (Split-Path -Leaf $path))
        $sanitized++
    }
}

Write-Host ("Done. {0} file(s) sanitized." -f $sanitized)
