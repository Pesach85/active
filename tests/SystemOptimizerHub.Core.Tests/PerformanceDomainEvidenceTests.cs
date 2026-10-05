using System.Diagnostics;
using System.Runtime.Versioning;
using System.Text.Json;
using SystemOptimizerHub.Core.Performance;
using SystemOptimizerHub.Windows;

namespace SystemOptimizerHub.Core.Tests;

public class PerformanceDomainEvidenceTests
{
    [Fact]
    public void Not_supported_domain_metrics_omit_a_numeric_value()
    {
        var metric = PerformanceMetric<long>.NotSupported();
        var json = JsonSerializer.Serialize(metric);

        Assert.Equal(MetricAvailability.NotSupported, metric.Availability);
        Assert.Null(metric.Value);
        Assert.DoesNotContain("\"Value\"", json, StringComparison.Ordinal);
    }

    [Fact]
    public void Unavailable_domain_metrics_omit_a_numeric_value()
    {
        var metric = PerformanceMetric<long>.Unavailable();
        var json = JsonSerializer.Serialize(metric);

        Assert.Equal(MetricAvailability.Unavailable, metric.Availability);
        Assert.Null(metric.Value);
        Assert.DoesNotContain("\"Value\"", json, StringComparison.Ordinal);
    }

    [Fact]
    public void Unknown_domain_metrics_omit_a_numeric_value()
    {
        var metric = PerformanceMetric<long>.Unknown();
        var json = JsonSerializer.Serialize(metric);

        Assert.Equal(MetricAvailability.Unknown, metric.Availability);
        Assert.Null(metric.Value);
        Assert.DoesNotContain("\"Value\"", json, StringComparison.Ordinal);
    }

    [Fact]
    public void Gpu_disk_latency_queue_and_thermal_stay_not_supported()
    {
        var snapshot = Window(ioReader: MetricAvailability.NotSupported);
        var gpu = JsonSerializer.Serialize(snapshot.Gpu);
        var io = JsonSerializer.Serialize(snapshot.Io);

        Assert.Equal(MetricAvailability.NotSupported, snapshot.Gpu.Utilization);
        Assert.Equal(MetricAvailability.NotSupported, snapshot.Gpu.Memory);
        Assert.Equal(MetricAvailability.NotSupported, snapshot.Gpu.Engine);
        Assert.Equal(MetricAvailability.NotSupported, snapshot.Gpu.Thermal);
        Assert.Equal(MetricAvailability.NotSupported, snapshot.Io.DiskLatency);
        Assert.Equal(MetricAvailability.NotSupported, snapshot.Io.QueueDepth);
        Assert.DoesNotContain("\"Value\"", gpu, StringComparison.Ordinal);
        Assert.DoesNotContain("0", io, StringComparison.Ordinal);
    }

    [Fact]
    public void Four_sample_window_deltas_cumulative_process_counters()
    {
        var snapshot = Window(ioReader: MetricAvailability.Observed);

        Assert.Equal(4, snapshot.SampleCount);
        Assert.Equal(3, snapshot.PositiveIntervalCount);
        Assert.Equal(MetricAvailability.Observed, snapshot.ProcessIoReader);
        Assert.Equal(MetricAvailability.Observed, snapshot.ProcessPageFaultReader);
        Assert.Equal(MetricAvailability.Observed, snapshot.Io.ProcessIoBytes);
        var row = Assert.Single(snapshot.ProcessTopConsumers);
        Assert.Equal(60L, row.IoReadBytesDelta.Value);
        Assert.Equal(7L, row.IoWriteBytesDelta.Value);
        Assert.Equal(4L, row.IoReadOperationsDelta.Value);
        Assert.Equal(2L, row.IoWriteOperationsDelta.Value);
        Assert.Equal(9L, row.PageFaultCountDelta.Value);
    }

