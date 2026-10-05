using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using SystemOptimizerHub.Core.Performance;

namespace SystemOptimizerHub.Windows;

[SupportedOSPlatform("windows")]
public sealed class WindowsPerformanceSampleSource : IPerformanceSampleSource
{
    public PerformanceRawSample Capture(int maxProcesses, CancellationToken cancellationToken)
    {
        if (maxProcesses < 1 || maxProcesses > PerformanceEvidenceLimits.HardMaxProcesses)
            throw new ArgumentOutOfRangeException(nameof(maxProcesses));
        cancellationToken.ThrowIfCancellationRequested();

        return new PerformanceRawSample
        {
            TimestampUtc = DateTimeOffset.UtcNow,
            LogicalProcessors = Environment.ProcessorCount > 0 ? Environment.ProcessorCount : null,
            Ram = WindowsMemoryStatusMapper.Read(),
            SystemCpu = WindowsSystemCpuReader.Read(),
            Processes = ReadProcesses(maxProcesses, cancellationToken, out var skipped),
            ProcessEnumeration = MetricAvailability.Observed,
            ProcessPriorityReader = MetricAvailability.Observed,
            IdentityUnreadableSkipped = skipped
        };
    }

    private static List<ProcessRawObservation> ReadProcesses(
        int maxProcesses,
        CancellationToken cancellationToken,
        out int identityUnreadableSkipped)
    {
        var kept = new List<Process>(maxProcesses + 1);
        identityUnreadableSkipped = 0;
        try
        {
            foreach (var process in Process.GetProcesses())
            {
                var owned = true;
                try
                {
                    cancellationToken.ThrowIfCancellationRequested();
                    long startTicks;
                    try
                    {
                        startTicks = process.StartTime.ToUniversalTime().Ticks;
                    }
                    catch
                    {
                        identityUnreadableSkipped++;
                        continue;
                    }

                    if (startTicks <= 0)
                    {
                        identityUnreadableSkipped++;
                        continue;
                    }

                    kept.Add(process);
                    owned = false;
                    if (kept.Count <= maxProcesses)
                        continue;

                    var worst = kept
                        .OrderBy(WorkingSetOrMin)
                        .ThenByDescending(p => p.Id)
                        .First();
                    kept.Remove(worst);
                    worst.Dispose();
                }
                finally
                {
                    if (owned)
                        process.Dispose();
                }
            }

            var rows = new List<ProcessRawObservation>(kept.Count);
            foreach (var process in kept)
            {
                cancellationToken.ThrowIfCancellationRequested();
                if (TryRead(process, out var row))
                    rows.Add(row);
                else
                    identityUnreadableSkipped++;
            }

            return rows;
        }
        finally
        {
            foreach (var process in kept)
                process.Dispose();
        }
    }

    private static long WorkingSetOrMin(Process process)
    {
        try
        {
            return process.WorkingSet64;
        }
        catch
        {
            return long.MinValue;
        }
    }

    private static bool TryRead(Process process, out ProcessRawObservation row)
    {
        row = new ProcessRawObservation();
        long startTicks;
        try
        {
            startTicks = process.StartTime.ToUniversalTime().Ticks;
        }
        catch
        {
            return false;
        }

        if (startTicks <= 0)
            return false;

        string? path = null;
        var pathRead = true;
        try
        {
            path = process.MainModule?.FileName;
        }
        catch
        {
            pathRead = false;
        }

        double? cpu = null;
        try
        {
            cpu = process.TotalProcessorTime.TotalSeconds;
        }
        catch
        {
            cpu = null;
        }

        long? workingSet = null;
        try
        {
            workingSet = process.WorkingSet64;
        }
        catch
        {
            workingSet = null;
        }

        long? privateBytes = null;
        try
        {
            privateBytes = process.PrivateMemorySize64;
        }
        catch
        {
            privateBytes = null;
        }

        bool? responding = null;
        try
        {
            responding = process.Responding;
        }
        catch
        {
            responding = null;
        }

        var priority = WindowsProcessPriorityReader.Read(process);

        string name;
        try
        {
            name = process.ProcessName;
        }
        catch
        {
            name = string.Empty;
        }

        row = new ProcessRawObservation
        {
            Pid = process.Id,
            StartTimeUtcTicks = startTicks,
            ProcessName = name,
            ImagePath = pathRead ? path ?? string.Empty : null,
            CpuTimeSeconds = cpu,
            WorkingSetBytes = workingSet,
            PrivateBytes = privateBytes,
            Responding = responding,
            Priority = priority.Availability,
            PriorityValue = priority.Value
        };
        return true;
    }
}

