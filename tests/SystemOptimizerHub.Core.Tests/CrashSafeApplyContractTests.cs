using System.Diagnostics;
using SystemOptimizerHub.Abstractions;
using SystemOptimizerHub.Core.Models;
using SystemOptimizerHub.Core.Resolution;

namespace SystemOptimizerHub.Core.Tests;

[CollectionDefinition("ApplyEnvironment")]
public sealed class ApplyEnvironmentCollection;

[Collection("ApplyEnvironment")]
public class CrashSafeApplyContractTests
{
    private static ProcessResolutionConfig Config() => new()
    {
        ConfirmPhraseTerminate = "STOP UNKNOWN",
        ConfirmPhraseMarkNecessary = "KEEP FOR WORK",
        NeverTerminateExact = ["System"]
    };

    private sealed class FakeSnap : IProcessSnapshotProvider
    {
        public ProcessSnapshot? Current { get; set; }
        public ProcessSnapshot? Recheck { get; set; }
        public ProcessSnapshot? PostState { get; set; }
        public bool FailPostRead { get; set; }
        public int Calls { get; private set; }
        private int _liveReads;

        public Task<ProcessSnapshot?> GetLiveSnapshotAsync(int processId, string processName, CancellationToken ct = default)
        {
            Calls++;
            _liveReads++;
            if (_liveReads > 1)
            {
                if (FailPostRead)
                    return Task.FromResult<ProcessSnapshot?>(null);
                if (PostState is not null)
                    return Task.FromResult<ProcessSnapshot?>(PostState);
            }
            return Task.FromResult(Current);
        }

        public Task<LiveProcessHandle?> GetLiveSnapshotWithHandleAsync(
            int processId, string processName, CancellationToken ct = default)
        {
            Calls++;
            var snap = Recheck ?? Current;
            if (snap is null)
                return Task.FromResult<LiveProcessHandle?>(null);
            // Unit tests: open a disposable handle to self (Dispose releases handle, does not kill).
            return Task.FromResult<LiveProcessHandle?>(new LiveProcessHandle(snap, Process.GetCurrentProcess()));
        }
    }

    private sealed class FakeMutator : IProcessMutator
    {
        public int ThrottleCalls { get; private set; }
        public int TerminateCalls { get; private set; }
        public bool FailThrottle { get; set; }

        public Task ThrottleBelowNormalAsync(Process handle, ProcessIdentity expectedIdentity, CancellationToken ct = default)
        {
            ArgumentNullException.ThrowIfNull(handle);
            ArgumentNullException.ThrowIfNull(expectedIdentity);
            ThrottleCalls++;
            if (FailThrottle)
                throw new InvalidOperationException("priority api failed");
            return Task.CompletedTask;
        }

        public Task TerminateAsync(int processId, CancellationToken ct = default)
        {
            TerminateCalls++;
            return Task.CompletedTask;
        }

        public Task TerminateOpenProcessAsync(Process handle, ProcessIdentity expectedIdentity, CancellationToken ct = default) =>
            throw new NotSupportedException();
    }

