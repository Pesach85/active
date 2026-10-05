using System.Text.Json;
using SystemOptimizerHub.Core.Performance;

namespace SystemOptimizerHub.Core.Tests;

public class PerformancePersistenceWindowTests
{
    [Fact]
    public void Four_captures_publish_sample_count_four()
    {
        var snapshot = Window(advancing: 3);

        Assert.Equal(4, snapshot.SampleCount);
    }

    [Fact]
    public void Three_advancing_intervals_are_positive()
    {
        var snapshot = Window(advancing: 3);

        Assert.Equal(4, snapshot.SampleCount);
        Assert.Equal(3, snapshot.PositiveIntervalCount);
        Assert.Equal(MetricAvailability.Observed, snapshot.Window);
        Assert.Equal(3d, snapshot.SampleDurationSeconds.Value);
    }

    [Theory]
    [InlineData(2)]
    [InlineData(1)]
    [InlineData(0)]
    public void Fewer_than_three_positive_intervals_fail_persistence(int advancing)
    {
        var snapshot = Window(advancing);
        var diagnosis = PerformanceDiagnosisEngine.Diagnose(snapshot);

        Assert.Equal(4, snapshot.SampleCount);
        Assert.Equal(advancing, snapshot.PositiveIntervalCount);
        Assert.Contains("INSUFFICIENT_PERSISTENCE", diagnosis.EvidenceReasons);
        Assert.False(diagnosis.CpuPolicyMatched);
        Assert.NotEqual(PerformanceAutomationEligibility.AUTO_CANDIDATE, diagnosis.AutomationEligibility);
    }

    [Fact]
    public void Stable_identity_is_paired_from_the_first_sample_to_the_last()
    {
        var snapshot = Window(advancing: 3, cpu: [1, 2, 3, 5]);
        var row = Assert.Single(snapshot.ProcessTopConsumers);

        Assert.Equal("10:100", row.IdentityKey);
        Assert.Empty(snapshot.IdentityDrift);
        Assert.Equal(1d, row.CpuTimeBaselineSeconds.Value);
        Assert.Equal(5d, row.CpuTimeCurrentSeconds.Value);
        Assert.Equal(4d, row.CpuDeltaSeconds.Value);
        Assert.True(row.IdentityPathMatches);
    }

    [Theory]
    [InlineData(2, 200L)]
    [InlineData(3, 300L)]
    [InlineData(4, 400L)]
    public void Identity_drift_is_not_followed_across_the_same_pid(int replacementSample, long replacementTicks)
    {
        var ticks = new long[4];
        for (var index = 0; index < 4; index++)
            ticks[index] = index + 1 >= replacementSample ? replacementTicks : 100;
        var snapshot = Window(advancing: 3, ticks: ticks, cpu: [1, 10, 20, 30]);
        var drift = Assert.Single(snapshot.IdentityDrift);
        var row = Assert.Single(snapshot.ProcessTopConsumers);

        Assert.Equal(10, drift.Pid);
        Assert.Equal(100, drift.BaselineStartTimeUtcTicks);
        Assert.Equal(replacementTicks, drift.CurrentStartTimeUtcTicks);
        Assert.Equal(replacementSample, drift.ReplacementSampleIndex);
        Assert.Equal(PerformanceIdentity.Key(10, replacementTicks), row.IdentityKey);
        Assert.NotEqual("10:100", row.IdentityKey);
        Assert.Equal(MetricAvailability.Unavailable, row.CpuTimeBaselineSeconds.Availability);
        Assert.Null(row.CpuDeltaSeconds.Value);

        var diagnosis = PerformanceDiagnosisEngine.Diagnose(snapshot);
        Assert.Contains("IDENTITY_DRIFT", diagnosis.EvidenceReasons);
        Assert.DoesNotContain("10:100", diagnosis.CandidateTargets);
        Assert.NotEqual(PerformanceAutomationEligibility.AUTO_CANDIDATE, diagnosis.AutomationEligibility);
    }

