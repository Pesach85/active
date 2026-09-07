# PS 5.1 parser gate for GUI modules (EXE dot-sources these under Windows PowerShell).
param([string]$GuiDir = '')

$ErrorActionPreference = 'Stop'
if (-not $GuiDir) {
    $GuiDir = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'gui'
}

$failures = [System.Collections.Generic.List[string]]::new()
Get-ChildItem -LiteralPath $GuiDir -Filter '*.ps1' -File | ForEach-Object {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tokens, [ref]$errors)
    if ($errors -and @($errors).Count -gt 0) {
        foreach ($e in @($errors)) {
            [void]$failures.Add(("{0}: {1}" -f $_.Name, $e.Message))
        }
    }
}

if ($failures.Count -gt 0) {
    Write-Host '[GUI-PARSE] FAILED'
    foreach ($f in $failures) { Write-Host "  - $f" }
    exit 1
}

Write-Host '[GUI-PARSE] ALL OK'
exit 0
