using System.Text.Json;
using SystemOptimizerHub.Abstractions;
using SystemOptimizerHub.Core.Defender;
using SystemOptimizerHub.Core.Models;

namespace SystemOptimizerHub.Core.Tests;

[Collection("ApplyEnvironment")]
public class DefenderExtremeNecessityApplyServiceTests
{
    private sealed class FakeMutator : IDefenderPolicyMutator
    {
        public FakeMutator(string? rollbackDirectory = null) => RollbackDirectory = rollbackDirectory;

        public string? RollbackDirectory { get; }
        public List<string> Exclusions { get; } = [];
        public List<string> CurrentExclusions { get; } = [];
        public bool? RtEnabled { get; private set; }
        public bool Stopped { get; private set; }
        public bool StartupManual { get; private set; }
        public int MutationCount { get; private set; }
        public int RegisterCalls { get; private set; }
        public bool RollbackReadableAtFirstMutation { get; private set; }
        public bool ServicePreStateCaptured { get; private set; }
        public bool FailAdd { get; set; }
        public bool FailExclusionRead { get; set; }
        public bool FailBeforeRead { get; set; }
        public bool FailAfterRead { get; set; }
        public IReadOnlyList<string>? BeforeReadback { get; set; }
        public IReadOnlyList<string>? AfterReadback { get; set; }
        private int _exclusionReads;

        public Task AddExclusionPathAsync(string path, CancellationToken ct = default)
        {
            NoteMutation();
            if (FailAdd)
                throw new InvalidOperationException("Add-MpPreference failed");
            Exclusions.Add(path);
            if (!CurrentExclusions.Contains(path))
                CurrentExclusions.Add(path);
            return Task.CompletedTask;
        }

        public Task<IReadOnlyList<string>?> TryGetExclusionPathsAsync(CancellationToken ct = default)
        {
            _exclusionReads++;
            if (FailExclusionRead
                || (_exclusionReads == 1 && FailBeforeRead)
                || (_exclusionReads > 1 && FailAfterRead))
                return Task.FromResult<IReadOnlyList<string>?>(null);
            if (_exclusionReads == 1 && BeforeReadback is not null)
                return Task.FromResult<IReadOnlyList<string>?>(BeforeReadback);
            if (_exclusionReads > 1 && AfterReadback is not null)
                return Task.FromResult<IReadOnlyList<string>?>(AfterReadback);
            return Task.FromResult<IReadOnlyList<string>?>(CurrentExclusions.ToList());
        }

        public Task SetRealtimeMonitoringAsync(bool enabled, CancellationToken ct = default)
        {
            NoteMutation();
            RtEnabled = enabled;
            return Task.CompletedTask;
        }

        public Task<DefenderServiceState?> GetWinDefendServiceStateAsync(CancellationToken ct = default)
        {
            if (!Stopped)
                ServicePreStateCaptured = true;
            return Task.FromResult<DefenderServiceState?>(new DefenderServiceState(
                "WinDefend",
                StartupManual ? "Manual" : "Automatic",
                Stopped ? "Stopped" : "Running"));
        }

        public Task StopWinDefendServiceAsync(CancellationToken ct = default)
        {
            NoteMutation();
            Stopped = true;
            return Task.CompletedTask;
        }

        public Task SetWinDefendStartupManualAsync(CancellationToken ct = default)
        {
            NoteMutation();
            StartupManual = true;
            return Task.CompletedTask;
        }

        public Task RegisterRollbackReenableTaskAsync(string rollbackJsonPath, string restoreScriptPath, int delayMinutes, string taskName, CancellationToken ct = default)
        {
            RegisterCalls++;
            if (!File.Exists(rollbackJsonPath))
                throw new InvalidOperationException("Restore task registered without a rollback file.");
            return Task.CompletedTask;
        }

        private void NoteMutation()
        {
            if (MutationCount == 0)
                RollbackReadableAtFirstMutation = RollbackFileProvesPreState(RollbackDirectory);
            MutationCount++;
        }

        private static bool RollbackFileProvesPreState(string? directory)
        {
            if (string.IsNullOrWhiteSpace(directory) || !Directory.Exists(directory))
                return false;
            var file = Directory.GetFiles(directory, "defender-extreme-rollback-*.json").SingleOrDefault();
            if (file is null)
                return false;
            var parsed = JsonSerializer.Deserialize<DefenderExtremeRollback>(
                File.ReadAllText(file),
                new JsonSerializerOptions { PropertyNameCaseInsensitive = true });
            return parsed is not null
                && parsed.SchemaVersion == "DefenderExtremeRollback.v1"
                && !string.IsNullOrWhiteSpace(parsed.Tier);
        }
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
        Assert.Equal(0, mutator.MutationCount);
        Assert.True(File.Exists(result.RollbackPath));
        try { Directory.Delete(dir, recursive: true); } catch { /* temp cleanup */ }
    }

