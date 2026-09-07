using System.Text.Json.Serialization;

namespace SystemOptimizerHub.Core.Models;

public sealed class ProcessResolutionResult
{
    [JsonPropertyName("SchemaVersion")]
    public string SchemaVersion { get; init; } = "ProcessResolutionResult.v1";

    [JsonPropertyName("GeneratedAt")]
    public string GeneratedAt { get; init; } = string.Empty;

    [JsonPropertyName("Action")]
    public string Action { get; init; } = string.Empty;

    [JsonPropertyName("DryRun")]
    public bool DryRun { get; init; }

    [JsonPropertyName("Outcome")]
    public string Outcome { get; init; } = string.Empty;

    [JsonPropertyName("Message")]
    public string Message { get; init; } = string.Empty;

    [JsonPropertyName("Process")]
    public ProcessSnapshotInput? Process { get; init; }

    [JsonPropertyName("Advisory")]
    public ProcessResolutionAdvisory? Advisory { get; init; }

    [JsonPropertyName("CatalogNecessity")]
    public ProcessNecessity? CatalogNecessity { get; init; }

    [JsonPropertyName("RollbackPath")]
    public string? RollbackPath { get; init; }
}

public sealed class DefenderPressureInput
{
    [JsonPropertyName("Score")]
    public double Score { get; init; }

    [JsonPropertyName("CpuPercent")]
    public double CpuPercent { get; init; }

    [JsonPropertyName("IoMBps")]
    public double IoMbPerSec { get; init; }

    [JsonPropertyName("WorkingSetMB")]
    public double WorkingSetMb { get; init; }

    [JsonPropertyName("DominantPressure")]
    public string DominantPressure { get; init; } = "Mixed";

    [JsonPropertyName("PID")]
    public int Pid { get; init; }

    [JsonPropertyName("ProcessName")]
    public string ProcessName { get; init; } = "MsMpEng";
}

public sealed class DefenderPlatformStatus
{
    [JsonPropertyName("ModuleAvailable")]
    public bool ModuleAvailable { get; init; }

    [JsonPropertyName("RealTimeProtectionEnabled")]
    public bool? RealTimeProtectionEnabled { get; init; }

    [JsonPropertyName("TamperProtectionEnabled")]
    public bool? TamperProtectionEnabled { get; init; }

    [JsonPropertyName("AMServiceEnabled")]
    public bool? AmServiceEnabled { get; init; }

    [JsonPropertyName("AntivirusEnabled")]
    public bool? AntivirusEnabled { get; init; }

    [JsonPropertyName("QuickScanAgeHours")]
    public double? QuickScanAgeHours { get; init; }

    [JsonPropertyName("FullScanAgeHours")]
    public double? FullScanAgeHours { get; init; }
}

public sealed class DefenderExtremeNecessityEvaluation
{
    [JsonPropertyName("SchemaVersion")]
    public string SchemaVersion { get; init; } = "DefenderExtremeNecessityEvaluation.v1";

    [JsonPropertyName("GeneratedAt")]
    public string GeneratedAt { get; init; } = string.Empty;

    [JsonPropertyName("CompositeScore")]
    public double CompositeScore { get; init; }

    [JsonPropertyName("RecommendedTier")]
    public string RecommendedTier { get; init; } = "Observe";

    [JsonPropertyName("AllowedToProceed")]
    public bool AllowedToProceed { get; init; }

    [JsonPropertyName("NeverAutoApply")]
    public bool NeverAutoApply { get; init; } = true;

    [JsonPropertyName("Rationale")]
    public string Rationale { get; init; } = string.Empty;

    [JsonPropertyName("MsMpEngMetrics")]
    public object? MsMpEngMetrics { get; init; }

    [JsonPropertyName("DefenderStatus")]
    public DefenderPlatformStatus DefenderStatus { get; init; } = new();

    [JsonPropertyName("Blockers")]
    public IReadOnlyList<string> Blockers { get; init; } = [];

    [JsonPropertyName("Prerequisites")]
    public IReadOnlyList<string> Prerequisites { get; init; } = [];

    [JsonPropertyName("EscalationLadder")]
    public IReadOnlyList<string> EscalationLadder { get; init; } = [];

    [JsonPropertyName("ReasonCodes")]
    public object ReasonCodes { get; init; } = new { };
}

public sealed class ExtremeNecessityDefenderConfig
{
    [JsonPropertyName("neverAutoApply")]
    public bool NeverAutoApply { get; set; } = true;

    [JsonPropertyName("tiers")]
    public Dictionary<string, ExtremeNecessityTierConfig> Tiers { get; set; } = new(StringComparer.OrdinalIgnoreCase);

    [JsonPropertyName("weights")]
    public Dictionary<string, double> Weights { get; set; } = new(StringComparer.OrdinalIgnoreCase);

    [JsonPropertyName("reasonCodes")]
    public Dictionary<string, string> ReasonCodes { get; set; } = new(StringComparer.OrdinalIgnoreCase);
}

public sealed class ExtremeNecessityTierConfig
{
    [JsonPropertyName("minCompositeScore")]
    public double MinCompositeScore { get; set; }
}
