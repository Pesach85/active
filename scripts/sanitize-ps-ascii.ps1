# One-off sanitizer: UTF-8 smart punctuation -> ASCII for Windows PowerShell 5.1 parser.
param([string]$Root = (Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts\lib'))

$utf8bom = New-Object System.Text.UTF8Encoding $true
Get-ChildItem -Path $Root -Filter '*.ps1' -File | ForEach-Object {
    $c = [System.IO.File]::ReadAllText($_.FullName)
    $c = $c.Replace([char]0x2014, '-')
    $c = $c -replace [char]0x2192, '->'
    $c = $c -replace [char]0x2026, '...'
    [System.IO.File]::WriteAllText($_.FullName, $c, $utf8bom)
    Write-Host ("Sanitized: {0}" -f $_.Name)
}
