[CmdletBinding()]
param(
    [ValidateSet('EnableUsbCapture','DisableUsbCapture','Status')]
    [string]$Mode = 'Status',

    [string]$OutputJson = 'logs/usbpcap-toggle-live.json'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$target = Join-Path -Path $PSScriptRoot -ChildPath 'scripts\set-usbpcap-capture-mode.ps1'
if (-not (Test-Path -LiteralPath $target)) {
    throw "Target script not found: $target"
}

& $target -Mode $Mode -OutputJson $OutputJson