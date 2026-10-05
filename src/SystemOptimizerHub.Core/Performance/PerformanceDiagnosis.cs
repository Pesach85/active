using System.Text.Json.Serialization;

namespace SystemOptimizerHub.Core.Performance;

[JsonConverter(typeof(JsonStringEnumConverter))]
public enum PerformanceOverallState
{
    NORMAL,
    DEGRADED,
    CRITICAL,
    UNKNOWN
}

[JsonConverter(typeof(JsonStringEnumConverter))]
public enum PerformanceCause
{
    NONE,
    CPU_CONTENTION,
    PROCESS_CPU_PRESSURE,
    PROCESS_SEMI_STALL,
    MEMORY_PRESSURE,
    PAGING_PRESSURE,
    IO_PRESSURE,
    GPU_PRESSURE,
    MIXED,
    UNKNOWN
}

[JsonConverter(typeof(JsonStringEnumConverter))]
public enum PerformanceConfidence
{
    HIGH,
    LIMITED,
    NONE
}

[JsonConverter(typeof(JsonStringEnumConverter))]
public enum PerformanceAutomationEligibility
{
    NO_ACTION,
    HITL_REQUIRED,
    AUTO_CANDIDATE
}

/// <summary>
/// CPU thresholds below were approved for the conservative policy.
/// Wall-clock duration, cooldown duration, process classification, and a CPU-only
/// exception for unread domains are not approved. Those gaps block AUTO_CANDIDATE.
/// </summary>
public static class PerformanceDiagnosisPolicy
{
    public const bool CpuUtilizationClassificationEnabled = true;

    public const bool MemoryPressureClassificationEnabled = false;

    public const bool PagingPressureClassificationEnabled = false;

    public const decimal ApprovedSystemCpuPercent = 90m;

    public const decimal ApprovedProcessCpuPercent = 40m;

    public const decimal ApprovedProcessShareOfBusy = 0.70m;

    public const int ApprovedMinimumSamples = 4;

    public const int ApprovedMinimumPositiveIntervals = 3;

    public const bool WallClockDurationApproved = false;

    public const bool CooldownDurationApproved = false;

    public const bool ProcessClassificationAvailable = false;

    public const bool UnsupportedDomainCpuOnlyPermitted = false;

    public static bool AutoCandidatePermitted() =>
        WallClockDurationApproved
        && CooldownDurationApproved
        && ProcessClassificationAvailable
        && UnsupportedDomainCpuOnlyPermitted;
}

public sealed class PerformanceDiagnosis
{
    public PerformanceOverallState OverallState { get; init; }

    public PerformanceCause PrimaryCause { get; init; }

    public PerformanceConfidence Confidence { get; init; }

    public IReadOnlyList<string> EvidenceReasons { get; init; } = [];

    public IReadOnlyList<string> CandidateTargets { get; init; } = [];

    public PerformanceAutomationEligibility AutomationEligibility { get; init; }

    public IReadOnlyList<string> UnknownReasons { get; init; } = [];

    public bool CpuPolicyMatched { get; init; }

    public IReadOnlyList<string> PolicyBlockers { get; init; } = [];
}
