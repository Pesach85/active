using System.Diagnostics;
using SystemOptimizerHub.Abstractions;
using SystemOptimizerHub.Core.Models;
using SystemOptimizerHub.Core.Resolution;

namespace SystemOptimizerHub.Core.Tests;

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
        public int Calls { get; private set; }

        public Task<ProcessSnapshot?> GetLiveSnapshotAsync(int processId, string processName, CancellationToken ct = default)
        {
            Calls++;
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

        public Task ThrottleBelowNormalAsync(Process handle, ProcessIdentity expectedIdentity, CancellationToken ct = default)
        {
            ArgumentNullException.ThrowIfNull(handle);
            ArgumentNullException.ThrowIfNull(expectedIdentity);
            ThrottleCalls++;
            return Task.CompletedTask;
        }

        public Task TerminateAsync(int processId, CancellationToken ct = default)
        {
            TerminateCalls++;
            return Task.CompletedTask;
        }
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
            var snapProvider = new FakeSnap { Current = live, Recheck = live };
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
        }
        finally
        {
            try { Directory.Delete(dir, true); } catch { }
        }
    }
}
