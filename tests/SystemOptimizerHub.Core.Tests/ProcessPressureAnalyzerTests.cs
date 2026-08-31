using SystemOptimizerHub.Core.Catalog;
using SystemOptimizerHub.Core.Models;
using SystemOptimizerHub.Core.Pressure;
using SystemOptimizerHub.Core.Transparency;

namespace SystemOptimizerHub.Core.Tests;

public class ProcessPressureAnalyzerTests
{
    private static ProcessIntelligenceCatalog SampleCatalog() => new()
    {
        VitalExact = ["System"],
        SecurityExact = ["MsMpEng"],
        KnownApplications = new Dictionary<string, KnownApplicationEntry>(StringComparer.OrdinalIgnoreCase)
        {
            ["chrome"] = new()
            {
                Category = "Browser",
                Priority = "Tune",
                PressureMitigations = new Dictionary<string, List<string>>(StringComparer.OrdinalIgnoreCase)
                {
                    ["CPUBound"] = ["Reduce tabs"]
                },
                References = ["https://example.com/chrome"]
            }
        }
    };

    [Fact]
    public void MeasureRows_Computes_Score_And_Actions()
    {
        var first = new Dictionary<string, ProcessPressureSnapshotRow>
        {
            ["100:1"] = new()
            {
                Key = "100:1", ProcessName = "chrome", Pid = 100,
                CpuTime = 0.0, WorkingSet64 = 500L * 1024 * 1024, IoBytes = 0
            }
        };
        var second = new Dictionary<string, ProcessPressureSnapshotRow>
        {
            ["100:1"] = new()
            {
                Key = "100:1", ProcessName = "chrome", Pid = 100,
                CpuTime = 48.0, WorkingSet64 = 600L * 1024 * 1024, IoBytes = 50L * 1024 * 1024
            }
        };

        var rows = ProcessPressureAnalyzer.MeasureRows(first, second, 6, 8, SampleCatalog());
        var row = Assert.Single(rows);
        Assert.Equal("chrome", row.ProcessName);
        Assert.Equal("Tune", row.Priority);
        Assert.True(row.Score > 0);
        Assert.Contains(row.RecommendedActions, a => a.Action == "LowerProcessPriority");
    }

    [Fact]
    public void Keep_Priority_Gets_ObserveOnly()
    {
        var first = new Dictionary<string, ProcessPressureSnapshotRow>
        {
            ["1:1"] = new ProcessPressureSnapshotRow
            {
                Key = "1:1", ProcessName = "MsMpEng", Pid = 1,
                CpuTime = 5, WorkingSet64 = 400L * 1024 * 1024
            }
        };
        var second = new Dictionary<string, ProcessPressureSnapshotRow>
        {
            ["1:1"] = new ProcessPressureSnapshotRow
            {
                Key = "1:1", ProcessName = "MsMpEng", Pid = 1,
                CpuTime = 10, WorkingSet64 = 400L * 1024 * 1024
            }
        };

        var rows = ProcessPressureAnalyzer.MeasureRows(first, second, 6, 8, SampleCatalog());
        var row = Assert.Single(rows);
        Assert.Equal("Keep", row.Priority);
        Assert.Contains(row.RecommendedActions, a => a.Action == "ObserveOnly");
    }
}

public class TransparencyReportBuilderTests
{
    [Fact]
    public void Unknown_High_Ram_Reduces_Posture()
    {
        var input = new TransparencyBuildInput
        {
            HostSnapshot = new HostResourceSnapshot
            {
                TotalRamMb = 16384, FreeRamMb = 8192, TotalRamGb = 16,
                LogicalProcessors = 8, DriveCFreePercent = 50
            },
            Profile = new OptimizationProfile { Name = "feather", Tier = "C", LlmAllowed = false },
            RamConsumers =
            [
                new RamConsumerInput { Pid = 1, Name = "mystery", RamMb = 500, CpuSec = 1 }
            ],
            UnknownRamThresholdMb = 400
        };

        var report = TransparencyReportBuilder.Build(input);
        Assert.Single(report.UnknownHighRam);
        Assert.True(report.Posture.Score < 100);
        Assert.Equal("T3_Unknown", report.RamConsumers[0].TrustLevel);
    }

    [Fact]
    public void Trusted_Process_Is_T0()
    {
        var input = new TransparencyBuildInput
        {
            HostSnapshot = new HostResourceSnapshot
            {
                TotalRamMb = 16384, FreeRamMb = 8192, TotalRamGb = 16,
                LogicalProcessors = 8, DriveCFreePercent = 50
            },
            RamConsumers =
            [
                new RamConsumerInput { Pid = 1, Name = "explorer", RamMb = 200, CpuSec = 1 }
            ]
        };

        var report = TransparencyReportBuilder.Build(input);
        Assert.Equal("T0_Observed", report.RamConsumers[0].TrustLevel);
    }
}

public class TransparencyPolicyTests
{
    [Fact]
    public void Catalog_Name_Is_T1()
    {
        var trust = TransparencyPolicy.ResolveProcessTrustLevel(
            "mysqld", "", ["mysqld"], new HashSet<string>());
        Assert.Equal("T1_Delegated", trust.Level);
    }
}
