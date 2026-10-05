using System.Text.Json;
using SystemOptimizerHub.Abstractions;
using SystemOptimizerHub.Core.Models;
using SystemOptimizerHub.Core.Resolution;

namespace SystemOptimizerHub.Core.Defender;

/// <summary>Port of apply-defender-extreme-necessity.ps1 (HITL gates + rollback JSON).</summary>
public static class DefenderExtremeNecessityApplyService
{
    private static readonly HashSet<string> ValidTiers = new(StringComparer.OrdinalIgnoreCase)
    {
        "TuneExclusions", "TemporaryRealtimeOff", "ExtremeServiceDisable"
    };

    private static readonly HashSet<string> ValidReasonCodes = new(StringComparer.OrdinalIgnoreCase)
    {
        "DevBuild", "EmergencyPerf", "ForensicCapture", "VendorSupport"
    };

    private static readonly JsonSerializerOptions RollbackJson = new()
    {
        WriteIndented = true,
        PropertyNameCaseInsensitive = true
    };

    public static async Task<DefenderExtremeApplyResult> ApplyAsync(
        DefenderExtremeNecessityEvaluation evaluation,
        DefenderExtremeApplyOptions options,
        IDefenderPolicyMutator mutator,
        Func<DefenderPlatformStatus> getPlatformStatus,
        CancellationToken ct = default)
    {
        if (!options.IUnderstandRisk)
            throw new InvalidOperationException("HITL gate: IUnderstandRisk must be true after reading evaluation blockers.");

        if (string.Equals(options.Tier, "ExtremeServiceDisable", StringComparison.OrdinalIgnoreCase)
            && !options.ConfirmExtremeDisable)
            throw new InvalidOperationException("ExtremeServiceDisable requires ConfirmExtremeDisable (second explicit gate).");

        if (!ValidTiers.Contains(options.Tier))
            throw new InvalidOperationException($"Unsupported tier: {options.Tier}");

        if (!ValidReasonCodes.Contains(options.ReasonCode))
            throw new InvalidOperationException($"Unsupported reason code: {options.ReasonCode}");

        if (!string.Equals(evaluation.RecommendedTier, options.Tier, StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidOperationException(
                $"Tier mismatch: evaluation recommends '{evaluation.RecommendedTier}' but you requested '{options.Tier}'.");
        }

        if (!evaluation.AllowedToProceed)
        {
            throw new InvalidOperationException(
                $"Evaluation blocked proceed. Blockers: {string.Join("; ", evaluation.Blockers)}");
        }

        var tier = ValidTiers.First(t => t.Equals(options.Tier, StringComparison.OrdinalIgnoreCase));
        var before = getPlatformStatus();
        var rollbackDir = options.RollbackDirectory ?? Path.GetTempPath();
        Directory.CreateDirectory(rollbackDir);
        var rollbackPath = Path.Combine(rollbackDir,
            $"defender-extreme-rollback-{DateTime.Now:yyyyMMdd-HHmmss}.json");

        var plannedPaths = new List<string>();
        var requestedPaths = new List<string>();
        var svcStates = new List<DefenderServiceStateDto>();
        var autoReenable = options.AutoReenableMinutes;

        switch (tier)
        {
            case "TuneExclusions":
                if (options.ExclusionPaths.Count < 1)
                    throw new InvalidOperationException("TuneExclusions requires at least one exclusion path.");
                requestedPaths.AddRange(options.ExclusionPaths);
                var known = await ReadExclusionsAsync(mutator, ct);
                if (known is null)
                {
                    return BuildResult(options, tier, rollbackPath: "", applied: [], after: null,
                        "PreStateUnavailable",
                        "The current Defender exclusion state could not be read, so no exclusion was changed.");
                }

                foreach (var path in requestedPaths)
                {
                    if (!DefenderExclusionPath.ListContains(known, path))
                        plannedPaths.Add(path);
                }
                break;

            case "TemporaryRealtimeOff":
                autoReenable = NormalizeReenableMinutes(autoReenable, 30, 60);
                break;

            case "ExtremeServiceDisable":
                autoReenable = NormalizeReenableMinutes(autoReenable, 60, 120);
                var svc = await mutator.GetWinDefendServiceStateAsync(ct);
                if (svc is null)
                {
                    throw new InvalidOperationException(
                        "Rollback preparation failed: WinDefend pre-state could not be read. No Defender mutation was performed.");
                }

                svcStates.Add(new DefenderServiceStateDto
                {
                    Name = svc.Name,
                    StartType = svc.StartType,
                    Status = svc.Status
                });
                break;
        }

        string? taskName = null;
        if (autoReenable > 0 && !options.DryRun)
        {
            if (string.IsNullOrWhiteSpace(options.RestoreScriptPath))
                throw new InvalidOperationException("RestoreScriptPath required for scheduled re-enable.");

            taskName = $"HubDefenderReenable-{DateTime.Now:yyyyMMddHHmmss}";
        }

        var rollback = new DefenderExtremeRollback
        {
            GeneratedAt = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss"),
            ReasonCode = options.ReasonCode,
            Tier = tier,
            DryRun = options.DryRun,
            Before = before,
            ExclusionPathsAdded = plannedPaths,
            ServiceStates = svcStates,
            ScheduledReenableMinutes = autoReenable,
            ScheduledTaskName = taskName
        };

        await CrashSafeApplyContract.WriteRollbackAsync(rollbackPath, rollback, ct);
        await VerifyRollbackReadableAsync(rollbackPath, tier, plannedPaths.Count, svcStates.Count, ct);

        if (CrashSafeApplyContract.StopAfterRollbackRequested())
        {
            return BuildResult(options, tier, rollbackPath, applied: [], after: null,
                "RollbackCheckpoint",
                $"Rollback written before mutate: {rollbackPath}");
        }

        var applied = new List<DefenderExtremeApplyAction>();
        switch (tier)
        {
            case "TuneExclusions":
                foreach (var path in requestedPaths)
                {
                    var alreadyPresent = !plannedPaths.Contains(path);
                    if (!options.DryRun && !alreadyPresent)
                    {
                        try
                        {
                            await mutator.AddExclusionPathAsync(path, ct);
                        }
                        catch (Exception ex)
                        {
                            applied.Add(new DefenderExtremeApplyAction
                            {
                                Action = "Add-MpPreference ExclusionPath",
                                Detail = path,
                                Applied = false
                            });
                            return BuildResult(options, tier, rollbackPath, applied, after: null,
                                "Failed",
                                $"The exclusion could not be applied: {ex.Message} Rollback={rollbackPath}");
                        }
                    }
                    applied.Add(new DefenderExtremeApplyAction
                    {
                        Action = "Add-MpPreference ExclusionPath",
                        Detail = alreadyPresent ? $"already present: {path}" : path,
                        Applied = !options.DryRun && !alreadyPresent
                    });
                }
                applied.Add(new DefenderExtremeApplyAction
                {
                    Action = "Guidance",
                    Detail = "Schedule full scan outside work hours via Windows Security or Set-MpPreference scan schedule.",
                    Applied = false
                });
                break;

            case "TemporaryRealtimeOff":
                if (!options.DryRun)
                    await mutator.SetRealtimeMonitoringAsync(false, ct);
                applied.Add(new DefenderExtremeApplyAction
                {
                    Action = "Set-MpPreference -DisableRealtimeMonitoring",
                    Detail = "true",
                    Applied = !options.DryRun
                });
                break;

            case "ExtremeServiceDisable":
                if (!options.DryRun)
                {
                    await mutator.StopWinDefendServiceAsync(ct);
                    await mutator.SetWinDefendStartupManualAsync(ct);
                }
                applied.Add(new DefenderExtremeApplyAction
                {
                    Action = "Stop-Service WinDefend + Manual start",
                    Detail = $"Re-enable within {autoReenable} min",
                    Applied = !options.DryRun
                });
                break;
        }

        if (options.DryRun)
        {
            return BuildResult(options, tier, rollbackPath, applied, after: null,
                "DryRunApplied",
                $"Defender apply tier={tier} rollback={rollbackPath}");
        }

        var after = getPlatformStatus();
        var (outcome, message) = await VerifyRequestedTierAsync(
            tier, after, mutator, rollbackPath, requestedPaths, ct);

        if (autoReenable > 0)
        {
            if (string.IsNullOrWhiteSpace(taskName) || string.IsNullOrWhiteSpace(options.RestoreScriptPath))
                throw new InvalidOperationException("Restore task was not prepared with the rollback artifact.");

            await mutator.RegisterRollbackReenableTaskAsync(
                rollbackPath, options.RestoreScriptPath, autoReenable, taskName, ct);
            applied.Add(new DefenderExtremeApplyAction
            {
                Action = "Register-ScheduledTask re-enable",
                Detail = taskName,
                Applied = true
            });
        }

        return BuildResult(options, tier, rollbackPath, applied, after, outcome, message);
    }

    private static async Task VerifyRollbackReadableAsync(
        string rollbackPath,
        string tier,
        int expectedExclusions,
        int expectedServiceStates,
        CancellationToken ct)
    {
        var json = await File.ReadAllTextAsync(rollbackPath, ct);
        var parsed = JsonSerializer.Deserialize<DefenderExtremeRollback>(json, RollbackJson);
        if (parsed is null
            || !string.Equals(parsed.SchemaVersion, "DefenderExtremeRollback.v1", StringComparison.Ordinal)
            || !string.Equals(parsed.Tier, tier, StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidOperationException(
                $"Rollback artifact is not readable: {rollbackPath}. No Defender mutation was performed.");
        }

        if (string.Equals(tier, "TuneExclusions", StringComparison.OrdinalIgnoreCase)
            && parsed.ExclusionPathsAdded.Count < expectedExclusions)
        {
            throw new InvalidOperationException(
                $"Rollback artifact is missing exclusion paths: {rollbackPath}. No Defender mutation was performed.");
        }

        if (string.Equals(tier, "ExtremeServiceDisable", StringComparison.OrdinalIgnoreCase)
            && parsed.ServiceStates.Count < expectedServiceStates)
        {
            throw new InvalidOperationException(
                $"Rollback artifact is missing WinDefend pre-state: {rollbackPath}. No Defender mutation was performed.");
        }
    }

    private static async Task<IReadOnlyList<string>?> ReadExclusionsAsync(
        IDefenderPolicyMutator mutator,
        CancellationToken ct)
    {
        try
        {
            return await mutator.TryGetExclusionPathsAsync(ct);
        }
        catch
        {
            return null;
        }
    }

    private static async Task<(string Outcome, string Message)> VerifyRequestedTierAsync(
        string tier,
        DefenderPlatformStatus after,
        IDefenderPolicyMutator mutator,
        string rollbackPath,
        IReadOnlyList<string> requestedExclusions,
        CancellationToken ct)
    {
        switch (tier)
        {
            case "TemporaryRealtimeOff":
                if (after.RealTimeProtectionEnabled is null)
                {
                    return ("StateUnverified",
                        $"RealTimeProtectionEnabled was not reported after TemporaryRealtimeOff. Applied withheld. Rollback={rollbackPath}");
                }

                if (after.RealTimeProtectionEnabled != false)
                {
                    return ("StateMismatch",
                        $"Real-time protection is still enabled after TemporaryRealtimeOff. Applied withheld. Rollback={rollbackPath}");
                }

                return ("Applied", $"Defender apply tier={tier} verified rollback={rollbackPath}");

            case "ExtremeServiceDisable":
                var svc = await mutator.GetWinDefendServiceStateAsync(ct);
                if (svc is null)
                {
                    return ("StateUnverified",
                        $"WinDefend post-state could not be read after ExtremeServiceDisable. Applied withheld. Rollback={rollbackPath}");
                }

                var stopped = svc.Status.Equals("Stopped", StringComparison.OrdinalIgnoreCase);
                var manual = svc.StartType.Equals("Manual", StringComparison.OrdinalIgnoreCase);
                if (!stopped || !manual)
                {
                    return ("StateMismatch",
                        $"WinDefend post-state is StartType={svc.StartType} Status={svc.Status}; expected Manual/Stopped. Applied withheld. Rollback={rollbackPath}");
                }

                return ("Applied", $"Defender apply tier={tier} verified rollback={rollbackPath}");

            default:
                IReadOnlyList<string>? actual;
                try
                {
                    actual = await mutator.TryGetExclusionPathsAsync(ct);
                }
                catch
                {
                    actual = null;
                }

                if (actual is null)
                {
                    return ("StateUnverified",
                        $"The exclusion command completed, but Windows did not provide enough state to confirm it. Rollback={rollbackPath}");
                }

                var missing = requestedExclusions
                    .Where(path => !DefenderExclusionPath.ListContains(actual, path))
                    .ToArray();
                if (missing.Length > 0)
                {
                    return ("StateMismatch",
                        $"The exclusion could not be confirmed. Missing: {string.Join("; ", missing)}. Rollback={rollbackPath}");
                }

                return ("Applied", "The exclusion is active.");
        }
    }

    private static DefenderExtremeApplyResult BuildResult(
        DefenderExtremeApplyOptions options,
        string tier,
        string rollbackPath,
        IReadOnlyList<DefenderExtremeApplyAction> applied,
        DefenderPlatformStatus? after,
        string outcome,
        string message) =>
        new()
        {
            GeneratedAt = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss"),
            Tier = tier,
            ReasonCode = options.ReasonCode,
            DryRun = options.DryRun,
            Applied = applied,
            RollbackPath = rollbackPath,
            After = after,
            Outcome = outcome,
            Message = message
        };

    private static int NormalizeReenableMinutes(int minutes, int defaultMinutes, int maxMinutes)
    {
        if (minutes < 1)
            minutes = defaultMinutes;
        if (minutes > maxMinutes)
            throw new InvalidOperationException($"Max duration is {maxMinutes} minutes.");
        return minutes;
    }
}
