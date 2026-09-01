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

public sealed record DefenderServiceState(
    string Name,
    string StartType,
    string Status);

public interface IProcessSnapshotProvider
{
    Task<ProcessSnapshot?> GetLiveSnapshotAsync(int processId, string processName, CancellationToken ct = default);
}

public interface IProcessMutator
{
    Task ThrottleBelowNormalAsync(int processId, CancellationToken ct = default);
    Task TerminateAsync(int processId, CancellationToken ct = default);
}

/// <summary>Port of apply-defender-extreme-necessity.ps1 OS mutations (Windows Defender module).</summary>
public interface IDefenderPolicyMutator
{
    Task AddExclusionPathAsync(string path, CancellationToken ct = default);
    Task SetRealtimeMonitoringAsync(bool enabled, CancellationToken ct = default);
    Task<DefenderServiceState?> GetWinDefendServiceStateAsync(CancellationToken ct = default);
    Task StopWinDefendServiceAsync(CancellationToken ct = default);
    Task SetWinDefendStartupManualAsync(CancellationToken ct = default);
    Task RegisterRollbackReenableTaskAsync(string rollbackJsonPath, string restoreScriptPath, int delayMinutes, string taskName, CancellationToken ct = default);
}

/// <summary>HITL network mutations (kill connection, block remote IP).</summary>
public interface INetworkMutator
{
    Task ResetTcpConnectionAsync(string localAddress, int localPort, string remoteAddress, int remotePort, CancellationToken ct = default);
    Task BlockRemoteIpAsync(string remoteAddress, string ruleName, CancellationToken ct = default);
}

public interface IPlatformServices
{
    PlatformInfo GetPlatformInfo();
    IProcessSnapshotProvider ProcessSnapshots { get; }
    IProcessMutator ProcessMutator { get; }
    IDefenderPolicyMutator DefenderPolicy { get; }
    INetworkMutator NetworkMutator { get; }
}
