namespace SystemOptimizerHub.Abstractions;

public sealed record ProcessSnapshot(
    int Pid,
    string ProcessName,
    double RamMb,
    double CpuSec,
    bool Responding,
    string PriorityClass,
    string ImagePath,
    bool NotRunning);

public sealed record PlatformInfo(
    string OsFamily,
    string OsDescription,
    string RuntimeVersion,
    string HubCoreVersion);

public interface IProcessSnapshotProvider
{
    Task<ProcessSnapshot?> GetLiveSnapshotAsync(int processId, string processName, CancellationToken ct = default);
}

public interface IProcessMutator
{
    Task ThrottleBelowNormalAsync(int processId, CancellationToken ct = default);
    Task TerminateAsync(int processId, CancellationToken ct = default);
}

public interface IPlatformServices
{
    PlatformInfo GetPlatformInfo();
    IProcessSnapshotProvider ProcessSnapshots { get; }
    IProcessMutator ProcessMutator { get; }
}