    [Fact]
    public async Task Throttle_Writes_Real_PreviousPriority_Before_Mutate_Checkpoint()
    {
        var dir = Path.Combine(Path.GetTempPath(), "hub-crash-safe-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(dir);
        try
        {
            Environment.SetEnvironmentVariable(CrashSafeApplyContract.StopAfterRollbackEnv, "1");
            var snapProvider = new FakeSnap
            {
                Current = new ProcessSnapshot(4242, "notepad", 10, 1, true, "Normal", @"C:\Windows\notepad.exe", false, 999888777)
            };
            var mutator = new FakeMutator();
            var input = new ProcessSnapshotInput(4242, "notepad", 10);
            var nec = new ProcessNecessity("Unknown", "Review", "Unknown", "");
            var adv = ResolutionAdvisoryService.BuildAdvisory(input, new KnowledgeHintInput(), Config(), nec);

            var result = await ResolutionExecutionService.ApplyAsync(
                "ThrottleBelowNormal", input, adv, nec, Config(), mutator,
                skipAuth: true, authVerified: true, rollbackDirectory: dir, snapshots: snapProvider);

            Assert.Equal("RollbackCheckpoint", result.Outcome);
            Assert.Equal(0, mutator.ThrottleCalls);
            Assert.False(string.IsNullOrWhiteSpace(result.RollbackPath));
            Assert.True(File.Exists(result.RollbackPath!));
            var json = await File.ReadAllTextAsync(result.RollbackPath!);
            Assert.Contains("\"PreviousPriority\": \"Normal\"", json);
            Assert.DoesNotContain("\"PreviousPriority\": \"Unknown\"", json);
            Assert.Contains("999888777", json);
        }
        finally
        {
            Environment.SetEnvironmentVariable(CrashSafeApplyContract.StopAfterRollbackEnv, null);
            try { Directory.Delete(dir, true); } catch { }
        }
    }

    [Fact]
    public async Task Throttle_Aborts_On_Identity_Mismatch()
    {
        var dir = Path.Combine(Path.GetTempPath(), "hub-crash-safe-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(dir);
        try
        {
            Environment.SetEnvironmentVariable(CrashSafeApplyContract.StopAfterRollbackEnv, null);
            var snapProvider = new FakeSnap
            {
                Current = new ProcessSnapshot(100, "old", 10, 1, true, "Normal", @"C:\a.exe", false, 111),
                Recheck = new ProcessSnapshot(100, "new", 10, 1, true, "Normal", @"C:\b.exe", false, 222)
            };
            var mutator = new FakeMutator();
            var input = new ProcessSnapshotInput(100, "old", 10);
            var nec = new ProcessNecessity("Unknown", "Review", "Unknown", "");
            var adv = ResolutionAdvisoryService.BuildAdvisory(input, new KnowledgeHintInput(), Config(), nec);

            var result = await ResolutionExecutionService.ApplyAsync(
                "ThrottleBelowNormal", input, adv, nec, Config(), mutator,
                skipAuth: true, authVerified: true, rollbackDirectory: dir, snapshots: snapProvider);

            Assert.Equal("PidIdentityMismatch", result.Outcome);
            Assert.Equal(0, mutator.ThrottleCalls);
            Assert.True(File.Exists(result.RollbackPath!));
        }
        finally
        {
            try { Directory.Delete(dir, true); } catch { }
        }
    }

    [Fact]
    public async Task Throttle_Mutates_When_Identity_Stable()
    {
        var dir = Path.Combine(Path.GetTempPath(), "hub-crash-safe-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(dir);
        try
        {
            var live = new ProcessSnapshot(55, "ok", 10, 1, true, "AboveNormal", @"C:\ok.exe", false, 555);
            var after = new ProcessSnapshot(55, "ok", 10, 1, true, "BelowNormal", @"C:\ok.exe", false, 555);
            var snapProvider = new FakeSnap { Current = live, Recheck = live, PostState = after };
            var mutator = new FakeMutator();
            var input = new ProcessSnapshotInput(55, "ok", 10);
            var nec = new ProcessNecessity("Unknown", "Review", "Unknown", "");
            var adv = ResolutionAdvisoryService.BuildAdvisory(input, new KnowledgeHintInput(), Config(), nec);

            var result = await ResolutionExecutionService.ApplyAsync(
                "ThrottleBelowNormal", input, adv, nec, Config(), mutator,
                skipAuth: true, authVerified: true, rollbackDirectory: dir, snapshots: snapProvider);

            Assert.Equal("Throttled", result.Outcome);
            Assert.Equal(1, mutator.ThrottleCalls);
            var json = await File.ReadAllTextAsync(result.RollbackPath!);
            Assert.Contains("\"PreviousPriority\": \"AboveNormal\"", json);
            Assert.Contains("Process priority was changed to Below Normal.", result.Message);
        }
        finally
        {
            try { Directory.Delete(dir, true); } catch { }
        }
    }

    [Fact]
    public async Task Throttle_PostState_Normal_Is_Not_Throttled()
    {
        var live = Snap(77, "Normal");
        var (result, mutator) = await Apply(live, Snap(77, "Normal"));
        Assert.Equal(1, mutator.ThrottleCalls);
        Assert.Equal("StateMismatch", result.Outcome);
        Assert.NotEqual("Throttled", result.Outcome);
    }

    [Fact]
    public async Task Throttle_PostRead_Failure_Is_Not_Throttled()
    {
        var (result, mutator) = await Apply(Snap(77, "Normal"), post: null, failPostRead: true);
        Assert.Equal(1, mutator.ThrottleCalls);
        Assert.Equal("StateUnverified", result.Outcome);
        Assert.NotEqual("Throttled", result.Outcome);
    }

    [Fact]
    public async Task Throttle_Process_Exit_Before_Proof_Is_Not_Throttled()
    {
        var (result, mutator) = await Apply(Snap(77, "Normal"), Snap(77, "BelowNormal", notRunning: true));
        Assert.Equal(1, mutator.ThrottleCalls);
        Assert.Equal("StateUnverified", result.Outcome);
        Assert.NotEqual("Throttled", result.Outcome);
    }

    [Fact]
    public async Task Throttle_Pid_Reuse_Is_Rejected()
    {
        var live = Snap(77, "Normal");
        var reused = new ProcessSnapshot(77, "other", 10, 1, true, "BelowNormal", @"C:\other.exe", false, 999);
        var (result, mutator) = await Apply(live, reused);
        Assert.Equal(1, mutator.ThrottleCalls);
        Assert.Equal("PidIdentityMismatch", result.Outcome);
        Assert.NotEqual("Throttled", result.Outcome);
    }

    [Fact]
    public async Task Throttle_Mutation_Failure_Keeps_Existing_Failure_Outcome()
    {
        var (result, mutator) = await Apply(Snap(77, "Normal"), Snap(77, "BelowNormal"), failThrottle: true);
        Assert.Equal(1, mutator.ThrottleCalls);
        Assert.Equal("PidIdentityMismatch", result.Outcome);
        Assert.Contains("priority api failed", result.Message);
        Assert.NotEqual("Throttled", result.Outcome);
    }

    [Fact]
    public async Task Throttle_Already_BelowNormal_Still_Requires_Proof()
    {
        var (result, mutator) = await Apply(Snap(77, "BelowNormal"), Snap(77, "BelowNormal"));
        Assert.Equal(1, mutator.ThrottleCalls);
        Assert.Equal("Throttled", result.Outcome);
    }

    [Fact]
    public async Task Throttle_Unknown_Priority_Is_Not_Proof()
    {
        var (result, _) = await Apply(Snap(77, "Normal"), Snap(77, "Unknown"));
        Assert.Equal("StateMismatch", result.Outcome);
        Assert.NotEqual("Throttled", result.Outcome);
    }

    private static ProcessSnapshot Snap(int pid, string priority, bool notRunning = false) =>
        new(pid, "ok", 10, 1, true, priority, @"C:\ok.exe", notRunning, 555);

    private static async Task<(ProcessResolutionResult Result, FakeMutator Mutator)> Apply(
        ProcessSnapshot before,
        ProcessSnapshot? post,
        bool failPostRead = false,
        bool failThrottle = false)
    {
        var snaps = new FakeSnap
        {
            Current = before,
            Recheck = before,
            PostState = post,
            FailPostRead = failPostRead
        };
        var mutator = new FakeMutator { FailThrottle = failThrottle };
        var input = new ProcessSnapshotInput(before.Pid, before.ProcessName, before.RamMb);
        var nec = new ProcessNecessity("Unknown", "Review", "Unknown", "");
        var adv = ResolutionAdvisoryService.BuildAdvisory(input, new KnowledgeHintInput(), Config(), nec);
        var result = await ResolutionExecutionService.ApplyAsync(
            "ThrottleBelowNormal", input, adv, nec, Config(), mutator,
            skipAuth: true, authVerified: true, snapshots: snaps);
        return (result, mutator);
    }
}
