using System.Diagnostics;
using SystemOptimizerHub.Abstractions;
using SystemOptimizerHub.Core.Models;
using SystemOptimizerHub.Core.Network;

namespace SystemOptimizerHub.Core.Tests;

public class NetworkKillPostStateTests
{
    [Fact]
    public async Task Unique_target_absent_after_reset_is_connection_reset()
    {
        var net = new FakeNetwork();
        var result = await Apply(net, KillRequest(), Before: [Row()], After: []);

        Assert.Equal("ConnectionReset", result.Outcome);
        Assert.Equal("The targeted connection is no longer present.", result.Message);
        Assert.Equal("Absent", result.PostState);
        Assert.Equal(1, net.Resets);
    }

    [Fact]
    public async Task Target_still_present_is_state_mismatch()
    {
        var net = new FakeNetwork();
        var row = Row();
        var result = await Apply(net, KillRequest(), Before: [row], After: [row]);

        Assert.Equal("StateMismatch", result.Outcome);
        Assert.Equal("The targeted connection is still present.", result.Message);
        Assert.Equal("Present", result.PostState);
        Assert.Equal(1, net.Resets);
    }

    [Fact]
    public async Task Post_snapshot_failure_is_state_unverified()
    {
        var net = new FakeNetwork();
        var result = await Apply(net, KillRequest(), Before: [Row()], After: null, FailAfter: true);

        Assert.Equal("StateUnverified", result.Outcome);
        Assert.Equal("The reset was requested, but the final connection state could not be confirmed.", result.Message);
        Assert.Equal("Unreadable", result.PostState);
        Assert.Equal(1, net.Resets);
    }

    [Fact]
    public async Task Target_absent_before_reset_is_not_connection_reset()
    {
        var net = new FakeNetwork();
        var result = await Apply(net, KillRequest(), Before: [], After: []);

        Assert.Equal("TargetAbsent", result.Outcome);
        Assert.Equal("The targeted connection was not present, so no reset was performed.", result.Message);
        Assert.Equal("AbsentBeforeAttempt", result.PostState);
        Assert.Equal(0, net.Resets);
    }

    [Fact]
    public async Task Similar_remote_ip_after_reset_does_not_keep_the_original_target()
    {
        var net = new FakeNetwork();
        var result = await Apply(
            net,
            KillRequest(),
            Before: [Row()],
            After: [Row(remote: "8.8.8.8:8443")]);

        Assert.Equal("ConnectionReset", result.Outcome);
        Assert.Equal("Absent", result.PostState);
        Assert.False(NetworkConnectionIdentity.SameConnection(
            Row(remote: "8.8.8.8:8443"), "192.168.1.5", 50000, "8.8.8.8", 443, 42));
    }

    [Fact]
    public void Different_remote_port_is_not_the_same_connection()
    {
        Assert.False(NetworkConnectionIdentity.SameConnection(
            Row(remote: "8.8.8.8:8443"), "192.168.1.5", 50000, "8.8.8.8", 443, 42));
        Assert.False(NetworkConnectionIdentity.SameConnection(
            Row(remote: "8.8.8.80:443"), "192.168.1.5", 50000, "8.8.8.8", 443, 42));
    }

    [Fact]
    public void Same_pid_with_different_endpoints_is_not_the_same_connection()
    {
        Assert.False(NetworkConnectionIdentity.SameConnection(
            Row(local: "10.0.0.9:40000", remote: "1.1.1.1:53"), "192.168.1.5", 50000, "8.8.8.8", 443, 42));
    }

    [Fact]
    public void Ipv4_and_ipv6_are_not_the_same_address()
    {
        Assert.False(NetworkConnectionIdentity.AddressEquals("8.8.8.8", "::ffff:8.8.8.8"));
        Assert.False(NetworkConnectionIdentity.SameConnection(
            Row(remote: "::ffff:8.8.8.8:443"), "192.168.1.5", 50000, "8.8.8.8", 443, 42));
        Assert.True(NetworkConnectionIdentity.AddressEquals("fe80::1", "FE80::1"));
    }

    [Fact]
    public async Task Multiple_matches_do_not_mutate()
    {
        var net = new FakeNetwork();
        var result = await Apply(net, KillRequest(), Before: [Row(), Row()], After: [Row(), Row()]);

        Assert.Equal("TargetAmbiguous", result.Outcome);
        Assert.Equal("The requested connection could not be uniquely identified, so nothing was changed.", result.Message);
        Assert.Equal(0, net.Resets);
    }

