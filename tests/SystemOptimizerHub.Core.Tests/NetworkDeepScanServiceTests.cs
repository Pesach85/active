using SystemOptimizerHub.Abstractions;
using SystemOptimizerHub.Core.Models;
using SystemOptimizerHub.Core.Network;

namespace SystemOptimizerHub.Core.Tests;

public class NetworkTrustResolverTests
{
    [Theory]
    [InlineData("127.0.0.1", true)]
    [InlineData("10.0.0.5", true)]
    [InlineData("8.8.8.8", false)]
    public void Private_and_loopback_detection(string address, bool isPrivate)
    {
        Assert.Equal(isPrivate, NetworkTrustResolver.IsPrivate(address) || NetworkTrustResolver.IsLoopback(address));
    }

    [Fact]
    public void Catalog_process_gets_delegated_on_private_lan()
    {
        var (level, _, _) = NetworkTrustResolver.Resolve("10.0.0.2", 443, 50000, "Established", "MyApp", ["MyApp"]);
        Assert.Equal("T1_Delegated", level);
    }

    [Fact]
    public void Unknown_process_on_nonstandard_port_gets_t3()
    {
        var (level, _, _) = NetworkTrustResolver.Resolve("8.8.8.8", 5353, 50000, "Established", "mystery", []);
        Assert.Equal("T3_Unknown", level);
    }
}

public class NetworkDeepScanServiceTests
{
    [Fact]
    public void Ghost_pid_produces_critical_finding()
    {
        var capture = new NetworkProbeCapture
        {
            PowerShellTcp =
            [
                new NetworkTcpMapRow { Local = "192.168.1.5:50000", Remote = "8.8.8.8:443", State = "Established", PID = 99999 }
            ],
            GhostPidAnomalies =
            [
                new GhostPidAnomaly { Kind = "GhostPid", Detail = "Active socket PID=99999 but process not visible", Severity = "Critical" }
            ]
        };
        var result = NetworkDeepScanService.Scan(capture, []);
        Assert.Contains(result.Findings, f => f.Layer == "GhostPid" && f.Severity == "Critical");
        Assert.Equal("Investigate ghost PIDs immediately", result.Summary.RecommendedAction);
    }

    [Fact]
    public void Cross_source_diff_adds_high_finding()
    {
        var capture = new NetworkProbeCapture
        {
            NetstatTcp = [new NetworkTcpMapRow { Local = "1.1.1.1:1", Remote = "2.2.2.2:2", State = "Established", PID = 1 }],
            PowerShellTcp = []
        };
        var result = NetworkDeepScanService.Scan(capture, []);
        Assert.Contains(result.Findings, f => f.Layer == "CrossSourceDiff");
    }
}

public class NetworkActionServiceTests
{
    [Fact]
    public void Block_private_ip_denied()
    {
        var req = new NetworkActionRequest
        {
            Action = "BlockRemoteIp",
            RemoteAddress = "192.168.1.1",
            IUnderstandRisk = true,
            ConfirmPhrase = NetworkActionService.ConfirmBlockIp
        };
        var result = NetworkActionService.Plan(req, authVerified: true, skipAuth: true);
        Assert.Equal("BlockDenied", result.Outcome);
    }

    [Fact]
    public void Terminate_requires_confirm_phrase()
    {
        var req = new NetworkActionRequest
        {
            Action = "TerminateProcess",
            PID = 1234,
            IUnderstandRisk = true
        };
        var result = NetworkActionService.Plan(req, authVerified: true, skipAuth: true);
        Assert.Equal("ConfirmPhraseRequired", result.Outcome);
    }

    [Fact]
    public void Kill_connection_dry_run_ok()
    {
        var req = new NetworkActionRequest
        {
            Action = "KillConnection",
            LocalAddress = "192.168.1.5",
            LocalPort = 50000,
            RemoteAddress = "8.8.8.8",
            RemotePort = 443,
            IUnderstandRisk = true,
            DryRun = true
        };
        var result = NetworkActionService.Plan(req, authVerified: true, skipAuth: true);
        Assert.Equal("DryRunKillConnection", result.Outcome);
    }
}
