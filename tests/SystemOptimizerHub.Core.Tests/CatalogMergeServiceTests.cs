using SystemOptimizerHub.Core.Identify;
using SystemOptimizerHub.Core.Models;

namespace SystemOptimizerHub.Core.Tests;

public class CatalogMergeServiceTests
{
    [Fact]
    public void BuildEntry_Uses_Cache_And_Hint()
    {
        var cache = new CatalogMergeCacheEntry
        {
            WhatItIs = "Test process",
            WhatItDoes = "Does test things",
            SuggestedCategory = "Other",
            SuggestedPriority = "Review"
        };
        var hint = new CatalogHintInput
        {
            Sources = ["https://example.com/doc"]
        };

        var entry = CatalogMergeService.BuildCatalogEntryFromSources("TestProc", hint, cache);
        Assert.Equal("Other", entry.Category);
        Assert.Equal("Test process", entry.Description);
        Assert.Contains("https://example.com/doc", entry.References);
    }

    [Fact]
    public void MergeFields_Preserves_Higher_Priority()
    {
        var existing = new KnownApplicationEntry
        {
            Priority = "Keep",
            Description = "Long existing description that should win",
            WhatItDoes = "Existing does",
            References = ["https://a.com"]
        };
        var incoming = new KnownApplicationEntry
        {
            Priority = "Review",
            Description = "Short",
            WhatItDoes = "New",
            References = ["https://b.com"],
            MergedFrom = ["operator-manual-identify"]
        };

        var merged = CatalogMergeService.MergeCatalogEntryFields(existing, incoming);
        Assert.Equal("Keep", merged.Priority);
        Assert.Equal("Long existing description that should win", merged.Description);
        Assert.Equal(2, merged.References.Count);
    }

    [Fact]
    public void Protected_Process_Blocked()
    {
        var dir = Path.Combine(Path.GetTempPath(), "hub-merge-test-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(dir);
        var catalogPath = Path.Combine(dir, "catalog.json");
        File.WriteAllText(catalogPath, """
            {"SchemaVersion":"ProcessIntelligence.v1","vitalExact":["System"],"securityExact":["MsMpEng"],"knownApplications":{}}
            """);

        try
        {
            var result = CatalogMergeService.MergeProcessIntoCatalog(
                dir, "MsMpEng", new KnownApplicationEntry { Category = "X" }, catalogPath);
            Assert.False(result.Ok);
            Assert.Equal("protected_system_process", result.Reason);
        }
        finally
        {
            Directory.Delete(dir, true);
        }
    }

    [Fact]
    public void Pipeline_Skips_When_SkipAuth_And_RequireAuth()
    {
        var settings = new Config.ProcessKnowledgeConfig { RequireAuthForCatalogMerge = true };
        var input = new CatalogMergeInput { SkipAuth = true, Confidence = 0.98 };
        var result = CatalogMergeService.RunPostIdentifyPipeline(
            ".", input, settings, "catalog.json", authVerified: false);
        Assert.True(result.Skipped);
        Assert.Equal("auth_required_for_catalog_merge", result.Reason);
    }
}
