using System.Text.Json;
using SystemOptimizerHub.Abstractions;
using SystemOptimizerHub.Core.Catalog;
using SystemOptimizerHub.Core.Models;

namespace SystemOptimizerHub.Core.Resolution;

/// <summary>
/// Phase8 Crash-Safe Apply Contract: snapshot identity → write+flush rollback → re-verify → mutate.
/// </summary>
public static class CrashSafeApplyContract
{
    public const string RollbackSchema = "ProcessResolutionRollback.v1";
    public const string StopAfterRollbackEnv = "HUB_APPLY_STOP_AFTER_ROLLBACK";

    public static string NormalizePath(string? path) =>
        string.IsNullOrWhiteSpace(path) ? string.Empty : path.Trim();

    public static bool IdentityMatches(
        int expectedPid,
        long expectedStartTicks,
        string expectedImagePath,
        ProcessSnapshot? live)
    {
        if (live is null || live.NotRunning) return false;
        if (live.Pid != expectedPid) return false;
        // When StartTime is unavailable (0), fall back to image path + pid only.
        if (expectedStartTicks > 0 && live.StartTimeUtcTicks > 0 &&
            live.StartTimeUtcTicks != expectedStartTicks)
            return false;
        var expectedPath = NormalizePath(expectedImagePath);
        var livePath = NormalizePath(live.ImagePath);
        if (!string.IsNullOrEmpty(expectedPath) && !string.IsNullOrEmpty(livePath) &&
            !string.Equals(expectedPath, livePath, StringComparison.OrdinalIgnoreCase))
            return false;
        return true;
    }

