using SystemOptimizerHub.Abstractions;
using SystemOptimizerHub.Core.Catalog;
using SystemOptimizerHub.Core.Models;

namespace SystemOptimizerHub.Core.Resolution;

/// <summary>Port of resolve-unknown-process.ps1 planning logic (dry-run / outcome only; no OS mutation).</summary>
public static class ResolutionExecutionService
{
    public static ProcessResolutionResult Plan(
        string action,
        bool dryRun,
        ProcessSnapshotInput snapshot,
        ProcessResolutionAdvisory advisory,
        ProcessNecessity catalogNecessity,
        ProcessResolutionConfig config,
        string? confirmPhrase = null,
        bool skipAuth = false,
        bool authVerified = false)
    {
        if (action == "Advisory")
        {
            return BuildResult(action, dryRun, snapshot, advisory, catalogNecessity,
                "AdvisoryOnly", "No action taken - review Advisory.RecommendedActionId");
        }

        if (snapshot.NotRunning)
        {
            return BuildResult(action, dryRun, snapshot, advisory, catalogNecessity,
                "ProcessNotRunning",
                "Process is not running - cannot apply this action. Refresh the list and pick a live process.");
        }

        if (!skipAuth && !authVerified)
        {
            return BuildResult(action, dryRun, snapshot, advisory, catalogNecessity,
                "AuthRequired", "HITL session expired or missing - unlock Control panel first.");
        }

        var block = ProcessNecessityResolver.TestCatalogActionBlocked(
            action switch
            {
                "ThrottleBelowNormal" => CatalogActionKind.ThrottleBelowNormal,
                "Terminate" => CatalogActionKind.Terminate,
                _ => CatalogActionKind.Observe
            },
            catalogNecessity);

        if (block.Blocked && action is "ThrottleBelowNormal" or "Terminate")
        {
            return BuildResult(action, dryRun, snapshot, advisory, catalogNecessity,
                "ActionBlocked", block.Reason);
        }

        return action switch
        {
            "Observe" => BuildResult(action, dryRun, snapshot, advisory, catalogNecessity,
                dryRun ? "DryRunObserve" : "Observed",
                "Operator chose observe - no system mutation."),
            "MarkWorkNecessary" => PlanMarkWorkNecessary(action, dryRun, snapshot, advisory, catalogNecessity, config, confirmPhrase),
            "MarkUnneeded" => BuildResult(action, dryRun, snapshot, advisory, catalogNecessity,
                dryRun ? "DryRunMarkUnneeded" : "MarkedUnneeded",
                "Recorded as unneeded - terminate still requires HITL."),
            "ThrottleBelowNormal" => PlanThrottle(action, dryRun, snapshot, advisory, catalogNecessity),
            "Terminate" => PlanTerminate(action, dryRun, snapshot, advisory, catalogNecessity, config, confirmPhrase),
            _ => BuildResult(action, dryRun, snapshot, advisory, catalogNecessity,
                "UnsupportedAction", $"Unsupported action: {action}")
        };
    }

    public static TerminateGateResult TestTerminateAllowed(string processName, ProcessResolutionConfig config)
    {
        var baseName = processName.Replace(".exe", "", StringComparison.OrdinalIgnoreCase);
        foreach (var n in config.NeverTerminateExact)
        {
            if (baseName.Equals(n, StringComparison.OrdinalIgnoreCase))
                return new TerminateGateResult(false, $"Process '{baseName}' is protected by resolution policy");
        }
        return new TerminateGateResult(true, "OK");
    }

    private static ProcessResolutionResult PlanMarkWorkNecessary(
        string action, bool dryRun, ProcessSnapshotInput snapshot, ProcessResolutionAdvisory advisory,
        ProcessNecessity catalogNecessity, ProcessResolutionConfig config, string? confirmPhrase)
    {
        var expected = config.ConfirmPhraseMarkNecessary;
        if (!string.IsNullOrWhiteSpace(expected) && confirmPhrase != expected)
        {
            return BuildResult(action, dryRun, snapshot, advisory, catalogNecessity,
                "ConfirmPhraseRequired", $"Confirm phrase required: {expected}");
        }

        return BuildResult(action, dryRun, snapshot, advisory, catalogNecessity,
            dryRun ? "DryRunMarkWorkNecessary" : "MarkedWorkNecessary",
            "Recorded operator decision - process treated as work-necessary.");
    }

    private static ProcessResolutionResult PlanThrottle(
        string action, bool dryRun, ProcessSnapshotInput snapshot, ProcessResolutionAdvisory advisory,
        ProcessNecessity catalogNecessity)
    {
        if (snapshot.Pid <= 0)
        {
            return BuildResult(action, dryRun, snapshot, advisory, catalogNecessity,
                "InvalidPid", "Throttle requires running process PID");
        }

        if (dryRun)
        {
            return BuildResult(action, dryRun, snapshot, advisory, catalogNecessity,
                "DryRunThrottle", "Would set BelowNormal priority");
        }

        return BuildResult(action, dryRun, snapshot, advisory, catalogNecessity,
            "HitlApplyRequired",
            "Live throttle requires hub resolve apply with password (HITL) - not enabled in plan mode.");
    }