    [Fact]
    public async Task Endpoint_shared_by_two_pids_is_unique_when_the_request_names_one()
    {
        var net = new FakeNetwork();
        var result = await Apply(
            net,
            KillRequest(pid: 42),
            Before: [Row(pid: 42), Row(pid: 99)],
            After: [Row(pid: 99)]);

        Assert.Equal("ConnectionReset", result.Outcome);
        Assert.Equal(1, net.Resets);
    }

    [Fact]
    public async Task Endpoint_shared_by_two_pids_is_ambiguous_without_a_pid()
    {
        var net = new FakeNetwork();
        var result = await Apply(
            net,
            KillRequest(pid: 0),
            Before: [Row(pid: 42), Row(pid: 99)],
            After: []);

        Assert.Equal("TargetAmbiguous", result.Outcome);
        Assert.Equal(0, net.Resets);
    }

    [Fact]
    public async Task Dry_run_does_not_reset()
    {
        var net = new FakeNetwork();
        var request = KillRequest();
        request.DryRun = true;
        var result = await Apply(net, request, Before: [Row()], After: []);

        Assert.Equal("DryRunKillConnection", result.Outcome);
        Assert.Equal(0, net.Resets);
    }

    [Fact]
    public async Task Unreadable_snapshot_before_reset_does_not_mutate()
    {
        var net = new FakeNetwork();
        var result = await Apply(net, KillRequest(), Before: null, After: []);

        Assert.Equal("SnapshotUnavailable", result.Outcome);
        Assert.Equal("The current connections could not be read, so nothing was changed.", result.Message);
        Assert.Equal(0, net.Resets);
    }

    [Fact]
    public void Plan_rejects_remote_address_only()
    {
        var result = NetworkActionService.Plan(new NetworkActionRequest
        {
            Action = "KillConnection",
            RemoteAddress = "8.8.8.8",
            IUnderstandRisk = true
        }, authVerified: true, skipAuth: true);

        Assert.Equal("InvalidTarget", result.Outcome);
    }

    private static async Task<NetworkActionResult> Apply(
        FakeNetwork net,
        NetworkActionRequest request,
        IReadOnlyList<NetworkTcpMapRow>? Before,
        IReadOnlyList<NetworkTcpMapRow>? After,
        bool FailAfter = false)
    {
        var reads = 0;
        return await NetworkActionService.ApplyAsync(
            request,
            net,
            new NoProcessMutator(),
            authVerified: true,
            skipAuth: true,
            readTcpConnections: _ =>
            {
                reads++;
                if (reads == 1)
                    return Task.FromResult<IReadOnlyList<NetworkTcpMapRow>?>(Before);
                if (FailAfter)
                    return Task.FromResult<IReadOnlyList<NetworkTcpMapRow>?>(null);
                return Task.FromResult<IReadOnlyList<NetworkTcpMapRow>?>(After);
            });
    }

    private static NetworkActionRequest KillRequest(int pid = 42) => new()
    {
        Action = "KillConnection",
        LocalAddress = "192.168.1.5",
        LocalPort = 50000,
        RemoteAddress = "8.8.8.8",
        RemotePort = 443,
        PID = pid,
        IUnderstandRisk = true
    };

    private static NetworkTcpMapRow Row(
        string local = "192.168.1.5:50000",
        string remote = "8.8.8.8:443",
        int pid = 42) => new()
    {
        Local = local,
        Remote = remote,
        PID = pid,
        State = "Established",
        Source = "test"
    };

    private sealed class FakeNetwork : INetworkMutator
    {
        public int Resets { get; private set; }

        public Task ResetTcpConnectionAsync(
            string localAddress, int localPort, string remoteAddress, int remotePort, CancellationToken ct = default)
        {
            Resets++;
            return Task.CompletedTask;
        }

        public Task BlockRemoteIpAsync(string remoteAddress, string ruleName, CancellationToken ct = default) =>
            Task.CompletedTask;
    }

    private sealed class NoProcessMutator : IProcessMutator
    {
        public Task ThrottleBelowNormalAsync(Process handle, ProcessIdentity expectedIdentity, CancellationToken ct = default) =>
            throw new NotSupportedException();

        public Task TerminateAsync(int processId, CancellationToken ct = default) =>
            throw new NotSupportedException();

        public Task TerminateOpenProcessAsync(Process handle, ProcessIdentity expectedIdentity, CancellationToken ct = default) =>
            throw new NotSupportedException();
    }
}
