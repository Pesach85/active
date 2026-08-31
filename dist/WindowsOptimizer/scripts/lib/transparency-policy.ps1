# Shared transparency & control contract (human operator + AI delegation).
# Dot-source from build-transparency-report.ps1, GUI panel, orchestrator.

$script:TransparencyPolicyVersion = 'TransparencyPolicy.v1'

function Get-HubAgentRegistry {
    return @(
        @{
            Id = 'resource-monitor'
            DisplayName = 'Resource Monitor'
            TaskName = 'SystemResourceMonitor'
            Script = 'monitor-resources.ps1'
            ControlLevel = 'T1_Delegated'
            Owner = 'Hub'
            WritesSystem = $true
            AllowedActions = @('ThrottlePriority', 'DiskWarningLog')
            RequiresAudit = $true
        },
        @{
            Id = 'hub-orchestrator'
            DisplayName = 'Hub Orchestrator'
            TaskName = 'SystemOptimizerHub-Orchestrator'
            Script = 'hub-orchestrator.ps1'
            ControlLevel = 'T1_Delegated'
            Owner = 'Hub'
            WritesSystem = $false
            AllowedActions = @('LogRotation', 'FsIntegrityScan', 'WheaMonitor', 'BuildContext', 'ProcessPressureAudit')
            RequiresAudit = $true
        },
        @{
            Id = 'storage-cleanup'
            DisplayName = 'Storage Cleanup Safe'
            TaskName = 'StorageCleanupSafe'
            Script = 'cleanup-storage-safe.ps1'
            ControlLevel = 'T1_Delegated'
            Owner = 'Hub'
            WritesSystem = $true
            AllowedActions = @('DeleteTempFiles')
            RequiresAudit = $true
        },
        @{
            Id = 'gui-worker'
            DisplayName = 'GUI Async Worker'
            TaskName = ''
            Script = 'system-optimizer-gui.ps1'
            ControlLevel = 'T0_Observed'
            Owner = 'Human'
            WritesSystem = $true
            AllowedActions = @('UserSelectedCommand')
            RequiresAudit = $true
        },
        @{
            Id = 'ollama-advisory'
            DisplayName = 'Ollama LLM Advisory'
            TaskName = ''
            Script = 'llm-advise.ps1'
            ControlLevel = 'T2_Review'
            Owner = 'HumanOptIn'
            WritesSystem = $false
            AllowedActions = @('AdvisoryJsonOnly')
            RequiresAudit = $true
        }
    )
}

function Get-TrustedProcessNames {
    param([string[]]$Extra = @())

    $base = @(
        'Idle', 'System', 'Registry', 'Memory Compression', 'Secure System',
        'svchost', 'csrss', 'wininit', 'winlogon', 'services', 'lsass', 'dwm',
        'explorer', 'ShellExperienceHost', 'SearchHost', 'RuntimeBroker',
        'SystemOptimizer', 'WindowsOptimizer', 'pwsh', 'powershell', 'Cursor',
        'Code', 'MsMpEng', 'NisSrv', 'SecurityHealthService', 'audiodg',
        'fontdrvhost', 'conhost', 'dllhost', 'sihost', 'taskhostw', 'WmiPrvSE',
        'spoolsv', 'ctfmon', 'smartscreen', 'ApplicationFrameHost'
    )
    return @($base + $Extra | Select-Object -Unique)
}

function Get-ControlLevelLabel {
    param([ValidateSet('T0_Observed', 'T1_Delegated', 'T2_Review', 'T3_Unknown')][string]$Level)

    switch ($Level) {
        'T0_Observed' { return 'Human observed' }
        'T1_Delegated' { return 'AI delegated (whitelisted)' }
        'T2_Review' { return 'Review required' }
        default { return 'Unknown — investigate' }
    }
}

