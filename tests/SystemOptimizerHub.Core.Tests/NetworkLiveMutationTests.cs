using System.Diagnostics;
using SystemOptimizerHub.Abstractions;
using SystemOptimizerHub.Core.Models;
using SystemOptimizerHub.Core.Network;

namespace SystemOptimizerHub.Core.Tests;

public class NetworkLiveMutationTests
{
    [Fact]
    public async Task Block_proven_when_named_rule_matches_the_ip()
    {
        var net = new FakeNetwork();
        var result = await ApplyBlock(net, observe: name => Blocked(name, "8.8.8.8"));

        Assert.Equal("RemoteIpBlocked", result.Outcome);
        Assert.Equal("The remote address is now blocked.", result.Message);
        Assert.Equal("Blocked", result.PostState);
        Assert.Equal(1, net.Blocks);
    }

    [Fact]
    public async Task Block_command_success_without_the_rule_is_mismatch()
    {
        var net = new FakeNetwork();
        var result = await ApplyBlock(net, observe: name => new FirewallBlockObservation
        {
            Found = false,
            RuleName = name
        });

        Assert.Equal("StateMismatch", result.Outcome);
        Assert.Equal("The requested state was not reached.", result.Message);
        Assert.Equal("Unblocked", result.PostState);
        Assert.Equal(1, net.Blocks);
    }

    [Fact]
    public async Task Block_unreadable_post_state_is_unverified()
    {
        var net = new FakeNetwork();
        var result = await ApplyBlock(net, observe: _ => null);

        Assert.Equal("StateUnverified", result.Outcome);
        Assert.Equal("The action was requested, but the final state could not be confirmed.", result.Message);
        Assert.Equal(1, net.Blocks);
    }

    [Fact]
    public async Task Block_command_failure_is_block_failed()
    {
        var net = new FakeNetwork { ThrowBlock = true };
        var result = await ApplyBlock(net, observe: name => Blocked(name, "8.8.8.8"));

        Assert.Equal("BlockFailed", result.Outcome);
        Assert.Equal(0, net.Blocks);
    }

    [Fact]
    public async Task Block_rejects_a_network_and_does_not_mutate()
    {
        var net = new FakeNetwork();
        var result = await ApplyBlock(net, address: "8.8.8.0/24", observe: name => Blocked(name, "8.8.8.0/24"));

        Assert.Equal("InvalidTarget", result.Outcome);
        Assert.Equal(0, net.Blocks);
    }

    [Fact]
    public async Task Block_does_not_treat_a_different_rule_as_this_action()
    {
        var net = new FakeNetwork();
        var result = await ApplyBlock(net, observe: _ => Blocked("Hub-Block-other", "8.8.8.8"));

        Assert.Equal("StateMismatch", result.Outcome);
        Assert.Equal(1, net.Blocks);
    }

    [Fact]
    public async Task Block_dry_run_does_not_mutate()
    {
        var net = new FakeNetwork();
        var request = BlockRequest();
        request.DryRun = true;
        var result = await ApplyBlock(net, request, name => Blocked(name, "8.8.8.8"));

        Assert.Equal("DryRunBlockRemoteIp", result.Outcome);
        Assert.Equal(0, net.Blocks);
    }

    [Fact]
    public void Block_host_prefix_matches_and_a_different_ip_does_not()
    {
        Assert.True(FirewallBlockIdentity.RemoteAddressMatches("8.8.8.8/32", "8.8.8.8"));
        Assert.False(FirewallBlockIdentity.RemoteAddressMatches("8.8.8.9", "8.8.8.8"));
        Assert.False(FirewallBlockIdentity.RemoteAddressMatches("8.8.8.8/24", "8.8.8.8"));
        Assert.False(FirewallBlockIdentity.RemoteAddressMatches("::ffff:8.8.8.8", "8.8.8.8"));
    }

    [Fact]
    public async Task Terminate_when_process_is_absent_after_the_attempt()
    {
        var proc = new FakeProcess();
        var result = await ApplyTerminate(proc, Before: Alive(), After: Gone());

        Assert.Equal("ProcessTerminated", result.Outcome);
        Assert.Equal("The targeted process is no longer running.", result.Message);
        Assert.Equal("Absent", result.PostState);
        Assert.Equal(1, proc.Kills);
    }

