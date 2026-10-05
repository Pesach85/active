namespace SystemOptimizerHub.Core.Performance;

public static class PerformanceEvidenceLimits
{
    public const int DefaultMaxProcesses = 15;

    public const int HardMaxProcesses = 30;
}

public static class PerformanceIdentity
{
    public static string Key(int pid, long startTimeUtcTicks) => $"{pid}:{startTimeUtcTicks}";
}

public sealed class RamEvidence
{
    public PerformanceMetric<long> TotalBytes { get; init; } = PerformanceMetric<long>.Unavailable();

    public PerformanceMetric<long> AvailableBytes { get; init; } = PerformanceMetric<long>.Unavailable();

    public PerformanceMetric<long> UsedBytes { get; init; } = PerformanceMetric<long>.Unavailable();

    public PerformanceMetric<long> CommitLimitBytes { get; init; } = PerformanceMetric<long>.Unavailable();

    public PerformanceMetric<long> CommitAvailableBytes { get; init; } = PerformanceMetric<long>.Unavailable();

    public PerformanceMetric<long> CommitUsedBytes { get; init; } = PerformanceMetric<long>.Unavailable();

    public PerformanceMetric<long> PagefileTotalBytes { get; init; } = PerformanceMetric<long>.NotSupported();

    public PerformanceMetric<long> PagefileAvailableBytes { get; init; } = PerformanceMetric<long>.NotSupported();
}

public sealed class CpuEvidence
{
    public PerformanceMetric<int> LogicalProcessors { get; init; } = PerformanceMetric<int>.Unknown();

    public PerformanceMetric<double> SystemUtilizationPercent { get; init; } = PerformanceMetric<double>.NotSupported();
}

public sealed class IoEvidence
{
    public MetricAvailability DiskLatency { get; init; } = MetricAvailability.NotSupported;

    public MetricAvailability QueueDepth { get; init; } = MetricAvailability.NotSupported;

    public MetricAvailability ProcessIoBytes { get; init; } = MetricAvailability.NotSupported;
}

public sealed class GpuEvidence
{
    public MetricAvailability Utilization { get; init; } = MetricAvailability.NotSupported;

    public MetricAvailability Memory { get; init; } = MetricAvailability.NotSupported;

    public MetricAvailability Engine { get; init; } = MetricAvailability.NotSupported;

    public MetricAvailability Thermal { get; init; } = MetricAvailability.NotSupported;
}

public sealed class ProcessPerformanceEvidence
{
    public string IdentityKey { get; init; } = string.Empty;

    public int Pid { get; init; }

    public long StartTimeUtcTicks { get; init; }

    public string ProcessName { get; init; } = string.Empty;

    public MetricAvailability ImagePathState { get; init; }

    public string? ImagePath { get; init; }

    public bool IdentityPathMatches { get; init; }

    public PerformanceMetric<double> CpuTimeBaselineSeconds { get; init; } = PerformanceMetric<double>.Unavailable();

    public PerformanceMetric<double> CpuTimeCurrentSeconds { get; init; } = PerformanceMetric<double>.Unavailable();

    public PerformanceMetric<double> CpuDeltaSeconds { get; init; } = PerformanceMetric<double>.Unknown();

    public PerformanceMetric<double> CpuUtilizationPercent { get; init; } = PerformanceMetric<double>.Unknown();

    public PerformanceMetric<bool> CpuTimeAdvanced { get; init; } = PerformanceMetric<bool>.Unknown();

    public PerformanceMetric<long> WorkingSetBytesBaseline { get; init; } = PerformanceMetric<long>.Unavailable();

    public PerformanceMetric<long> WorkingSetBytes { get; init; } = PerformanceMetric<long>.Unavailable();

    public PerformanceMetric<long> PrivateBytes { get; init; } = PerformanceMetric<long>.Unavailable();

    public PerformanceMetric<long> IoReadBytesBaseline { get; init; } = PerformanceMetric<long>.NotSupported();

    public PerformanceMetric<long> IoReadBytesCurrent { get; init; } = PerformanceMetric<long>.NotSupported();

    public PerformanceMetric<long> IoReadBytesDelta { get; init; } = PerformanceMetric<long>.NotSupported();

    public PerformanceMetric<long> IoWriteBytesBaseline { get; init; } = PerformanceMetric<long>.NotSupported();

    public PerformanceMetric<long> IoWriteBytesCurrent { get; init; } = PerformanceMetric<long>.NotSupported();

    public PerformanceMetric<long> IoWriteBytesDelta { get; init; } = PerformanceMetric<long>.NotSupported();

    public PerformanceMetric<long> IoReadOperationsBaseline { get; init; } = PerformanceMetric<long>.NotSupported();

