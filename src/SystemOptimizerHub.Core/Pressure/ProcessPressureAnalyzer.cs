using SystemOptimizerHub.Core.Catalog;
using SystemOptimizerHub.Core.Models;
using SystemOptimizerHub.Core.Scoring;

namespace SystemOptimizerHub.Core.Pressure;

/// <summary>Port of Measure-ProcessPressureRows + report builder from analyze-process-pressure.ps1.</summary>
public static class ProcessPressureAnalyzer
{
    public static readonly string[] DefaultExcludedProcesses =
        ["Idle", "System Idle Process", "Registry", "Memory Compression"];

    public static IReadOnlyList<ProcessPressureRow> MeasureRows(
        IReadOnlyDictionary<string, ProcessPressureSnapshotRow> first,
        IReadOnlyDictionary<string, ProcessPressureSnapshotRow> second,
        int durationSec,
        int logicalProcessors,
        ProcessIntelligenceCatalog catalog)
    {
        var list = new List<ProcessPressureRow>();
        foreach (var (key, b) in second)
        {
            if (!first.TryGetValue(key, out var a))
                continue;

            var cpuDelta = Math.Max(0.0, b.CpuTime - a.CpuTime);
            var cpuPercent = (cpuDelta / (durationSec * Math.Max(1, logicalProcessors))) * 100.0;
            var ioDelta = Math.Max(0L, b.IoBytes - a.IoBytes);
            var ioMbPerSec = (ioDelta / (1024.0 * 1024.0)) / durationSec;
            var workingSetMb = Math.Round(b.WorkingSet64 / (1024.0 * 1024.0), 2);
            var privateMb = Math.Round(b.PrivateMemorySize64 / (1024.0 * 1024.0), 2);

            var score = PressureScorer.CompositeScore(cpuPercent, workingSetMb, ioMbPerSec);
            var dominant = PressureScorer.DominantPressure(cpuPercent, workingSetMb, ioMbPerSec);
            var nec = ProcessNecessityResolver.Resolve(b.ProcessName, catalog);
            var actions = PressureActionResolver.Resolve(nec.Priority, dominant, score, b.ProcessName, catalog);

            var autoEligible = actions
                .Where(x => !x.RequiresHitl && x.Action is "LowerProcessPriority" or "ObserveOnly")
                .ToList();
            var hitlRequired = actions.Where(x => x.RequiresHitl).ToList();

            list.Add(new ProcessPressureRow
            {
                Score = score,
                ProcessName = b.ProcessName,
                Pid = b.Pid,
                ImagePath = b.ImagePath,
                CpuPercent = Math.Round(cpuPercent, 2),
                WorkingSetMb = workingSetMb,
                PrivateMb = privateMb,
                IoMbPerSec = Math.Round(ioMbPerSec, 3),
                DominantPressure = dominant,
                Necessity = nec.Level,
                Priority = nec.Priority,
                Category = nec.Category,
                Notes = nec.Notes,
                Responding = b.Responding,
                Recommendation = GetLegacyRecommendation(score, dominant, actions),
                RecommendedActions = actions,
                AutoEligibleActions = autoEligible,
                HitlRequiredActions = hitlRequired
            });
        }

        return list;
    }

    public static ProcessPressureReport BuildReport(
        IReadOnlyList<ProcessPressureRow> rows,
        int durationSec,
        int logicalProcessors,
        int top,
        string platform,
        string catalogPath)
    {
        var topRows = rows
            .OrderByDescending(r => r.Score)
            .Take(Math.Clamp(top, 3, 30))
            .ToList();

        var highPressure = topRows.Count(r => r.Score >= 45);
        var autoEligible = topRows.Count(r => r.AutoEligibleActions.Count > 0 && r.Priority != "Keep");
        var hitlRequired = topRows.Count(r => r.HitlRequiredActions.Count > 0);
        var vitalPreserved = topRows.Count(r => r.Priority == "Keep");

        return new ProcessPressureReport
        {
            GeneratedAt = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss"),
            Platform = platform,
            DurationSec = durationSec,
            LogicalProcessors = logicalProcessors,
            TotalProcessesObserved = rows.Count,
            CatalogPath = catalogPath,
            Summary = new ProcessPressureSummary
            {
                HighPressureCount = highPressure,
                VitalPreserved = vitalPreserved,
                AutoEligibleCount = autoEligible,
                HitlRequiredCount = hitlRequired
            },
            TopProcesses = topRows
        };
    }

    public static string GetLegacyRecommendation(double score, string dominantPressure, IReadOnlyList<PressureAction> actions)
    {
        if (score >= 75)
        {
            if (actions.Any(a => a.Action == "LowerProcessPriority" && !a.RequiresHitl))
                return "ThrottlePriority";

            return dominantPressure switch
            {
                "CPUBound" => "ThrottlePriority",
                "MemoryHeavy" => "InvestigateMemory",
                "IOHeavy" => "CheckDiskContention",
                _ => "InvestigateImmediately"
            };
        }

        if (score >= 45)
            return "Observe";

        return "Normal";
    }
}