    [Fact]
    public async Task Terminate_when_the_same_process_remains()
    {
        var proc = new FakeProcess();
        var alive = Alive();
        var result = await ApplyTerminate(proc, Before: alive, After: alive);

        Assert.Equal("StateMismatch", result.Outcome);
        Assert.Equal("The requested state was not reached.", result.Message);
        Assert.Equal("Present", result.PostState);
        Assert.Equal(1, proc.Kills);
    }

    [Fact]
    public async Task Terminate_post_read_failure_is_unverified()
    {
        var proc = new FakeProcess();
        var result = await ApplyTerminate(proc, Before: Alive(), After: null);

        Assert.Equal("StateUnverified", result.Outcome);
        Assert.Equal("The action was requested, but the final state could not be confirmed.", result.Message);
        Assert.Equal(1, proc.Kills);
    }

    [Fact]
    public async Task Terminate_command_failure_is_not_success()
    {
        var proc = new FakeProcess { ThrowKill = true };
        var result = await ApplyTerminate(proc, Before: Alive(), After: Gone());

        Assert.Equal("TerminateFailed", result.Outcome);
        Assert.Equal(0, proc.Kills);
    }

    [Fact]
    public async Task Terminate_already_absent_does_not_mutate()
    {
        var proc = new FakeProcess();
        var result = await ApplyTerminate(proc, Before: Gone(), After: Gone());

        Assert.Equal("ProcessNotRunning", result.Outcome);
        Assert.Equal("The targeted process was not running, so no termination was performed.", result.Message);
        Assert.Equal("AbsentBeforeAttempt", result.PostState);
        Assert.Equal(0, proc.Kills);
    }

    [Fact]
    public async Task Terminate_pid_reuse_is_identity_mismatch()
    {
        var proc = new FakeProcess();
        var result = await ApplyTerminate(
            proc,
            Before: Alive(),
            After: Alive(path: @"C:\Other\other.exe", ticks: 9999, name: "other"));

        Assert.Equal("PidIdentityMismatch", result.Outcome);
        Assert.Equal("The process that now uses this PID is not the process that was selected.", result.Message);
        Assert.Equal(1, proc.Kills);
    }

    [Fact]
    public async Task Terminate_rejects_a_process_without_path_or_start_time()
    {
        var proc = new FakeProcess();
        var result = await ApplyTerminate(proc, Before: Alive(path: "", ticks: 0), After: Gone());

        Assert.Equal("InvalidTarget", result.Outcome);
        Assert.Equal("The targeted process could not be uniquely identified, so nothing was changed.", result.Message);
        Assert.Equal(0, proc.Kills);
    }

    [Fact]
    public async Task Terminate_kills_the_verified_process_object_and_not_a_pid_lookup()
    {
        var proc = new FakeProcess();
        using var verified = new Process();
        using var other = new Process();
        var result = await ApplyTerminate(proc, Before: Alive(), After: Gone(), handle: verified);

        Assert.Equal("ProcessTerminated", result.Outcome);
        Assert.Same(verified, proc.Killed);
        Assert.NotSame(other, proc.Killed);
        Assert.Equal(1, proc.Kills);
        Assert.Equal(0, proc.PidKills);
    }

    [Fact]
    public async Task Pid_reuse_before_kill_does_not_terminate_the_replacement()
    {
        var proc = new FakeProcess();
        using var replacement = new Process();
        var result = await ApplyTerminate(
            proc,
            Before: Alive(),
            After: Gone(),
            openedSnapshot: Alive(path: @"C:\Other\other.exe", ticks: 9999, name: "other"),
            handle: replacement);

        Assert.Equal("PidIdentityMismatch", result.Outcome);
        Assert.Equal("The process at this PID is not the requested process, so nothing was changed.", result.Message);
        Assert.Null(proc.Killed);
        Assert.Equal(0, proc.Kills);
        Assert.Equal(0, proc.PidKills);
    }

    [Fact]
    public async Task Terminate_dry_run_does_not_mutate()
    {
        var proc = new FakeProcess();
        var request = TerminateRequest();
        request.DryRun = true;
        var result = await ApplyTerminate(proc, request, Alive(), Gone());

        Assert.Equal("DryRunTerminateProcess", result.Outcome);
        Assert.Equal(0, proc.Kills);
    }

    private static async Task<NetworkActionResult> ApplyBlock(
        FakeNetwork net,
        Func<string, FirewallBlockObservation?> observe,
        string address = "8.8.8.8")
    {
        var request = BlockRequest(address);
        return await ApplyBlock(net, request, observe);
    }

