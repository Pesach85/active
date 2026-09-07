using System.Diagnostics;
using SystemOptimizerHub.Abstractions;
using SystemOptimizerHub.Core;

namespace SystemOptimizerHub.Windows;

public sealed class WindowsPlatformServices : IPlatformServices
{
    public PlatformInfo GetPlatformInfo() => new(
        "Windows",
        Environment.OSVersion.VersionString,
        Environment.Version.ToString(),
        HubVersion.Version);

    public IProcessSnapshotProvider ProcessSnapshots { get; } = new WindowsProcessSnapshotProvider();
    public IProcessMutator ProcessMutator { get; } = new WindowsProcessMutator();
    public IDefenderPolicyMutator DefenderPolicy { get; } = new WindowsDefenderPolicyMutator();
    public INetworkMutator NetworkMutator { get; } = new WindowsNetworkMutator();
}

internal sealed class WindowsProcessSnapshotProvider : IProcessSnapshotProvider
{
    public Task<ProcessSnapshot?> GetLiveSnapshotAsync(int processId, string processName, CancellationToken ct = default)
    {
        Process? proc = null;
        try
        {
            if (processId > 0)
                proc = Process.GetProcessById(processId);
            else if (!string.IsNullOrWhiteSpace(processName))
            {
                var baseName = processName.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)
                    ? processName[..^4] : processName;
                proc = Process.GetProcessesByName(baseName).FirstOrDefault();
            }
        }
        catch
        {
            // match PS: swallow and return null
        }

        if (proc is null)
            return Task.FromResult<ProcessSnapshot?>(null);

        string path = string.Empty;
        try { path = proc.MainModule?.FileName ?? string.Empty; } catch { }

        var snap = new ProcessSnapshot(
            proc.Id,
            proc.ProcessName,
            Math.Round(proc.WorkingSet64 / (1024.0 * 1024.0), 1),
            Math.Round(proc.TotalProcessorTime.TotalSeconds, 1),
            proc.Responding,
            proc.PriorityClass.ToString(),
            path,
            NotRunning: false);
        proc.Dispose();
        return Task.FromResult<ProcessSnapshot?>(snap);
    }
}

internal sealed class WindowsProcessMutator : IProcessMutator
{
    public Task ThrottleBelowNormalAsync(int processId, CancellationToken ct = default)
    {
        var proc = Process.GetProcessById(processId);
        proc.PriorityClass = ProcessPriorityClass.BelowNormal;
        proc.Dispose();
        return Task.CompletedTask;
    }

    public Task TerminateAsync(int processId, CancellationToken ct = default)
    {
        var proc = Process.GetProcessById(processId);
        proc.Kill(true);
        proc.Dispose();
        return Task.CompletedTask;
    }
}

public static class WindowsPlatform
{
    public static bool IsCurrentOs() =>
        OperatingSystem.IsWindows();

    public static IPlatformServices CreateServices() => new WindowsPlatformServices();
}
