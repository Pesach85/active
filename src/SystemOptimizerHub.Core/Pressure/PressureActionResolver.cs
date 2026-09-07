using SystemOptimizerHub.Core.Models;

namespace SystemOptimizerHub.Core.Pressure;

/// <summary>Port of Resolve-PressureActions from process-pressure-core.ps1.</summary>
public static class PressureActionResolver
{
    public static IReadOnlyList<PressureAction> Resolve(
        string priority,
        string dominantPressure,
        double score,
        string processName,
        ProcessIntelligenceCatalog catalog)
    {
        var actions = new List<PressureAction>();

        if (priority == "Keep")
        {
            actions.Add(new PressureAction
            {
                Action = "ObserveOnly",
                Level = "Safe",
                RequiresHitl = false,
                Rationale = "Vital/security process preserved."
            });

            var known = FindKnownApplication(processName, catalog);
            if (known is not null &&
                known.PressureMitigations.TryGetValue(dominantPressure, out var tips))
            {
                foreach (var tip in tips)
                {
                    actions.Add(new PressureAction
                    {
                        Action = "GuidanceOnly",
                        Level = "Safe",
                        RequiresHitl = true,
                        Rationale = tip
                    });
                }
            }

            if (known is not null && known.References.Count > 0)
            {
                actions.Add(new PressureAction
                {
                    Action = "ReferenceLinks",
                    Level = "Safe",
                    RequiresHitl = false,
                    Rationale = string.Join("; ", known.References)
                });
            }

            if (processName == "MsMpEng" && score >= 55)
            {
                actions.Add(new PressureAction
                {
                    Action = "DefenderExtremeNecessityReview",
                    Level = "Aggressive",
                    RequiresHitl = true,
                    Rationale = "Run evaluate-defender-extreme-necessity.ps1 - escalation ladder before any disable."
                });
            }

            return actions;
        }

        if (priority == "Tune")
        {
            if (dominantPressure == "CPUBound" && score >= 40)
            {
                actions.Add(new PressureAction
                {
                    Action = "LowerProcessPriority",
                    Level = "Safe",
                    RequiresHitl = false,
                    Rationale = "Reversible priority throttle (BelowNormal)."
                });
            }

            if (dominantPressure == "IOHeavy")
            {
                actions.Add(new PressureAction
                {
                    Action = "StartupAndCacheTuning",
                    Level = "Moderate",
                    RequiresHitl = true,
                    Rationale = "Reduce autostart / cache / sync scope."
                });
            }

            if (dominantPressure == "MemoryHeavy")
            {
                actions.Add(new PressureAction
                {
                    Action = "ReduceInstancesOrTabs",
                    Level = "Moderate",
                    RequiresHitl = true,
                    Rationale = "Close redundant instances or background tabs."
                });
            }

            actions.Add(new PressureAction
            {
                Action = "ObserveOnly",
                Level = "Safe",
                RequiresHitl = false,
                Rationale = "Monitor after optional tune."
            });
            return actions;
        }

        if (score >= 55)
        {
            actions.Add(new PressureAction
            {
                Action = "DisableStartupEntry",
                Level = "Moderate",
                RequiresHitl = true,
                Rationale = "High score optional background - review then disable autostart."
            });
        }

        if (score >= 75 && priority == "Review")
        {
            actions.Add(new PressureAction
            {
                Action = "LowerProcessPriority",
                Level = "Safe",
                RequiresHitl = false,
                Rationale = "Temporary throttle while investigating."
            });
        }

        actions.Add(new PressureAction
        {
            Action = "ObserveOnly",
            Level = "Safe",
            RequiresHitl = false,
            Rationale = "Default safe path when classification uncertain."
        });
        return actions;
    }

    private static KnownApplicationEntry? FindKnownApplication(string processName, ProcessIntelligenceCatalog catalog)
    {
        var lower = processName.ToLowerInvariant();
        foreach (var kvp in catalog.KnownApplications)
        {
            var keyLower = kvp.Key.ToLowerInvariant();
            if (lower == keyLower || lower.StartsWith(keyLower, StringComparison.Ordinal))
                return kvp.Value;
        }

        return null;
    }
}
