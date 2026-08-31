using System.Text.Json.Serialization;

namespace SystemOptimizerHub.Core.Models;

public sealed class HostResourceSnapshot
{
    [JsonPropertyName("TotalRamMb")]
    public int TotalRamMb { get; init; }

    [JsonPropertyName("FreeRamMb")]
    public int FreeRamMb { get; init; }

    [JsonPropertyName("TotalRamGb")]
    public double TotalRamGb { get; init; }

    [JsonPropertyName("LogicalProcessors")]
    public int LogicalProcessors { get; init; }

    [JsonPropertyName("DriveCFreePercent")]
    public double DriveCFreePercent { get; init; }
}

public sealed class OptimizationProfile
{
    [JsonPropertyName("Name")]
    public string Name { get; init; } = "feather";

    [JsonPropertyName("Tier")]
    public string Tier { get; init; } = "C";

    [JsonPropertyName("LlmAllowed")]
    public bool LlmAllowed { get; init; }
}

public sealed class RamConsumerRow
{
    [JsonPropertyName("PID")]
    public int Pid { get; init; }

    [JsonPropertyName("Name")]
    public string Name { get; init; } = string.Empty;

    [JsonPropertyName("RamMb")]
    public double RamMb { get; init; }

    [JsonPropertyName("CpuSec")]
    public double CpuSec { get; init; }

    [JsonPropertyName("TrustLevel")]
    public string TrustLevel { get; init; } = string.Empty;

    [JsonPropertyName("TrustReason")]
    public string TrustReason { get; init; } = string.Empty;

    [JsonPropertyName("Responding")]
    public bool Responding { get; init; }
}

public sealed class AgentStatusRow
{
    [JsonPropertyName("AgentId")]
    public string AgentId { get; init; } = string.Empty;

    [JsonPropertyName("DisplayName")]
    public string DisplayName { get; init; } = string.Empty;

    [JsonPropertyName("TaskState")]
    public string TaskState { get; init; } = string.Empty;

    [JsonPropertyName("ControlLevel")]
    public string ControlLevel { get; init; } = string.Empty;
}

public sealed class TransparencyPosture
{
    [JsonPropertyName("Score")]
    public int Score { get; init; }

    [JsonPropertyName("Grade")]
    public string Grade { get; init; } = string.Empty;

    [JsonPropertyName("Notes")]
    public IReadOnlyList<string> Notes { get; init; } = [];
}

public sealed class TransparencyReport
{
    [JsonPropertyName("SchemaVersion")]
    public string SchemaVersion { get; init; } = "TransparencyReport.v1";

    [JsonPropertyName("GeneratedAt")]
    public string GeneratedAt { get; init; } = string.Empty;

    [JsonPropertyName("PolicyVersion")]
    public string PolicyVersion { get; init; } = "TransparencyPolicy.v1";

    [JsonPropertyName("Posture")]
    public TransparencyPosture Posture { get; init; } = new();

    [JsonPropertyName("Host")]
    public object Host { get; init; } = new();

    [JsonPropertyName("RamConsumers")]
    public IReadOnlyList<RamConsumerRow> RamConsumers { get; init; } = [];

    [JsonPropertyName("UnknownHighRam")]
    public IReadOnlyList<RamConsumerRow> UnknownHighRam { get; init; } = [];

    [JsonPropertyName("RegisteredAgents")]
    public IReadOnlyList<AgentStatusRow> RegisteredAgents { get; init; } = [];

    [JsonPropertyName("DelegationManifest")]
    public object DelegationManifest { get; init; } = new();

    [JsonPropertyName("ControlLevels")]
    public Dictionary<string, string> ControlLevels { get; init; } = new();
}

public sealed class TransparencyBuildInput
{
    [JsonPropertyName("HostSnapshot")]
    public HostResourceSnapshot HostSnapshot { get; init; } = new();

    [JsonPropertyName("Profile")]
    public OptimizationProfile Profile { get; init; } = new();

    [JsonPropertyName("RamConsumers")]
    public List<RamConsumerInput> RamConsumers { get; init; } = [];

    [JsonPropertyName("Agents")]
    public List<AgentStatusRow> Agents { get; init; } = [];

    [JsonPropertyName("UnknownRamThresholdMb")]
    public int UnknownRamThresholdMb { get; init; } = 400;

    [JsonPropertyName("AutoTerminate")]
    public bool AutoTerminate { get; init; }

    [JsonPropertyName("LlmEnabled")]
    public bool LlmEnabled { get; init; }

    [JsonPropertyName("NetworkUnknownTrustCount")]
    public int NetworkUnknownTrustCount { get; init; }

    [JsonPropertyName("NetworkHiddenProcessCount")]
    public int NetworkHiddenProcessCount { get; init; }

    [JsonPropertyName("NetworkAvailable")]
    public bool NetworkAvailable { get; init; }

    [JsonPropertyName("CatalogNames")]
    public List<string> CatalogNames { get; init; } = [];

    [JsonPropertyName("RunningHubScriptNames")]
    public List<string> RunningHubScriptNames { get; init; } = [];
}

public sealed class RamConsumerInput
{
    [JsonPropertyName("PID")]
    public int Pid { get; init; }

    [JsonPropertyName("Name")]
    public string Name { get; init; } = string.Empty;

    [JsonPropertyName("RamMb")]
    public double RamMb { get; init; }

    [JsonPropertyName("CpuSec")]
    public double CpuSec { get; init; }

    [JsonPropertyName("ImagePath")]
    public string ImagePath { get; init; } = string.Empty;

    [JsonPropertyName("Responding")]
    public bool Responding { get; init; } = true;
}
