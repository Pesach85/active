using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using SystemOptimizerHub.Core.Performance;

namespace SystemOptimizerHub.Windows;

public readonly record struct PagefileObservation(MetricAvailability Availability, long TotalBytes, long AvailableBytes)
{
    public static PagefileObservation Unavailable() => new(MetricAvailability.Unavailable, 0, 0);

    public static PagefileObservation Unknown() => new(MetricAvailability.Unknown, 0, 0);
}

public readonly record struct ProcessCounterObservation(
    long? ReadBytes,
    long? WriteBytes,
    long? ReadOperations,
    long? WriteOperations,
    long? PageFaults);

public static class WindowsPagefileReader
{
    public static PagefileObservation FromPages(ulong totalPages, ulong usedPages, uint pageSize, int fileCount)
    {
        if (fileCount < 1 || pageSize == 0)
            return PagefileObservation.Unavailable();
        if (usedPages > totalPages)
            return PagefileObservation.Unknown();

        try
        {
            var total = checked((long)(totalPages * pageSize));
            var used = checked((long)(usedPages * pageSize));
            return new PagefileObservation(MetricAvailability.Observed, total, total - used);
        }
        catch (OverflowException)
        {
            return PagefileObservation.Unknown();
        }
    }

    private static readonly EnumPageFilesDelegate CallbackDelegate = Callback;

    [SupportedOSPlatform("windows")]
    public static PagefileObservation Read()
    {
        var accum = new Accumulator();
        var handle = GCHandle.Alloc(accum);
        try
        {
            var ok = EnumPageFilesW(CallbackDelegate, GCHandle.ToIntPtr(handle));
            if (!ok || accum.Count < 1)
                return PagefileObservation.Unavailable();
            return FromPages(accum.TotalPages, accum.UsedPages, PageSize(), accum.Count);
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            return PagefileObservation.Unavailable();
        }
        finally
        {
            handle.Free();
        }
    }

    private static uint PageSize()
    {
        GetSystemInfo(out var info);
        return info.dwPageSize;
    }

    private static bool Callback(IntPtr context, IntPtr infoPtr, IntPtr namePtr)
    {
        _ = namePtr;
        var info = Marshal.PtrToStructure<EnumPageFileInformation>(infoPtr);
        var accum = (Accumulator)GCHandle.FromIntPtr(context).Target!;
        accum.TotalPages += (ulong)info.TotalSize;
        accum.UsedPages += (ulong)info.TotalInUse;
        accum.Count++;
        return true;
    }

    private sealed class Accumulator
    {
        public ulong TotalPages;
        public ulong UsedPages;
        public int Count;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct EnumPageFileInformation
    {
        public uint cb;
        public uint Reserved;
        public nuint TotalSize;
        public nuint TotalInUse;
        public nuint PeakUsage;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct SystemInfo
    {
        public ushort wProcessorArchitecture;
        public ushort wReserved;
        public uint dwPageSize;
        public nint lpMinimumApplicationAddress;
        public nint lpMaximumApplicationAddress;
        public nint dwActiveProcessorMask;
        public uint dwNumberOfProcessors;
        public uint dwProcessorType;
        public uint dwAllocationGranularity;
        public ushort wProcessorLevel;
        public ushort wProcessorRevision;
    }

    private delegate bool EnumPageFilesDelegate(IntPtr context, IntPtr info, IntPtr fileName);

    [DllImport("psapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool EnumPageFilesW(EnumPageFilesDelegate callback, IntPtr context);

    [DllImport("kernel32.dll")]
    private static extern void GetSystemInfo(out SystemInfo info);
}

[SupportedOSPlatform("windows")]
public static class WindowsProcessCounterReader
{
    public static ProcessCounterObservation Read(Process process)
    {
        try
        {
            var handle = process.Handle;
            long? readBytes = null;
            long? writeBytes = null;
            long? readOps = null;
            long? writeOps = null;
            long? faults = null;
            if (GetProcessIoCounters(handle, out var io))
            {
                readBytes = ToLong(io.ReadTransferCount);
                writeBytes = ToLong(io.WriteTransferCount);
                readOps = ToLong(io.ReadOperationCount);
                writeOps = ToLong(io.WriteOperationCount);
            }

            var memory = new ProcessMemoryCounters { cb = (uint)Marshal.SizeOf<ProcessMemoryCounters>() };
            if (GetProcessMemoryInfo(handle, ref memory, memory.cb))
                faults = memory.PageFaultCount;

            return new ProcessCounterObservation(readBytes, writeBytes, readOps, writeOps, faults);
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            return new ProcessCounterObservation(null, null, null, null, null);
        }
    }

    private static long? ToLong(ulong value) =>
        value <= long.MaxValue ? (long)value : null;

    [StructLayout(LayoutKind.Sequential)]
    private struct IoCounters
    {
        public ulong ReadOperationCount;
        public ulong WriteOperationCount;
        public ulong OtherOperationCount;
        public ulong ReadTransferCount;
        public ulong WriteTransferCount;
        public ulong OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ProcessMemoryCounters
    {
        public uint cb;
        public uint PageFaultCount;
        public nuint PeakWorkingSetSize;
        public nuint WorkingSetSize;
        public nuint QuotaPeakPagedPoolUsage;
        public nuint QuotaPagedPoolUsage;
        public nuint QuotaPeakNonPagedPoolUsage;
        public nuint QuotaNonPagedPoolUsage;
        public nuint PagefileUsage;
        public nuint PeakPagefileUsage;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetProcessIoCounters(nint process, out IoCounters counters);

    [DllImport("psapi.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetProcessMemoryInfo(nint process, ref ProcessMemoryCounters counters, uint size);
}