function Resolve-ProcessTrustLevel {
    param(
        $Process,
        [string[]]$CatalogNames = @(),
        [hashtable]$RunningHubScripts = @{}
    )

    $name = [string]$Process.ProcessName
    $path = ''
    try { $path = [string]$Process.Path } catch { }

    foreach ($entry in (Get-HubAgentRegistry)) {
        if ($path -and $path -match [regex]::Escape($entry.Script)) {
            return @{ Level = $entry.ControlLevel; Reason = "Hub script: $($entry.DisplayName)"; AgentId = $entry.Id }
        }
    }

    if ($CatalogNames -contains $name) {
        return @{ Level = 'T1_Delegated'; Reason = 'Process intelligence catalog'; AgentId = 'ppi-catalog' }
    }

    if ($name -in (Get-TrustedProcessNames)) {
        return @{ Level = 'T0_Observed'; Reason = 'Trusted OS / operator toolchain'; AgentId = 'trusted-os' }
    }

    if ($RunningHubScripts.ContainsKey($name)) {
        return @{ Level = 'T1_Delegated'; Reason = 'Active hub subprocess'; AgentId = 'hub-subprocess' }
    }

    return @{ Level = 'T3_Unknown'; Reason = 'Not in hub registry or trust list'; AgentId = '' }
}

function Get-DelegationManifest {
    param($Config)

    $humanOnly = [System.Collections.ArrayList]@(
        'Defender disable / KEEP services',
        'Moderate+ health fixes, wbadmin, registry writes',
        'Process termination outside monitor policy',
        'Enabling LLM advisory or cloud egress'
    )
    $aiDelegated = [System.Collections.ArrayList]@()

    $manifest = [ordered]@{
        PolicyVersion = $script:TransparencyPolicyVersion
        Principles = @(
            'No OS mutation without whitelisted script + audit trail',
            'Human operator can pause or disable any delegated agent',
            'Unknown high-RAM processes flagged T3 until classified',
            'LLM advisory never auto-applies; actionId whitelist only',
            'All automated writes require rollback JSON when applicable'
        )
        HumanOnly = @($humanOnly)
        AiDelegatedWhenEnabled = @($aiDelegated)
    }

    if (-not $Config) {
        $manifest.HumanOnly = @($humanOnly)
        $manifest.AiDelegatedWhenEnabled = @($aiDelegated)
        return $manifest
    }

    $co = $null
    if ($Config -is [hashtable]) { $co = $Config['ContinuousOptimization'] }
    elseif ($Config.ContinuousOptimization) { $co = $Config.ContinuousOptimization }

    $pp = $null
    if ($Config -is [hashtable]) { $pp = $Config['ProcessPressure'] }
    elseif ($Config.ProcessPressure) { $pp = $Config.ProcessPressure }

    $llm = $null
    if ($Config -is [hashtable]) { $llm = $Config['LlmAdvisory'] }
    elseif ($Config.LlmAdvisory) { $llm = $Config.LlmAdvisory }

    if ($co -and (($co -is [hashtable] -and $co['Enabled']) -or $co.Enabled)) {
        [void]$aiDelegated.Add('Orchestrator: context build, optional PPI audit')
    }

    $autoPpi = $false
    if ($pp) {
        $autoPpi = if ($pp -is [hashtable]) { [bool]$pp['AutoApplySafeActions'] } else { [bool]$pp.AutoApplySafeActions }
    }
    if ($autoPpi) {
        [void]$aiDelegated.Add('PPI: Safe throttle auto-apply')
    } else {
        [void]$humanOnly.Add('PPI Safe throttle (AutoApplySafeActions=false)')
    }

    $llmOn = $false
    if ($llm) {
        $llmOn = if ($llm -is [hashtable]) { [bool]$llm['Enabled'] } else { [bool]$llm.Enabled }
    }
    if ($llmOn) {
        [void]$aiDelegated.Add('LLM: read-only advisory JSON (no direct OS writes)')
    } else {
        [void]$humanOnly.Add('LLM advisory (disabled)')
    }

    $manifest.HumanOnly = @($humanOnly)
    $manifest.AiDelegatedWhenEnabled = @($aiDelegated)
    return $manifest
}
