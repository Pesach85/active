$body = @{ processId = 8480; processName = 'vmware-vmx'; offline = $true } | ConvertTo-Json
try {
    $r = Invoke-WebRequest -Uri 'http://127.0.0.1:8765/api/process/advisory' -Method POST -Body $body -ContentType 'application/json' -UseBasicParsing
    Write-Host "Status: $($r.StatusCode)"
    Write-Host $r.Content.Substring(0, [Math]::Min(600, $r.Content.Length))
} catch {
    Write-Host "Error: $($_.Exception.Message)"
    if ($_.ErrorDetails.Message) { Write-Host $_.ErrorDetails.Message }
}
