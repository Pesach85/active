using SystemOptimizerHub.Core.Models;

namespace SystemOptimizerHub.Core.Catalog;

/// <summary>
/// Port of Resolve-ProcessNecessity from process-pressure-core.ps1 (deterministic parity).
/// </summary>
public static class ProcessNecessityResolver
{
    public static ProcessNecessity Resolve(string processName, ProcessIntelligenceCatalog catalog)
    {
        var name = processName.Trim();
        var lower = name.ToLowerInvariant();

        if (ProcessNameMatcher.Matches(name, catalog.VitalExact, catalog.VitalPatterns))
        {
            return new ProcessNecessity(
                "CriticalSystem", "Keep", "OSCore",
                "Windows core / session process - never terminate or throttle aggressively.");
        }

        if (ProcessNameMatcher.Matches(name, catalog.SecurityExact, []))
        {
            return new ProcessNecessity(
                "Security", "Keep", "Security",
                "Security component - tune schedule/scope only; never disable without HITL security review.");
        }

        foreach (var pattern in catalog.PlatformServicePatterns)
        {
            if (string.IsNullOrWhiteSpace(pattern))
                continue;
            try
            {
                if (System.Text.RegularExpressions.Regex.IsMatch(name, pattern,
                        System.Text.RegularExpressions.RegexOptions.IgnoreCase))
                {
                    return new ProcessNecessity(
                        "PlatformService", "Tune", "Platform",
                        "Platform service - scope or schedule tuning preferred over kill.");
                }
            }
            catch (System.Text.RegularExpressions.RegexParseException) { }
        }

        KnownApplicationEntry? known = null;
        foreach (var kvp in catalog.KnownApplications)
        {
            var keyLower = kvp.Key.ToLowerInvariant();
            if (lower == keyLower || lower.StartsWith(keyLower, StringComparison.Ordinal))
            {
                known = kvp.Value;
                break;
            }
        }

        if (known is not null)
        {
            return new ProcessNecessity(
                "KnownApplication", known.Priority, known.Category,
                "Catalog match - review mitigations for dominant pressure.");
        }

        foreach (var pat in catalog.OptionalBackgroundPatterns)
        {
            if (name.Contains(pat, StringComparison.OrdinalIgnoreCase))
            {
                return new ProcessNecessity(
                    "OptionalBackground", "Review", "Background",
                    "Optional background/updater/remote - candidate for manual-start after review.");
            }
        }

        return new ProcessNecessity(
            "Unknown", "Review", "Unknown",
            "Not in catalog - classify owner and business need before any action.");
    }

    public static CatalogActionBlockResult TestCatalogActionBlocked(
        CatalogActionKind action,
        ProcessNecessity necessity)
    {
        if (necessity.Priority == "Keep" &&
            action is CatalogActionKind.ThrottleBelowNormal or CatalogActionKind.Terminate)
        {
            var detail = string.IsNullOrWhiteSpace(necessity.Notes)
                ? $"Priority=Keep ({necessity.Category})"
                : necessity.Notes;
            return new CatalogActionBlockResult(
                true,
                $"Process is Priority=Keep ({necessity.Category}) - {action} blocked. {detail}");
        }

        return new CatalogActionBlockResult(false, string.Empty);
    }
}
