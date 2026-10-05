using System.Text.Json;
using SystemOptimizerHub.Core.Performance;
using SystemOptimizerHub.Windows;

namespace SystemOptimizerHub.Core.Tests;

public class PerformanceEvidenceTests
{
    private const long FakeTotal = 16L * 1024 * 1024 * 1024;
    private const long FakeAvailable = 4L * 1024 * 1024 * 1024;

    [Fact]
    public void Ram_reader_success_publishes_physical_and_commit()
    {
        var evidence = RamEvidenceFactory.From(WindowsMemoryStatusMapper.Map(
            new WindowsMemoryStatus(true, 32UL << 30, 8UL << 30, 40UL << 30, 12UL << 30)));

        Assert.Equal(MetricAvailability.Observed, evidence.TotalBytes.Availability);
        Assert.Equal(32L << 30, evidence.TotalBytes.Value);
        Assert.Equal(8L << 30, evidence.AvailableBytes.Value);
        Assert.Equal(24L << 30, evidence.UsedBytes.Value);
        Assert.Equal(40L << 30, evidence.CommitLimitBytes.Value);
        Assert.Equal(12L << 30, evidence.CommitAvailableBytes.Value);
        Assert.Equal(28L << 30, evidence.CommitUsedBytes.Value);
        Assert.Equal(MetricAvailability.NotSupported, evidence.PagefileTotalBytes.Availability);
        Assert.Null(evidence.PagefileTotalBytes.Value);
    }

    [Fact]
    public void Ram_reader_failure_is_unavailable()
    {
        var evidence = RamEvidenceFactory.From(WindowsMemoryStatusMapper.Map(
            new WindowsMemoryStatus(false, 0, 0, 0, 0)));

        Assert.Equal(MetricAvailability.Unavailable, evidence.TotalBytes.Availability);
        Assert.Equal(MetricAvailability.Unavailable, evidence.AvailableBytes.Availability);
        Assert.Equal(MetricAvailability.Unavailable, evidence.UsedBytes.Availability);
        Assert.Equal(MetricAvailability.Unavailable, evidence.CommitLimitBytes.Availability);
        Assert.Null(evidence.TotalBytes.Value);
        Assert.Null(evidence.AvailableBytes.Value);
        Assert.Null(evidence.CommitUsedBytes.Value);
    }

    [Fact]
    public void Ram_reader_failure_does_not_publish_the_legacy_fake_fallback()
    {
        var evidence = RamEvidenceFactory.From(WindowsMemoryStatusMapper.Map(
            new WindowsMemoryStatus(false, (ulong)FakeTotal, (ulong)FakeAvailable, 0, 0)));

        Assert.Null(evidence.TotalBytes.Value);
        Assert.Null(evidence.AvailableBytes.Value);
        Assert.NotEqual(FakeTotal, evidence.TotalBytes.Value);
        Assert.NotEqual(FakeAvailable, evidence.AvailableBytes.Value);
    }

    [Fact]
    public void Cpu_sample_pair_preserves_identity_and_computes_delta()
    {
        var start = new DateTimeOffset(2026, 10, 5, 8, 0, 0, TimeSpan.Zero);
        var snapshot = Build(
            Sample(start, 2, Process(10, 100, "a.exe", 1, responding: true)),
            Sample(start.AddSeconds(2), 2, Process(10, 100, "a.exe", 5, responding: true)));

        var row = Assert.Single(snapshot.ProcessTopConsumers);
        Assert.Equal("10:100", row.IdentityKey);
        Assert.True(row.IdentityPathMatches);
        Assert.Equal(1, row.CpuTimeBaselineSeconds.Value);
        Assert.Equal(5, row.CpuTimeCurrentSeconds.Value);
        Assert.Equal(4, row.CpuDeltaSeconds.Value);
        Assert.Equal(MetricAvailability.Observed, row.CpuTimeAdvanced.Availability);
        Assert.True(row.CpuTimeAdvanced.Value);
        Assert.Equal(100d, row.CpuUtilizationPercent.Value);
        Assert.Equal(2, snapshot.SampleDurationSeconds.Value);
        Assert.Equal(MetricAvailability.Observed, snapshot.Window);
    }

    [Fact]
    public void Cpu_delta_zero_is_observed_not_progressing()
    {
        var start = new DateTimeOffset(2026, 10, 5, 8, 0, 0, TimeSpan.Zero);
        var snapshot = Build(
            Sample(start, Process(10, 100, "a.exe", 3, responding: true)),
            Sample(start.AddSeconds(1), Process(10, 100, "a.exe", 3, responding: true)));

        var row = Assert.Single(snapshot.ProcessTopConsumers);
        Assert.Equal(0, row.CpuDeltaSeconds.Value);
        Assert.Equal(MetricAvailability.Observed, row.CpuTimeAdvanced.Availability);
        Assert.False(row.CpuTimeAdvanced.Value);
        Assert.Equal(1, snapshot.Progress.CpuTimeNotAdvancedCount);
    }

