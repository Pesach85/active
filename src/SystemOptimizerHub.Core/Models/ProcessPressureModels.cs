using System.Text.Json.Serialization;

namespace SystemOptimizerHub.Core.Models;

public sealed class ProcessPressureSnapshotRow
{
    public string Key { get; init; } = string.Empty;
    public string ProcessName { get; init; } = string.Empty;
    public int Pid { get; init; }
    public double CpuTime { get; init; }
    public long WorkingSet64 { get; init; }
    public long PrivateMemorySize64 { get; init; }
    public long IoBytes { get; init; }
    public string ImagePath { get; init; } = string.Empty;
    public bool Responding { get; init; } = true;
}

public sealed class PressureAction
{
    [JsonPropertyName("Action")]
    public string Action { get; init; } = string.Empty;

    [JsonPropertyName("Level")]
    public string Level { get; init; } = string.Empty;

    [JsonPropertyName("RequiresHitl")]
    public bool RequiresHitl { get; init; }

    [JsonPropertyName("Rationale")]
    public string Rationale { get; init; } = string.Empty;
}

public sealed class ProcessPressureRow
{
    [JsonPropertyName("Score")]
    public double Score { get; init; }

    [JsonPropertyName("ProcessName")]
    public string ProcessName { get; init; } = string.Empty;

    [JsonPropertyName("PID")]
    public int Pid { get; init; }

    [JsonPropertyName("ImagePath")]
    public string ImagePath { get; init; } = string.Empty;

    [JsonPropertyName("CpuPercent")]
    public double CpuPercent { get; init; }

    [JsonPropertyName("WorkingSetMB")]
    public double WorkingSetMb { get; init; }

    [JsonPropertyName("PrivateMB")]
    public double PrivateMb { get; init; }

    [JsonPropertyName("IoMBps")]
    public double IoMbPerSec { get; init; }

    [JsonPropertyName("DominantPressure")]
    public string DominantPressure { get; init; } = string.Empty;

    [JsonPropertyName("Necessity")]
    public string Necessity { get; init; } = string.Empty;

    [JsonPropertyName("Priority")]
    public string Priority { get; init; } = string.Empty;

    [JsonPropertyName("Category")]
    public string Category { get; init; } = string.Empty;

    [JsonPropertyName("Notes")]
    public string Notes { get; init; } = string.Empty;

    [JsonPropertyName("Responding")]
    public bool Responding { get; init; }

    [JsonPropertyName("Recommendation")]
    public string Recommendation { get; init; } = string.Empty;

    [JsonPropertyName("RecommendedActions")]
    public IReadOnlyList<PressureAction> RecommendedActions { get; init; } = [];

    [JsonPropertyName("AutoEligibleActions")]
    public IReadOnlyList<PressureAction> AutoEligibleActions { get; init; } = [];

    [JsonPropertyName("HitlRequiredActions")]
    public IReadOnlyList<PressureAction> HitlRequiredActions { get; init; } = [];
}

public sealed class ProcessPressureReport
{
    [JsonPropertyName("SchemaVersion")]
    public string SchemaVersion { get; init; } = "ProcessPressureReport.v1";

    [JsonPropertyName("GeneratedAt")]
    public string GeneratedAt { get; init; } = string.Empty;

    [JsonPropertyName("Platform")]
    public string Platform { get; init; } = string.Empty;

    [JsonPropertyName("DurationSec")]
    public int DurationSec { get; init; }

    [JsonPropertyName("LogicalProcessors")]
    public int LogicalProcessors { get; init; }

    [JsonPropertyName("TotalProcessesObserved")]
    public int TotalProcessesObserved { get; init; }

    [JsonPropertyName("CatalogPath")]
    public string CatalogPath { get; init; } = string.Empty;

    [JsonPropertyName("Summary")]
    public ProcessPressureSummary Summary { get; init; } = new();

    [JsonPropertyName("TopProcesses")]
    public IReadOnlyList<ProcessPressureRow> TopProcesses { get; init; } = [];

    [JsonPropertyName("ResearchNotes")]
    public IReadOnlyList<object> ResearchNotes { get; init; } = [];
}

public sealed class ProcessPressureSummary
{
    [JsonPropertyName("HighPressureCount")]
    public int HighPressureCount { get; init; }

    [JsonPropertyName("VitalPreserved")]
    public int VitalPreserved { get; init; }

    [JsonPropertyName("AutoEligibleCount")]
    public int AutoEligibleCount { get; init; }

    [JsonPropertyName("HitlRequiredCount")]
    public int HitlRequiredCount { get; init; }
}