    [Fact]
    public void Missing_intermediate_sample_is_recorded_and_is_not_termination()
    {
        var present = Process(10, 100, 1);
        var later = Process(10, 100, 4);
        var snapshot = PerformanceEvidenceBuilder.Build(
        [
            Sample(T(0), present),
            Sample(T(1)),
            Sample(T(2), Process(10, 100, 3)),
            Sample(T(3), later)
        ], 15);
        var diagnosis = PerformanceDiagnosisEngine.Diagnose(snapshot);
        var json = JsonSerializer.Serialize(diagnosis);

        Assert.Equal("10:100", Assert.Single(snapshot.ProcessTopConsumers).IdentityKey);
        Assert.Equal(new[] { "10:100" }, snapshot.AbsentFromIntermediateSample);
        Assert.Empty(snapshot.AbsentFromCurrentSample);
        Assert.Contains("absentFromRetainedWindowIsNotTermination", diagnosis.EvidenceReasons);
        Assert.DoesNotContain("PROCESS_TERMINATED", json);
        Assert.DoesNotContain("\"Terminated\"", json);
        Assert.DoesNotContain("10:100", diagnosis.CandidateTargets);
    }

    [Fact]
    public async Task Cancellation_during_an_interval_returns_no_snapshot()
    {
        using var cts = new CancellationTokenSource();
        var source = new ScriptedSource((call, token) =>
        {
            token.ThrowIfCancellationRequested();
            if (call == 1)
                cts.Cancel();
            return Sample(T(0), Process(10, 100, 1));
        });

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
            PerformanceEvidenceCollector.CollectAsync(source, TimeSpan.FromMilliseconds(200), 15, cts.Token));
        Assert.Equal(1, source.Calls);
    }

    [Fact]
    public async Task Cancellation_during_capture_returns_no_snapshot()
    {
        var source = new ScriptedSource((call, token) =>
        {
            if (call == 2)
                throw new OperationCanceledException(token);
            token.ThrowIfCancellationRequested();
            return Sample(T(call), Process(10, 100, call));
        });

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
            PerformanceEvidenceCollector.CollectAsync(source, TimeSpan.Zero, 15, CancellationToken.None));
        Assert.Equal(2, source.Calls);
    }

    [Fact]
    public void Incomplete_window_stays_fail_closed()
    {
        var snapshot = PerformanceEvidenceBuilder.Build(
        [
            Sample(T(0), Process(10, 100, 0), priorityReader: MetricAvailability.Observed),
            Sample(T(1), Process(10, 100, 1), priorityReader: MetricAvailability.Observed),
            Sample(T(2), Process(10, 100, 2), priorityReader: MetricAvailability.Observed)
        ], 15);
        var diagnosis = PerformanceDiagnosisEngine.Diagnose(snapshot);

        Assert.Equal(3, snapshot.SampleCount);
        Assert.True(snapshot.PositiveIntervalCount < 3);
        Assert.Contains("INSUFFICIENT_PERSISTENCE", diagnosis.EvidenceReasons);
        Assert.False(diagnosis.CpuPolicyMatched);
        Assert.NotEqual(PerformanceAutomationEligibility.AUTO_CANDIDATE, diagnosis.AutomationEligibility);
    }

    [Fact]
    public void Completed_window_can_match_cpu_policy_without_auto_candidate()
    {
        var snapshot = LoadedWindow(systemBusy100Ns: 30_000_000, cpuSeconds: [0, 0.8, 1.6, 2.4]);
        var diagnosis = PerformanceDiagnosisEngine.Diagnose(snapshot);

        Assert.Equal(4, snapshot.SampleCount);
        Assert.Equal(3, snapshot.PositiveIntervalCount);
        Assert.Equal(MetricAvailability.Observed, snapshot.Cpu.SystemUtilizationPercent.Availability);
        Assert.True(snapshot.Cpu.SystemUtilizationPercent.Value >= 90);
        Assert.True(Assert.Single(snapshot.ProcessTopConsumers).CpuUtilizationPercent.Value >= 40);
        Assert.True(diagnosis.CpuPolicyMatched);
        Assert.Equal(PerformanceAutomationEligibility.HITL_REQUIRED, diagnosis.AutomationEligibility);
        Assert.NotEqual(PerformanceAutomationEligibility.AUTO_CANDIDATE, diagnosis.AutomationEligibility);
        Assert.Contains("WALL_CLOCK_POLICY_UNDECIDED", diagnosis.PolicyBlockers);
    }

    [Fact]
    public void System_90_and_process_40_are_still_rejected_by_share()
    {
        var diagnosis = Diagnose(90, 40, samples: 4, intervals: 3);

        Assert.False(diagnosis.CpuPolicyMatched);
        Assert.Contains("PROCESS_SHARE_BELOW_THRESHOLD", diagnosis.EvidenceReasons);
        Assert.NotEqual(PerformanceAutomationEligibility.AUTO_CANDIDATE, diagnosis.AutomationEligibility);
    }

    [Fact]
    public void System_90_and_process_63_meet_the_share_boundary_without_auto_candidate()
    {
        var diagnosis = Diagnose(90, 63, samples: 4, intervals: 3);

        Assert.True(diagnosis.CpuPolicyMatched);
        Assert.Equal(PerformanceAutomationEligibility.HITL_REQUIRED, diagnosis.AutomationEligibility);
        Assert.Contains("WALL_CLOCK_POLICY_UNDECIDED", diagnosis.PolicyBlockers);
        Assert.Contains("COOLDOWN_UNDECIDED", diagnosis.PolicyBlockers);
    }

    [Fact]
    public void Wall_clock_duration_stays_undecided()
    {
        Assert.False(PerformanceDiagnosisPolicy.WallClockDurationApproved);
        Assert.False(PerformanceDiagnosisPolicy.AutoCandidatePermitted());
        Assert.Equal(90m, PerformanceDiagnosisPolicy.ApprovedSystemCpuPercent);
        Assert.Equal(40m, PerformanceDiagnosisPolicy.ApprovedProcessCpuPercent);
        Assert.Equal(0.70m, PerformanceDiagnosisPolicy.ApprovedProcessShareOfBusy);
        Assert.Equal(4, PerformanceDiagnosisPolicy.ApprovedMinimumSamples);
        Assert.Equal(3, PerformanceDiagnosisPolicy.ApprovedMinimumPositiveIntervals);

        var collector = File.ReadAllText(Repo("src", "SystemOptimizerHub.Core", "Performance", "PerformanceEvidenceCollector.cs"));
        Assert.DoesNotContain("FromSeconds(30)", collector, StringComparison.Ordinal);
        Assert.DoesNotContain("30000", collector, StringComparison.Ordinal);
    }

    [Fact]
    public async Task Collector_enumerates_once_per_capture_and_does_not_invent_intervals()
    {
        var source = new ScriptedSource((call, token) =>
        {
            token.ThrowIfCancellationRequested();
            return Sample(T(call - 1), Process(10, 100, call), enumeration: MetricAvailability.Observed);
        });
        var started = DateTimeOffset.UtcNow;
        var snapshot = await PerformanceEvidenceCollector.CollectAsync(source, TimeSpan.Zero, 15, CancellationToken.None);

        Assert.Equal(4, source.Calls);
        Assert.Equal(4, source.Enumerations);
        Assert.Equal(4, snapshot.SampleCount);
        Assert.Equal(3, snapshot.PositiveIntervalCount);
        Assert.Single(snapshot.ProcessTopConsumers);
        Assert.Equal(MetricAvailability.Observed, snapshot.ProcessEnumeration);
        Assert.True(DateTimeOffset.UtcNow - started < TimeSpan.FromSeconds(2));
    }

    private static PerformanceSnapshot Window(int advancing, double[]? cpu = null, long[]? ticks = null)
    {
        cpu ??= [1, 1, 1, 1];
        ticks ??= [100, 100, 100, 100];
        var samples = new PerformanceRawSample[4];
        var stamp = T(0);
        for (var index = 0; index < 4; index++)
        {
            if (index > 0 && index <= advancing)
                stamp = T(index);
            samples[index] = Sample(stamp, Process(10, ticks[index], cpu[index]));
        }

        return PerformanceEvidenceBuilder.Build(samples, 15);
    }

    private static PerformanceSnapshot LoadedWindow(long systemBusy100Ns, double[] cpuSeconds)
    {
        var samples = new PerformanceRawSample[4];
        for (var index = 0; index < 4; index++)
        {
            samples[index] = Sample(
                T(index),
                Process(10, 100, cpuSeconds[index], priority: ObservedProcessPriority.Normal),
                processors: 1,
                system: index == 0
                    ? SystemCpuRaw.Observed(0, 0, 0)
                    : SystemCpuRaw.Observed(0, 0, index == 3 ? systemBusy100Ns : 0),
                priorityReader: MetricAvailability.Observed);
        }

        return PerformanceEvidenceBuilder.Build(samples, 15);
    }

    private static PerformanceDiagnosis Diagnose(double system, double process, int samples, int intervals)
    {
        var row = new ProcessPerformanceEvidence
        {
            IdentityKey = "10:100",
            Pid = 10,
            StartTimeUtcTicks = 100,
            ProcessName = "worker",
            IdentityPathMatches = true,
            ImagePathState = MetricAvailability.Observed,
            ImagePath = @"C:\worker.exe",
            CpuTimeBaselineSeconds = PerformanceMetric<double>.Observed(1),
            CpuDeltaSeconds = PerformanceMetric<double>.Observed(1),
            CpuUtilizationPercent = PerformanceMetric<double>.Observed(process),
            CpuTimeAdvanced = PerformanceMetric<bool>.Observed(true),
            Responding = PerformanceMetric<bool>.Observed(true),
            PriorityCurrent = PerformanceMetric<ObservedProcessPriority>.Observed(ObservedProcessPriority.Normal)
        };
        return PerformanceDiagnosisEngine.Diagnose(new PerformanceSnapshot
        {
            SampleCount = samples,
            PositiveIntervalCount = intervals,
            SampleDurationSeconds = PerformanceMetric<double>.Observed(1),
            Window = MetricAvailability.Observed,
            Cpu = new CpuEvidence
            {
                LogicalProcessors = PerformanceMetric<int>.Observed(1),
                SystemUtilizationPercent = PerformanceMetric<double>.Observed(system)
            },
            ProcessEnumeration = MetricAvailability.Observed,
            ProcessTopConsumers = [row]
        });
    }

    private static DateTimeOffset T(int seconds) =>
        new DateTimeOffset(2026, 10, 5, 8, 0, 0, TimeSpan.Zero).AddSeconds(seconds);

    private static PerformanceRawSample Sample(
        DateTimeOffset timestamp,
        ProcessRawObservation? process = null,
        int processors = 1,
        SystemCpuRaw? system = null,
        MetricAvailability priorityReader = MetricAvailability.NotSupported,
        MetricAvailability enumeration = MetricAvailability.Observed) => new()
    {
        TimestampUtc = timestamp,
        LogicalProcessors = processors,
        Ram = RamSample.Unread(),
        SystemCpu = system ?? SystemCpuRaw.NotSupported(),
        Processes = process is null ? [] : [process],
        ProcessEnumeration = enumeration,
        ProcessPriorityReader = priorityReader
    };

    private static ProcessRawObservation Process(
        int pid,
        long startTicks,
        double cpuSeconds,
        ObservedProcessPriority? priority = null) => new()
    {
        Pid = pid,
        StartTimeUtcTicks = startTicks,
        ProcessName = "worker",
        ImagePath = @"C:\worker.exe",
        CpuTimeSeconds = cpuSeconds,
        WorkingSetBytes = 1024,
        PrivateBytes = 1024,
        Responding = true,
        Priority = priority is null ? MetricAvailability.Unavailable : MetricAvailability.Observed,
        PriorityValue = priority
    };

    private static string Repo(params string[] parts)
    {
        var path = Path.GetFullPath(Path.Combine(new[] { AppContext.BaseDirectory, "..", "..", "..", "..", ".." }.Concat(parts).ToArray()));
        Assert.True(File.Exists(path), path);
        return path;
    }

    private sealed class ScriptedSource : IPerformanceSampleSource
    {
        private readonly Func<int, CancellationToken, PerformanceRawSample> _capture;

        public ScriptedSource(Func<int, CancellationToken, PerformanceRawSample> capture) => _capture = capture;

        public int Calls { get; private set; }

        public int Enumerations { get; private set; }

        public PerformanceRawSample Capture(int maxProcesses, CancellationToken cancellationToken)
        {
            Calls++;
            var sample = _capture(Calls, cancellationToken);
            if (sample.ProcessEnumeration == MetricAvailability.Observed)
                Enumerations++;
            return sample;
        }
    }
}