    [Fact]
    public void Identity_drift_does_not_pair_domain_counters()
    {
        var start = T(0);
        var snapshot = PerformanceEvidenceBuilder.Build(
        [
            Sample(start, Row(100, read: 10, faults: 3), MetricAvailability.Observed),
            Sample(T(1), Row(200, read: 90, faults: 40), MetricAvailability.Observed)
        ], 15);
        var row = Assert.Single(snapshot.ProcessTopConsumers);

        Assert.Equal(2, Assert.Single(snapshot.IdentityDrift).ReplacementSampleIndex);
        Assert.Equal(MetricAvailability.Unavailable, row.IoReadBytesBaseline.Availability);
        Assert.Null(row.IoReadBytesDelta.Value);
        Assert.Null(row.PageFaultCountDelta.Value);
    }

    [Fact]
    public void Missing_intermediate_sample_keeps_the_endpoint_delta()
    {
        var present = Row(100, read: 10, faults: 2);
        var snapshot = PerformanceEvidenceBuilder.Build(
        [
            Sample(T(0), present, MetricAvailability.Observed),
            Sample(T(1), null, MetricAvailability.Observed),
            Sample(T(2), Row(100, read: 15, faults: 4), MetricAvailability.Observed),
            Sample(T(3), Row(100, read: 25, faults: 8), MetricAvailability.Observed)
        ], 15);

        Assert.Equal(new[] { "10:100" }, snapshot.AbsentFromIntermediateSample);
        Assert.Equal(15L, Assert.Single(snapshot.ProcessTopConsumers).IoReadBytesDelta.Value);
        Assert.Equal(6L, snapshot.ProcessTopConsumers[0].PageFaultCountDelta.Value);
    }

    [Fact]
    public void Decreasing_counter_is_unknown_and_has_no_value()
    {
        var snapshot = PerformanceEvidenceBuilder.Build(
        [
            Sample(T(0), Row(100, read: 50, faults: 8), MetricAvailability.Observed),
            Sample(T(1), Row(100, read: 10, faults: 8), MetricAvailability.Observed)
        ], 15);
        var delta = Assert.Single(snapshot.ProcessTopConsumers).IoReadBytesDelta;
        var json = JsonSerializer.Serialize(delta);

        Assert.Equal(MetricAvailability.Unknown, delta.Availability);
        Assert.Null(delta.Value);
        Assert.DoesNotContain("\"Value\"", json, StringComparison.Ordinal);
    }

    [Fact]
    public void Observed_reader_without_a_counter_is_unavailable()
    {
        var row = Row(100, read: null, faults: null);
        var snapshot = PerformanceEvidenceBuilder.Build(
        [
            Sample(T(0), row, MetricAvailability.Observed),
            Sample(T(1), row, MetricAvailability.Observed)
        ], 15);
        var current = Assert.Single(snapshot.ProcessTopConsumers);

        Assert.Equal(MetricAvailability.Unavailable, current.IoReadBytesCurrent.Availability);
        Assert.Null(current.IoReadBytesCurrent.Value);
        Assert.Equal(MetricAvailability.Unavailable, current.PageFaultCountDelta.Availability);
        Assert.Null(current.PageFaultCountDelta.Value);
    }

    [Fact]
    public void Cpu_pair_stays_valid_when_domain_readers_are_not_supported()
    {
        var start = T(0);
        var snapshot = PerformanceEvidenceBuilder.Build(
            CpuSample(start, 1),
            CpuSample(start.AddSeconds(2), 5),
            15);
        var row = Assert.Single(snapshot.ProcessTopConsumers);

        Assert.Equal(100d, row.CpuUtilizationPercent.Value);
        Assert.Equal(MetricAvailability.NotSupported, row.IoReadBytesDelta.Availability);
        Assert.Null(row.IoReadBytesDelta.Value);
        Assert.Equal(MetricAvailability.NotSupported, snapshot.Io.DiskLatency);
        Assert.Equal(MetricAvailability.NotSupported, snapshot.Gpu.Thermal);
    }

