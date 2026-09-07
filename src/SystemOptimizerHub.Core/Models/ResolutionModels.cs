using System.Text.Json.Serialization;

namespace SystemOptimizerHub.Core.Models;

public sealed class ProcessResolutionConfig
{
    [JsonPropertyName("SchemaVersion")]
    public string SchemaVersion { get; set; } = "ProcessResolutionConfig.v1";

    [JsonPropertyName("HighRamThresholdMb")]
    public double HighRamThresholdMb { get; set; } = 400;

    [JsonPropertyName("LowRamThresholdMb")]
    public double LowRamThresholdMb { get; set; } = 80;

    [JsonPropertyName("UnidentifiedConfidenceThreshold")]
    public double UnidentifiedConfidenceThreshold { get; set; } = 0.72;

    [JsonPropertyName("PreferReversibleActions")]
    public bool PreferReversibleActions { get; set; } = true;

    [JsonPropertyName("OperatorDecisionsPath")]
    public string OperatorDecisionsPath { get; set; } = "KB/operator-process-decisions.json";

    [JsonPropertyName("NeverTerminateExact")]
    public List<string> NeverTerminateExact { get; set; } = [];

    [JsonPropertyName("ConfirmPhraseTerminate")]
    public string ConfirmPhraseTerminate { get; set; } = "STOP UNKNOWN";

    [JsonPropertyName("ConfirmPhraseMarkNecessary")]
    public string ConfirmPhraseMarkNecessary { get; set; } = "KEEP FOR WORK";
}

public sealed record KnowledgeHintInput(
    double Confidence = 0.55,
    string TrustLevel = "T3_Unknown",
    string WhatItIs = "Unknown process",
    string SuggestedCategory = "Unknown");

public sealed record ProcessSnapshotInput(
    int Pid,
    string ProcessName,
    double RamMb,
    bool NotRunning = false);

public sealed record ResolutionAdvisoryOption(
    string ActionId,
    string Label,
    int EfficiencyCost,
    string Rationale,
    bool Reversible,
    bool RequiresHitl);

public sealed record ProcessResolutionAdvisory(
    string SchemaVersion,
    string ProcessName,
    int Pid,
    double RamMb,
    bool Identifiable,
    double Confidence,
    string TrustLevel,
    string WhatItIs,
    string? OperatorDecision,
    IReadOnlyList<string> Warnings,
    string RecommendedActionId,
    ResolutionAdvisoryOption? Recommended,
    IReadOnlyList<ResolutionAdvisoryOption> Options,
    IReadOnlyList<string> BlockedActionIds,
    string AiAidedSummary,
    string ControlLevel,
    bool RequiresOperatorApproval)
{
    public const string CurrentSchema = "ProcessResolutionAdvisory.v1";
}
