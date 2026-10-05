using SystemOptimizerHub.Core.Performance;

namespace SystemOptimizerHub.Linux;

public sealed class LinuxPerformanceSampleSource : IPerformanceSampleSource
{
    public PerformanceRawSample Capture(int maxProcesses, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        _ = maxProcesses;
        return new PerformanceRawSample
        {
            TimestampUtc = DateTimeOffset.UtcNow,
            LogicalProcessors = Environment.ProcessorCount > 0 ? Environment.ProcessorCount : null,
            Ram = LinuxMemInfo.Read(),
            SystemCpu = SystemCpuRaw.NotSupported(),
            Processes = [],
            ProcessEnumeration = MetricAvailability.NotSupported,
            ProcessPriorityReader = MetricAvailability.NotSupported,
            ProcessIoReader = MetricAvailability.NotSupported,
            ProcessPageFaultReader = MetricAvailability.NotSupported,
            IdentityUnreadableSkipped = 0
        };
    }
}

public static class LinuxMemInfo
{
    public static RamSample Read()
    {
        try
        {
            if (!File.Exists("/proc/meminfo"))
                return RamSample.Unread();
            return Parse(File.ReadAllText("/proc/meminfo"));
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            return RamSample.Unread();
        }
    }

    public static RamSample Parse(string? text)
    {
        if (string.IsNullOrWhiteSpace(text))
            return RamSample.Unread();

        long? total = null;
        long? available = null;
        long? commitLimit = null;
        long? committed = null;
        long? swapTotal = null;
        long? swapFree = null;
        foreach (var line in text.Split('\n'))
        {
            var parts = line.Split(' ', StringSplitOptions.RemoveEmptyEntries);
            if (parts.Length < 2 || !long.TryParse(parts[1], out var kib))
                continue;
            var bytes = kib * 1024;
            switch (parts[0])
            {
                case "MemTotal:":
                    total = bytes;
                    break;
                case "MemAvailable:":
                    available = bytes;
                    break;
                case "CommitLimit:":
                    commitLimit = bytes;
                    break;
                case "Committed_AS:":
                    committed = bytes;
                    break;
                case "SwapTotal:":
                    swapTotal = bytes;
                    break;
                case "SwapFree:":
                    swapFree = bytes;
                    break;
            }
        }

        if (total is null || available is null)
            return RamSample.Unread();

        var commitObserved = commitLimit is not null && committed is not null && commitLimit >= committed;
        var pagefile = swapTotal is not null && swapFree is not null
            ? MetricAvailability.Observed
            : MetricAvailability.Unavailable;

        return new RamSample
        {
            PhysicalObserved = true,
            TotalBytes = total.Value,
            AvailableBytes = available.Value,
            CommitObserved = commitObserved,
            CommitLimitBytes = commitObserved ? commitLimit!.Value : 0,
            CommitAvailableBytes = commitObserved ? commitLimit!.Value - committed!.Value : 0,
            Pagefile = pagefile,
            PagefileTotalBytes = pagefile == MetricAvailability.Observed ? swapTotal!.Value : 0,
            PagefileAvailableBytes = pagefile == MetricAvailability.Observed ? swapFree!.Value : 0
        };
    }
}
