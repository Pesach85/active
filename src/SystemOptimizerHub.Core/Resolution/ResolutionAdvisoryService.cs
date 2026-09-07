using SystemOptimizerHub.Core.Models;

namespace SystemOptimizerHub.Core.Resolution;

/// <summary>Port of Get-ProcessResolutionAdvisory (process-resolution-policy.ps1).</summary>
public static class ResolutionAdvisoryService
{
    public static ProcessResolutionAdvisory BuildAdvisory(
        ProcessSnapshotInput snapshot,
        KnowledgeHintInput hint,
        ProcessResolutionConfig config,
        ProcessNecessity? catalogNecessity = null,
        string? operatorDecision = null)
    {
        if (snapshot is null) throw new ArgumentNullException(nameof(snapshot));
        if (config is null) throw new ArgumentNullException(nameof(config));

        var name = snapshot.ProcessName;
        var ram = snapshot.RamMb;
        var confidence = hint.Confidence;
        var trustLevel = hint.TrustLevel;
        var whatItIs = hint.WhatItIs;
        var category = hint.SuggestedCategory;

        var identifiable = confidence >= config.UnidentifiedConfidenceThreshold && category != "Unknown";
        var operatorChoice = operatorDecision;

        var warnings = new List<string>();
        var options = new List<ResolutionAdvisoryOption>();
        string recommended;

        if (operatorChoice == "WorkNecessary")
        {
            warnings.Add("Operator marked this process as necessary for work - terminate not recommended.");
            options.Add(Mk("Observe", "Keep running (operator approved)", 0, "You marked it work-necessary.", true, false));
            options.Add(Mk("ThrottleBelowNormal", "Throttle if RAM/CPU spikes", 1, "Reversible relief without stopping work tool.", true, false));
            recommended = "Observe";
        }
        else if (operatorChoice == "Unneeded")
        {
            warnings.Add("Operator marked unneeded - terminate available with confirmation.");
            options.Add(Mk("ThrottleBelowNormal", "Throttle first (reversible)", 1, "Try cheap relief before kill.", true, false));
            options.Add(Mk("Terminate", "Stop process", 10, "You marked it unneeded.", false, true));
            recommended = "ThrottleBelowNormal";
        }
        else if (!identifiable && ram >= config.HighRamThresholdMb)
        {
            warnings.Add("Cannot reliably identify this process and it uses significant RAM.");
            warnings.Add("Most efficient safe path: reversible throttle BEFORE terminate.");
            options.Add(Mk("ThrottleBelowNormal", "Throttle (BelowNormal) - recommended", 1,
                "Mathematically cheapest reversible action for unknown high-RAM.", true, false));
            options.Add(Mk("Observe", "Observe 24h", 0, "Zero cost if you need time to investigate.", true, false));
            options.Add(Mk("MarkWorkNecessary", "Mark necessary for my work", 0,
                "Stops future terminate recommendations.", true, true));
            options.Add(Mk("Terminate", "Stop process (last resort)", 10,
                "Use only if you accept data loss risk for this app.", false, true));
            recommended = "ThrottleBelowNormal";
        }
        else if (!identifiable && ram < config.LowRamThresholdMb)
        {
            warnings.Add("Low RAM unknown process - observe unless network egress is suspicious.");
            options.Add(Mk("Observe", "Observe - recommended", 0, "Low resource cost; investigate before action.", true, false));
            options.Add(Mk("MarkWorkNecessary", "Mark work-necessary", 0, "If you know this belongs to your workflow.", true, true));
            options.Add(Mk("Terminate", "Stop process", 10, "Only if you are sure it is unwanted.", false, true));
            recommended = "Observe";
        }
        else if (identifiable)
        {
            warnings.Add($"Identified with confidence {confidence} - prefer classify in catalog over terminate.");
            options.Add(Mk("Observe", "Keep + classify in catalog", 0, "Add to process-intelligence after review.", true, false));
            options.Add(Mk("MarkWorkNecessary", "Mark necessary for work", 0, "Document operator decision now.", true, true));
            options.Add(Mk("ThrottleBelowNormal", "Throttle if pressure continues", 1, "Tune without kill.", true, false));
            options.Add(Mk("Terminate", "Stop anyway (override)", 10, "Operator override - HITL only.", false, true));
            recommended = "Observe";
        }
        else
        {
            options.Add(Mk("Observe", "Observe", 0, "Default when uncertain.", true, false));
            options.Add(Mk("ThrottleBelowNormal", "Throttle", 1, "Reversible step.", true, false));
            options.Add(Mk("Terminate", "Terminate", 10, "HITL required.", false, true));
            recommended = "Observe";
        }

        var blockedActionIds = new List<string>();
        if (catalogNecessity?.Priority == "Keep")
        {
            warnings.Add($"Catalog Priority=Keep ({catalogNecessity.Category}) - throttle and terminate blocked.");
            blockedActionIds.AddRange(["ThrottleBelowNormal", "Terminate"]);
            options = options.Where(o => !blockedActionIds.Contains(o.ActionId)).ToList();
            if (recommended is "ThrottleBelowNormal" or "Terminate")
                recommended = "Observe";
        }

        var sorted = options.OrderBy(o => o.EfficiencyCost).ToList();
        var recObj = sorted.FirstOrDefault(o => o.ActionId == recommended);

        var aiSummary = catalogNecessity?.Priority == "Keep"
            ? $"AI/KB: {catalogNecessity.Notes} Observe only; throttle/terminate blocked by catalog."
            : identifiable
                ? $"AI/KB suggests: {whatItIs} ({category}). Prefer catalog merge over kill."
                : $"AI/KB cannot fully identify '{name}'. Reversible throttle is the efficient first step if RAM is high.";

        return new ProcessResolutionAdvisory(
            ProcessResolutionAdvisory.CurrentSchema,
            name,
            snapshot.Pid,
            ram,
            identifiable,
            confidence,
            trustLevel,
            whatItIs,
            operatorChoice,
            warnings,
            recommended,
            recObj,
            sorted,
            blockedActionIds,
            aiSummary,
            "T2_Review",
            true);
    }

    private static ResolutionAdvisoryOption Mk(
        string id, string label, int cost, string rationale, bool reversible, bool requiresHitl) =>
        new(id, label, cost, rationale, reversible, requiresHitl);
}
