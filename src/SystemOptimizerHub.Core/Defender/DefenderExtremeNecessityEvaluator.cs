using SystemOptimizerHub.Core.Models;

namespace SystemOptimizerHub.Core.Defender;

/// <summary>Port of Get-DefenderExtremeNecessityEvaluation (read-only).</summary>
public static class DefenderExtremeNecessityEvaluator
{
    public static DefenderExtremeNecessityEvaluation Evaluate(
        DefenderPressureInput? msMpEngRow,
        ExtremeNecessityDefenderConfig? cfg,
        DefenderPlatformStatus defenderStatus,
        bool isAdmin)
    {
        var pressureScore = msMpEngRow?.Score ?? 0;
        var cpu = msMpEngRow?.CpuPercent ?? 0;
        var io = msMpEngRow?.IoMbPerSec ?? 0;
        var mem = msMpEngRow?.WorkingSetMb ?? 0;
        var dominant = msMpEngRow?.DominantPressure ?? "Mixed";

        var weights = new Dictionary<string, double>(StringComparer.OrdinalIgnoreCase)
        {
            ["pressureScore"] = 0.35,
            ["cpuPercent"] = 0.25,
            ["ioMbPerSec"] = 0.20,
            ["workingSetMb"] = 0.10,
            ["dominantPressureMatch"] = 0.10
        };
        if (cfg?.Weights is not null)
        {
            foreach (var kvp in cfg.Weights)
                weights[kvp.Key] = kvp.Value;
        }

        var cpuNorm = Math.Clamp(cpu, 0, 100);
        var ioNorm = Math.Clamp(io / 400.0 * 100.0, 0, 100);
        var memNorm = Math.Clamp(mem / 8192.0 * 100.0, 0, 100);
        var domBonus = dominant is "CPUBound" or "IOHeavy" ? 100.0 : 40.0;

        var composite = Math.Round(
            pressureScore * weights["pressureScore"] +
            cpuNorm * weights["cpuPercent"] +
            ioNorm * weights["ioMbPerSec"] +
            memNorm * weights["workingSetMb"] +
            domBonus * weights["dominantPressureMatch"],
            2);

        var tier = ResolveTier(composite, cfg);

        var blockers = new List<string>();
        var prereqs = new List<string>();

        if (!isAdmin)
            blockers.Add("Administrator elevation required for any Defender mutation.");
        if (!defenderStatus.ModuleAvailable)
            blockers.Add("Defender PowerShell module unavailable - cannot verify or change state safely.");

        if (tier is "TemporaryRealtimeOff" or "ExtremeServiceDisable")
        {
            if (defenderStatus.TamperProtectionEnabled == true)
            {
                blockers.Add("Tamper Protection is ON - disable manually in Windows Security > Virus & threat protection > Manage settings before Tier 2+.");
            }
            prereqs.Add("Document reason code and planned re-enable window.");
            prereqs.Add("Ensure secondary offline AV or isolated network if disabling real-time protection.");
        }

        if (tier == "ExtremeServiceDisable")
        {
            prereqs.Add("Double human confirmation required (ExtremeServiceDisable).");
            prereqs.Add("Register rollback JSON and scheduled re-enable before apply.");
        }

        if (msMpEngRow is null)
        {
            blockers.Add("MsMpEng not in current pressure top - run process-pressure analyze first.");
            tier = "Observe";
        }

        var allowed = tier != "Observe" && blockers.Count == 0;
        var neverAuto = cfg?.NeverAutoApply ?? true;

        return new DefenderExtremeNecessityEvaluation
        {
            GeneratedAt = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss"),
            CompositeScore = composite,
            RecommendedTier = tier,
            AllowedToProceed = allowed,
            NeverAutoApply = neverAuto,
            Rationale = TierRationale(tier),
            MsMpEngMetrics = msMpEngRow is null ? null : new
            {
                Score = pressureScore,
                CpuPercent = cpu,
                IoMBps = io,
                WorkingSetMB = mem,
                DominantPressure = dominant,
                PID = msMpEngRow.Pid
            },
            DefenderStatus = defenderStatus,
            Blockers = blockers,
            Prerequisites = prereqs,
            EscalationLadder =
            [
                "1. Observe and confirm sustained pressure (not a one-shot spike)",
                "2. TuneExclusions: Add-Defender exclusions for trusted build paths + off-hours scan",
                "3. TemporaryRealtimeOff: Set-MpPreference -DisableRealtimeMonitoring (time-boxed)",
                "4. ExtremeServiceDisable: Stop-Service WinDefend (last resort, rollback mandatory)"
            ],
            ReasonCodes = cfg?.ReasonCodes ?? new Dictionary<string, string>()
        };
    }

    public static DefenderPressureInput? FindMsMpEngRow(ProcessPressureReport? report)
    {
        if (report?.TopProcesses is null)
            return null;

        var row = report.TopProcesses.FirstOrDefault(r =>
            r.ProcessName.Equals("MsMpEng", StringComparison.OrdinalIgnoreCase));
        if (row is null)
            return null;

        return new DefenderPressureInput
        {
            Score = row.Score,
            CpuPercent = row.CpuPercent,
            IoMbPerSec = row.IoMbPerSec,
            WorkingSetMb = row.WorkingSetMb,
            DominantPressure = row.DominantPressure,
            Pid = row.Pid,
            ProcessName = row.ProcessName
        };
    }

    private static string ResolveTier(double composite, ExtremeNecessityDefenderConfig? cfg)
    {
        if (cfg?.Tiers is not null && cfg.Tiers.Count > 0)
        {
            if (cfg.Tiers.TryGetValue("ExtremeServiceDisable", out var extreme) &&
                composite >= extreme.MinCompositeScore)
                return "ExtremeServiceDisable";
            if (cfg.Tiers.TryGetValue("TemporaryRealtimeOff", out var temp) &&
                composite >= temp.MinCompositeScore)
                return "TemporaryRealtimeOff";
            if (cfg.Tiers.TryGetValue("TuneExclusions", out var tune) &&
                composite >= tune.MinCompositeScore)
                return "TuneExclusions";
            return "Observe";
        }

        if (composite >= 95) return "ExtremeServiceDisable";
        if (composite >= 90) return "TemporaryRealtimeOff";
        if (composite >= 85) return "TuneExclusions";
        return "Observe";
    }

    private static string TierRationale(string tier) => tier switch
    {
        "Observe" => "Defender pressure does not justify disable path - continue monitoring or tune other workloads.",
        "TuneExclusions" => "Deterministic gate: composite >= 55 - prefer exclusions and scan schedule (keeps AV active).",
        "TemporaryRealtimeOff" => "Deterministic gate: composite >= 70 - time-boxed real-time off allowed ONLY with HITL + Tamper Protection off.",
        "ExtremeServiceDisable" => "Deterministic gate: composite >= 85 - last-resort service stop; maximum risk, mandatory rollback timer.",
        _ => "Unknown tier."
    };
}