    private static Task<NetworkActionResult> ApplyBlock(
        FakeNetwork net,
        NetworkActionRequest request,
        Func<string, FirewallBlockObservation?> observe) =>
        NetworkActionService.ApplyAsync(
            request,
            net,
            new FakeProcess(),
            authVerified: true,
            skipAuth: true,
            readBlockRule: (name, _) => Task.FromResult(observe(name)));

    private static Task<NetworkActionResult> ApplyTerminate(
        FakeProcess proc,
        ProcessSnapshot? Before,
        ProcessSnapshot? After,
        ProcessSnapshot? openedSnapshot = null,
        Process? handle = null) =>
        ApplyTerminate(proc, TerminateRequest(), Before, After, openedSnapshot, handle);

    private static async Task<NetworkActionResult> ApplyTerminate(
        FakeProcess proc,
        NetworkActionRequest request,
        ProcessSnapshot? Before,
        ProcessSnapshot? After,
        ProcessSnapshot? openedSnapshot = null,
        Process? handle = null)
    {
        var reads = 0;
        return await NetworkActionService.ApplyAsync(
            request,
            new FakeNetwork(),
            proc,
            authVerified: true,
            skipAuth: true,
            readProcess: (_, _, _) =>
            {
                reads++;
                return Task.FromResult(reads == 1 ? Before : After);
            },
            openProcess: (_, _, _) =>
            {
                var snapshot = openedSnapshot ?? Before;
                if (snapshot is null)
                    return Task.FromResult<LiveProcessHandle?>(null);
                var target = handle ?? new Process();
                return Task.FromResult<LiveProcessHandle?>(new LiveProcessHandle(snapshot, target));
            });
    }

    private static NetworkActionRequest BlockRequest(string address = "8.8.8.8") => new()
    {
        Action = "BlockRemoteIp",
        RemoteAddress = address,
        IUnderstandRisk = true,
        ConfirmPhrase = NetworkActionService.ConfirmBlockIp
    };

    private static NetworkActionRequest TerminateRequest() => new()
    {
        Action = "TerminateProcess",
        PID = 42,
        ProcessName = "target",
        IUnderstandRisk = true,
        ConfirmPhrase = NetworkActionService.ConfirmTerminate
    };

    private static FirewallBlockObservation Blocked(string ruleName, string remote) => new()
    {
        Found = true,
        Enabled = true,
        RuleName = ruleName,
        RemoteAddress = remote,
        Direction = "Outbound",
        Action = "Block"
    };

    private static ProcessSnapshot Alive(
        string path = @"C:\App\target.exe",
        long ticks = 1000,
        string name = "target") =>
        new(42, name, 1, 0, true, "Normal", path, NotRunning: false, StartTimeUtcTicks: ticks);

    private static ProcessSnapshot Gone() =>
        new(42, "target", 0, 0, false, "", "", NotRunning: true, 0);

    private sealed class FakeNetwork : INetworkMutator
    {
        public int Blocks { get; private set; }
        public bool ThrowBlock { get; init; }

        public Task ResetTcpConnectionAsync(
            string localAddress, int localPort, string remoteAddress, int remotePort, CancellationToken ct = default) =>
            Task.CompletedTask;

        public Task BlockRemoteIpAsync(string remoteAddress, string ruleName, CancellationToken ct = default)
        {
            if (ThrowBlock)
                throw new InvalidOperationException("firewall failed");
            Blocks++;
            return Task.CompletedTask;
        }
    }

    private sealed class FakeProcess : IProcessMutator
    {
        public int Kills { get; private set; }
        public bool ThrowKill { get; init; }

        public Task ThrottleBelowNormalAsync(Process handle, ProcessIdentity expectedIdentity, CancellationToken ct = default) =>
            throw new NotSupportedException();

        public int PidKills { get; private set; }
        public Process? Killed { get; private set; }

        public Task TerminateAsync(int processId, CancellationToken ct = default)
        {
            PidKills++;
            return Task.CompletedTask;
        }

        public Task TerminateOpenProcessAsync(Process handle, ProcessIdentity expectedIdentity, CancellationToken ct = default)
        {
            if (ThrowKill)
                throw new InvalidOperationException("kill failed");
            Killed = handle;
            Kills++;
            return Task.CompletedTask;
        }
    }
}