    private static ProcessResolutionResult PlanTerminate(
        string action, bool dryRun, ProcessSnapshotInput snapshot, ProcessResolutionAdvisory advisory,
        ProcessNecessity catalogNecessity, ProcessResolutionConfig config, string? confirmPhrase)
    {
        var gate = TestTerminateAllowed(snapshot.ProcessName, config);
        if (!gate.Allowed)
        {
            return BuildResult(action, dryRun, snapshot, advisory, catalogNecessity,
                "TerminateBlocked", gate.Reason);
        }

        var expected = config.ConfirmPhraseTerminate;
        if (confirmPhrase != expected)
        {
            return BuildResult(action, dryRun, snapshot, advisory, catalogNecessity,
                "ConfirmPhraseRequired", $"Terminate requires -ConfirmPhrase '{expected}'");
        }

        if (snapshot.Pid <= 0)
        {
            return BuildResult(action, dryRun, snapshot, advisory, catalogNecessity,
                "InvalidPid", "Terminate requires running process PID");
        }

        if (dryRun)
        {
            return BuildResult(action, dryRun, snapshot, advisory, catalogNecessity,
                "DryRunTerminate", "Would stop process after HITL confirmation");
        }

        return BuildResult(action, dryRun, snapshot, advisory, catalogNecessity,
            "HitlApplyRequired",
            "Live terminate requires hub resolve apply with password (HITL) - not enabled in plan mode.");
    }

    /// <summary>Live apply (Windows mutator). Requires valid HITL session or skipAuth.</summary>
    public static async Task<ProcessResolutionResult> ApplyAsync(
        string action,
        ProcessSnapshotInput snapshot,
        ProcessResolutionAdvisory advisory,
        ProcessNecessity catalogNecessity,
        ProcessResolutionConfig config,
        IProcessMutator mutator,
        string? confirmPhrase = null,
        bool skipAuth = false,
        bool authVerified = false,
        string? rollbackDirectory = null,
        CancellationToken ct = default)
    {
        var check = Plan(action, dryRun: true, snapshot, advisory, catalogNecessity, config,
            confirmPhrase, skipAuth, authVerified);

        if (check.Outcome is not ("DryRunThrottle" or "DryRunTerminate" or "DryRunObserve"
            or "DryRunMarkWorkNecessary" or "DryRunMarkUnneeded"))
            return check;

        return action switch
        {
            "Observe" => BuildResult(action, false, snapshot, advisory, catalogNecessity,
                "Observed", "Operator chose observe - no system mutation."),
            "ThrottleBelowNormal" => await ApplyThrottleAsync(action, snapshot, advisory, catalogNecessity, mutator, rollbackDirectory, ct),
            "Terminate" => await ApplyTerminateAsync(action, snapshot, advisory, catalogNecessity, mutator, ct),
            _ => check
        };
    }

    private static async Task<ProcessResolutionResult> ApplyThrottleAsync(
        string action, ProcessSnapshotInput snapshot, ProcessResolutionAdvisory advisory,
        ProcessNecessity catalogNecessity, IProcessMutator mutator, string? rollbackDir, CancellationToken ct)
    {
        if (snapshot.Pid <= 0)
        {
            return BuildResult(action, false, snapshot, advisory, catalogNecessity,
                "InvalidPid", "Throttle requires running process PID");
        }

        string? rollbackPath = null;
        if (!string.IsNullOrWhiteSpace(rollbackDir))
        {
            Directory.CreateDirectory(rollbackDir);
            rollbackPath = Path.Combine(rollbackDir,
                $"process-resolution-rollback-{DateTime.Now:yyyyMMdd-HHmmss}.json");
            var rollback = new
            {
                SchemaVersion = "ProcessResolutionRollback.v1",
                snapshot.Pid,
                snapshot.ProcessName,
                PreviousPriority = "Unknown",
                Action = "ThrottleBelowNormal"
            };
            await File.WriteAllTextAsync(rollbackPath, System.Text.Json.JsonSerializer.Serialize(rollback), ct);
        }

        await mutator.ThrottleBelowNormalAsync(snapshot.Pid, ct);
        return BuildResult(action, false, snapshot, advisory, catalogNecessity,
            "Throttled",
            rollbackPath is null ? "Priority set BelowNormal" : $"Priority set BelowNormal. Rollback: {rollbackPath}",
            rollbackPath);
    }

    private static async Task<ProcessResolutionResult> ApplyTerminateAsync(
        string action, ProcessSnapshotInput snapshot, ProcessResolutionAdvisory advisory,
        ProcessNecessity catalogNecessity, IProcessMutator mutator, CancellationToken ct)
    {
        if (snapshot.Pid <= 0)
        {
            return BuildResult(action, false, snapshot, advisory, catalogNecessity,
                "InvalidPid", "Terminate requires running process PID");
        }

        await mutator.TerminateAsync(snapshot.Pid, ct);
        return BuildResult(action, false, snapshot, advisory, catalogNecessity,
            "Terminated", "Process terminated by operator HITL decision.");
    }

    private static ProcessResolutionResult BuildResult(
        string action, bool dryRun, ProcessSnapshotInput snapshot, ProcessResolutionAdvisory advisory,
        ProcessNecessity catalogNecessity, string outcome, string message, string? rollbackPath = null) =>
        new()
        {
            GeneratedAt = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss"),
            Action = action,
            DryRun = dryRun,
            Process = snapshot,
            Advisory = advisory,
            CatalogNecessity = catalogNecessity,
            Outcome = outcome,
            Message = message,
            RollbackPath = rollbackPath
        };
}

public sealed record TerminateGateResult(bool Allowed, string Reason);
