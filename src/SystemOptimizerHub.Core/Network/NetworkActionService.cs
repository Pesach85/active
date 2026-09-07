using SystemOptimizerHub.Abstractions;
using SystemOptimizerHub.Core.Models;

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
        CancellationToken ct = default)
    {
        var plan = Plan(request, authVerified, skipAuth);
        if (plan.Outcome is not ("DryRunKillConnection" or "DryRunBlockRemoteIp" or "DryRunTerminateProcess"))
            return plan;

        return request.Action switch
        {
            "KillConnection" => await ApplyKillAsync(request, mutator, rollbackDirectory, ct),
            "BlockRemoteIp" => await ApplyBlockIpAsync(request, mutator, rollbackDirectory, ct),
            "TerminateProcess" => await ApplyTerminateAsync(request, processMutator, ct),
            _ => plan
        };
    }

    private static NetworkActionResult PlanKillConnection(NetworkActionRequest request)
    {
        if (string.IsNullOrWhiteSpace(request.RemoteAddress) || request.LocalPort <= 0)
            return Result(request, "InvalidTarget", "KillConnection requires local/remote endpoint.");
        if (request.DryRun)
            return Result(request, "DryRunKillConnection", "Would reset TCP connection (admin required).");
        return Result(request, "ReadyToApply", "Kill connection approved for apply.");
    }

    private static NetworkActionResult PlanBlockRemoteIp(NetworkActionRequest request)
    {
        if (string.IsNullOrWhiteSpace(request.RemoteAddress))
            return Result(request, "InvalidTarget", "BlockRemoteIp requires RemoteAddress.");
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
        NetworkActionRequest request, INetworkMutator mutator, string? rollbackDir, CancellationToken ct)
    {
        string? rollback = null;
        if (!string.IsNullOrWhiteSpace(rollbackDir))
        {
            Directory.CreateDirectory(rollbackDir);
            rollback = Path.Combine(rollbackDir, $"network-kill-rollback-{DateTime.Now:yyyyMMdd-HHmmss}.json");
            await File.WriteAllTextAsync(rollback,
                System.Text.Json.JsonSerializer.Serialize(new
                {
                    SchemaVersion = "NetworkKillRollback.v1",
                    request.LocalAddress,
                    request.LocalPort,
                    request.RemoteAddress,
                    request.RemotePort,
                    request.PID
                }), ct);
        }

        await mutator.ResetTcpConnectionAsync(
            request.LocalAddress, request.LocalPort, request.RemoteAddress, request.RemotePort, ct);
        return Result(request, "ConnectionReset", "TCP connection reset attempted.", rollback);
    }

    private static async Task<NetworkActionResult> ApplyBlockIpAsync(
        NetworkActionRequest request, INetworkMutator mutator, string? rollbackDir, CancellationToken ct)
    {
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

        await mutator.BlockRemoteIpAsync(request.RemoteAddress, ruleName, ct);
        return Result(request, "RemoteIpBlocked", $"Outbound block rule created: {ruleName}", rollback);
    }

    private static async Task<NetworkActionResult> ApplyTerminateAsync(
        NetworkActionRequest request, IProcessMutator processMutator, CancellationToken ct)
    {
        await processMutator.TerminateAsync(request.PID, ct);
        return Result(request, "ProcessTerminated", $"Process PID={request.PID} terminated by operator HITL.");
    }

    private static NetworkActionResult Result(
        NetworkActionRequest request, string outcome, string message, string? rollback = null) =>
        new()
        {
            GeneratedAt = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss"),
            Action = request.Action,
            DryRun = request.DryRun,
            Outcome = outcome,
            Message = message,
            RollbackPath = rollback
        };
}
