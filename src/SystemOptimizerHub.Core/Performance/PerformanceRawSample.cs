namespace SystemOptimizerHub.Core.Performance;

public sealed class RamSample
{
    public bool PhysicalObserved { get; init; }

    public long TotalBytes { get; init; }

    public long AvailableBytes { get; init; }

    public bool CommitObserved { get; init; }

    public long CommitLimitBytes { get; init; }

    public long CommitAvailableBytes { get; init; }

    public MetricAvailability Pagefile { get; init; } = MetricAvailability.NotSupported;

    public long PagefileTotalBytes { get; init; }

    public long PagefileAvailableBytes { get; init; }

    public static RamSample Unread() => new();
}

public sealed class SystemCpuRaw
{
    public MetricAvailability Availability { get; init; } = MetricAvailability.NotSupported;

    public long Idle100Ns { get; init; }

    public long Kernel100Ns { get; init; }

    public long User100Ns { get; init; }

    public static SystemCpuRaw NotSupported() => new();

    public static SystemCpuRaw Unavailable() => new()
    {
        Availability = MetricAvailability.Unavailable
    };

    public static SystemCpuRaw Observed(long idle100Ns, long kernel100Ns, long user100Ns) => new()
    {
        Availability = MetricAvailability.Observed,
        Idle100Ns = idle100Ns,
        Kernel100Ns = kernel100Ns,
        User100Ns = user100Ns
    };
}

public sealed class ProcessRawObservation
{
    public int Pid { get; init; }

    public long? StartTimeUtcTicks { get; init; }

    public string ProcessName { get; init; } = string.Empty;

    public string? ImagePath { get; init; }

    public double? CpuTimeSeconds { get; init; }

    public long? WorkingSetBytes { get; init; }

    public long? PrivateBytes { get; init; }

    public bool? Responding { get; init; }

    public MetricAvailability Priority { get; init; } = MetricAvailability.Unavailable;

    public ObservedProcessPriority? PriorityValue { get; init; }
}

public sealed class PerformanceRawSample
{
    public DateTimeOffset TimestampUtc { get; init; }

    public int? LogicalProcessors { get; init; }

    public RamSample Ram { get; init; } = RamSample.Unread();

    public SystemCpuRaw SystemCpu { get; init; } = SystemCpuRaw.NotSupported();

    public IReadOnlyList<ProcessRawObservation> Processes { get; init; } = [];

    public MetricAvailability ProcessEnumeration { get; init; } = MetricAvailability.Observed;

    public MetricAvailability ProcessPriorityReader { get; init; } = MetricAvailability.NotSupported;

    public int IdentityUnreadableSkipped { get; init; }
}

public interface IPerformanceSampleSource
{
    PerformanceRawSample Capture(int maxProcesses, CancellationToken cancellationToken);
}
