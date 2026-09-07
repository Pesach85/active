using SystemOptimizerHub.Core.Models;
using SystemOptimizerHub.Core.Resolution;

namespace SystemOptimizerHub.Core.Tests;

public class ResolutionAdvisoryServiceTests
{
    private static ProcessResolutionConfig DefaultConfig() => new();

    [Fact]
    public void MsMpEng_Identified_Keep_Recommends_Observe_With_Blocked_Actions()
    {
        var snap = new ProcessSnapshotInput(5808, "MsMpEng", 446.2);
        var hint = new KnowledgeHintInput(0.98, "T1_Delegated", "Microsoft Defender", "Security");
        var nec = new ProcessNecessity("Security", "Keep", "Security",
            "Security component - tune schedule/scope only; never disable without HITL security review.");

        var adv = ResolutionAdvisoryService.BuildAdvisory(snap, hint, DefaultConfig(), nec);

        Assert.Equal("Observe", adv.RecommendedActionId);
        Assert.Contains("ThrottleBelowNormal", adv.BlockedActionIds);
        Assert.Contains("Terminate", adv.BlockedActionIds);
        Assert.DoesNotContain(adv.Options, o => o.ActionId == "ThrottleBelowNormal");
        Assert.Contains(adv.Warnings, w => w.Contains("Priority=Keep"));
    }

    [Fact]
    public void Unknown_HighRam_Recommends_Throttle()
    {
        var snap = new ProcessSnapshotInput(1234, "TotallyUnknownProcessXYZ", 512.0);
        var hint = new KnowledgeHintInput(0.55, "T3_Unknown", "Unknown process", "Unknown");

        var adv = ResolutionAdvisoryService.BuildAdvisory(snap, hint, DefaultConfig());

        Assert.Equal("ThrottleBelowNormal", adv.RecommendedActionId);
        Assert.False(adv.Identifiable);
    }

    [Fact]
    public void Unknown_LowRam_Recommends_Observe()
    {
        var snap = new ProcessSnapshotInput(1234, "TotallyUnknownProcessXYZ", 50.0);
        var hint = new KnowledgeHintInput(0.55, "T3_Unknown", "Unknown process", "Unknown");

        var adv = ResolutionAdvisoryService.BuildAdvisory(snap, hint, DefaultConfig());

        Assert.Equal("Observe", adv.RecommendedActionId);
    }

    [Fact]
    public void Operator_WorkNecessary_Recommends_Observe()
    {
        var snap = new ProcessSnapshotInput(100, "chrome", 800);
        var hint = new KnowledgeHintInput(0.95, "T1_Delegated", "Browser", "Browser");

        var adv = ResolutionAdvisoryService.BuildAdvisory(snap, hint, DefaultConfig(), operatorDecision: "WorkNecessary");

        Assert.Equal("Observe", adv.RecommendedActionId);
        Assert.Contains(adv.Warnings, w => w.Contains("necessary for work"));
    }
}