    public static async Task WriteRollbackAsync(
        string rollbackPath,
        object rollbackPayload,
        CancellationToken ct)
    {
        var dir = Path.GetDirectoryName(rollbackPath);
        if (!string.IsNullOrEmpty(dir))
            Directory.CreateDirectory(dir);
        var json = JsonSerializer.Serialize(rollbackPayload, new JsonSerializerOptions { WriteIndented = true });
        await File.WriteAllTextAsync(rollbackPath, json, ct);
        // Force durable flush so a kill immediately after write still leaves an actionable file.
        await using (var fs = new FileStream(rollbackPath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
        {
            fs.Flush(flushToDisk: true);
        }
    }

    public static bool StopAfterRollbackRequested() =>
        string.Equals(Environment.GetEnvironmentVariable(StopAfterRollbackEnv), "1", StringComparison.Ordinal) ||
        string.Equals(Environment.GetEnvironmentVariable(StopAfterRollbackEnv), "true", StringComparison.OrdinalIgnoreCase);
}

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
        IProcessSnapshotProvider? snapshots = null,
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
            "ThrottleBelowNormal" => await ApplyThrottleAsync(
                action, snapshot, advisory, catalogNecessity, mutator, snapshots, rollbackDirectory, ct),
            "Terminate" => await ApplyTerminateAsync(
                action, snapshot, advisory, catalogNecessity, mutator, snapshots, rollbackDirectory, ct),
            _ => check
        };
    }

    private static async Task<ProcessResolutionResult> ApplyThrottleAsync(
        string action, ProcessSnapshotInput snapshot, ProcessResolutionAdvisory advisory,
        ProcessNecessity catalogNecessity, IProcessMutator mutator, IProcessSnapshotProvider? snapshots,
        string? rollbackDir, CancellationToken ct)
    {
        if (snapshot.Pid <= 0)
        {
            return BuildResult(action, false, snapshot, advisory, catalogNecessity,
                "InvalidPid", "Throttle requires running process PID");
        }

        var live = snapshots is null
            ? null
            : await snapshots.GetLiveSnapshotAsync(snapshot.Pid, snapshot.ProcessName, ct);
        if (snapshots is not null && (live is null || live.NotRunning))
        {
            return BuildResult(action, false, snapshot, advisory, catalogNecessity,
                "ProcessNotRunning", "Process disappeared before throttle apply.");
        }

        var pid = live?.Pid ?? snapshot.Pid;
        var processName = live?.ProcessName ?? snapshot.ProcessName;
        var imagePath = CrashSafeApplyContract.NormalizePath(live?.ImagePath);
        var startTicks = live?.StartTimeUtcTicks ?? 0;
        var previousPriority = string.IsNullOrWhiteSpace(live?.PriorityClass)
            ? "Unknown"
            : live!.PriorityClass;
        if (previousPriority == "Unknown" && snapshots is null)
        {
            // Fail closed for actionable rollback when we cannot read live priority.
            return BuildResult(action, false, snapshot, advisory, catalogNecessity,
                "SnapshotRequired", "Crash-safe throttle requires live process snapshot provider.");
        }

        string? rollbackPath = null;
        if (!string.IsNullOrWhiteSpace(rollbackDir))
        {
            Directory.CreateDirectory(rollbackDir);
            rollbackPath = Path.Combine(rollbackDir,
                $"process-resolution-rollback-{DateTime.Now:yyyyMMdd-HHmmss}.json");
            var rollback = new
            {
                SchemaVersion = CrashSafeApplyContract.RollbackSchema,
                PID = pid,
                ProcessName = processName,
                ImagePath = imagePath,
                StartTimeUtcTicks = startTicks,
                PreviousPriority = previousPriority,
                Action = "ThrottleBelowNormal"
            };
            await CrashSafeApplyContract.WriteRollbackAsync(rollbackPath, rollback, ct);
        }

        if (CrashSafeApplyContract.StopAfterRollbackRequested())
        {
            return BuildResult(action, false, snapshot, advisory, catalogNecessity,
                "RollbackCheckpoint",
                rollbackPath is null
                    ? "Rollback checkpoint (no mutate)."
                    : $"Rollback written before mutate: {rollbackPath}",
                rollbackPath);
        }

        // Crash-safe throttle mutate requires a held OS handle from recheck through PriorityClass write.
        if (snapshots is null)
        {
            return BuildResult(action, false, snapshot, advisory, catalogNecessity,
                "SnapshotRequired", "Crash-safe throttle requires live process snapshot provider.",
                rollbackPath);
        }

        System.Diagnostics.Process? held = null;
        try
        {
            var heldLive = await snapshots.GetLiveSnapshotWithHandleAsync(pid, processName, ct);
            if (heldLive is null || heldLive.Snapshot.NotRunning)
            {
                return BuildResult(action, false, snapshot, advisory, catalogNecessity,
                    "ProcessNotRunning", "Process disappeared before throttle apply.",
                    rollbackPath);
            }

            held = heldLive.Handle;
            if (!CrashSafeApplyContract.IdentityMatches(pid, startTicks, imagePath, heldLive.Snapshot))
            {
                return BuildResult(action, false, snapshot, advisory, catalogNecessity,
                    "PidIdentityMismatch",
                    "Process identity changed between snapshot and mutate — aborting throttle.",
                    rollbackPath);
            }

            var expected = new ProcessIdentity(pid, processName, imagePath, startTicks);
            await mutator.ThrottleBelowNormalAsync(held, expected, ct);
        }
        catch (InvalidOperationException ex)
        {
            return BuildResult(action, false, snapshot, advisory, catalogNecessity,
                "PidIdentityMismatch",
                $"Throttle aborted (handle identity/exit): {ex.Message}",
                rollbackPath);
        }
        finally
        {
            held?.Dispose();
        }

        return BuildResult(action, false, snapshot, advisory, catalogNecessity,
            "Throttled",
            rollbackPath is null ? "Priority set BelowNormal" : $"Priority set BelowNormal. Rollback: {rollbackPath}",
            rollbackPath);
    }

    private static async Task<ProcessResolutionResult> ApplyTerminateAsync(
        string action, ProcessSnapshotInput snapshot, ProcessResolutionAdvisory advisory,
        ProcessNecessity catalogNecessity, IProcessMutator mutator, IProcessSnapshotProvider? snapshots,
        string? rollbackDir, CancellationToken ct)
    {
        if (snapshot.Pid <= 0)
        {
            return BuildResult(action, false, snapshot, advisory, catalogNecessity,
                "InvalidPid", "Terminate requires running process PID");
        }

        var live = snapshots is null
            ? null
            : await snapshots.GetLiveSnapshotAsync(snapshot.Pid, snapshot.ProcessName, ct);
        if (snapshots is not null && (live is null || live.NotRunning))
        {
            return BuildResult(action, false, snapshot, advisory, catalogNecessity,
                "ProcessNotRunning", "Process disappeared before terminate apply.");
        }

        var pid = live?.Pid ?? snapshot.Pid;
        var processName = live?.ProcessName ?? snapshot.ProcessName;
        var imagePath = CrashSafeApplyContract.NormalizePath(live?.ImagePath);
        var startTicks = live?.StartTimeUtcTicks ?? 0;

        string? rollbackPath = null;
        if (!string.IsNullOrWhiteSpace(rollbackDir))
        {
            Directory.CreateDirectory(rollbackDir);
            rollbackPath = Path.Combine(rollbackDir,
                $"process-resolution-rollback-{DateTime.Now:yyyyMMdd-HHmmss}.json");
            var rollback = new
            {
                SchemaVersion = CrashSafeApplyContract.RollbackSchema,
                PID = pid,
                ProcessName = processName,
                ImagePath = imagePath,
                StartTimeUtcTicks = startTicks,
                PreviousPriority = live?.PriorityClass ?? "Unknown",
                Action = "Terminate",
                Note = "Terminate is irreversible; rollback records identity evidence only."
            };
            await CrashSafeApplyContract.WriteRollbackAsync(rollbackPath, rollback, ct);
        }

        if (CrashSafeApplyContract.StopAfterRollbackRequested())
        {
            return BuildResult(action, false, snapshot, advisory, catalogNecessity,
                "RollbackCheckpoint",
                rollbackPath is null
                    ? "Rollback checkpoint (no mutate)."
                    : $"Rollback written before mutate: {rollbackPath}",
                rollbackPath);
        }

        if (snapshots is not null)
        {
            var recheck = await snapshots.GetLiveSnapshotAsync(pid, processName, ct);
            if (!CrashSafeApplyContract.IdentityMatches(pid, startTicks, imagePath, recheck))
            {
                return BuildResult(action, false, snapshot, advisory, catalogNecessity,
                    "PidIdentityMismatch",
                    "Process identity changed between snapshot and mutate — aborting terminate.",
                    rollbackPath);
            }
        }

        await mutator.TerminateAsync(pid, ct);
        return BuildResult(action, false, snapshot, advisory, catalogNecessity,
            "Terminated", "Process terminated by operator HITL decision.", rollbackPath);
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