    [Fact]
    public async Task Rollback_Directory_Not_Writable_Performs_Zero_Mutations()
    {
        var root = Path.Combine(Path.GetTempPath(), "hub-def-fail-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        var blocker = Path.Combine(root, "not-a-directory");
        await File.WriteAllTextAsync(blocker, "x");
        var mutator = new FakeMutator(root);

        await Assert.ThrowsAnyAsync<Exception>(() =>
            DefenderExtremeNecessityApplyService.ApplyAsync(
                Eval("TuneExclusions"),
                new DefenderExtremeApplyOptions
                {
                    Tier = "TuneExclusions",
                    IUnderstandRisk = true,
                    ExclusionPaths = ["C:\\Temp\\HubTestExclusion"],
                    RollbackDirectory = blocker
                },
                mutator,
                () => new DefenderPlatformStatus { ModuleAvailable = true }));

        Assert.Equal(0, mutator.MutationCount);
        Assert.Empty(mutator.Exclusions);
        Assert.Equal(0, mutator.RegisterCalls);
        try { Directory.Delete(root, recursive: true); } catch { /* temp cleanup */ }
    }

    [Fact]
    public async Task First_Mutation_Sees_Readable_Rollback()
    {
        var dir = Path.Combine(Path.GetTempPath(), "hub-def-order-" + Guid.NewGuid().ToString("N"));
        var mutator = new FakeMutator(dir);
        var result = await DefenderExtremeNecessityApplyService.ApplyAsync(
            Eval("TuneExclusions"),
            new DefenderExtremeApplyOptions
            {
                Tier = "TuneExclusions",
                IUnderstandRisk = true,
                ExclusionPaths = ["C:\\Temp\\HubTestExclusion"],
                RollbackDirectory = dir
            },
            mutator,
            () => new DefenderPlatformStatus { ModuleAvailable = true });

        Assert.Equal(1, mutator.MutationCount);
        Assert.True(mutator.RollbackReadableAtFirstMutation);
        Assert.Equal("Applied", result.Outcome);
        try { Directory.Delete(dir, recursive: true); } catch { /* temp cleanup */ }
    }

    [Fact]
    public async Task TemporaryRealtimeOff_Applied_Only_When_Realtime_Is_Off()
    {
        var dir = Path.Combine(Path.GetTempPath(), "hub-def-rt-" + Guid.NewGuid().ToString("N"));
        var mutator = new FakeMutator(dir);
        var calls = 0;
        var result = await DefenderExtremeNecessityApplyService.ApplyAsync(
            Eval("TemporaryRealtimeOff"),
            new DefenderExtremeApplyOptions
            {
                Tier = "TemporaryRealtimeOff",
                IUnderstandRisk = true,
                RollbackDirectory = dir,
                RestoreScriptPath = Path.Combine(dir, "restore.ps1"),
                AutoReenableMinutes = 30
            },
            mutator,
            () =>
            {
                calls++;
                return new DefenderPlatformStatus
                {
                    ModuleAvailable = true,
                    RealTimeProtectionEnabled = calls >= 2 ? false : true
                };
            });

        Assert.True(mutator.RollbackReadableAtFirstMutation);
        Assert.Equal(false, mutator.RtEnabled);
        Assert.Equal("Applied", result.Outcome);
        Assert.Equal(1, mutator.RegisterCalls);
        Assert.NotNull(result.After);
        Assert.False(result.After!.RealTimeProtectionEnabled);
        try { Directory.Delete(dir, recursive: true); } catch { /* temp cleanup */ }
    }

    [Fact]
    public async Task TemporaryRealtimeOff_StateMismatch_Is_Not_Applied()
    {
        var dir = Path.Combine(Path.GetTempPath(), "hub-def-rt-miss-" + Guid.NewGuid().ToString("N"));
        var mutator = new FakeMutator(dir);
        var result = await DefenderExtremeNecessityApplyService.ApplyAsync(
            Eval("TemporaryRealtimeOff"),
            new DefenderExtremeApplyOptions
            {
                Tier = "TemporaryRealtimeOff",
                IUnderstandRisk = true,
                RollbackDirectory = dir,
                RestoreScriptPath = Path.Combine(dir, "restore.ps1")
            },
            mutator,
            () => new DefenderPlatformStatus { ModuleAvailable = true, RealTimeProtectionEnabled = true });

        Assert.Equal(1, mutator.MutationCount);
        Assert.Equal("StateMismatch", result.Outcome);
        Assert.NotEqual("Applied", result.Outcome);
        try { Directory.Delete(dir, recursive: true); } catch { /* temp cleanup */ }
    }

    [Fact]
    public async Task ExtremeServiceDisable_Rollback_Captures_PreState_Before_Stop()
    {
        var dir = Path.Combine(Path.GetTempPath(), "hub-def-svc-" + Guid.NewGuid().ToString("N"));
        var mutator = new FakeMutator(dir);
        var result = await DefenderExtremeNecessityApplyService.ApplyAsync(
            Eval("ExtremeServiceDisable"),
            new DefenderExtremeApplyOptions
            {
                Tier = "ExtremeServiceDisable",
                IUnderstandRisk = true,
                ConfirmExtremeDisable = true,
                RollbackDirectory = dir,
                RestoreScriptPath = Path.Combine(dir, "restore.ps1")
            },
            mutator,
            () => new DefenderPlatformStatus { ModuleAvailable = true });

        Assert.True(mutator.ServicePreStateCaptured);
        Assert.True(mutator.RollbackReadableAtFirstMutation);
        Assert.Equal("Applied", result.Outcome);
        var parsed = JsonSerializer.Deserialize<DefenderExtremeRollback>(
            await File.ReadAllTextAsync(result.RollbackPath),
            new JsonSerializerOptions { PropertyNameCaseInsensitive = true });
        Assert.NotNull(parsed);
        Assert.Equal("Automatic", parsed!.ServiceStates[0].StartType);
        Assert.Equal("Running", parsed.ServiceStates[0].Status);
        try { Directory.Delete(dir, recursive: true); } catch { /* temp cleanup */ }
    }

    [Fact]
    public void Exclusion_Normalization_Does_Not_Match_Longer_Path()
    {
        Assert.True(DefenderExclusionPath.Equivalent(@"C:\Example\", @"C:\Example"));
        Assert.True(DefenderExclusionPath.Equivalent(@"C:/Example", @"C:\Example"));
        Assert.True(DefenderExclusionPath.Equivalent(@"C:\Example", @"c:\example"));
        Assert.False(DefenderExclusionPath.Equivalent(@"C:\Example", @"C:\Example2"));
        Assert.False(DefenderExclusionPath.ListContains(["C:\\Example2"], @"C:\Example"));
    }

    [Fact]
    public async Task TuneExclusions_Applied_When_PostRead_Contains_Path()
    {
        var (mutator, result) = await RunTune(@"C:\Example", before: [], after: ["C:\\Example"]);
        Assert.Equal("Applied", result.Outcome);
        Assert.Equal(1, mutator.MutationCount);
        Assert.Contains("C:\\Example", mutator.Exclusions);
        var added = await ReadAddedAsync(result.RollbackPath);
        Assert.Equal(["C:\\Example"], added);
    }

    [Fact]
    public async Task TuneExclusions_Missing_PostRead_Is_Not_Applied()
    {
        var (_, result) = await RunTune(@"C:\Example", before: [], after: ["C:\\Other"]);
        Assert.Equal("StateMismatch", result.Outcome);
        Assert.NotEqual("Applied", result.Outcome);
    }

    [Fact]
    public async Task TuneExclusions_BeforeRead_Failure_Performs_Zero_Mutations()
    {
        var dir = NewDir();
        var mutator = new FakeMutator(dir) { FailBeforeRead = true };
        var result = await ApplyTune(mutator, dir, @"C:\Example");
        Assert.Equal(0, mutator.MutationCount);
        Assert.Empty(mutator.Exclusions);
        Assert.Equal("PreStateUnavailable", result.Outcome);
        Assert.NotEqual("Applied", result.Outcome);
        Assert.NotEqual("StateUnverified", result.Outcome);
        Assert.Empty(Directory.GetFiles(dir, "defender-extreme-rollback-*.json"));
        try { Directory.Delete(dir, recursive: true); } catch { /* temp cleanup */ }
    }

    [Fact]
    public async Task TuneExclusions_BeforeRead_Failure_Records_No_Requested_Paths()
    {
        var dir = NewDir();
        var mutator = new FakeMutator(dir) { FailBeforeRead = true };
        var result = await DefenderExtremeNecessityApplyService.ApplyAsync(
            Eval("TuneExclusions"),
            new DefenderExtremeApplyOptions
            {
                Tier = "TuneExclusions",
                IUnderstandRisk = true,
                ExclusionPaths = [@"C:\One", @"C:\Two"],
                RollbackDirectory = dir
            },
            mutator,
            () => new DefenderPlatformStatus { ModuleAvailable = true });
        Assert.Equal(0, mutator.MutationCount);
        Assert.Empty(mutator.Exclusions);
        Assert.Equal("PreStateUnavailable", result.Outcome);
        Assert.Empty(Directory.GetFiles(dir, "defender-extreme-rollback-*.json"));
        try { Directory.Delete(dir, recursive: true); } catch { /* temp cleanup */ }
    }

    [Fact]
    public async Task TuneExclusions_AfterRead_Failure_Stays_StateUnverified()
    {
        var dir = NewDir();
        var mutator = new FakeMutator(dir) { BeforeReadback = [], FailAfterRead = true };
        var result = await ApplyTune(mutator, dir, @"C:\Example");
        Assert.Equal(1, mutator.MutationCount);
        Assert.Equal("StateUnverified", result.Outcome);
        Assert.NotEqual("PreStateUnavailable", result.Outcome);
        var added = await ReadAddedAsync(result.RollbackPath);
        Assert.Equal(["C:\\Example"], added);
        try { Directory.Delete(dir, recursive: true); } catch { /* temp cleanup */ }
    }

    [Fact]
    public async Task TuneExclusions_Mutation_Failure_Is_Failed()
    {
        var dir = NewDir();
        var mutator = new FakeMutator(dir) { FailAdd = true, BeforeReadback = [] };
        var result = await ApplyTune(mutator, dir, @"C:\Example");
        Assert.Equal(1, mutator.MutationCount);
        Assert.Equal("Failed", result.Outcome);
        Assert.NotEqual("Applied", result.Outcome);
        var added = await ReadAddedAsync(result.RollbackPath);
        Assert.Equal(["C:\\Example"], added);
    }

    [Fact]
    public async Task TuneExclusions_Already_Present_Does_Not_Record_A_New_Addition()
    {
        var dir = NewDir();
        var mutator = new FakeMutator(dir)
        {
            BeforeReadback = ["C:\\Example"],
            AfterReadback = ["C:\\Example"]
        };
        var result = await ApplyTune(mutator, dir, @"C:\Example");
        Assert.Equal(0, mutator.MutationCount);
        Assert.Equal("Applied", result.Outcome);
        var parsed = JsonSerializer.Deserialize<DefenderExtremeRollback>(
            await File.ReadAllTextAsync(result.RollbackPath),
            new JsonSerializerOptions { PropertyNameCaseInsensitive = true });
        Assert.NotNull(parsed);
        Assert.Empty(parsed!.ExclusionPathsAdded);
        try { Directory.Delete(dir, recursive: true); } catch { /* temp cleanup */ }
    }

    [Fact]
    public async Task TuneExclusions_Equivalent_Existing_Path_Is_Not_Added()
    {
        var dir = NewDir();
        var mutator = new FakeMutator(dir)
        {
            BeforeReadback = ["C:\\Example"],
            AfterReadback = ["C:\\Example"]
        };
        var result = await ApplyTune(mutator, dir, @"C:\Example\");
        Assert.Equal(0, mutator.MutationCount);
        Assert.Equal("Applied", result.Outcome);
        var added = await ReadAddedAsync(result.RollbackPath);
        Assert.Empty(added);
        try { Directory.Delete(dir, recursive: true); } catch { /* temp cleanup */ }
    }

    [Fact]
    public async Task TuneExclusions_Near_Match_Is_Not_Applied()
    {
        var (_, result) = await RunTune(@"C:\Example", before: [], after: ["C:\\Example2"]);
        Assert.Equal("StateMismatch", result.Outcome);
    }

    [Fact]
    public async Task TuneExclusions_Trailing_Separator_Matches()
    {
        var (mutator, result) = await RunTune(@"C:\Example\", before: [], after: ["C:\\Example"]);
        Assert.Equal("Applied", result.Outcome);
        Assert.Equal(1, mutator.MutationCount);
    }

    private static async Task<IReadOnlyList<string>> ReadAddedAsync(string rollbackPath)
    {
        var parsed = JsonSerializer.Deserialize<DefenderExtremeRollback>(
            await File.ReadAllTextAsync(rollbackPath),
            new JsonSerializerOptions { PropertyNameCaseInsensitive = true });
        Assert.NotNull(parsed);
        return parsed!.ExclusionPathsAdded;
    }

    private static string NewDir() =>
        Path.Combine(Path.GetTempPath(), "hub-def-excl-" + Guid.NewGuid().ToString("N"));

    private static async Task<(FakeMutator Mutator, DefenderExtremeApplyResult Result)> RunTune(
        string requested, IReadOnlyList<string> before, IReadOnlyList<string> after)
    {
        var dir = NewDir();
        var mutator = new FakeMutator(dir) { BeforeReadback = before, AfterReadback = after };
        var result = await ApplyTune(mutator, dir, requested);
        return (mutator, result);
    }

    private static async Task<DefenderExtremeApplyResult> ApplyTune(FakeMutator mutator, string dir, string path)
    {
        return await DefenderExtremeNecessityApplyService.ApplyAsync(
            Eval("TuneExclusions"),
            new DefenderExtremeApplyOptions
            {
                Tier = "TuneExclusions",
                IUnderstandRisk = true,
                ExclusionPaths = [path],
                RollbackDirectory = dir
            },
            mutator,
            () => new DefenderPlatformStatus { ModuleAvailable = true });
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
