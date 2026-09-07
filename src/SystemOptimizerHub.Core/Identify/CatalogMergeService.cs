using SystemOptimizerHub.Core.Catalog;
using SystemOptimizerHub.Core.Config;
using SystemOptimizerHub.Core.Models;

namespace SystemOptimizerHub.Core.Identify;

/// <summary>Port of process-catalog-merge.ps1 deterministic merge logic.</summary>
public static class CatalogMergeService
{
    private static readonly Dictionary<string, int> PriorityRank = new(StringComparer.OrdinalIgnoreCase)
    {
        ["Keep"] = 3,
        ["Tune"] = 2,
        ["Review"] = 1
    };

    public static string GetCacheEntryKey(string processName) =>
        processName.ToLowerInvariant().Replace(".exe", "", StringComparison.OrdinalIgnoreCase);

    public static KnownApplicationEntry BuildCatalogEntryFromSources(
        string processName,
        CatalogHintInput? hint,
        CatalogMergeCacheEntry cacheEntry)
    {
        var draft = hint?.SuggestedCatalogEntry;

        var category = cacheEntry.SuggestedCategory;
        if (string.IsNullOrWhiteSpace(category) || category == "Unknown")
            category = draft?.Category ?? hint?.SuggestedCategory ?? "Other";
        if (string.IsNullOrWhiteSpace(category))
            category = "Other";

        var priority = cacheEntry.SuggestedPriority;
        if (string.IsNullOrWhiteSpace(priority))
            priority = draft?.Priority ?? hint?.SuggestedPriority ?? "Review";
        if (string.IsNullOrWhiteSpace(priority))
            priority = "Review";

        var whatItIs = cacheEntry.WhatItIs;
        if (string.IsNullOrWhiteSpace(whatItIs))
            whatItIs = hint?.WhatItIs ?? string.Empty;

        var whatItDoes = cacheEntry.WhatItDoes;
        if (string.IsNullOrWhiteSpace(whatItDoes))
            whatItDoes = hint?.WhatItDoes ?? string.Empty;

        var resourceProfile = cacheEntry.ResourceProfile;
        if (string.IsNullOrWhiteSpace(resourceProfile))
            resourceProfile = draft?.ResourceProfile ?? hint?.ResourceProfile ?? "Mixed";
        if (string.IsNullOrWhiteSpace(resourceProfile))
            resourceProfile = "Mixed";

        var mitigations = draft?.PressureMitigations;
        if (mitigations is null || mitigations.Count == 0)
        {
            mitigations = new Dictionary<string, List<string>>(StringComparer.OrdinalIgnoreCase)
            {
                ["MemoryHeavy"] = [$"Review if RAM justified for active work on {processName}"],
                ["CPUBound"] = ["Check for runaway loops or updates"],
                ["IOHeavy"] = ["Check disk usage by parent application"]
            };
        }

        var refs = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        if (hint?.Sources is not null)
        {
            foreach (var s in hint.Sources)
            {
                if (s.StartsWith("http://", StringComparison.OrdinalIgnoreCase) ||
                    s.StartsWith("https://", StringComparison.OrdinalIgnoreCase))
                    refs.Add(s);
            }
        }
        if (draft?.References is not null)
        {
            foreach (var r in draft.References)
            {
                if (!string.IsNullOrWhiteSpace(r))
                    refs.Add(r);
            }
        }

        var businessHint = cacheEntry.BusinessHint;
        if (string.IsNullOrWhiteSpace(businessHint))
            businessHint = hint?.BusinessHint ?? string.Empty;

        return new KnownApplicationEntry
        {
            Category = category,
            Priority = priority,
            DisplayName = processName,
            Description = whatItIs,
            WhatItDoes = whatItDoes,
            ResourceProfile = resourceProfile,
            BusinessHint = businessHint,
            PressureMitigations = mitigations,
            References = refs.ToList(),
            MergedAt = DateTime.UtcNow.ToString("o"),
            MergedFrom = ["operator-manual-identify", "kb-hint-enrichment"]
        };
    }

