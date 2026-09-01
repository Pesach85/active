using SystemOptimizerHub.Core.Models;

namespace SystemOptimizerHub.Core.Network;

public static class NetworkTransparencyService
{
    public static NetworkTransparencySnapshot BuildSnapshot(
        NetworkProbeCapture capture,
        IReadOnlyList<string> catalogNames,
        int maxConnections = 120,
        int smallProcessRamMb = 120)
    {
        var snapshot = new NetworkTransparencySnapshot();
        try
        {
            var rows = BuildConnectionRows(capture, catalogNames);
            var established = rows.Where(r => r.State.Equals("Established", StringComparison.OrdinalIgnoreCase)).ToList();
            var listeners = rows.Where(r => r.State.Equals("Listen", StringComparison.OrdinalIgnoreCase)).ToList();

            snapshot.Summary = new NetworkSummary
            {
                TotalConnections = rows.Count,
                Established = established.Count,
                Listen = listeners.Count,
                LoopbackOnly = rows.Count(r => NetworkTrustResolver.IsLoopback(ParseHost(r.Remote))),
                PrivateRemote = rows.Count(r => NetworkTrustResolver.IsPrivate(ParseHost(r.Remote))),
                PublicRemote = rows.Count(r =>
                    !NetworkTrustResolver.IsPrivate(ParseHost(r.Remote)) &&
                    !NetworkTrustResolver.IsLoopback(ParseHost(r.Remote))),
                UnknownTrustCount = rows.Count(r => r.TrustLevel == "T3_Unknown"),
                HiddenNetworkProcessCount = 0
            };

            snapshot.Connections = established
                .OrderByDescending(r => r.TrustLevel == "T3_Unknown")
                .ThenByDescending(r => r.TrustLevel == "T2_Review")
                .Take(maxConnections)
                .ToList();

            snapshot.Listeners = listeners.Take(60).ToList();
            snapshot.HiddenNetworkProcesses = BuildHiddenProcesses(established, capture, smallProcessRamMb);
            snapshot.Summary.HiddenNetworkProcessCount = snapshot.HiddenNetworkProcesses.Count;
            snapshot.Available = true;
        }
        catch (Exception ex)
        {
            snapshot.Available = false;
            snapshot.Error = ex.Message;
        }

        return snapshot;
    }

    private static List<NetworkConnectionRow> BuildConnectionRows(
        NetworkProbeCapture capture,
        IReadOnlyList<string> catalogNames)
    {
        var source = capture.PowerShellTcp.Count > 0 ? capture.PowerShellTcp : capture.NetstatTcp;
        var rows = new List<NetworkConnectionRow>();
        foreach (var c in source)
        {
            if (c.Local.Contains(':') || c.Remote.Contains(':')) continue;
            capture.ProcessInfoByPid.TryGetValue(c.PID, out var pinfo);
            var procName = pinfo?.Name ?? "?";
            var trust = NetworkTrustResolver.Resolve(
                ParseHost(c.Remote), ParsePort(c.Remote), ParsePort(c.Local), c.State, procName, catalogNames);
            rows.Add(new NetworkConnectionRow
            {
                State = c.State,
                Local = c.Local,
                Remote = c.Remote,
                PID = c.PID,
                ProcessName = procName,
                RamMb = pinfo?.RamMb ?? 0,
                TrustLevel = trust.Level,
                TrustReason = trust.Reason,
                ImagePath = pinfo?.Path ?? "",
                CommandLine = pinfo?.CommandLine ?? ""
            });
        }
        return rows;
    }

    private static List<NetworkHiddenProcessRow> BuildHiddenProcesses(
        IReadOnlyList<NetworkConnectionRow> established,
        NetworkProbeCapture capture,
        int smallProcessRamMb)
    {
        var byPid = established
            .Where(r => r.TrustLevel is "T3_Unknown" or "T2_Review")
            .GroupBy(r => r.PID)
            .Select(g =>
            {
                var first = g.First();
                var ext = g.Count(x => !NetworkTrustResolver.IsPrivate(ParseHost(x.Remote)));
                return new NetworkHiddenProcessRow
                {
                    PID = g.Key,
                    Name = first.ProcessName,
                    RamMb = first.RamMb,
                    ExternalConnections = ext,
                    TrustLevel = first.TrustLevel,
                    TrustReason = first.TrustReason
                };
            })
            .Where(h => h.RamMb <= smallProcessRamMb || string.IsNullOrWhiteSpace(
                capture.ProcessInfoByPid.GetValueOrDefault(h.PID)?.Path))
            .Take(20)
            .ToList();
        return byPid;
    }

    private static string ParseHost(string endpoint)
    {
        var idx = endpoint.LastIndexOf(':');
        return idx > 0 ? endpoint[..idx] : endpoint;
    }

    private static int ParsePort(string endpoint)
    {
        var idx = endpoint.LastIndexOf(':');
        return idx > 0 && int.TryParse(endpoint[(idx + 1)..], out var p) ? p : 0;
    }
}
