using System.Diagnostics;
using System.Globalization;
using System.Net;
using System.Text.RegularExpressions;
using SystemOptimizerHub.Abstractions;
using SystemOptimizerHub.Core.Models;

namespace SystemOptimizerHub.Windows;

public static class WindowsNetworkProbeProvider
{
    private static readonly int[] TorPorts = [9050, 9051, 9150, 9151, 4443, 9001, 9030];
    private static readonly string[] TorPatterns = [".onion", "socks5", "obfs4", "TorBrowser", "tor.exe"];
    private static readonly Regex NetstatLine = new(
        @"^\s*TCP\s+(\S+)\s+(\S+)\s+(\S+)\s+(\d+)\s*$",
        RegexOptions.Compiled | RegexOptions.IgnoreCase);

    public static async Task<NetworkProbeCapture> CaptureAsync(
        bool includeMemoryScan = false,
        CancellationToken ct = default)
    {
        var capture = new NetworkProbeCapture
        {
            IsAdmin = WindowsDefenderStatusProvider.IsCurrentUserAdmin()
        };

        capture.NetstatTcp = ParseNetstat(await RunNetstatAsync("-ano -p tcp", ct));
        capture.PowerShellTcp = await CapturePowerShellTcpAsync(ct);
        capture.UdpEndpoints = await CaptureUdpAsync(ct);
        capture.DnsCache = await CaptureDnsCacheAsync(ct);
        capture.ProcessInfoByPid = await CaptureProcessInfoAsync(ct);
        capture.GhostPidAnomalies = BuildGhostPidAnomalies(capture.PowerShellTcp, capture.ProcessInfoByPid);
        capture.TorSurface = BuildTorIndicators(capture);
        if (includeMemoryScan)
            capture.MemoryNetworkScan = await CaptureMemoryHitsAsync(capture, ct);
        if (capture.IsAdmin)
            capture.AdminProbes = await CaptureAdminProbesAsync(ct);

        return capture;
    }

    private static async Task<string> RunNetstatAsync(string args, CancellationToken ct)
    {
        var psi = new ProcessStartInfo("netstat.exe", args)
        {
            RedirectStandardOutput = true,
            UseShellExecute = false,
            CreateNoWindow = true
        };
        using var proc = Process.Start(psi)!;
        var output = await proc.StandardOutput.ReadToEndAsync(ct);
        await proc.WaitForExitAsync(ct);
        return output;
    }

    internal static List<NetworkTcpMapRow> ParseNetstat(string output)
    {
        var rows = new List<NetworkTcpMapRow>();
        foreach (var line in output.Split('\n'))
        {
            var m = NetstatLine.Match(line.Trim());
            if (!m.Success) continue;
            rows.Add(new NetworkTcpMapRow
            {
                Local = m.Groups[1].Value,
                Remote = m.Groups[2].Value,
                State = m.Groups[3].Value,
                PID = int.Parse(m.Groups[4].Value, CultureInfo.InvariantCulture),
                Source = "netstat"
            });
        }
        return rows;
    }

    private static async Task<List<NetworkTcpMapRow>> CapturePowerShellTcpAsync(CancellationToken ct)
    {
        var script = @"
Get-NetTCPConnection -ErrorAction SilentlyContinue |
  Where-Object { $_.State -in @('Established','Listen','CloseWait','TimeWait') } |
  Select-Object -First 400 LocalAddress,LocalPort,RemoteAddress,RemotePort,State,OwningProcess |
  ConvertTo-Json -Compress
";
        var json = await RunPowerShellAsync(script, ct);
        if (string.IsNullOrWhiteSpace(json)) return [];
        try
        {
            using var doc = System.Text.Json.JsonDocument.Parse(json);
            var rows = new List<NetworkTcpMapRow>();
            var root = doc.RootElement;
            var items = root.ValueKind == System.Text.Json.JsonValueKind.Array ? root.EnumerateArray() : new[] { root }.AsEnumerable();
            foreach (var item in items)
            {
                var local = $"{item.GetProperty("LocalAddress").GetString()}:{item.GetProperty("LocalPort").GetInt32()}";
                var remote = $"{item.GetProperty("RemoteAddress").GetString()}:{item.GetProperty("RemotePort").GetInt32()}";
                rows.Add(new NetworkTcpMapRow
                {
                    Local = local,
                    Remote = remote,
                    State = item.GetProperty("State").GetString() ?? "",
                    PID = item.GetProperty("OwningProcess").GetInt32(),
                    Source = "Get-NetTCPConnection"
                });
            }
            return rows;
        }
        catch
        {
            return [];
        }
    }

