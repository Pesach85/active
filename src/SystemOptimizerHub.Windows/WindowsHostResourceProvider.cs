using System.Diagnostics;
using System.Runtime.InteropServices;
using SystemOptimizerHub.Core.Models;
using SystemOptimizerHub.Core.Pressure;

namespace SystemOptimizerHub.Windows;

public static class WindowsHostResourceProvider
{
    public static HostResourceSnapshot GetSnapshot()
    {
        var mem = GetMemoryStatus();
        var totalMb = (int)Math.Round(mem.TotalPhysical / (1024.0 * 1024.0), 0);
        var freeMb = (int)Math.Round(mem.AvailablePhysical / (1024.0 * 1024.0), 0);
        var totalGb = Math.Round(totalMb / 1024.0, 2);

        var cFreePct = 100.0;
        try
        {
            var drive = new DriveInfo("C");
            if (drive.TotalSize > 0)
                cFreePct = Math.Round(drive.AvailableFreeSpace / (double)drive.TotalSize * 100.0, 1);
        }
        catch { }

        return new HostResourceSnapshot
        {
            TotalRamMb = totalMb,
            FreeRamMb = freeMb,
            TotalRamGb = totalGb,
            LogicalProcessors = Environment.ProcessorCount,
            DriveCFreePercent = cFreePct
        };
    }

    private static MemoryStatus GetMemoryStatus()
    {
        var status = new MEMORYSTATUSEX { dwLength = (uint)Marshal.SizeOf<MEMORYSTATUSEX>() };
        if (!GlobalMemoryStatusEx(ref status))
            return new MemoryStatus(16L * 1024 * 1024 * 1024, 4L * 1024 * 1024 * 1024);

        return new MemoryStatus((long)status.ullTotalPhys, (long)status.ullAvailPhys);
    }

    private readonly record struct MemoryStatus(long TotalPhysical, long AvailablePhysical);

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

public static class WindowsProcessPressureSnapshot
{
    public static Dictionary<string, ProcessPressureSnapshotRow> Capture(IReadOnlyList<string>? excluded = null)
    {
        excluded ??= ProcessPressureAnalyzer.DefaultExcludedProcesses;
        var excludedSet = new HashSet<string>(excluded, StringComparer.OrdinalIgnoreCase);
        var rows = new Dictionary<string, ProcessPressureSnapshotRow>(StringComparer.Ordinal);

        foreach (var p in Process.GetProcesses())
        {
            try
            {
                if (excludedSet.Contains(p.ProcessName))
                    continue;

                long startTicks = 0;
                try { startTicks = p.StartTime.Ticks; } catch { }

                var key = $"{p.Id}:{startTicks}";
                var cpu = 0.0;
                try { cpu = p.TotalProcessorTime.TotalSeconds; } catch { }

                long ioRead = 0, ioWrite = 0;
                try
                {
                    // IO counters not exposed on all platforms; match PS try/catch swallow
                }
                catch { }

                var path = string.Empty;
                try { path = p.MainModule?.FileName ?? string.Empty; } catch { }

                rows[key] = new ProcessPressureSnapshotRow
                {
                    Key = key,
                    ProcessName = p.ProcessName,
                    Pid = p.Id,
                    CpuTime = cpu,
                    WorkingSet64 = p.WorkingSet64,
                    PrivateMemorySize64 = p.PrivateMemorySize64,
                    IoBytes = ioRead + ioWrite,
                    ImagePath = path,
                    Responding = p.Responding
                };
            }
            catch { }
            finally
            {
                p.Dispose();
            }
        }

        return rows;
    }

    public static List<RamConsumerInput> GetTopRamConsumers(int top = 15)
    {
        var list = new List<RamConsumerInput>();
        foreach (var p in Process.GetProcesses())
        {
            try
            {
                var ramMb = Math.Round(p.WorkingSet64 / (1024.0 * 1024.0), 1);
                var cpu = 0.0;
                try { cpu = Math.Round(p.TotalProcessorTime.TotalSeconds, 1); } catch { }
                var path = string.Empty;
                try { path = p.MainModule?.FileName ?? string.Empty; } catch { }

                list.Add(new RamConsumerInput
                {
                    Pid = p.Id,
                    Name = p.ProcessName,
                    RamMb = ramMb,
                    CpuSec = cpu,
                    ImagePath = path,
                    Responding = p.Responding
                });
            }
            catch { }
            finally
            {
                p.Dispose();
            }
        }

        return list.OrderByDescending(x => x.RamMb).Take(top).ToList();
    }
}