    [Fact]
    public async Task Cancellation_still_returns_no_domain_snapshot()
    {
        using var cts = new CancellationTokenSource();
        cts.Cancel();
        var source = new ThrowingSource();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
            PerformanceEvidenceCollector.CollectAsync(source, TimeSpan.FromMilliseconds(200), 15, cts.Token));
        Assert.Equal(0, source.Calls);
    }

    [Fact]
    public void Observed_pagefile_and_process_io_do_not_open_auto_candidate()
    {
        var ram = WindowsMemoryStatusMapper.WithPagefile(
            new RamSample
            {
                PhysicalObserved = true,
                TotalBytes = 1000,
                AvailableBytes = 400,
                CommitObserved = true,
                CommitLimitBytes = 2000,
                CommitAvailableBytes = 500,
                Pagefile = MetricAvailability.NotSupported
            },
            new PagefileObservation(MetricAvailability.Observed, 8192, 2048));
        var snapshot = PerformanceEvidenceBuilder.Build(
        [
            Sample(T(0), Row(100, read: 1, faults: 1), MetricAvailability.Observed, ram),
            Sample(T(1), Row(100, read: 2, faults: 2), MetricAvailability.Observed, ram),
            Sample(T(2), Row(100, read: 3, faults: 3), MetricAvailability.Observed, ram),
            Sample(T(3), Row(100, read: 4, faults: 4), MetricAvailability.Observed, ram)
        ], 15);
        var diagnosis = PerformanceDiagnosisEngine.Diagnose(snapshot);

        Assert.Equal(MetricAvailability.Observed, snapshot.Ram.PagefileTotalBytes.Availability);
        Assert.Equal(8192L, snapshot.Ram.PagefileTotalBytes.Value);
        Assert.NotEqual(PerformanceCause.IO_PRESSURE, diagnosis.PrimaryCause);
        Assert.NotEqual(PerformanceCause.PAGING_PRESSURE, diagnosis.PrimaryCause);
        Assert.NotEqual(PerformanceCause.GPU_PRESSURE, diagnosis.PrimaryCause);
        Assert.NotEqual(PerformanceAutomationEligibility.AUTO_CANDIDATE, diagnosis.AutomationEligibility);
        Assert.False(PerformanceDiagnosisPolicy.AutoCandidatePermitted());
        Assert.False(diagnosis.CpuPolicyMatched);
        Assert.Contains("UNSUPPORTED_DOMAIN_POLICY", diagnosis.PolicyBlockers);
        Assert.Contains("pagingClassificationInactive", diagnosis.UnknownReasons);
        Assert.Contains("ioNotSupported", diagnosis.UnknownReasons);
        Assert.Contains("gpuNotSupported", diagnosis.UnknownReasons);
    }

    [Fact]
    public void Pagefile_pages_do_not_invent_a_zero_total()
    {
        var empty = WindowsPagefileReader.FromPages(0, 0, 4096, 0);
        var inverted = WindowsPagefileReader.FromPages(1, 2, 4096, 1);
        var observed = WindowsPagefileReader.FromPages(4, 1, 4096, 2);

        Assert.Equal(MetricAvailability.Unavailable, empty.Availability);
        Assert.Equal(MetricAvailability.Unknown, inverted.Availability);
        Assert.Equal(MetricAvailability.Observed, observed.Availability);
        Assert.Equal(16384L, observed.TotalBytes);
        Assert.Equal(12288L, observed.AvailableBytes);
    }

    [Fact]
    [SupportedOSPlatform("windows")]
    public void Live_pagefile_and_process_counters_are_not_false_zeros()
    {
        var pagefile = WindowsPagefileReader.Read();
        Assert.NotEqual(MetricAvailability.NotSupported, pagefile.Availability);
        if (pagefile.Availability == MetricAvailability.Observed)
        {
            Assert.True(pagefile.TotalBytes > 0);
            Assert.InRange(pagefile.AvailableBytes, 0, pagefile.TotalBytes);
        }

        var counters = WindowsProcessCounterReader.Read(Process.GetCurrentProcess());
        Assert.NotNull(counters.ReadBytes);
        Assert.NotNull(counters.WriteBytes);
        Assert.NotNull(counters.PageFaults);
        Assert.True(counters.ReadBytes >= 0);
        Assert.True(counters.WriteBytes >= 0);
        Assert.True(counters.PageFaults >= 0);
    }

    [Fact]
    public void Domain_reader_sources_do_not_mutate()
    {
        var text = File.ReadAllText(Repo("src", "SystemOptimizerHub.Windows", "WindowsDomainEvidenceReaders.cs"));
        foreach (var token in new[] { "SetPriorityClass", "PriorityClass =", "ApplyThrottleAsync", "Kill(", "TerminateAsync" })
            Assert.DoesNotContain(token, text, StringComparison.Ordinal);
        Assert.Equal(90m, PerformanceDiagnosisPolicy.ApprovedSystemCpuPercent);
        Assert.Equal(40m, PerformanceDiagnosisPolicy.ApprovedProcessCpuPercent);
        Assert.Equal(0.70m, PerformanceDiagnosisPolicy.ApprovedProcessShareOfBusy);
        Assert.Equal(4, PerformanceDiagnosisPolicy.ApprovedMinimumSamples);
        Assert.Equal(3, PerformanceDiagnosisPolicy.ApprovedMinimumPositiveIntervals);
    }

    private static PerformanceSnapshot Window(MetricAvailability ioReader)
    {
        return PerformanceEvidenceBuilder.Build(
        [
            Sample(T(0), Row(100, read: 10, write: 1, readOps: 1, writeOps: 1, faults: 1), ioReader),
            Sample(T(1), Row(100, read: 20, write: 2, readOps: 2, writeOps: 1, faults: 3), ioReader),
            Sample(T(2), Row(100, read: 40, write: 4, readOps: 3, writeOps: 2, faults: 6), ioReader),
            Sample(T(3), Row(100, read: 70, write: 8, readOps: 5, writeOps: 3, faults: 10), ioReader)
        ], 15);
    }

    private static DateTimeOffset T(int seconds) =>
        new DateTimeOffset(2026, 10, 5, 8, 0, 0, TimeSpan.Zero).AddSeconds(seconds);

    private static PerformanceRawSample Sample(
        DateTimeOffset timestamp,
        ProcessRawObservation? process,
        MetricAvailability reader,
        RamSample? ram = null) => new()
    {
        TimestampUtc = timestamp,
        LogicalProcessors = 1,
        Ram = ram ?? RamSample.Unread(),
        SystemCpu = SystemCpuRaw.NotSupported(),
        Processes = process is null ? [] : [process],
        ProcessEnumeration = MetricAvailability.Observed,
        ProcessIoReader = reader,
        ProcessPageFaultReader = reader
    };

    private static PerformanceRawSample CpuSample(DateTimeOffset timestamp, double cpuSeconds) => new()
    {
        TimestampUtc = timestamp,
        LogicalProcessors = 2,
        Ram = RamSample.Unread(),
        SystemCpu = SystemCpuRaw.NotSupported(),
        Processes =
        [
            new ProcessRawObservation
            {
                Pid = 10,
                StartTimeUtcTicks = 100,
                ProcessName = "worker",
                ImagePath = @"C:\worker.exe",
                CpuTimeSeconds = cpuSeconds,
                WorkingSetBytes = 1024,
                Responding = true
            }
        ],
        ProcessEnumeration = MetricAvailability.Observed
    };

    private static ProcessRawObservation Row(
        long ticks,
        long? read,
        long? write = 0,
        long? readOps = 0,
        long? writeOps = 0,
        long? faults = 0) => new()
    {
        Pid = 10,
        StartTimeUtcTicks = ticks,
        ProcessName = "worker",
        ImagePath = @"C:\worker.exe",
        CpuTimeSeconds = 1,
        WorkingSetBytes = 1024,
        Responding = true,
        IoReadBytes = read,
        IoWriteBytes = write,
        IoReadOperations = readOps,
        IoWriteOperations = writeOps,
        PageFaultCount = faults
    };

    private static string Repo(params string[] parts)
    {
        var path = Path.GetFullPath(Path.Combine(new[] { AppContext.BaseDirectory, "..", "..", "..", "..", ".." }.Concat(parts).ToArray()));
        Assert.True(File.Exists(path), path);
        return path;
    }

    private sealed class ThrowingSource : IPerformanceSampleSource
    {
        public int Calls { get; private set; }

        public PerformanceRawSample Capture(int maxProcesses, CancellationToken cancellationToken)
        {
            Calls++;
            cancellationToken.ThrowIfCancellationRequested();
            return new PerformanceRawSample();
        }
    }
}
