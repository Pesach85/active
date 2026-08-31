using System.Globalization;
using SystemOptimizerHub.Abstractions;
using SystemOptimizerHub.Core;

namespace SystemOptimizerHub.Linux;

public sealed class LinuxPlatformServices : IPlatformServices
{
    public PlatformInfo GetPlatformInfo() => new(
        "Linux",
        ReadOsReleasePrettyName(),
        Environment.Version.ToString(),
        HubVersion.Version);

    public IProcessSnapshotProvider ProcessSnapshots { get; } = new LinuxProcessSnapshotProvider();
    public IProcessMutator ProcessMutator { get; } = new LinuxProcessMutator();

    private static string ReadOsReleasePrettyName()
    {
        try
        {
            if (File.Exists("/etc/os-release"))
            {
                foreach (var line in File.ReadLines("/etc/os-release"))
                {
                    if (line.StartsWith("PRETTY_NAME=", StringComparison.Ordinal))
                    {
                        return line["PRETTY_NAME=".Length..].Trim('"');
                    }
                }
            }
        }
        catch { }
        return "Linux";
    }
}

internal sealed class LinuxProcessSnapshotProvider : IProcessSnapshotProvider
{
    public Task<ProcessSnapshot?> GetLiveSnapshotAsync(int processId, string processName, CancellationToken ct = default)
    {
        if (processId <= 0 && string.IsNullOrWhiteSpace(processName))
            return Task.FromResult<ProcessSnapshot?>(null);

        if (processId <= 0)
        {
            // name-only lookup via /proc (minimal Phase 0)
            return Task.FromResult<ProcessSnapshot?>(null);
        }

        var statPath = $"/proc/{processId}/stat";
        var statusPath = $"/proc/{processId}/status";
        if (!File.Exists(statPath))
            return Task.FromResult<ProcessSnapshot?>(null);

        var comm = processName;
        double ramMb = 0;
        try
        {
            foreach (var line in File.ReadLines(statusPath))
            {
                if (line.StartsWith("VmRSS:", StringComparison.Ordinal))
                {
                    var parts = line.Split(' ', StringSplitOptions.RemoveEmptyEntries);
                    if (parts.Length >= 2 && double.TryParse(parts[1], NumberStyles.Integer, CultureInfo.InvariantCulture, out var kb))
                        ramMb = Math.Round(kb / 1024.0, 1);
                    break;
                }
            }
        }
        catch { }

        var snap = new ProcessSnapshot(processId, comm, ramMb, 0, true, "Unknown", string.Empty, false);
        return Task.FromResult<ProcessSnapshot?>(snap);
    }
}

internal sealed class LinuxProcessMutator : IProcessMutator
{
    public Task ThrottleBelowNormalAsync(int processId, CancellationToken ct = default)
    {
        // renice +5 — parity with apply-process-pressure-safe.sh Safe level
        throw new PlatformNotSupportedException(
            "Linux renice apply is Phase 2; use scripts/linux/apply-process-pressure-safe.sh until hub parity gate passes.");
    }

    public Task TerminateAsync(int processId, CancellationToken ct = default) =>
        throw new PlatformNotSupportedException("Terminate on Linux requires explicit HITL Phase 2 implementation.");
}

public static class LinuxPlatform
{
    public static bool IsCurrentOs() =>
        OperatingSystem.IsLinux();

    public static IPlatformServices CreateServices() => new LinuxPlatformServices();
}