    private static async Task<List<UdpEndpointRow>> CaptureUdpAsync(CancellationToken ct)
    {
        var script = @"
Get-NetUDPEndpoint -ErrorAction SilentlyContinue |
  Select-Object -First 200 LocalAddress,LocalPort,OwningProcess |
  ConvertTo-Json -Compress
";
        var json = await RunPowerShellAsync(script, ct);
        if (string.IsNullOrWhiteSpace(json)) return [];
        try
        {
            using var doc = System.Text.Json.JsonDocument.Parse(json);
            var rows = new List<UdpEndpointRow>();
            var root = doc.RootElement;
            var items = root.ValueKind == System.Text.Json.JsonValueKind.Array ? root.EnumerateArray() : new[] { root }.AsEnumerable();
            foreach (var item in items)
            {
                var pid = item.GetProperty("OwningProcess").GetInt32();
                rows.Add(new UdpEndpointRow
                {
                    Local = $"{item.GetProperty("LocalAddress").GetString()}:{item.GetProperty("LocalPort").GetInt32()}",
                    PID = pid,
                    ProcessName = TryGetProcessName(pid)
                });
            }
            return rows;
        }
        catch { return []; }
    }

    private static async Task<DnsCacheLayer> CaptureDnsCacheAsync(CancellationToken ct)
    {
        var script = @"
Get-DnsClientCache -ErrorAction SilentlyContinue |
  Select-Object -First 150 Entry,Name,Data |
  ConvertTo-Json -Compress
";
        var json = await RunPowerShellAsync(script, ct);
        var layer = new DnsCacheLayer();
        if (string.IsNullOrWhiteSpace(json)) return layer;
        try
        {
            using var doc = System.Text.Json.JsonDocument.Parse(json);
            var root = doc.RootElement;
            var items = root.ValueKind == System.Text.Json.JsonValueKind.Array ? root.EnumerateArray() : new[] { root }.AsEnumerable();
            foreach (var item in items)
            {
                var name = item.TryGetProperty("Entry", out var e) ? e.GetString() ?? "" :
                    item.TryGetProperty("Name", out var n) ? n.GetString() ?? "" : "";
                var data = item.TryGetProperty("Data", out var d) ? d.GetString() ?? "" : "";
                var tor = TorPatterns.Any(p => name.Contains(p, StringComparison.OrdinalIgnoreCase) ||
                    data.Contains(p, StringComparison.OrdinalIgnoreCase));
                layer.Entries.Add(new DnsCacheRow { Name = name, Data = data, TorRelated = tor });
                if (tor) layer.TorRelatedCount++;
            }
            layer.EntryCount = layer.Entries.Count;
        }
        catch { }
        return layer;
    }

    private static async Task<Dictionary<int, ProcessNetworkInfo>> CaptureProcessInfoAsync(CancellationToken ct)
    {
        var script = @"
Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
  Select-Object ProcessId,Name,ExecutablePath,CommandLine |
  ConvertTo-Json -Compress
";
        var json = await RunPowerShellAsync(script, ct);
        var map = new Dictionary<int, ProcessNetworkInfo>();
        if (string.IsNullOrWhiteSpace(json)) return map;
        try
        {
            using var doc = System.Text.Json.JsonDocument.Parse(json);
            var root = doc.RootElement;
            var items = root.ValueKind == System.Text.Json.JsonValueKind.Array ? root.EnumerateArray() : new[] { root }.AsEnumerable();
            foreach (var item in items)
            {
                var pid = item.GetProperty("ProcessId").GetInt32();
                double ram = 0;
                try
                {
                    using var proc = Process.GetProcessById(pid);
                    ram = Math.Round(proc.WorkingSet64 / (1024.0 * 1024.0), 1);
                }
                catch { }
                map[pid] = new ProcessNetworkInfo
                {
                    PID = pid,
                    Name = item.GetProperty("Name").GetString()?.Replace(".exe", "") ?? "?",
                    Path = item.TryGetProperty("ExecutablePath", out var p) ? p.GetString() ?? "" : "",
                    CommandLine = item.TryGetProperty("CommandLine", out var c) ? c.GetString() ?? "" : "",
                    RamMb = ram
                };
            }
        }
        catch { }
        return map;
    }

