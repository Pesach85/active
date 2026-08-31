using SystemOptimizerHub.Core.Models;

namespace SystemOptimizerHub.Core.Transparency;

/// <summary>Port of transparency-policy.ps1 trust + delegation contract.</summary>
public static class TransparencyPolicy
{
    public const string PolicyVersion = "TransparencyPolicy.v1";

    private static readonly HubAgentInfo[] AgentRegistry =
    [
        new("resource-monitor", "Resource Monitor", "monitor-resources.ps1", "T1_Delegated"),
        new("hub-orchestrator", "Hub Orchestrator", "hub-orchestrator.ps1", "T1_Delegated"),
        new("storage-cleanup", "Storage Cleanup Safe", "cleanup-storage-safe.ps1", "T1_Delegated"),
        new("gui-worker", "GUI Async Worker", "system-optimizer-gui.ps1", "T0_Observed"),
        new("ollama-advisory", "Ollama LLM Advisory", "llm-advise.ps1", "T2_Review")
    ];

    private static readonly HashSet<string> TrustedProcessNames = new(StringComparer.OrdinalIgnoreCase)
    {
        "Idle", "System", "Registry", "Memory Compression", "Secure System",
        "svchost", "csrss", "wininit", "winlogon", "services", "lsass", "dwm",
        "explorer", "ShellExperienceHost", "SearchHost", "RuntimeBroker",
        "SystemOptimizer", "WindowsOptimizer", "pwsh", "powershell", "Cursor",
        "Code", "MsMpEng", "NisSrv", "SecurityHealthService", "audiodg",
        "fontdrvhost", "conhost", "dllhost", "sihost", "taskhostw", "WmiPrvSE",
        "spoolsv", "ctfmon", "smartscreen", "ApplicationFrameHost"
    };

    public static IReadOnlyList<HubAgentInfo> GetAgentRegistry() => AgentRegistry;

    public static string GetControlLevelLabel(string level) => level switch
    {
        "T0_Observed" => "Human observed",
        "T1_Delegated" => "AI delegated (whitelisted)",
        "T2_Review" => "Review required",
        _ => "Unknown - investigate"
    };

    public static TrustResolution ResolveProcessTrustLevel(
        string processName,
        string imagePath,
        IReadOnlyList<string> catalogNames,
        IReadOnlySet<string> runningHubScriptNames)
    {
        foreach (var entry in AgentRegistry)
        {
            if (!string.IsNullOrEmpty(imagePath) &&
                imagePath.Contains(entry.Script, StringComparison.OrdinalIgnoreCase))
            {
                return new TrustResolution(entry.ControlLevel, $"Hub script: {entry.DisplayName}", entry.Id);
            }
        }

        if (catalogNames.Contains(processName, StringComparer.OrdinalIgnoreCase))
            return new TrustResolution("T1_Delegated", "Process intelligence catalog", "ppi-catalog");

        if (TrustedProcessNames.Contains(processName))
            return new TrustResolution("T0_Observed", "Trusted OS / operator toolchain", "trusted-os");

        if (runningHubScriptNames.Contains(processName))
            return new TrustResolution("T1_Delegated", "Active hub subprocess", "hub-subprocess");

        return new TrustResolution("T3_Unknown", "Not in hub registry or trust list", string.Empty);
    }

    public static object BuildDelegationManifest(bool continuousOptimizationEnabled, bool autoApplySafeActions, bool llmEnabled)
    {
        var humanOnly = new List<string>
        {
            "Defender disable / KEEP services",
            "Moderate+ health fixes, wbadmin, registry writes",
            "Process termination outside monitor policy",
            "Enabling LLM advisory or cloud egress"
        };
        var aiDelegated = new List<string>();

        if (continuousOptimizationEnabled)
            aiDelegated.Add("Orchestrator: context build, optional PPI audit");

        if (autoApplySafeActions)
            aiDelegated.Add("PPI: Safe throttle auto-apply");
        else
            humanOnly.Add("PPI Safe throttle (AutoApplySafeActions=false)");

        if (llmEnabled)
            aiDelegated.Add("LLM: read-only advisory JSON (no direct OS writes)");
        else
            humanOnly.Add("LLM advisory (disabled)");

        return new
        {
            PolicyVersion,
            Principles = new[]
            {
                "No OS mutation without whitelisted script + audit trail",
                "Human operator can pause or disable any delegated agent",
                "Unknown high-RAM processes flagged T3 until classified",
                "LLM advisory never auto-applies; actionId whitelist only",
                "All automated writes require rollback JSON when applicable"
            },
            HumanOnly = humanOnly,
            AiDelegatedWhenEnabled = aiDelegated
        };
    }
}

public sealed record HubAgentInfo(string Id, string DisplayName, string Script, string ControlLevel);

public sealed record TrustResolution(string Level, string Reason, string AgentId);
