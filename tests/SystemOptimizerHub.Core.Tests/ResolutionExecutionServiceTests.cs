using SystemOptimizerHub.Core.Defender;
using SystemOptimizerHub.Core.Models;
using SystemOptimizerHub.Core.Resolution;

namespace SystemOptimizerHub.Core.Tests;

public class ResolutionExecutionServiceTests
{
    private static ProcessResolutionConfig Config() => new()
    {
        ConfirmPhraseTerminate = "STOP UNKNOWN",
        ConfirmPhraseMarkNecessary = "KEEP FOR WORK",
        NeverTerminateExact = ["System", "MsMpEng"]
    };

    [Fact]
    public void Keep_Throttle_Is_ActionBlocked()
    {
        var snap = new ProcessSnapshotInput(1, "MsMpEng", 400);
        var nec = new ProcessNecessity("Security", "Keep", "Security", "keep notes");
        var adv = ResolutionAdvisoryService.BuildAdvisory(snap, new KnowledgeHintInput(), Config(), nec);
        var result = ResolutionExecutionService.Plan(
            "ThrottleBelowNormal", false, snap, adv, nec, Config(), skipAuth: true, authVerified: true);
        Assert.Equal("ActionBlocked", result.Outcome);
    }

    [Fact]
    public void NotRunning_DryRun_Throttle_Is_ProcessNotRunning()
    {
        var snap = new ProcessSnapshotInput(1234, "foo", 0, NotRunning: true);
        var nec = new ProcessNecessity("Unknown", "Review", "Unknown", "");
        var adv = ResolutionAdvisoryService.BuildAdvisory(snap, new KnowledgeHintInput(), Config(), nec);
        var result = ResolutionExecutionService.Plan(
            "ThrottleBelowNormal", true, snap, adv, nec, Config());
        Assert.Equal("ProcessNotRunning", result.Outcome);
    }

    [Fact]
    public void DryRun_Throttle_Live_Process_Is_DryRunThrottle()
    {
        var snap = new ProcessSnapshotInput(999, "foo", 100);
        var nec = new ProcessNecessity("Unknown", "Review", "Unknown", "");
        var adv = ResolutionAdvisoryService.BuildAdvisory(snap, new KnowledgeHintInput(), Config(), nec);
        var result = ResolutionExecutionService.Plan(
            "ThrottleBelowNormal", true, snap, adv, nec, Config(), skipAuth: true, authVerified: true);
        Assert.Equal("DryRunThrottle", result.Outcome);
    }
}

public class DefenderExtremeNecessityEvaluatorTests
{
    [Fact]
    public void No_MsMpEng_Forces_Observe()
    {
        var eval = DefenderExtremeNecessityEvaluator.Evaluate(
            null, null, new DefenderPlatformStatus { ModuleAvailable = true }, isAdmin: true);
        Assert.Equal("Observe", eval.RecommendedTier);
        Assert.Contains(eval.Blockers, b => b.Contains("MsMpEng"));
    }

    [Fact]
    public void High_Composite_Reaches_TuneExclusions()
    {
        var row = new DefenderPressureInput
        {
            Score = 100, CpuPercent = 100, IoMbPerSec = 200, WorkingSetMb = 6000,
            DominantPressure = "CPUBound", Pid = 1
        };
        var eval = DefenderExtremeNecessityEvaluator.Evaluate(
            row, null, new DefenderPlatformStatus { ModuleAvailable = true }, isAdmin: true);
        Assert.InRange(eval.CompositeScore, 85, 89.99);
        Assert.Equal("TuneExclusions", eval.RecommendedTier);
    }
}