    [Fact]
    public void Invalid_elapsed_time_does_not_invent_a_percentage()
    {
        var start = new DateTimeOffset(2026, 10, 5, 8, 0, 0, TimeSpan.Zero);
        var snapshot = Build(
            Sample(start, Process(10, 100, "a.exe", 1, responding: true)),
            Sample(start, Process(10, 100, "a.exe", 4, responding: true)));

        var row = Assert.Single(snapshot.ProcessTopConsumers);
        Assert.Equal(MetricAvailability.Unknown, snapshot.SampleDurationSeconds.Availability);
        Assert.Null(snapshot.SampleDurationSeconds.Value);
        Assert.Equal(MetricAvailability.Unknown, snapshot.Window);
        Assert.Equal(3, row.CpuDeltaSeconds.Value);
        Assert.Equal(MetricAvailability.Unknown, row.CpuUtilizationPercent.Availability);
        Assert.Null(row.CpuUtilizationPercent.Value);
    }

    [Fact]
    public void Process_identity_change_is_not_paired()
    {
        var start = new DateTimeOffset(2026, 10, 5, 8, 0, 0, TimeSpan.Zero);
        var snapshot = Build(
            Sample(start, Process(10, 100, @"C:\old.exe", 1, responding: true)),
            Sample(start.AddSeconds(1), Process(10, 200, @"C:\new.exe", 9, responding: true)));

        Assert.Equal("10:200", Assert.Single(snapshot.ProcessTopConsumers).IdentityKey);
        Assert.Equal(MetricAvailability.Unavailable, snapshot.ProcessTopConsumers[0].CpuTimeBaselineSeconds.Availability);
        Assert.Null(snapshot.ProcessTopConsumers[0].CpuDeltaSeconds.Value);
        var drift = Assert.Single(snapshot.IdentityDrift);
        Assert.Equal(10, drift.Pid);
        Assert.Equal(100, drift.BaselineStartTimeUtcTicks);
        Assert.Equal(200, drift.CurrentStartTimeUtcTicks);
        Assert.Contains("10:100", snapshot.AbsentFromCurrentSample);
        Assert.Contains("10:200", snapshot.AppearedInCurrentSample);
    }

    [Fact]
    public void Responding_available_is_observed()
    {
        var snapshot = Pair(Process(4, 50, "a.exe", 1, responding: false), Process(4, 50, "a.exe", 2, responding: false));
        var row = Assert.Single(snapshot.ProcessTopConsumers);
        Assert.Equal(MetricAvailability.Observed, row.Responding.Availability);
        Assert.False(row.Responding.Value);
        Assert.Equal(1, snapshot.Progress.RespondingObservedCount);
    }

    [Fact]
    public void Responding_unavailable_has_no_boolean_value()
    {
        var snapshot = Pair(
            Process(4, 50, "a.exe", 1, responding: null),
            Process(4, 50, "a.exe", 2, responding: null));
        var row = Assert.Single(snapshot.ProcessTopConsumers);
        Assert.Equal(MetricAvailability.Unavailable, row.Responding.Availability);
        Assert.Null(row.Responding.Value);
        Assert.Equal(1, snapshot.Progress.RespondingUnavailableCount);
    }

    [Fact]
    public void Gpu_is_not_supported_and_has_no_zero_value()
    {
        var snapshot = Pair(Process(1, 1, "a.exe", 0, true), Process(1, 1, "a.exe", 0, true));
        var json = JsonSerializer.Serialize(snapshot.Gpu);
        Assert.Equal(MetricAvailability.NotSupported, snapshot.Gpu.Utilization);
        Assert.Equal(MetricAvailability.NotSupported, snapshot.Gpu.Memory);
        Assert.DoesNotContain("0", json, StringComparison.Ordinal);
    }

    [Fact]
    public void Io_is_not_supported_and_has_no_zero_value()
    {
        var snapshot = Pair(Process(1, 1, "a.exe", 0, true), Process(1, 1, "a.exe", 0, true));
        var json = JsonSerializer.Serialize(snapshot.Io);
        Assert.Equal(MetricAvailability.NotSupported, snapshot.Io.DiskLatency);
        Assert.Equal(MetricAvailability.NotSupported, snapshot.Io.QueueDepth);
        Assert.Equal(MetricAvailability.NotSupported, snapshot.Io.ProcessIoBytes);
        Assert.DoesNotContain("0", json, StringComparison.Ordinal);
    }

    [Fact]
    public void Missing_process_is_listed_and_not_given_a_zero_delta()
    {
        var start = new DateTimeOffset(2026, 10, 5, 8, 0, 0, TimeSpan.Zero);
        var snapshot = Build(
            Sample(start, Process(7, 70, "gone.exe", 4, true), Process(8, 80, "stay.exe", 1, true)),
            Sample(start.AddSeconds(1), Process(8, 80, "stay.exe", 2, true)));

        Assert.Equal("8:80", Assert.Single(snapshot.ProcessTopConsumers).IdentityKey);
        Assert.Equal(new[] { "7:70" }, snapshot.AbsentFromCurrentSample);
        Assert.DoesNotContain(snapshot.ProcessTopConsumers, row => row.Pid == 7);
    }

