using SystemOptimizerHub.Core.Catalog;
using SystemOptimizerHub.Core.Models;
using SystemOptimizerHub.Core.Scoring;

namespace SystemOptimizerHub.Core.Tests;

public class ProcessNecessityResolverTests
{
    private static ProcessIntelligenceCatalog SampleCatalog() => new()
    {
        VitalExact = ["System", "csrss"],
        SecurityExact = ["MsMpEng", "NisSrv"],
        PlatformServicePatterns = ["SearchIndexer"],
        KnownApplications = new Dictionary<string, KnownApplicationEntry>(StringComparer.OrdinalIgnoreCase)
        {
            ["mysqld"] = new() { Category = "Database", Priority = "Keep" },
            ["chrome"] = new() { Category = "Browser", Priority = "Tune" }
        },
        OptionalBackgroundPatterns = ["Updater"]
    };

    [Fact]
    public void MsMpEng_Is_Keep_Security()
    {
        var nec = ProcessNecessityResolver.Resolve("MsMpEng", SampleCatalog());
        Assert.Equal("Keep", nec.Priority);
        Assert.Equal("Security", nec.Category);
    }

    [Fact]
    public void Throttle_Blocked_For_Keep()
    {
        var nec = ProcessNecessityResolver.Resolve("MsMpEng", SampleCatalog());
        var block = ProcessNecessityResolver.TestCatalogActionBlocked(CatalogActionKind.ThrottleBelowNormal, nec);
        Assert.True(block.Blocked);
    }

    [Fact]
    public void Mysqld_Known_Application()
    {
        var nec = ProcessNecessityResolver.Resolve("mysqld", SampleCatalog());
        Assert.Equal("KnownApplication", nec.Level);
        Assert.Equal("Database", nec.Category);
    }

    [Fact]
    public void Unknown_Process_Review()
    {
        var nec = ProcessNecessityResolver.Resolve("TotallyUnknownProcessXYZ", SampleCatalog());
        Assert.Equal("Unknown", nec.Level);
        Assert.Equal("Review", nec.Priority);
    }
}

public class PressureScorerTests
{
    [Fact]
    public void Dominant_Cpu_Wins()
    {
        Assert.Equal("CPUBound", PressureScorer.DominantPressure(90, 100, 1));
    }
}
