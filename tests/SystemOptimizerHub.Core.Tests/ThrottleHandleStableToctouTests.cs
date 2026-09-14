using System.Diagnostics;
using SystemOptimizerHub.Abstractions;
using SystemOptimizerHub.Windows;

namespace SystemOptimizerHub.Core.Tests;

/// <summary>
/// T1 — TOCTOU / PID-reuse simulation for Core Throttle handle-stable contract.
/// Uses a real OS Process handle (no production changes); does not require true OS PID reuse.
/// </summary>
public class ThrottleHandleStableToctouTests
{
    private static IProcessMutator Mutator() => WindowsPlatform.CreateServices().ProcessMutator;

    private static Process StartDisposableNotepad()
    {
        var psi = new ProcessStartInfo
        {
            FileName = "notepad.exe",
            UseShellExecute = true,
            WindowStyle = ProcessWindowStyle.Hidden
        };
        var proc = Process.Start(psi)
            ?? throw new InvalidOperationException("Failed to start notepad for T1.");
        // Ensure StartTime / Id are populated before identity capture.
        proc.Refresh();
        return proc;
    }

    private static ProcessIdentity CaptureIdentity(Process handle)
    {
        string path = string.Empty;
        try { path = handle.MainModule?.FileName ?? string.Empty; } catch { /* may require elevation */ }
        long startTicks = 0;
        try { startTicks = handle.StartTime.ToUniversalTime().Ticks; } catch { }
        return new ProcessIdentity(handle.Id, handle.ProcessName, path, startTicks);
    }

    [Fact]
    public async Task T1_ThrottleBelowNormal_Aborts_When_Handle_HasExited()
    {
        if (!OperatingSystem.IsWindows())
            return; // Windows mutator path only

        Process? victim = null;
        Process? decoy = null;
        try
        {
            victim = StartDisposableNotepad();
            var expected = CaptureIdentity(victim);
            Assert.True(expected.StartTimeUtcTicks > 0, "Victim StartTime required for meaningful T1 setup.");

            victim.Kill(entireProcessTree: true);
            Assert.True(victim.WaitForExit(10_000), "Victim did not exit in time.");
            victim.Refresh();
            Assert.True(victim.HasExited);

            // Decoy proves we do not fall back to a fresh Pid lookup and mutate another process.
            decoy = StartDisposableNotepad();
            var decoyBefore = decoy.PriorityClass;

            var mutator = Mutator();
            var ex = await Assert.ThrowsAsync<InvalidOperationException>(
                () => mutator.ThrottleBelowNormalAsync(victim, expected, CancellationToken.None));

            Assert.Contains("abort", ex.Message, StringComparison.OrdinalIgnoreCase);
            Assert.Contains("exited", ex.Message, StringComparison.OrdinalIgnoreCase);
            Assert.Contains("no Pid re-lookup", ex.Message, StringComparison.OrdinalIgnoreCase);

            decoy.Refresh();
            Assert.Equal(decoyBefore, decoy.PriorityClass);
            Assert.NotEqual(ProcessPriorityClass.BelowNormal, decoy.PriorityClass);
        }
        finally
        {
            TryKillDispose(victim);
            TryKillDispose(decoy);
        }
    }

    [Fact]
    public async Task T1_ThrottleBelowNormal_Aborts_When_Live_Handle_Identity_Mismatches()
    {
        if (!OperatingSystem.IsWindows())
            return;

        Process? live = null;
        try
        {
            live = StartDisposableNotepad();
            live.Refresh();
            var before = live.PriorityClass;
            Assert.False(live.HasExited);

            // Simulate PID reuse: same Pid on the handle, but StartTime/Path belong to a different process.
            var wrongStart = live.StartTime.ToUniversalTime().Ticks + TimeSpan.FromMinutes(5).Ticks;
            Assert.NotEqual(0, wrongStart);
            var expected = new ProcessIdentity(
                live.Id,
                live.ProcessName,
                @"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe",
                wrongStart);

            var mutator = Mutator();
            var ex = await Assert.ThrowsAsync<InvalidOperationException>(
                () => mutator.ThrottleBelowNormalAsync(live, expected, CancellationToken.None));

            Assert.Contains("abort", ex.Message, StringComparison.OrdinalIgnoreCase);
            Assert.Contains("mismatch", ex.Message, StringComparison.OrdinalIgnoreCase);

            live.Refresh();
            Assert.Equal(before, live.PriorityClass);
            Assert.NotEqual(ProcessPriorityClass.BelowNormal, live.PriorityClass);
        }
        finally
        {
            TryKillDispose(live);
        }
    }

    [Fact]
    public async Task T1c_ThrottleBelowNormal_Aborts_When_Identity_Field_Unreadable()
    {
        if (!OperatingSystem.IsWindows())
            return;

        Process? live = null;
        try
        {
            live = StartDisposableNotepad();
            live.Refresh();
            var before = live.PriorityClass;
            Assert.False(live.HasExited);

            var readableStart = live.StartTime.ToUniversalTime().Ticks;
            Assert.True(readableStart > 0);

            // Expected StartTime unreadable (0) — must fail-closed, no soft-skip.
            var expectedStartUnreadable = new ProcessIdentity(
                live.Id,
                live.ProcessName,
                @"C:\Windows\System32\notepad.exe",
                StartTimeUtcTicks: 0);

            var mutator = Mutator();
            var exStart = await Assert.ThrowsAsync<InvalidOperationException>(
                () => mutator.ThrottleBelowNormalAsync(live, expectedStartUnreadable, CancellationToken.None));
            Assert.Contains("IdentityFieldUnreadable", exStart.Message, StringComparison.Ordinal);
            Assert.Contains("StartTimeUtcTicks", exStart.Message, StringComparison.Ordinal);
            Assert.Contains("abort", exStart.Message, StringComparison.OrdinalIgnoreCase);

            // Expected ImagePath unreadable (empty) — same exception family, distinct reason.
            var expectedPathUnreadable = new ProcessIdentity(
                live.Id,
                live.ProcessName,
                ImagePath: "",
                StartTimeUtcTicks: readableStart);

            var exPath = await Assert.ThrowsAsync<InvalidOperationException>(
                () => mutator.ThrottleBelowNormalAsync(live, expectedPathUnreadable, CancellationToken.None));
            Assert.Contains("IdentityFieldUnreadable", exPath.Message, StringComparison.Ordinal);
            Assert.Contains("ImagePath", exPath.Message, StringComparison.Ordinal);
            Assert.Contains("abort", exPath.Message, StringComparison.OrdinalIgnoreCase);

            live.Refresh();
            Assert.Equal(before, live.PriorityClass);
            Assert.NotEqual(ProcessPriorityClass.BelowNormal, live.PriorityClass);
        }
        finally
        {
            TryKillDispose(live);
        }
    }

    private static void TryKillDispose(Process? proc)
    {
        if (proc is null) return;
        try
        {
            if (!proc.HasExited)
            {
                proc.Kill(entireProcessTree: true);
                proc.WaitForExit(5_000);
            }
        }
        catch { /* best-effort cleanup */ }
        try { proc.Dispose(); } catch { }
    }
}
