using System.Text.Json.Serialization;

namespace SystemOptimizerHub.Core.Models;

public sealed class DefenderExtremeApplyOptions
{
    public string Tier { get; set; } = "TuneExclusions";
    public string ReasonCode { get; set; } = "DevBuild";
    public IReadOnlyList<string> ExclusionPaths { get; set; } = [];
    public int AutoReenableMinutes { get; set; }
    public bool DryRun { get; set; }
    public bool IUnderstandRisk { get; set; }
    public bool ConfirmExtremeDisable { get; set; }
    public string? RollbackDirectory { get; set; }
    public string? RestoreScriptPath { get; set; }
}

public sealed class DefenderExtremeApplyAction
{
    [JsonPropertyName("Action")]
    public string Action { get; init; } = string.Empty;

    [JsonPropertyName("Detail")]
    public string Detail { get; init; } = string.Empty;

    [JsonPropertyName("Applied")]
    public bool Applied { get; init; }
}

public sealed class DefenderExtremeRollback
{
    [JsonPropertyName("SchemaVersion")]
    public string SchemaVersion { get; init; } = "DefenderExtremeRollback.v1";

    [JsonPropertyName("GeneratedAt")]
    public string GeneratedAt { get; init; } = string.Empty;

    [JsonPropertyName("ReasonCode")]
    public string ReasonCode { get; init; } = string.Empty;

    [JsonPropertyName("Tier")]
    public string Tier { get; init; } = string.Empty;

    [JsonPropertyName("DryRun")]
    public bool DryRun { get; init; }

    [JsonPropertyName("Before")]
    public DefenderPlatformStatus Before { get; init; } = new();

    [JsonPropertyName("ExclusionPathsAdded")]
    public IReadOnlyList<string> ExclusionPathsAdded { get; init; } = [];

    [JsonPropertyName("ServiceStates")]
    public IReadOnlyList<DefenderServiceStateDto> ServiceStates { get; init; } = [];

    [JsonPropertyName("ScheduledReenableMinutes")]
    public int ScheduledReenableMinutes { get; init; }

    [JsonPropertyName("ScheduledTaskName")]
    public string? ScheduledTaskName { get; init; }
}

public sealed class DefenderServiceStateDto
{
    [JsonPropertyName("Name")]
    public string Name { get; init; } = string.Empty;

    [JsonPropertyName("StartType")]
    public string StartType { get; init; } = string.Empty;

    [JsonPropertyName("Status")]
    public string Status { get; init; } = string.Empty;
}

public sealed class DefenderExtremeApplyResult
{
    [JsonPropertyName("SchemaVersion")]
    public string SchemaVersion { get; init; } = "DefenderExtremeApplyResult.v1";

    [JsonPropertyName("GeneratedAt")]
    public string GeneratedAt { get; init; } = string.Empty;

    [JsonPropertyName("Tier")]
    public string Tier { get; init; } = string.Empty;

    [JsonPropertyName("ReasonCode")]
    public string ReasonCode { get; init; } = string.Empty;

    [JsonPropertyName("DryRun")]
    public bool DryRun { get; init; }

    [JsonPropertyName("Applied")]
    public IReadOnlyList<DefenderExtremeApplyAction> Applied { get; init; } = [];

    [JsonPropertyName("RollbackPath")]
    public string RollbackPath { get; init; } = string.Empty;

    [JsonPropertyName("After")]
    public DefenderPlatformStatus? After { get; init; }

    [JsonPropertyName("Outcome")]
    public string Outcome { get; init; } = "Applied";

    [JsonPropertyName("Message")]
    public string Message { get; init; } = string.Empty;
}
