using SystemOptimizerHub.Core.Models;

namespace SystemOptimizerHub.Core.Network;

public static class NetworkDeepScanService
{
    public static NetworkDeepScanResult Scan(
        NetworkProbeCapture capture,
        IReadOnlyList<string> catalogNames,
        bool includeMemoryScan = false)
    {
        var started = DateTime.UtcNow;
        var baseline = NetworkTransparencyService.BuildSnapshot(capture, catalogNames, maxConnections: 250);
        var cross = BuildCrossDiff(capture.NetstatTcp, capture.PowerShellTcp);

        if (includeMemoryScan && capture.MemoryNetworkScan.Count == 0)
            capture.MemoryNetworkScan = [];

        var findings = new List<NetworkFinding>();
        if (cross.AnomalyScore > 0)
        {
            findings.Add(new NetworkFinding
            {
                Layer = "CrossSourceDiff",
                Severity = "High",
                Detail = $"netstat vs PS mismatch count={cross.AnomalyScore}"
            });
        }

        foreach (var g in capture.GhostPidAnomalies.Where(g => g.Severity == "Critical"))
        {
            findings.Add(new NetworkFinding { Layer = "GhostPid", Severity = "Critical", Detail = g.Detail });
        }

        foreach (var t in capture.TorSurface)
        {
            findings.Add(new NetworkFinding { Layer = "TorSurface", Severity = t.Severity, Detail = t.Detail });
        }

        if (capture.DnsCache.TorRelatedCount > 0)
        {
            findings.Add(new NetworkFinding
            {
                Layer = "DnsCache",
                Severity = "High",
                Detail = $"Tor-related DNS cache entries={capture.DnsCache.TorRelatedCount}"
            });
        }

        foreach (var m in capture.MemoryNetworkScan)
        {
            findings.Add(new NetworkFinding
            {
                Layer = "MemoryForensics",
                Severity = m.Severity,
                Detail = $"{m.ProcessName} PID={m.PID} hits={m.MemoryNetworkHits.Count}"
            });
        }

        if (capture.AdminProbes is { Available: true } admin)
        {
            if (admin.TcpIpEventCount > 0)
            {
                findings.Add(new NetworkFinding
                {
                    Layer = "EtwTcpIp",
                    Severity = "Medium",
                    Detail = $"Recent Microsoft-Windows-TCPIP events={admin.TcpIpEventCount}"
                });
            }
            if (admin.WfpFilterEstimate > 500)
            {
                findings.Add(new NetworkFinding
                {
                    Layer = "WfpState",
                    Severity = "Medium",
                    Detail = $"WFP filter estimate={admin.WfpFilterEstimate} (admin probe)"
                });
            }
            foreach (var note in admin.Notes)
            {
                findings.Add(new NetworkFinding { Layer = "AdminProbe", Severity = "Info", Detail = note });
            }
        }

        var critical = findings.Count(f => f.Severity == "Critical");
        var high = findings.Count(f => f.Severity == "High");

        return new NetworkDeepScanResult
        {
            GeneratedAt = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss"),
            DurationMs = (int)(DateTime.UtcNow - started).TotalMilliseconds,
            AdminScan = capture.IsAdmin,
            BaselineSnapshot = baseline,
            Layers = new NetworkDeepScanLayers
            {
                CrossSourceDiff = cross,
                UdpEndpoints = capture.UdpEndpoints,
                DnsCache = capture.DnsCache,
                TorSurface = capture.TorSurface,
                GhostPidAnomalies = capture.GhostPidAnomalies,
                MemoryNetworkScan = capture.MemoryNetworkScan,
                AdminProbes = capture.AdminProbes
            },
            Findings = findings,
            Summary = new NetworkDeepScanSummary
            {
                FindingCount = findings.Count,
                CriticalCount = critical,
                HighCount = high,
                HiddenProcessCount = baseline.Summary.HiddenNetworkProcessCount,
                RecommendedAction = critical > 0 ? "Investigate ghost PIDs immediately"
                    : high > 0 ? "Review Tor/hidden egress findings"
                    : "Continue periodic monitoring"
            }
        };
    }

    public static CrossSourceDiffLayer BuildCrossDiff(
        IReadOnlyList<NetworkTcpMapRow> netstat,
        IReadOnlyList<NetworkTcpMapRow> ps)
    {
        string Key(NetworkTcpMapRow r) => $"{r.Local}|{r.Remote}|{r.State}|{r.PID}";
        var netMap = netstat.ToDictionary(Key, r => r, StringComparer.Ordinal);
        var psMap = ps.ToDictionary(Key, r => r, StringComparer.Ordinal);
        var onlyNet = netMap.Keys.Except(psMap.Keys).Select(k => netMap[k]).ToList();
        var onlyPs = psMap.Keys.Except(netMap.Keys).Select(k => psMap[k]).ToList();
        return new CrossSourceDiffLayer
        {
            NetstatCount = netstat.Count,
            PowerShellCount = ps.Count,
            OnlyInNetstat = onlyNet,
            OnlyInPowerShell = onlyPs,
            AnomalyScore = onlyNet.Count + onlyPs.Count
        };
    }
}