    public PerformanceMetric<long> IoReadOperationsCurrent { get; init; } = PerformanceMetric<long>.NotSupported();

    public PerformanceMetric<long> IoReadOperationsDelta { get; init; } = PerformanceMetric<long>.NotSupported();

    public PerformanceMetric<long> IoWriteOperationsBaseline { get; init; } = PerformanceMetric<long>.NotSupported();

    public PerformanceMetric<long> IoWriteOperationsCurrent { get; init; } = PerformanceMetric<long>.NotSupported();

    public PerformanceMetric<long> IoWriteOperationsDelta { get; init; } = PerformanceMetric<long>.NotSupported();

    public PerformanceMetric<long> PageFaultCountBaseline { get; init; } = PerformanceMetric<long>.NotSupported();

    public PerformanceMetric<long> PageFaultCountCurrent { get; init; } = PerformanceMetric<long>.NotSupported();

    public PerformanceMetric<long> PageFaultCountDelta { get; init; } = PerformanceMetric<long>.NotSupported();

    public PerformanceMetric<bool> Responding { get; init; } = PerformanceMetric<bool>.Unavailable();

    public PerformanceMetric<ObservedProcessPriority> PriorityBaseline { get; init; } =
        PerformanceMetric<ObservedProcessPriority>.Unavailable();

    public PerformanceMetric<ObservedProcessPriority> PriorityCurrent { get; init; } =
        PerformanceMetric<ObservedProcessPriority>.Unavailable();

    /// <summary>
    /// Observed only when both samples published a priority. The value means the pair is complete, not that the two priorities match.
    /// </summary>
    public PerformanceMetric<bool> PriorityPairComplete { get; init; } = PerformanceMetric<bool>.Unavailable();
}

public sealed class ProcessIdentityDrift
{
    public int Pid { get; init; }

    public long BaselineStartTimeUtcTicks { get; init; }

    public long CurrentStartTimeUtcTicks { get; init; }

    public int ReplacementSampleIndex { get; init; }

    public string? BaselineImagePath { get; init; }

    public string? CurrentImagePath { get; init; }
}

public sealed class ProgressEvidence
{
    public PerformanceMetric<double> ElapsedSeconds { get; init; } = PerformanceMetric<double>.Unknown();

    public int PairedIdentityCount { get; init; }

    public int CpuTimeAdvancedCount { get; init; }

    public int CpuTimeNotAdvancedCount { get; init; }

    public int RespondingObservedCount { get; init; }

    public int RespondingUnavailableCount { get; init; }

    public int IdentityDriftCount { get; init; }

    public int AbsentFromCurrentSampleCount { get; init; }
}

public sealed class EvidenceQuality
{
    public int ObservedCount { get; init; }

    public int UnavailableCount { get; init; }

    public int NotSupportedCount { get; init; }

    public int UnknownCount { get; init; }
}

public sealed class PerformanceSnapshot
{
    public DateTimeOffset BaselineTimestampUtc { get; init; }

    public DateTimeOffset TimestampUtc { get; init; }

    public int SampleCount { get; init; }

    public int PositiveIntervalCount { get; init; }

    public PerformanceMetric<double> SampleDurationSeconds { get; init; } = PerformanceMetric<double>.Unknown();

    public MetricAvailability Window { get; init; }

    public RamEvidence Ram { get; init; } = new();

    public CpuEvidence Cpu { get; init; } = new();

    public IoEvidence Io { get; init; } = new();

    public GpuEvidence Gpu { get; init; } = new();

    public MetricAvailability ProcessEnumeration { get; init; }

    public MetricAvailability ProcessPriorityReader { get; init; } = MetricAvailability.NotSupported;

    public MetricAvailability ProcessIoReader { get; init; } = MetricAvailability.NotSupported;

    public MetricAvailability ProcessPageFaultReader { get; init; } = MetricAvailability.NotSupported;

    public IReadOnlyList<ProcessPerformanceEvidence> ProcessTopConsumers { get; init; } = [];

    public IReadOnlyList<string> AbsentFromCurrentSample { get; init; } = [];

    public IReadOnlyList<string> AbsentFromIntermediateSample { get; init; } = [];

    public IReadOnlyList<string> AppearedInCurrentSample { get; init; } = [];

    public IReadOnlyList<ProcessIdentityDrift> IdentityDrift { get; init; } = [];

    public ProgressEvidence Progress { get; init; } = new();

    public EvidenceQuality EvidenceQuality { get; init; } = new();

    public int MaxProcesses { get; init; }

    public int BaselineIdentityUnreadableSkipped { get; init; }

    public int CurrentIdentityUnreadableSkipped { get; init; }
}
