using SystemOptimizerHub.Abstractions;
using SystemOptimizerHub.Core.Defender;
using SystemOptimizerHub.Core.Models;

namespace SystemOptimizerHub.Core.Tests;

public class DefenderExtremeNecessityApplyServiceTests
{
    private sealed class FakeMutator : IDefenderPolicyMutator
    {
        public List<string> Exclusions { get; } = [];
        public bool? RtEnabled { get; private set; }
        public bool Stopped { get; private set; }

        public Task AddExclusionPathAsync(string path, CancellationToken ct = default)
        {
            Exclusions.Add(path);
            return Task.CompletedTask;
        }

        public Task SetRealtimeMonitoringAsync(bool enabled, CancellationToken ct = default)
        {
            RtEnabled = enabled;
            return Task.CompletedTask;
        }

        public Task<DefenderServiceState?> GetWinDefendServiceStateAsync(CancellationToken ct = default) =>
            Task.FromResult<DefenderServiceState?>(new DefenderServiceState("WinDefend", "Automatic", "Running"));

        public Task StopWinDefendServiceAsync(CancellationToken ct = default)
        {
            Stopped = true;
            return Task.CompletedTask;
        }

        public Task SetWinDefendStartupManualAsync(CancellationToken ct = default) => Task.CompletedTask;

        public Task RegisterRollbackReenableTaskAsync(string rollbackJsonPath, string restoreScriptPath, int delayMinutes, string taskName, CancellationToken ct = default) =>
            Task.CompletedTask;
    }

    private static DefenderExtremeNecessityEvaluation Eval(string tier, bool allowed = true) => new()
    {
        RecommendedTier = tier,
        AllowedToProceed = allowed,
        CompositeScore = 86,
        Blockers = allowed ? [] : ["blocked"]
    };

    [Fact]
    public async Task DryRun_TuneExclusions_Writes_Rollback_No_Mutation()
    {
        var mutator = new FakeMutator();
        var dir = Path.Combine(Path.GetTempPath(), "hub-def-test-" + Guid.NewGuid().ToString("N"));
        var result = await DefenderExtremeNecessityApplyService.ApplyAsync(
            Eval("TuneExclusions"),
            new DefenderExtremeApplyOptions
            {
                Tier = "TuneExclusions",
                IUnderstandRisk = true,
                DryRun = true,
                ExclusionPaths = ["C:\\Temp\\HubTestExclusion"],
                RollbackDirectory = dir
            },
            mutator,
            () => new DefenderPlatformStatus { ModuleAvailable = true });

        Assert.Equal("DryRunApplied", result.Outcome);
        Assert.Empty(mutator.Exclusions);
        Assert.True(File.Exists(result.RollbackPath));
    }

    [Fact]
    public async Task Missing_IUnderstandRisk_Throws()
    {
        var mutator = new FakeMutator();
        await Assert.ThrowsAsync<InvalidOperationException>(() =>
            DefenderExtremeNecessityApplyService.ApplyAsync(
                Eval("TuneExclusions"),
                new DefenderExtremeApplyOptions { Tier = "TuneExclusions", ExclusionPaths = ["C:\\x"] },
                mutator,
                () => new DefenderPlatformStatus()));
    }

    [Fact]
    public async Task Tier_Mismatch_Throws()
    {
        var mutator = new FakeMutator();
        await Assert.ThrowsAsync<InvalidOperationException>(() =>
            DefenderExtremeNecessityApplyService.ApplyAsync(
                Eval("Observe"),
                new DefenderExtremeApplyOptions { Tier = "TuneExclusions", IUnderstandRisk = true, ExclusionPaths = ["C:\\x"] },
                mutator,
                () => new DefenderPlatformStatus()));
    }
}