    public static KnownApplicationEntry MergeCatalogEntryFields(
        KnownApplicationEntry? existing,
        KnownApplicationEntry incoming)
    {
        if (existing is null)
            return incoming;

        var outEntry = new KnownApplicationEntry
        {
            Category = incoming.Category,
            Priority = incoming.Priority,
            DisplayName = incoming.DisplayName,
            Description = incoming.Description,
            WhatItDoes = incoming.WhatItDoes,
            ResourceProfile = incoming.ResourceProfile,
            BusinessHint = incoming.BusinessHint,
            PressureMitigations = incoming.PressureMitigations,
            References = incoming.References.ToList(),
            MergedAt = incoming.MergedAt,
            MergedFrom = incoming.MergedFrom.ToList()
        };

        if ((existing.Description?.Length ?? 0) > (incoming.Description?.Length ?? 0) + 10)
            outEntry.Description = existing.Description;

        if ((existing.WhatItDoes?.Length ?? 0) > (incoming.WhatItDoes?.Length ?? 0) + 10)
            outEntry.WhatItDoes = existing.WhatItDoes;

        if (PriorityRank.TryGetValue(existing.Priority, out var existRank) &&
            PriorityRank.TryGetValue(incoming.Priority, out var inRank) &&
            existRank > inRank)
        {
            outEntry.Priority = existing.Priority;
        }

        var refSet = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var r in existing.References)
            if (!string.IsNullOrWhiteSpace(r)) refSet.Add(r);
        foreach (var r in incoming.References)
            if (!string.IsNullOrWhiteSpace(r)) refSet.Add(r);
        outEntry.References = refSet.ToList();

        var mergedFrom = new List<string>(existing.MergedFrom);
        foreach (var s in incoming.MergedFrom)
        {
            if (!string.IsNullOrWhiteSpace(s) && !mergedFrom.Contains(s, StringComparer.Ordinal))
                mergedFrom.Add(s);
        }
        outEntry.MergedFrom = mergedFrom;

        return outEntry;
    }

    public static CatalogMergeResult MergeProcessIntoCatalog(
        string hubRoot,
        string processName,
        KnownApplicationEntry catalogEntry,
        string catalogPath,
        double confidence = 0.98)
    {
        var key = GetCacheEntryKey(processName);
        if (string.IsNullOrWhiteSpace(key))
            return Fail("empty_process_name", processName, catalogPath);

        var catalog = CatalogLoader.LoadFromFile(catalogPath);
        if (catalog.VitalExact.Contains(key, StringComparer.OrdinalIgnoreCase) ||
            catalog.SecurityExact.Contains(key, StringComparer.OrdinalIgnoreCase))
        {
            return Fail("protected_system_process", key, catalogPath);
        }

        var logsDir = Path.Combine(hubRoot, "logs");
        Directory.CreateDirectory(logsDir);
        var rollbackPath = Path.Combine(logsDir,
            $"process-intelligence-rollback-{DateTime.Now:yyyyMMdd-HHmmss}.json");
        if (File.Exists(catalogPath))
            File.Copy(catalogPath, rollbackPath, overwrite: true);

        catalog.KnownApplications.TryGetValue(key, out var existing);
        var merged = MergeCatalogEntryFields(existing, catalogEntry);
        catalog.KnownApplications[key] = merged;
        CatalogLoader.SaveToFile(catalogPath, catalog);

        return new CatalogMergeResult
        {
            Ok = true,
            ProcessName = key,
            CatalogPath = catalogPath,
            RollbackPath = rollbackPath,
            WasUpdate = existing is not null,
            Confidence = confidence,
            TrustLevel = "T1_Delegated"
        };
    }

    public static PostIdentifyPipelineResult RunPostIdentifyPipeline(
        string hubRoot,
        CatalogMergeInput input,
        ProcessKnowledgeConfig settings,
        string catalogPath,
        bool authVerified)
    {
        if (!settings.AutoMergeCatalogOnIdentify)
            return Skipped("disabled");

        if (settings.RequireAuthForCatalogMerge && input.SkipAuth)
            return Skipped("auth_required_for_catalog_merge");

        if (settings.RequireAuthForCatalogMerge && !authVerified)
            return Skipped("auth_failed");

        if (input.Confidence < settings.CatalogMergeMinConfidence)
            return Skipped("confidence_below_threshold");

        var name = string.IsNullOrWhiteSpace(input.ProcessName)
            ? input.CacheEntry.ProcessName
            : input.ProcessName;

        var entry = BuildCatalogEntryFromSources(name, input.Hint, input.CacheEntry);
        var merge = MergeProcessIntoCatalog(hubRoot, name, entry, catalogPath, input.Confidence);

        return new PostIdentifyPipelineResult
        {
            Skipped = false,
            CatalogMerge = merge
        };
    }

    private static PostIdentifyPipelineResult Skipped(string reason) =>
        new() { Skipped = true, Reason = reason };

    private static CatalogMergeResult Fail(string reason, string processName, string catalogPath) =>
        new() { Ok = false, Reason = reason, ProcessName = processName, CatalogPath = catalogPath };
}