    [Fact]
    public void Process_enumeration_is_bounded()
    {
        var start = new DateTimeOffset(2026, 10, 5, 8, 0, 0, TimeSpan.Zero);
        var many = Enumerable.Range(1, 20)
            .Select(pid => Process(pid, 1000 + pid, "p.exe", 1, true, workingSet: pid * 10))
            .ToArray();
        var later = many.Select(row => Process(row.Pid, row.StartTimeUtcTicks!.Value, row.ImagePath!, 2, true, row.WorkingSetBytes)).ToArray();
        var snapshot = Build(Sample(start, many), Sample(start.AddSeconds(1), later), maxProcesses: 3);

        Assert.Equal(3, snapshot.ProcessTopConsumers.Count);
        Assert.Equal(new[] { 18, 19, 20 }, snapshot.ProcessTopConsumers.Select(p => p.Pid).OrderBy(pid => pid).ToArray());
    }

    [Fact]
    public async Task Cancellation_does_not_return_a_snapshot()
    {
        using var cts = new CancellationTokenSource();
        cts.Cancel();
        var source = new CountingSource();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
            PerformanceEvidenceCollector.CollectAsync(source, TimeSpan.FromMilliseconds(200), 15, cts.Token));
        Assert.Equal(0, source.Calls);
    }

    [Fact]
    public void Snapshot_serialization_is_deterministic_and_omits_unavailable_values()
    {
        var start = new DateTimeOffset(2026, 10, 5, 8, 0, 0, TimeSpan.Zero);
        var first = Build(
            Sample(start, Process(2, 20, "b.exe", 1, null), Process(1, 10, "a.exe", 1, true)),
            Sample(start.AddSeconds(1), Process(2, 20, "b.exe", 1, null), Process(1, 10, "a.exe", 2, true)));
        var second = Build(
            Sample(start, Process(1, 10, "a.exe", 1, true), Process(2, 20, "b.exe", 1, null)),
            Sample(start.AddSeconds(1), Process(1, 10, "a.exe", 2, true), Process(2, 20, "b.exe", 1, null)));

        var options = new JsonSerializerOptions { WriteIndented = false };
        var jsonA = JsonSerializer.Serialize(first, options);
        var jsonB = JsonSerializer.Serialize(second, options);
        Assert.Equal(jsonA, jsonB);
        Assert.Equal(new[] { "1:10", "2:20" }, first.ProcessTopConsumers.Select(p => p.IdentityKey).ToArray());
        Assert.Contains("\"Availability\":\"Unavailable\"", jsonA, StringComparison.Ordinal);
        Assert.DoesNotContain("\"Responding\":{\"Availability\":\"Unavailable\",\"Value\"", jsonA, StringComparison.Ordinal);
    }

    private static PerformanceSnapshot Pair(ProcessRawObservation baseline, ProcessRawObservation current)
    {
        var start = new DateTimeOffset(2026, 10, 5, 8, 0, 0, TimeSpan.Zero);
        return Build(Sample(start, baseline), Sample(start.AddSeconds(1), current));
    }

    private static PerformanceSnapshot Build(
        PerformanceRawSample baseline,
        PerformanceRawSample current,
        int maxProcesses = 15) =>
        PerformanceEvidenceBuilder.Build(baseline, current, maxProcesses);

    private static PerformanceRawSample Sample(DateTimeOffset timestamp, params ProcessRawObservation[] processes) =>
        Sample(timestamp, 1, processes);

    private static PerformanceRawSample Sample(
        DateTimeOffset timestamp,
        int logicalProcessors,
        params ProcessRawObservation[] processes) => new()
    {
        TimestampUtc = timestamp,
        LogicalProcessors = logicalProcessors,
        Ram = RamSample.Unread(),
        SystemCpu = SystemCpuRaw.NotSupported(),
        Processes = processes,
        ProcessEnumeration = MetricAvailability.Observed
    };

    private static ProcessRawObservation Process(
        int pid,
        long startTicks,
        string path,
        double cpuSeconds,
        bool? responding,
        long? workingSet = 1024) => new()
    {
        Pid = pid,
        StartTimeUtcTicks = startTicks,
        ProcessName = Path.GetFileNameWithoutExtension(path),
        ImagePath = path,
        CpuTimeSeconds = cpuSeconds,
        WorkingSetBytes = workingSet,
        PrivateBytes = workingSet,
        Responding = responding
    };

    private sealed class CountingSource : IPerformanceSampleSource
    {
        public int Calls { get; private set; }

        public PerformanceRawSample Capture(int maxProcesses, CancellationToken cancellationToken)
        {
            Calls++;
            cancellationToken.ThrowIfCancellationRequested();
            return new PerformanceRawSample { TimestampUtc = DateTimeOffset.UnixEpoch };
        }
    }
}
