using System.Text.Json;
using SystemOptimizerHub.Abstractions;
using SystemOptimizerHub.Core.Models;

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

        var before = getPlatformStatus();
        var rollbackDir = options.RollbackDirectory ?? Path.GetTempPath();
        Directory.CreateDirectory(rollbackDir);
        var rollbackPath = Path.Combine(rollbackDir,
            $"defender-extreme-rollback-{DateTime.Now:yyyyMMdd-HHmmss}.json");

        var pathsAdded = new List<string>();
        var svcStates = new List<DefenderServiceStateDto>();
        var applied = new List<DefenderExtremeApplyAction>();
        var autoReenable = options.AutoReenableMinutes;
        string? taskName = null;

        switch (options.Tier)
        {
            case "TuneExclusions":
                if (options.ExclusionPaths.Count < 1)
                    throw new InvalidOperationException("TuneExclusions requires at least one exclusion path.");
                foreach (var path in options.ExclusionPaths)
                {
                    if (!options.DryRun)
                        await mutator.AddExclusionPathAsync(path, ct);
                    pathsAdded.Add(path);
                    applied.Add(new DefenderExtremeApplyAction
                    {
                        Action = "Add-MpPreference ExclusionPath",
                        Detail = path,
                        Applied = !options.DryRun
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
                autoReenable = NormalizeReenableMinutes(autoReenable, 30, 60);
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
                autoReenable = NormalizeReenableMinutes(autoReenable, 60, 120);
                var svc = await mutator.GetWinDefendServiceStateAsync(ct);
                if (svc is not null)
                {
                    svcStates.Add(new DefenderServiceStateDto
                    {
                        Name = svc.Name,
                        StartType = svc.StartType,
                        Status = svc.Status
                    });
                }
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

        if (autoReenable > 0 && !options.DryRun)
        {
            if (string.IsNullOrWhiteSpace(options.RestoreScriptPath))
                throw new InvalidOperationException("RestoreScriptPath required for scheduled re-enable.");

            taskName = $"HubDefenderReenable-{DateTime.Now:yyyyMMddHHmmss}";
            await mutator.RegisterRollbackReenableTaskAsync(
                rollbackPath, options.RestoreScriptPath, autoReenable, taskName, ct);
            applied.Add(new DefenderExtremeApplyAction
            {
                Action = "Register-ScheduledTask re-enable",
                Detail = taskName,
                Applied = true
            });
        }

        var rollback = new DefenderExtremeRollback
        {
            GeneratedAt = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss"),
            ReasonCode = options.ReasonCode,
            Tier = options.Tier,
            DryRun = options.DryRun,
            Before = before,
            ExclusionPathsAdded = pathsAdded,
            ServiceStates = svcStates,
            ScheduledReenableMinutes = autoReenable,
            ScheduledTaskName = taskName
        };

        await File.WriteAllTextAsync(rollbackPath, JsonSerializer.Serialize(rollback, new JsonSerializerOptions { WriteIndented = true }), ct);

        DefenderPlatformStatus? after = null;
        if (!options.DryRun)
            after = getPlatformStatus();

        return new DefenderExtremeApplyResult
        {
            GeneratedAt = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss"),
            Tier = options.Tier,
            ReasonCode = options.ReasonCode,
            DryRun = options.DryRun,
            Applied = applied,
            RollbackPath = rollbackPath,
            After = after,
            Outcome = options.DryRun ? "DryRunApplied" : "Applied",
            Message = $"Defender apply tier={options.Tier} rollback={rollbackPath}"
        };
    }

    private static int NormalizeReenableMinutes(int minutes, int defaultMinutes, int maxMinutes)
    {
        if (minutes < 1)
            minutes = defaultMinutes;
        if (minutes > maxMinutes)
            throw new InvalidOperationException($"Max duration is {maxMinutes} minutes.");
        return minutes;
    }
}
