param(
    [Parameter(Mandatory = $true)]
    [string]$Objective,

    [Parameter(Mandatory = $true)]
    [string]$Task,

    [Parameter(Mandatory = $true)]
    [string[]]$Changes,

    [Parameter(Mandatory = $true)]
    [string[]]$Decisions,

    [string]$Outcome = "Completato",
    [string]$KbRoot = "C:\\KB"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $KbRoot)) {
    New-Item -Path $KbRoot -ItemType Directory -Force | Out-Null
}

$journalPath = Join-Path -Path $KbRoot -ChildPath "journal.md"
if (-not (Test-Path -LiteralPath $journalPath)) {
    "# Journal Decisionale`n" | Out-File -LiteralPath $journalPath -Encoding utf8
}

$timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")

$entry = New-Object System.Collections.Generic.List[string]
$entry.Add("")
$entry.Add("## $timestamp")
$entry.Add("### Obiettivo")
$entry.Add($Objective)
$entry.Add("")
$entry.Add("### Task")
$entry.Add($Task)
$entry.Add("")
$entry.Add("### Modifiche")
foreach ($item in $Changes) {
    $entry.Add("- $item")
}
$entry.Add("")
$entry.Add("### Decisioni")
foreach ($item in $Decisions) {
    $entry.Add("- $item")
}
$entry.Add("")
$entry.Add("### Esito")
$entry.Add($Outcome)

$entry -join "`n" | Out-File -LiteralPath $journalPath -Encoding utf8 -Append
Write-Host "KB aggiornata: $journalPath"