    private static List<GhostPidAnomaly> BuildGhostPidAnomalies(
        IReadOnlyList<NetworkTcpMapRow> tcp,
        IReadOnlyDictionary<int, ProcessNetworkInfo> procMap)
    {
        var anomalies = new List<GhostPidAnomaly>();
        foreach (var pid in tcp.Select(t => t.PID).Distinct())
        {
            if (pid == 0)
            {
                anomalies.Add(new GhostPidAnomaly { Kind = "SystemPidZero", Detail = "Connection owned by PID 0 (kernel)", Severity = "Info" });
                continue;
            }
            if (pid == 4)
            {
                anomalies.Add(new GhostPidAnomaly { Kind = "SystemPidFour", Detail = "Connection owned by PID 4 (System)", Severity = "Info" });
                continue;
            }
            if (!procMap.ContainsKey(pid))
            {
                anomalies.Add(new GhostPidAnomaly
                {
                    Kind = "GhostPid",
                    Detail = $"Active socket PID={pid} but process not visible",
                    Severity = "Critical"
                });
            }
        }
        return anomalies;
    }

    private static List<TorSurfaceIndicator> BuildTorIndicators(NetworkProbeCapture capture)
    {
        var list = new List<TorSurfaceIndicator>();
        foreach (var row in capture.PowerShellTcp.Concat(capture.NetstatTcp))
        {
            var localPort = ParsePort(row.Local);
            var remotePort = ParsePort(row.Remote);
            if (TorPorts.Contains(localPort) || TorPorts.Contains(remotePort))
            {
                list.Add(new TorSurfaceIndicator
                {
                    Kind = "TorPort",
                    Detail = $"Tor-related port activity {row.Local} -> {row.Remote} PID={row.PID}",
                    Severity = "High"
                });
            }
        }

        foreach (var (pid, info) in capture.ProcessInfoByPid)
        {
            if (info.Name.Contains("tor", StringComparison.OrdinalIgnoreCase))
            {
                list.Add(new TorSurfaceIndicator
                {
                    Kind = "TorProcess",
                    Detail = $"Tor-like process {info.Name} PID={pid}",
                    Severity = "High"
                });
            }
            if (TorPatterns.Any(p => info.CommandLine.Contains(p, StringComparison.OrdinalIgnoreCase)))
            {
                list.Add(new TorSurfaceIndicator
                {
                    Kind = "TorCommandLine",
                    Detail = $"Tor pattern in command line PID={pid}",
                    Severity = "Medium"
                });
            }
        }
        return list.DistinctBy(x => x.Detail).Take(30).ToList();
    }

    private static async Task<List<MemoryNetworkHit>> CaptureMemoryHitsAsync(
        NetworkProbeCapture capture, CancellationToken ct)
    {
        var hits = new List<MemoryNetworkHit>();
        var pids = capture.ProcessInfoByPid.Keys.Take(8);
        foreach (var pid in pids)
        {
            if (!capture.ProcessInfoByPid.TryGetValue(pid, out var info)) continue;
            var patterns = await ScanProcessStringsAsync(pid, ct);
            if (patterns.Count == 0) continue;
            hits.Add(new MemoryNetworkHit
            {
                PID = pid,
                ProcessName = info.Name,
                Severity = patterns.Any(p => p.Contains("onion", StringComparison.OrdinalIgnoreCase)) ? "High" : "Medium",
                MemoryNetworkHits = patterns
            });
        }
        return hits;
    }

    private static async Task<List<string>> ScanProcessStringsAsync(int pid, CancellationToken ct)
    {
        var script = $@"
$patterns = @('.onion','socks5','SOCKS5','TorBrowser','9050','9150')
try {{
  $p = Get-Process -Id {pid} -ErrorAction Stop
  $path = $p.Path
  if (-not $path) {{ '[]' ; return }}
  $bytes = [IO.File]::ReadAllBytes($path)
  $text = [Text.Encoding]::ASCII.GetString($bytes)
  $found = @()
  foreach ($pat in $patterns) {{ if ($text -match [regex]::Escape($pat)) {{ $found += $pat }} }}
  $found | ConvertTo-Json -Compress
}} catch {{ '[]' }}
";
        var json = await RunPowerShellAsync(script, ct);
        try
        {
            using var doc = System.Text.Json.JsonDocument.Parse(json);
            if (doc.RootElement.ValueKind == System.Text.Json.JsonValueKind.Array)
                return doc.RootElement.EnumerateArray().Select(e => e.GetString() ?? "").Where(s => s.Length > 0).ToList();
            var s = doc.RootElement.GetString();
            return string.IsNullOrWhiteSpace(s) ? [] : [s];
        }
        catch { return []; }
    }

