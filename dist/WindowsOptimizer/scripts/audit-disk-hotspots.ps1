[CmdletBinding()]
param(
    [string[]]$Drives = @("C", "D"),
    [int]$Top = 20,
    [string]$OutputCsv = "C:\\logs\\disk-hotspots.csv",
    [switch]$IncludeFiles
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$logDir = Split-Path -Path $OutputCsv -Parent
if (-not (Test-Path -LiteralPath $logDir)) {
    New-Item -Path $logDir -ItemType Directory -Force | Out-Null
}

$rows = New-Object System.Collections.Generic.List[object]

foreach ($drive in $Drives) {
    $root = "{0}:\\" -f $drive
    if (-not (Test-Path -LiteralPath $root)) {
        continue
    }

    Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object {
        $folder = $_
        $sizeBytes = 0L
        $itemCount = 0
        Get-ChildItem -LiteralPath $folder.FullName -Recurse -File -Force -ErrorAction SilentlyContinue | ForEach-Object {
            $sizeBytes += [int64]$_.Length
            $itemCount++
        }

        $rows.Add([PSCustomObject]@{
            Drive = $drive
            Type = "Directory"
            Path = $folder.FullName
            SizeGB = [math]::Round($sizeBytes / 1GB, 3)
            Items = $itemCount
        })
    }

    if ($IncludeFiles) {
        Get-ChildItem -LiteralPath $root -File -Force -ErrorAction SilentlyContinue | ForEach-Object {
            $rows.Add([PSCustomObject]@{
                Drive = $drive
                Type = "File"
                Path = $_.FullName
                SizeGB = [math]::Round($_.Length / 1GB, 3)
                Items = 1
            })
        }
    }
}

$result = $rows | Sort-Object SizeGB -Descending | Select-Object -First $Top
$result | Export-Csv -LiteralPath $OutputCsv -NoTypeInformation -Encoding UTF8
$result