public readonly record struct WindowsMemoryStatus(
    bool Succeeded,
    ulong TotalPhysical,
    ulong AvailablePhysical,
    ulong TotalPageFile,
    ulong AvailablePageFile);

public static class WindowsMemoryStatusMapper
{
    public static RamSample Map(WindowsMemoryStatus status)
    {
        if (!status.Succeeded)
            return RamSample.Unread();

        return new RamSample
        {
            PhysicalObserved = true,
            TotalBytes = checked((long)status.TotalPhysical),
            AvailableBytes = checked((long)status.AvailablePhysical),
            CommitObserved = true,
            CommitLimitBytes = checked((long)status.TotalPageFile),
            CommitAvailableBytes = checked((long)status.AvailablePageFile),
            Pagefile = MetricAvailability.NotSupported
        };
    }

    [SupportedOSPlatform("windows")]
    public static RamSample Read()
    {
        var status = new MEMORYSTATUSEX { dwLength = (uint)Marshal.SizeOf<MEMORYSTATUSEX>() };
        if (!GlobalMemoryStatusEx(ref status))
            return Map(new WindowsMemoryStatus(false, 0, 0, 0, 0));

        return Map(new WindowsMemoryStatus(
            true,
            status.ullTotalPhys,
            status.ullAvailPhys,
            status.ullTotalPageFile,
            status.ullAvailPageFile));
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MEMORYSTATUSEX
    {
        public uint dwLength;
        public uint dwMemoryLoad;
        public ulong ullTotalPhys;
        public ulong ullAvailPhys;
        public ulong ullTotalPageFile;
        public ulong ullAvailPageFile;
        public ulong ullTotalVirtual;
        public ulong ullAvailVirtual;
        public ulong ullAvailExtendedVirtual;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GlobalMemoryStatusEx(ref MEMORYSTATUSEX lpBuffer);
}

public static class WindowsSystemCpuReader
{
    [SupportedOSPlatform("windows")]
    public static SystemCpuRaw Read()
    {
        if (!GetSystemTimes(out var idle, out var kernel, out var user))
            return SystemCpuRaw.Unavailable();
        return SystemCpuRaw.Observed(To100Ns(idle), To100Ns(kernel), To100Ns(user));
    }

    private static long To100Ns(FILETIME value) =>
        ((long)value.dwHighDateTime << 32) | value.dwLowDateTime;

    [StructLayout(LayoutKind.Sequential)]
    private struct FILETIME
    {
        public uint dwLowDateTime;
        public uint dwHighDateTime;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetSystemTimes(out FILETIME idle, out FILETIME kernel, out FILETIME user);
}

public readonly record struct ProcessPriorityObservation(
    MetricAvailability Availability,
    ObservedProcessPriority? Value)
{
    public static ProcessPriorityObservation Observed(ObservedProcessPriority value) =>
        new(MetricAvailability.Observed, value);

    public static ProcessPriorityObservation Unavailable() =>
        new(MetricAvailability.Unavailable, null);

    public static ProcessPriorityObservation Unknown() =>
        new(MetricAvailability.Unknown, null);
}

[SupportedOSPlatform("windows")]
public static class WindowsProcessPriorityReader
{
    public static ProcessPriorityObservation Read(Process process)
    {
        try
        {
            var priority = process.PriorityClass;
            return WindowsProcessPriorityMapper.TryMap(priority, out var mapped)
                ? ProcessPriorityObservation.Observed(mapped)
                : ProcessPriorityObservation.Unknown();
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            return ProcessPriorityObservation.Unavailable();
        }
    }
}

public static class WindowsProcessPriorityMapper
{
    public static bool TryMap(ProcessPriorityClass priority, out ObservedProcessPriority mapped)
    {
        switch (priority)
        {
            case ProcessPriorityClass.Idle:
                mapped = ObservedProcessPriority.Idle;
                return true;
            case ProcessPriorityClass.BelowNormal:
                mapped = ObservedProcessPriority.BelowNormal;
                return true;
            case ProcessPriorityClass.Normal:
                mapped = ObservedProcessPriority.Normal;
                return true;
            case ProcessPriorityClass.AboveNormal:
                mapped = ObservedProcessPriority.AboveNormal;
                return true;
            case ProcessPriorityClass.High:
                mapped = ObservedProcessPriority.High;
                return true;
            case ProcessPriorityClass.RealTime:
                mapped = ObservedProcessPriority.RealTime;
                return true;
            default:
                mapped = default;
                return false;
        }
    }
}
