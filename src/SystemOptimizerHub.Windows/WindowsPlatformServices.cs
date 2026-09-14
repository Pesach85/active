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
        var held = TryOpen(processId, processName);
        if (held is null)
            return Task.FromResult<ProcessSnapshot?>(null);
        try
        {
            return Task.FromResult<ProcessSnapshot?>(held.Value.Snapshot);
        }
        finally
        {
            held.Value.Handle.Dispose();
        }
    }

    public Task<LiveProcessHandle?> GetLiveSnapshotWithHandleAsync(
        int processId, string processName, CancellationToken ct = default)
    {
        var held = TryOpen(processId, processName);
        if (held is null)
            return Task.FromResult<LiveProcessHandle?>(null);
        return Task.FromResult<LiveProcessHandle?>(new LiveProcessHandle(held.Value.Snapshot, held.Value.Handle));
    }

    private static (ProcessSnapshot Snapshot, Process Handle)? TryOpen(int processId, string processName)
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
            return null;

        string path = string.Empty;
        long startTicks = 0;
        try { path = proc.MainModule?.FileName ?? string.Empty; } catch { }
        try { startTicks = proc.StartTime.ToUniversalTime().Ticks; } catch { }

        var snap = new ProcessSnapshot(
            proc.Id,
            proc.ProcessName,
            Math.Round(proc.WorkingSet64 / (1024.0 * 1024.0), 1),
            Math.Round(proc.TotalProcessorTime.TotalSeconds, 1),
            proc.Responding,
            proc.PriorityClass.ToString(),
            path,
            NotRunning: false,
            StartTimeUtcTicks: startTicks);
        return (snap, proc);
    }
}

internal sealed class WindowsProcessMutator : IProcessMutator
{
    public Task ThrottleBelowNormalAsync(Process handle, ProcessIdentity expectedIdentity, CancellationToken ct = default)
    {
        ArgumentNullException.ThrowIfNull(handle);
        ArgumentNullException.ThrowIfNull(expectedIdentity);

        // Fail-closed: never re-open by Pid. Ambiguity / exit → abort.
        if (handle.HasExited)
            throw new InvalidOperationException("Process handle exited before throttle — abort (no Pid re-lookup).");

        string path = string.Empty;
        long startTicks = 0;
        try { path = handle.MainModule?.FileName ?? string.Empty; } catch { }
        try { startTicks = handle.StartTime.ToUniversalTime().Ticks; } catch { }

        if (handle.Id != expectedIdentity.Pid)
            throw new InvalidOperationException("Process handle Pid mismatch — abort.");

        // Fail-closed: unreadable identity fields must not soft-skip.
        if (expectedIdentity.StartTimeUtcTicks == 0 || startTicks == 0)
            throw new InvalidOperationException("IdentityFieldUnreadable: StartTimeUtcTicks — abort.");
        if (startTicks != expectedIdentity.StartTimeUtcTicks)
            throw new InvalidOperationException("Process handle StartTime mismatch — abort.");

        var expectedPath = expectedIdentity.ImagePath?.Trim() ?? string.Empty;
        var actualPath = path.Trim();
        if (string.IsNullOrEmpty(expectedPath) || string.IsNullOrEmpty(actualPath))
            throw new InvalidOperationException("IdentityFieldUnreadable: ImagePath — abort.");
        if (!string.Equals(expectedPath, actualPath, StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("Process handle ImagePath mismatch — abort.");

        handle.PriorityClass = ProcessPriorityClass.BelowNormal;
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
