using SystemOptimizerHub.Abstractions;
using SystemOptimizerHub.Core.Models;
using SystemOptimizerHub.Core.Resolution;

namespace SystemOptimizerHub.Core.Network;

public static class NetworkActionService
{
    public const string ConfirmTerminate = "TERMINATE-NETWORK-PROCESS";
    public const string ConfirmBlockIp = "BLOCK-REMOTE-IP";

    public static NetworkActionResult Plan(
        NetworkActionRequest request,
        bool authVerified,
        bool skipAuth = false)
    {
        if (!request.IUnderstandRisk)
        {
            return Result(request, "RiskAckRequired",
                "HITL gate: set IUnderstandRisk after reviewing connection context.");
        }

        if (!skipAuth && !authVerified)
        {
            return Result(request, "AuthRequired",
                "HITL session expired or missing - unlock Control panel first.");
        }

        return request.Action switch
        {
            "KillConnection" => PlanKillConnection(request),
            "BlockRemoteIp" => PlanBlockRemoteIp(request),
            "TerminateProcess" => PlanTerminateProcess(request),
            _ => Result(request, "UnsupportedAction", $"Unsupported network action: {request.Action}")
        };
    }

    public static async Task<NetworkActionResult> ApplyAsync(
        NetworkActionRequest request,
        INetworkMutator mutator,
        IProcessMutator processMutator,
        bool authVerified,
        bool skipAuth = false,
        string? rollbackDirectory = null,
        Func<CancellationToken, Task<IReadOnlyList<NetworkTcpMapRow>?>>? readTcpConnections = null,
        Func<string, CancellationToken, Task<FirewallBlockObservation?>>? readBlockRule = null,
        Func<int, string, CancellationToken, Task<ProcessSnapshot?>>? readProcess = null,
        Func<int, string, CancellationToken, Task<LiveProcessHandle?>>? openProcess = null,
        CancellationToken ct = default)
    {
        var plan = Plan(request, authVerified, skipAuth);
        if (request.DryRun || plan.Outcome is not "ReadyToApply")
            return plan;

        if (request.Action == "KillConnection")
            return await ApplyKillAsync(request, mutator, readTcpConnections, rollbackDirectory, ct);
        if (request.Action == "BlockRemoteIp")
            return await ApplyBlockIpAsync(request, mutator, readBlockRule, rollbackDirectory, ct);
        if (request.Action == "TerminateProcess")
            return await ApplyTerminateAsync(request, processMutator, readProcess, openProcess, ct);
        return plan;
    }

    private static NetworkActionResult PlanKillConnection(NetworkActionRequest request)
    {
        if (string.IsNullOrWhiteSpace(request.LocalAddress)
            || string.IsNullOrWhiteSpace(request.RemoteAddress)
            || request.LocalPort <= 0
            || request.RemotePort <= 0)
            return Result(request, "InvalidTarget", "KillConnection requires local and remote address and port.");
        if (request.DryRun)
            return Result(request, "DryRunKillConnection", "Would reset TCP connection (admin required).");
        return Result(request, "ReadyToApply", "Kill connection approved for apply.");
    }

    private static NetworkActionResult PlanBlockRemoteIp(NetworkActionRequest request)
    {
        if (!FirewallBlockIdentity.IsSingleIp(request.RemoteAddress))
            return Result(request, "InvalidTarget", "BlockRemoteIp requires one remote IP address.");
        if (NetworkTrustResolver.IsLoopback(request.RemoteAddress) || NetworkTrustResolver.IsPrivate(request.RemoteAddress))
            return Result(request, "BlockDenied", "Refusing to block loopback/private addresses.");
        if (request.ConfirmPhrase != ConfirmBlockIp)
            return Result(request, "ConfirmPhraseRequired", $"Block IP requires ConfirmPhrase '{ConfirmBlockIp}'.");
        if (request.DryRun)
            return Result(request, "DryRunBlockRemoteIp", $"Would block outbound to {request.RemoteAddress}.");
        return Result(request, "ReadyToApply", "Block IP approved for apply.");
    }

