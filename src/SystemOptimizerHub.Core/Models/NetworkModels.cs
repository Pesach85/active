namespace SystemOptimizerHub.Core.Models;

public sealed class NetworkConnectionRow
{
    public string State { get; set; } = "";
    public string Local { get; set; } = "";
    public string Remote { get; set; } = "";
    public int PID { get; set; }
    public string ProcessName { get; set; } = "";
    public double RamMb { get; set; }
    public string TrustLevel { get; set; } = "";
    public string TrustReason { get; set; } = "";
    public string ImagePath { get; set; } = "";
    public string CommandLine { get; set; } = "";
}

public sealed class NetworkHiddenProcessRow
{
    public int PID { get; set; }
    public string Name { get; set; } = "";
    public double RamMb { get; set; }
    public int ExternalConnections { get; set; }
    public string TrustLevel { get; set; } = "";
    public string TrustReason { get; set; } = "";
}

public sealed class NetworkSummary
{
    public int TotalConnections { get; set; }
    public int Established { get; set; }
    public int Listen { get; set; }
    public int LoopbackOnly { get; set; }
    public int PrivateRemote { get; set; }
    public int PublicRemote { get; set; }
    public int UnknownTrustCount { get; set; }
    public int HiddenNetworkProcessCount { get; set; }
}

public sealed class NetworkTransparencySnapshot
{
    public string SchemaVersion { get; set; } = "NetworkTransparency.v1";
    public bool Available { get; set; } = true;
    public string? Error { get; set; }
    public NetworkSummary Summary { get; set; } = new();
    public List<NetworkConnectionRow> Connections { get; set; } = [];
    public List<NetworkConnectionRow> Listeners { get; set; } = [];
    public List<NetworkHiddenProcessRow> HiddenNetworkProcesses { get; set; } = [];
}

public sealed class NetworkTcpMapRow
{
    public string Local { get; set; } = "";
    public string Remote { get; set; } = "";
    public string State { get; set; } = "";
    public int PID { get; set; }
    public string Source { get; set; } = "";
}

public sealed class CrossSourceDiffLayer
{
    public int NetstatCount { get; set; }
    public int PowerShellCount { get; set; }
    public int AnomalyScore { get; set; }
    public List<NetworkTcpMapRow> OnlyInNetstat { get; set; } = [];
    public List<NetworkTcpMapRow> OnlyInPowerShell { get; set; } = [];
}

public sealed class UdpEndpointRow
{
    public string Local { get; set; } = "";
    public int PID { get; set; }
    public string ProcessName { get; set; } = "";
}

public sealed class DnsCacheRow
{
    public string Name { get; set; } = "";
    public string Data { get; set; } = "";
    public bool TorRelated { get; set; }
}

public sealed class DnsCacheLayer
{
    public int EntryCount { get; set; }
    public int TorRelatedCount { get; set; }
    public List<DnsCacheRow> Entries { get; set; } = [];
}

public sealed class TorSurfaceIndicator
{
    public string Kind { get; set; } = "";
    public string Detail { get; set; } = "";
    public string Severity { get; set; } = "Medium";
}

public sealed class GhostPidAnomaly
{
    public string Kind { get; set; } = "";
    public string Detail { get; set; } = "";
    public string Severity { get; set; } = "Info";
}

public sealed class MemoryNetworkHit
{
    public int PID { get; set; }
    public string ProcessName { get; set; } = "";
    public string Severity { get; set; } = "Medium";
    public List<string> MemoryNetworkHits { get; set; } = [];
}

public sealed class AdminProbeLayer
{
    public bool Available { get; set; }
    public int TcpIpEventCount { get; set; }
    public int WfpFilterEstimate { get; set; }
    public List<string> Notes { get; set; } = [];
}

public sealed class NetworkFinding
{
    public string Layer { get; set; } = "";
    public string Severity { get; set; } = "";
    public string Detail { get; set; } = "";
}

public sealed class NetworkDeepScanSummary
{
    public int FindingCount { get; set; }
    public int CriticalCount { get; set; }
    public int HighCount { get; set; }
    public int HiddenProcessCount { get; set; }
    public string RecommendedAction { get; set; } = "";
}

public sealed class NetworkDeepScanLayers
{
    public CrossSourceDiffLayer CrossSourceDiff { get; set; } = new();
    public List<UdpEndpointRow> UdpEndpoints { get; set; } = [];
    public DnsCacheLayer DnsCache { get; set; } = new();
    public List<TorSurfaceIndicator> TorSurface { get; set; } = [];
    public List<GhostPidAnomaly> GhostPidAnomalies { get; set; } = [];
    public List<MemoryNetworkHit> MemoryNetworkScan { get; set; } = [];
    public AdminProbeLayer? AdminProbes { get; set; }
}

public sealed class NetworkDeepScanResult
{
    public string SchemaVersion { get; set; } = "NetworkDeepScan.v1";
    public string GeneratedAt { get; set; } = "";
    public int DurationMs { get; set; }
    public bool AdminScan { get; set; }
    public NetworkTransparencySnapshot BaselineSnapshot { get; set; } = new();
    public NetworkDeepScanLayers Layers { get; set; } = new();
    public List<NetworkFinding> Findings { get; set; } = [];
    public NetworkDeepScanSummary Summary { get; set; } = new();
}

public sealed class NetworkActionRequest
{
    public string Action { get; set; } = "";
    public int PID { get; set; }
    public string ProcessName { get; set; } = "";
    public string LocalAddress { get; set; } = "";
    public int LocalPort { get; set; }
    public string RemoteAddress { get; set; } = "";
    public int RemotePort { get; set; }
    public bool DryRun { get; set; }
    public bool IUnderstandRisk { get; set; }
    public string? ConfirmPhrase { get; set; }
}

public sealed class NetworkActionResult
{
    public string SchemaVersion { get; set; } = "NetworkActionResult.v1";
    public string GeneratedAt { get; set; } = "";
    public string Action { get; set; } = "";
    public bool DryRun { get; set; }
    public string Outcome { get; set; } = "";
    public string Message { get; set; } = "";
    public string? RollbackPath { get; set; }
}

public sealed class NetworkProbeCapture
{
    public List<NetworkTcpMapRow> NetstatTcp { get; set; } = [];
    public List<NetworkTcpMapRow> PowerShellTcp { get; set; } = [];
    public List<UdpEndpointRow> UdpEndpoints { get; set; } = [];
    public DnsCacheLayer DnsCache { get; set; } = new();
    public List<TorSurfaceIndicator> TorSurface { get; set; } = [];
    public List<GhostPidAnomaly> GhostPidAnomalies { get; set; } = [];
    public List<MemoryNetworkHit> MemoryNetworkScan { get; set; } = [];
    public AdminProbeLayer? AdminProbes { get; set; }
    public Dictionary<int, ProcessNetworkInfo> ProcessInfoByPid { get; set; } = new();
    public bool IsAdmin { get; set; }
}

public sealed class ProcessNetworkInfo
{
    public int PID { get; set; }
    public string Name { get; set; } = "";
    public string Path { get; set; } = "";
    public string CommandLine { get; set; } = "";
    public double RamMb { get; set; }
}