    private static async Task<AdminProbeLayer> CaptureAdminProbesAsync(CancellationToken ct)
    {
        var layer = new AdminProbeLayer { Available = true, Notes = [] };
        try
        {
            var etwScript = @"
try {
  $q = New-Object System.Diagnostics.Eventing.Reader.EventLogQuery('Microsoft-Windows-TCPIP/Operational',[System.Diagnostics.Eventing.Reader.PathType]::LogName)
  $r = New-Object System.Diagnostics.Eventing.Reader.EventLogReader($q)
  $n = 0
  for ($i=0; $i -lt 50; $i++) { if ($null -eq $r.ReadEvent()) { break }; $n++ }
  $n
} catch { 0 }
";
            var etwOut = await RunPowerShellAsync(etwScript, ct);
            if (int.TryParse(etwOut.Trim(), out var ec)) layer.TcpIpEventCount = ec;
        }
        catch { layer.Notes.Add("ETW TCPIP probe skipped"); }

        try
        {
            var wfp = await RunProcessAsync("netsh.exe", "wfp show state", ct);
            layer.WfpFilterEstimate = wfp.Split('\n').Count(l =>
                l.Contains("filter", StringComparison.OrdinalIgnoreCase));
            layer.Notes.Add("WFP state captured via netsh (admin)");
        }
        catch { layer.Notes.Add("WFP probe skipped"); }

        return layer;
    }

    private static async Task<string> RunPowerShellAsync(string script, CancellationToken ct)
    {
        var exe = File.Exists(@"C:\Program Files\PowerShell\7\pwsh.exe")
            ? @"C:\Program Files\PowerShell\7\pwsh.exe"
            : "powershell.exe";
        return await RunProcessAsync(exe, $"-NoProfile -NonInteractive -Command \"{script.Replace("\"", "\\\"")}\"", ct);
    }

    private static async Task<string> RunProcessAsync(string file, string args, CancellationToken ct)
    {
        var psi = new ProcessStartInfo(file, args)
        {
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true
        };
        using var proc = Process.Start(psi)!;
        var output = await proc.StandardOutput.ReadToEndAsync(ct);
        await proc.WaitForExitAsync(ct);
        return output;
    }

    private static string TryGetProcessName(int pid)
    {
        try { return Process.GetProcessById(pid).ProcessName; }
        catch { return "?"; }
    }

    private static int ParsePort(string endpoint)
    {
        var idx = endpoint.LastIndexOf(':');
        return idx > 0 && int.TryParse(endpoint[(idx + 1)..], out var p) ? p : 0;
    }
}

internal sealed class WindowsNetworkMutator : INetworkMutator
{
    public async Task ResetTcpConnectionAsync(
        string localAddress, int localPort, string remoteAddress, int remotePort, CancellationToken ct = default)
    {
        var script = $@"
Reset-NetTCPConnection -LocalAddress '{localAddress}' -LocalPort {localPort} `
  -RemoteAddress '{remoteAddress}' -RemotePort {remotePort} -Confirm:$false -ErrorAction Stop
";
        await RunPowerShellAsync(script, ct);
    }

    public async Task BlockRemoteIpAsync(string remoteAddress, string ruleName, CancellationToken ct = default)
    {
        if (!IPAddress.TryParse(remoteAddress, out _))
            throw new ArgumentException($"Invalid remote IP: {remoteAddress}");
        var script = $@"
New-NetFirewallRule -DisplayName '{ruleName}' -Direction Outbound -Action Block `
  -RemoteAddress '{remoteAddress}' -ErrorAction Stop | Out-Null
";
        await RunPowerShellAsync(script, ct);
    }

    private static async Task RunPowerShellAsync(string script, CancellationToken ct)
    {
        var exe = File.Exists(@"C:\Program Files\PowerShell\7\pwsh.exe")
            ? @"C:\Program Files\PowerShell\7\pwsh.exe"
            : "powershell.exe";
        var psi = new ProcessStartInfo(exe, $"-NoProfile -NonInteractive -Command \"{script.Replace("\"", "\\\"")}\"")
        {
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true
        };
        using var proc = Process.Start(psi)!;
        var err = await proc.StandardError.ReadToEndAsync(ct);
        await proc.WaitForExitAsync(ct);
        if (proc.ExitCode != 0)
            throw new InvalidOperationException(string.IsNullOrWhiteSpace(err) ? "PowerShell network mutation failed" : err.Trim());
    }
}