    private static NetworkActionResult PlanTerminateProcess(NetworkActionRequest request)
    {
        if (request.PID <= 0)
            return Result(request, "InvalidPid", "TerminateProcess requires running PID.");
        if (request.ConfirmPhrase != ConfirmTerminate)
            return Result(request, "ConfirmPhraseRequired", $"Terminate requires ConfirmPhrase '{ConfirmTerminate}'.");
        if (request.DryRun)
            return Result(request, "DryRunTerminateProcess", $"Would terminate PID={request.PID} ({request.ProcessName}).");
        return Result(request, "ReadyToApply", "Terminate approved for apply.");
    }

    private static async Task<NetworkActionResult> ApplyKillAsync(
        NetworkActionRequest request,
        INetworkMutator mutator,
        Func<CancellationToken, Task<IReadOnlyList<NetworkTcpMapRow>?>>? readTcpConnections,
        string? rollbackDir,
        CancellationToken ct)
    {
        if (readTcpConnections is null)
        {
            return Result(request, "SnapshotUnavailable",
                "The current connections could not be read, so nothing was changed.",
                postState: "UnreadableBeforeAttempt");
        }

        var before = await ReadTcpAsync(readTcpConnections, ct);
        if (before is null)
        {
            return Result(request, "SnapshotUnavailable",
                "The current connections could not be read, so nothing was changed.",
                postState: "UnreadableBeforeAttempt");
        }

        int? requestedPid = request.PID > 0 ? request.PID : null;
        var matches = NetworkConnectionIdentity.Find(
            before, request.LocalAddress, request.LocalPort, request.RemoteAddress, request.RemotePort, requestedPid);
        if (matches.Count == 0)
        {
            return Result(request, "TargetAbsent",
                "The targeted connection was not present, so no reset was performed.",
                postState: "AbsentBeforeAttempt");
        }

        if (matches.Count != 1)
        {
            return Result(request, "TargetAmbiguous",
                "The requested connection could not be uniquely identified, so nothing was changed.",
                postState: "Ambiguous");
        }

        var target = matches[0];
        if (!NetworkConnectionIdentity.TryParseEndpoint(target.Local, out var localAddress, out var localPort)
            || !NetworkConnectionIdentity.TryParseEndpoint(target.Remote, out var remoteAddress, out var remotePort))
        {
            return Result(request, "TargetAmbiguous",
                "The requested connection could not be uniquely identified, so nothing was changed.",
                postState: "Ambiguous");
        }

        var targetPid = target.PID;
        var rollback = await WriteKillRollbackAsync(
            rollbackDir, localAddress, localPort, remoteAddress, remotePort, targetPid, ct);

        try
        {
            await mutator.ResetTcpConnectionAsync(localAddress, localPort, remoteAddress, remotePort, ct);
        }
        catch (InvalidOperationException)
        {
            return Result(request, "ResetFailed",
                "The connection reset command failed, so the final connection state was not confirmed.",
                rollback, "CommandFailed");
        }

        var after = await ReadTcpAsync(readTcpConnections, ct);
        if (after is null)
        {
            return Result(request, "StateUnverified",
                "The reset was requested, but the final connection state could not be confirmed.",
                rollback, "Unreadable");
        }

        var stillPresent = NetworkConnectionIdentity.Find(
            after, localAddress, localPort, remoteAddress, remotePort, targetPid);
        if (stillPresent.Count == 0)
        {
            // Absence after the attempt. This does not prove the reset command caused it.
            return Result(request, "ConnectionReset",
                "The targeted connection is no longer present.",
                rollback, "Absent");
        }

        return Result(request, "StateMismatch",
            "The targeted connection is still present.",
            rollback, "Present");
    }

    private static async Task<IReadOnlyList<NetworkTcpMapRow>?> ReadTcpAsync(
        Func<CancellationToken, Task<IReadOnlyList<NetworkTcpMapRow>?>> readTcpConnections,
        CancellationToken ct)
    {
        try
        {
            return await readTcpConnections(ct);
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            return null;
        }
    }

    private static async Task<string?> WriteKillRollbackAsync(
        string? rollbackDir,
        string localAddress,
        int localPort,
        string remoteAddress,
        int remotePort,
        int pid,
        CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(rollbackDir))
            return null;

        Directory.CreateDirectory(rollbackDir);
        var rollback = Path.Combine(rollbackDir, $"network-kill-rollback-{DateTime.Now:yyyyMMdd-HHmmss}.json");
        await File.WriteAllTextAsync(rollback,
            System.Text.Json.JsonSerializer.Serialize(new
            {
                SchemaVersion = "NetworkKillRollback.v1",
                LocalAddress = localAddress,
                LocalPort = localPort,
                RemoteAddress = remoteAddress,
                RemotePort = remotePort,
                PID = pid
            }), ct);
        return rollback;
    }

    private static async Task<NetworkActionResult> ApplyBlockIpAsync(
        NetworkActionRequest request,
        INetworkMutator mutator,
        Func<string, CancellationToken, Task<FirewallBlockObservation?>>? readBlockRule,
        string? rollbackDir,
        CancellationToken ct)
    {
        if (readBlockRule is null)
        {
            return Result(request, "SnapshotUnavailable",
                "The firewall state could not be read, so no block was changed.",
                postState: "UnreadableBeforeAttempt");
        }

        var ruleName = $"Hub-Block-{request.RemoteAddress.Replace('.', '-')}-{DateTime.Now:yyyyMMddHHmmss}";
        string? rollback = null;
        if (!string.IsNullOrWhiteSpace(rollbackDir))
        {
            Directory.CreateDirectory(rollbackDir);
            rollback = Path.Combine(rollbackDir, $"network-block-rollback-{DateTime.Now:yyyyMMdd-HHmmss}.json");
            await File.WriteAllTextAsync(rollback,
                System.Text.Json.JsonSerializer.Serialize(new
                {
                    SchemaVersion = "NetworkBlockRollback.v1",
                    RuleName = ruleName,
                    request.RemoteAddress
                }), ct);
        }

        try
        {
            await mutator.BlockRemoteIpAsync(request.RemoteAddress, ruleName, ct);
        }
        catch (Exception ex) when (ex is InvalidOperationException or ArgumentException)
        {
            return Result(request, "BlockFailed",
                "The block command failed, so the final firewall state was not confirmed.",
                rollback, "CommandFailed");
        }

        FirewallBlockObservation? observed;
        try
        {
            observed = await readBlockRule(ruleName, ct);
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            observed = null;
        }

        if (observed is null)
        {
            return Result(request, "StateUnverified",
                "The action was requested, but the final state could not be confirmed.",
                rollback, "Unreadable");
        }

        if (!FirewallBlockIdentity.IsProvenBlock(observed, ruleName, request.RemoteAddress))
        {
            return Result(request, "StateMismatch",
                "The requested state was not reached.",
                rollback, "Unblocked");
        }

        return Result(request, "RemoteIpBlocked",
            "The remote address is now blocked.",
            rollback, "Blocked");
    }

    private static async Task<NetworkActionResult> ApplyTerminateAsync(
        NetworkActionRequest request,
        IProcessMutator processMutator,
        Func<int, string, CancellationToken, Task<ProcessSnapshot?>>? readProcess,
        Func<int, string, CancellationToken, Task<LiveProcessHandle?>>? openProcess,
        CancellationToken ct)
    {
        if (readProcess is null)
        {
            return Result(request, "InvalidTarget",
                "The targeted process could not be uniquely identified, so nothing was changed.");
        }

        ProcessSnapshot? before;
        try
        {
            before = await readProcess(request.PID, request.ProcessName ?? "", ct);
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            before = null;
        }

        if (before is null)
        {
            return Result(request, "InvalidTarget",
                "The targeted process could not be uniquely identified, so nothing was changed.",
                postState: "UnreadableBeforeAttempt");
        }

        if (before.NotRunning)
        {
            return Result(request, "ProcessNotRunning",
                "The targeted process was not running, so no termination was performed.",
                postState: "AbsentBeforeAttempt");
        }

        if (!ProcessIdentityIsSpecific(before))
        {
            return Result(request, "InvalidTarget",
                "The targeted process could not be uniquely identified, so nothing was changed.");
        }

        if (!RequestedNameMatches(request.ProcessName, before.ProcessName))
        {
            return Result(request, "PidIdentityMismatch",
                "The process at this PID is not the requested process, so nothing was changed.");
        }

        var path = before.ImagePath;
        var startTicks = before.StartTimeUtcTicks;
        if (!CrashSafeApplyContract.IdentityMatches(request.PID, startTicks, path, before))
        {
            return Result(request, "PidIdentityMismatch",
                "The process at this PID is not the requested process, so nothing was changed.");
        }

        if (openProcess is null)
        {
            return Result(request, "InvalidTarget",
                "The targeted process could not be uniquely identified, so nothing was changed.");
        }

        LiveProcessHandle? opened;
        try
        {
            opened = await openProcess(request.PID, request.ProcessName ?? "", ct);
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            opened = null;
        }

        if (opened is null
            || opened.Snapshot.NotRunning
            || !RequestedNameMatches(request.ProcessName, opened.Snapshot.ProcessName)
            || !CrashSafeApplyContract.IdentityMatches(request.PID, startTicks, path, opened.Snapshot))
        {
            opened?.Handle.Dispose();
            return Result(request, "PidIdentityMismatch",
                "The process at this PID is not the requested process, so nothing was changed.");
        }

        try
        {
            var expected = new ProcessIdentity(request.PID, before.ProcessName, path, startTicks);
            await processMutator.TerminateOpenProcessAsync(opened.Handle, expected, ct);
        }
        catch (Exception ex) when (ex is InvalidOperationException or ArgumentException)
        {
            return Result(request, "TerminateFailed",
                "The terminate command failed, so the final process state was not confirmed.",
                postState: "CommandFailed");
        }
        finally
        {
            opened.Handle.Dispose();
        }

        ProcessSnapshot? after;
        try
        {
            after = await readProcess(request.PID, request.ProcessName ?? "", ct);
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            after = null;
        }

        if (after is null)
        {
            return Result(request, "StateUnverified",
                "The action was requested, but the final state could not be confirmed.",
                postState: "Unreadable");
        }

        if (after.NotRunning)
        {
            return Result(request, "ProcessTerminated",
                "The targeted process is no longer running.",
                postState: "Absent");
        }

        if (!CrashSafeApplyContract.IdentityMatches(request.PID, startTicks, path, after))
        {
            return Result(request, "PidIdentityMismatch",
                "The process that now uses this PID is not the process that was selected.",
                postState: "IdentityMismatch");
        }

        return Result(request, "StateMismatch",
            "The requested state was not reached.",
            postState: "Present");
    }

    private static bool ProcessIdentityIsSpecific(ProcessSnapshot snapshot) =>
        snapshot.Pid > 0 &&
        snapshot.StartTimeUtcTicks > 0 &&
        !string.IsNullOrWhiteSpace(snapshot.ImagePath);

    private static bool RequestedNameMatches(string? requested, string? actual)
    {
        if (string.IsNullOrWhiteSpace(requested))
            return true;
        return string.Equals(BaseProcessName(requested), BaseProcessName(actual), StringComparison.OrdinalIgnoreCase);
    }

    private static string BaseProcessName(string? name)
    {
        var trimmed = (name ?? "").Trim();
        return trimmed.EndsWith(".exe", StringComparison.OrdinalIgnoreCase) ? trimmed[..^4] : trimmed;
    }

    private static NetworkActionResult Result(
        NetworkActionRequest request,
        string outcome,
        string message,
        string? rollback = null,
        string postState = "") =>
        new()
        {
            GeneratedAt = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss"),
            Action = request.Action,
            DryRun = request.DryRun,
            Outcome = outcome,
            Message = message,
            RollbackPath = rollback,
            PostState = postState
        };
}
