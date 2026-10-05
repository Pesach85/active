using System.Diagnostics;
using System.Runtime.Versioning;
using System.Text.Json;
using SystemOptimizerHub.Core.Performance;
using SystemOptimizerHub.Windows;
using Xunit.Abstractions;

namespace SystemOptimizerHub.Core.Tests;

public class PerformanceNvmlEvidenceTests
{
    [Fact]
    public void Success_zero_is_observed_and_not_supported_discards_the_out_parameter()
    {
        var zero = NvmlReturn.Percent(NvmlReturn.Success, 0);
        var unsupported = NvmlReturn.Percent(NvmlReturn.NotSupported, 0);
        var power = NvmlReturn.PowerMilliwatts(NvmlReturn.NotSupported, 0);
        var memory = NvmlReturn.ProcessMemory(NvmlReturn.Success, NvmlReturn.ProcessMemoryNotAvailable);

        Assert.Equal(MetricAvailability.Observed, zero.Availability);
        Assert.Equal(0, zero.Value);
        Assert.Equal(MetricAvailability.NotSupported, unsupported.Availability);
        Assert.Null(unsupported.Value);
        Assert.Null(power.Value);
        Assert.Equal(MetricAvailability.NotSupported, memory.Availability);
        Assert.Null(memory.Value);
        Assert.DoesNotContain("\"Value\"", JsonSerializer.Serialize(unsupported), StringComparison.Ordinal);
        Assert.DoesNotContain("\"Value\"", JsonSerializer.Serialize(memory), StringComparison.Ordinal);
    }

    [Theory]
    [InlineData(NvmlReturn.Uninitialized)]
    [InlineData(NvmlReturn.NoPermission)]
    [InlineData(NvmlReturn.DriverNotLoaded)]
    [InlineData(NvmlReturn.GpuIsLost)]
    [InlineData(NvmlReturn.NotFound)]
    public void Device_and_permission_errors_are_unavailable(int code)
    {
        var metric = NvmlReturn.TemperatureCelsius(code, 0);

        Assert.Equal(MetricAvailability.Unavailable, metric.Availability);
        Assert.Null(metric.Value);
    }

    [Theory]
    [InlineData(NvmlReturn.InvalidArgument)]
    [InlineData(NvmlReturn.VersionMismatch)]
    [InlineData(NvmlReturn.Unknown)]
    [InlineData(NvmlReturn.InsufficientSize)]
    public void Malformed_and_version_errors_are_unknown(int code)
    {
        var metric = NvmlReturn.Percent(code, 0);

        Assert.Equal(MetricAvailability.Unknown, metric.Availability);
        Assert.Null(metric.Value);
    }

    [Fact]
    public void Session_maps_a_missing_library_init_failure_and_version_mismatch()
    {
        Assert.Equal(MetricAvailability.NotSupported, NvmlReturn.Session(false, false, 0));
        Assert.Equal(MetricAvailability.Unknown, NvmlReturn.Session(true, false, 0));
        Assert.Equal(MetricAvailability.Unavailable, NvmlReturn.Session(true, true, NvmlReturn.DriverNotLoaded));
        Assert.Equal(MetricAvailability.Unknown, NvmlReturn.Session(true, true, NvmlReturn.VersionMismatch));
        Assert.Equal(MetricAvailability.Observed, NvmlReturn.Session(true, true, NvmlReturn.Success));
    }

    [Fact]
    public void Insufficient_size_does_not_become_an_empty_success()
    {
        var retry = NvmlBufferQuery.First(NvmlReturn.InsufficientSize, 2);
        var empty = NvmlBufferQuery.First(NvmlReturn.Success, 0);
        var zeroSized = NvmlBufferQuery.First(NvmlReturn.InsufficientSize, 0);
        var overflow = NvmlBufferQuery.Second(NvmlReturn.Success, 5, 2);

        Assert.True(retry.CallAgain);
        Assert.Equal(2, retry.Count);
        Assert.Equal(MetricAvailability.Observed, empty.Availability);
        Assert.False(empty.CallAgain);
        Assert.Equal(MetricAvailability.Unknown, zeroSized.Availability);
        Assert.False(zeroSized.CallAgain);
        Assert.Equal(MetricAvailability.Unknown, overflow);
    }

    [Fact]
    public void Percent_above_100_and_inverted_memory_are_unknown()
    {
        var percent = NvmlReturn.Percent(NvmlReturn.Success, 140);
        var memory = NvmlReturn.Memory(NvmlReturn.Success, 10, 11);
        var state = NvmlReturn.PerformanceState(NvmlReturn.Success, NvmlReturn.UnknownPerformanceState);

        Assert.Equal(MetricAvailability.Unknown, percent.Availability);
        Assert.Null(percent.Value);
        Assert.Equal(MetricAvailability.Unknown, memory.Used.Availability);
        Assert.Null(memory.Used.Value);
        Assert.Null(memory.Total.Value);
        Assert.Equal(MetricAvailability.Unknown, state.Availability);
        Assert.Null(state.Value);
    }

    [Fact]
    public void Missing_start_ticks_does_not_attach_process_utilization()
    {
        var row = GpuProcessRaw.Join(
            40,
            GpuIdentityLookup.Unavailable(),
            99,
            MetricAvailability.Observed,
            PerformanceMetric<int>.Observed(12),
            PerformanceMetric<int>.Observed(0),
            PerformanceMetric<int>.Observed(0),
            PerformanceMetric<int>.Observed(0),
            PerformanceMetric<long>.NotSupported());
        var snapshot = GpuEvidenceFactory.Build([Sample(T(0), row), Sample(T(1), row)]);
        var published = Assert.Single(snapshot.Processes);

        Assert.Null(published.IdentityKey);
        Assert.Equal(MetricAvailability.Unavailable, published.Identity);
        Assert.Null(published.SmUtilizationPercent.Value);
        Assert.Null(published.DriverTimestamp);
        Assert.Equal(MetricAvailability.NotSupported, published.ProcessMemoryBytes.Availability);
        Assert.Null(published.ProcessMemoryBytes.Value);
    }

    [Fact]
    public void Joined_process_keeps_pid_and_start_ticks()
    {
        var row = Joined(40, 1000, sm: 7, timestamp: 50);
        var snapshot = GpuEvidenceFactory.Build([Sample(T(0), row), Sample(T(1), row)]);
        var published = Assert.Single(snapshot.Processes);

        Assert.Equal("40:1000", published.IdentityKey);
        Assert.Equal(1000, published.StartTimeUtcTicks);
        Assert.Equal(7, published.SmUtilizationPercent.Value);
        Assert.Equal(50UL, published.DriverTimestamp);
        Assert.Equal(T(1), published.CollectorTimestampUtc);
    }

    [Fact]
    public void Pid_reuse_does_not_pair_gpu_process_samples()
    {
        var snapshot = GpuEvidenceFactory.Build(
        [
            Sample(T(0), Joined(40, 1000, sm: 10, timestamp: 5)),
            Sample(T(1), Joined(40, 2000, sm: 80, timestamp: 9))
        ]);
        var published = Assert.Single(snapshot.Processes);
        var drift = Assert.Single(snapshot.ProcessIdentityDrift);

        Assert.Equal("40:2000", published.IdentityKey);
        Assert.Equal(80, published.SmUtilizationPercent.Value);
        Assert.Equal(1000, drift.BaselineStartTimeUtcTicks);
        Assert.Equal(2000, drift.CurrentStartTimeUtcTicks);
        Assert.Equal(2, drift.ReplacementSampleIndex);
        Assert.Contains("GPU-A|40:1000", snapshot.ProcessAbsentFromCurrentSample);
    }

    [Fact]
    public void Process_absent_from_the_last_sample_is_not_a_zero_row()
    {
        var snapshot = GpuEvidenceFactory.Build(
        [
            Sample(T(0), Joined(40, 1000, sm: 5, timestamp: 1)),
            Sample(T(1), Joined(40, 1000, sm: 6, timestamp: 2)),
            Sample(T(2), Joined(40, 1000, sm: 7, timestamp: 3)),
            Sample(T(3), null)
        ]);

        Assert.Empty(snapshot.Processes);
        Assert.Contains("GPU-A|40:1000", snapshot.ProcessAbsentFromCurrentSample);
    }

    [Fact]
    public void Process_appearing_inside_the_window_keeps_its_own_sample()
    {
        var snapshot = GpuEvidenceFactory.Build(
        [
            Sample(T(0), null),
            Sample(T(1), Joined(40, 1000, sm: 1, timestamp: 4)),
            Sample(T(2), Joined(40, 1000, sm: 2, timestamp: 5)),
            Sample(T(3), Joined(40, 1000, sm: 4, timestamp: 6))
        ]);
        var published = Assert.Single(snapshot.Processes);

        Assert.Contains("GPU-A|40:1000", snapshot.ProcessAppearedInCurrentSample);
        Assert.Equal(4, published.SmUtilizationPercent.Value);
        Assert.True(published.AbsentFromIntermediateSample);
        Assert.NotEqual(0, published.SmUtilizationPercent.Value);
    }

    [Fact]
    public void Intermediate_process_gap_keeps_the_last_gauge()
    {
        var snapshot = GpuEvidenceFactory.Build(
        [
            Sample(T(0), Joined(40, 1000, sm: 3, timestamp: 1)),
            Sample(T(1), null),
            Sample(T(2), Joined(40, 1000, sm: 4, timestamp: 3)),
            Sample(T(3), Joined(40, 1000, sm: 9, timestamp: 4))
        ]);
        var published = Assert.Single(snapshot.Processes);

        Assert.Contains("GPU-A|40:1000", snapshot.ProcessAbsentFromIntermediateSample);
        Assert.True(published.AbsentFromIntermediateSample);
        Assert.Equal(9, published.SmUtilizationPercent.Value);
        Assert.Equal(MetricAvailability.Observed, published.DriverTimestampAdvanced.Availability);
        Assert.True(published.DriverTimestampAdvanced.Value);
    }

    [Fact]
    public void Decreasing_driver_timestamp_is_unknown_and_has_no_value()
    {
        var snapshot = GpuEvidenceFactory.Build(
        [
            Sample(T(0), Joined(40, 1000, sm: 8, timestamp: 20)),
            Sample(T(1), Joined(40, 1000, sm: 3, timestamp: 10))
        ]);
        var published = Assert.Single(snapshot.Processes);
        var json = JsonSerializer.Serialize(published.DriverTimestampAdvanced);

        Assert.Equal(3, published.SmUtilizationPercent.Value);
        Assert.Equal(MetricAvailability.Unknown, published.DriverTimestampAdvanced.Availability);
        Assert.Null(published.DriverTimestampAdvanced.Value);
        Assert.DoesNotContain("\"Value\"", json, StringComparison.Ordinal);
    }

    [Fact]
    public void Stable_device_identity_uses_the_last_nvml_gauges()
    {
        var snapshot = GpuEvidenceFactory.Build(
        [
            Sample(T(0), null, Device(util: 10, used: 100)),
            Sample(T(1), null, Device(util: 20, used: 110)),
            Sample(T(2), null, Device(util: 15, used: 90)),
            Sample(T(3), null, Device(util: 18, used: 80))
        ]);
        var device = Assert.Single(snapshot.Devices);

        Assert.True(device.IdentityStable);
        Assert.Equal("GPU-A", device.Uuid);
        Assert.Equal(18, device.UtilizationPercent.Value);
        Assert.Equal(80L, device.MemoryUsedBytes.Value);
        Assert.Equal(55, device.TemperatureCelsius.Value);
        Assert.Equal("NVML", snapshot.MemorySource);
        Assert.Equal(MetricAvailability.NotSupported, device.JpegUtilizationPercent.Availability);
        Assert.Null(device.JpegUtilizationPercent.Value);
        Assert.Empty(snapshot.DeviceIdentityDrift);
        Assert.Equal(MetricAvailability.Observed, snapshot.Utilization);
        Assert.Equal(MetricAvailability.Observed, snapshot.Thermal);
    }

    [Fact]
    public void Device_uuid_change_invalidates_the_series()
    {
        var snapshot = GpuEvidenceFactory.Build(
        [
            Sample(T(0), null, Device(util: 10, uuid: "GPU-A")),
            Sample(T(1), null, Device(util: 90, uuid: "GPU-B"))
        ]);
        var device = Assert.Single(snapshot.Devices);
        var drift = Assert.Single(snapshot.DeviceIdentityDrift);
        var json = JsonSerializer.Serialize(device.UtilizationPercent);

        Assert.False(device.IdentityStable);
        Assert.Equal(MetricAvailability.Unknown, device.UtilizationPercent.Availability);
        Assert.Null(device.UtilizationPercent.Value);
        Assert.Null(device.MemoryUsedBytes.Value);
        Assert.Equal("GPU-A", drift.BaselineUuid);
        Assert.Equal("GPU-B", drift.CurrentUuid);
        Assert.Equal(2, drift.ReplacementSampleIndex);
        Assert.Equal(MetricAvailability.Unknown, snapshot.Utilization);
        Assert.Null(snapshot.MemorySource);
        Assert.DoesNotContain("\"Value\"", json, StringComparison.Ordinal);
    }

    [Fact]
    public void Multiple_gpus_stay_separate()
    {
        var snapshot = GpuEvidenceFactory.Build(
        [
            Sample(T(0), null, Device(util: 1, uuid: "GPU-A"), Device(index: 1, util: 2, uuid: "GPU-B")),
            Sample(T(1), null, Device(util: 3, uuid: "GPU-A"), Device(index: 1, util: 4, uuid: "GPU-B"))
        ]);

        Assert.Equal(2, snapshot.Devices.Count);
        Assert.Equal(3, snapshot.Devices[0].UtilizationPercent.Value);
        Assert.Equal(4, snapshot.Devices[1].UtilizationPercent.Value);
        Assert.Equal("GPU-B", snapshot.Devices[1].Uuid);
    }

    [Fact]
    public void No_devices_is_unavailable_rather_than_zero()
    {
        var snapshot = GpuEvidenceFactory.Build(
        [
            new PerformanceRawSample { TimestampUtc = T(0), Gpu = new GpuRawSample { Reader = MetricAvailability.Observed } },
            new PerformanceRawSample { TimestampUtc = T(1), Gpu = new GpuRawSample { Reader = MetricAvailability.Observed } }
        ]);
        var json = JsonSerializer.Serialize(snapshot);

        Assert.Equal(MetricAvailability.Unavailable, snapshot.Utilization);
        Assert.Empty(snapshot.Devices);
        Assert.DoesNotContain("\"Value\"", json, StringComparison.Ordinal);
    }

    [Fact]
    public void A_reader_failure_inside_the_window_is_not_paired()
    {
        var snapshot = GpuEvidenceFactory.Build(
        [
            Sample(T(0), null, Device(util: 10)),
            new PerformanceRawSample { TimestampUtc = T(1), Gpu = GpuRawSample.Unavailable() }
        ]);

        Assert.Equal(MetricAvailability.Unavailable, snapshot.Reader);
        Assert.Empty(snapshot.Devices);
        Assert.Null(snapshot.MemorySource);
    }

    [Fact]
    public void Cpu_evidence_stays_valid_and_auto_candidate_stays_closed()
    {
        var device = Device(util: 99, used: 1000);
        var start = T(0);
        var snapshot = PerformanceEvidenceBuilder.Build(
        [
            Cpu(start, 0, device),
            Cpu(start.AddSeconds(1), 0.8, device),
            Cpu(start.AddSeconds(2), 1.6, device),
            Cpu(start.AddSeconds(3), 2.4, device)
        ], 15);
        var diagnosis = PerformanceDiagnosisEngine.Diagnose(snapshot);

        Assert.Equal(40d, Assert.Single(snapshot.ProcessTopConsumers).CpuUtilizationPercent.Value);
        Assert.Equal(MetricAvailability.Observed, snapshot.Gpu.Utilization);
        Assert.Equal(MetricAvailability.Observed, snapshot.Gpu.Memory);
        Assert.NotEqual(PerformanceCause.GPU_PRESSURE, diagnosis.PrimaryCause);
        Assert.NotEqual(PerformanceAutomationEligibility.AUTO_CANDIDATE, diagnosis.AutomationEligibility);
        Assert.Contains("UNSUPPORTED_DOMAIN_POLICY", diagnosis.PolicyBlockers);
        Assert.Contains("gpuClassificationInactive", diagnosis.UnknownReasons);
        Assert.False(PerformanceDiagnosisPolicy.AutoCandidatePermitted());
        Assert.False(PerformanceDiagnosisPolicy.UnsupportedDomainCpuOnlyPermitted);
        Assert.Equal(90m, PerformanceDiagnosisPolicy.ApprovedSystemCpuPercent);
        Assert.Equal(40m, PerformanceDiagnosisPolicy.ApprovedProcessCpuPercent);
        Assert.Equal(0.70m, PerformanceDiagnosisPolicy.ApprovedProcessShareOfBusy);
        Assert.Equal(4, PerformanceDiagnosisPolicy.ApprovedMinimumSamples);
        Assert.Equal(3, PerformanceDiagnosisPolicy.ApprovedMinimumPositiveIntervals);
    }

    [Fact]
    public async Task Cancellation_returns_no_snapshot()
    {
        using var cts = new CancellationTokenSource();
        cts.Cancel();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
            PerformanceEvidenceCollector.CollectAsync(new CancelSource(), TimeSpan.FromMilliseconds(20), 15, cts.Token));
    }

    [Fact]
    public void Product_sources_do_not_call_nvidia_smi_hwinfo_or_mutators()
    {
        var files = new[]
        {
            Repo("src", "SystemOptimizerHub.Windows", "WindowsNvmlGpuReader.cs"),
            Repo("src", "SystemOptimizerHub.Windows", "WindowsPerformanceSampleSource.cs"),
            Repo("src", "SystemOptimizerHub.Core", "Performance", "GpuEvidence.cs"),
            Repo("src", "SystemOptimizerHub.Core", "Performance", "PerformanceEvidenceCollector.cs"),
            Repo("src", "SystemOptimizerHub.Core", "Performance", "PerformanceDiagnosisEngine.cs")
        };
        foreach (var file in files)
        {
            var text = File.ReadAllText(file);
            Assert.DoesNotContain("nvidia-smi", text, StringComparison.OrdinalIgnoreCase);
            Assert.DoesNotContain("HWiNFO", text, StringComparison.OrdinalIgnoreCase);
            Assert.DoesNotContain("SetPriorityClass", text, StringComparison.Ordinal);
            Assert.DoesNotContain("Kill(", text, StringComparison.Ordinal);
            Assert.DoesNotContain("TerminateAsync", text, StringComparison.Ordinal);
        }

        var diagnosis = File.ReadAllText(Repo("src", "SystemOptimizerHub.Core", "Performance", "PerformanceDiagnosis.cs"));
        Assert.DoesNotContain("ApprovedGpu", diagnosis, StringComparison.Ordinal);
    }

    private static PerformanceRawSample Sample(DateTimeOffset timestamp, GpuProcessRaw? process, params GpuDeviceRaw[] extra)
    {
        var device = extra.Length > 0 ? extra : [Device()];
        if (process is not null)
            device[0] = WithProcess(device[0], process);
        return new PerformanceRawSample
        {
            TimestampUtc = timestamp,
            Gpu = new GpuRawSample
            {
                Reader = MetricAvailability.Observed,
                Devices = device
            }
        };
    }

    private static GpuDeviceRaw WithProcess(GpuDeviceRaw device, GpuProcessRaw process) => new()
    {
        Index = device.Index,
        Identity = device.Identity,
        Name = device.Name,
        Uuid = device.Uuid,
        Pci = device.Pci,
        PciBusId = device.PciBusId,
        UtilizationPercent = device.UtilizationPercent,
        MemoryTotalBytes = device.MemoryTotalBytes,
        MemoryUsedBytes = device.MemoryUsedBytes,
        TemperatureCelsius = device.TemperatureCelsius,
        PowerDrawMilliwatts = device.PowerDrawMilliwatts,
        PerformanceState = device.PerformanceState,
        EncoderUtilizationPercent = device.EncoderUtilizationPercent,
        DecoderUtilizationPercent = device.DecoderUtilizationPercent,
        EncoderSamplingPeriodMicroseconds = device.EncoderSamplingPeriodMicroseconds,
        DecoderSamplingPeriodMicroseconds = device.DecoderSamplingPeriodMicroseconds,
        ProcessUtilizationQuery = MetricAvailability.Observed,
        ProcessMemoryQuery = MetricAvailability.Observed,
        Processes = [process]
    };

    private static GpuDeviceRaw Device(int index = 0, int util = 1, long used = 10, string uuid = "GPU-A") => new()
    {
        Index = index,
        Identity = MetricAvailability.Observed,
        Name = "GPU",
        Uuid = uuid,
        Pci = MetricAvailability.Observed,
        PciBusId = "0000:01:00.0",
        UtilizationPercent = PerformanceMetric<int>.Observed(util),
        MemoryTotalBytes = PerformanceMetric<long>.Observed(1000),
        MemoryUsedBytes = PerformanceMetric<long>.Observed(used),
        TemperatureCelsius = PerformanceMetric<int>.Observed(55),
        PowerDrawMilliwatts = PerformanceMetric<int>.Observed(5000),
        PerformanceState = PerformanceMetric<int>.Observed(8),
        EncoderUtilizationPercent = PerformanceMetric<int>.Observed(0),
        DecoderUtilizationPercent = PerformanceMetric<int>.Observed(0),
        EncoderSamplingPeriodMicroseconds = PerformanceMetric<long>.Observed(167000),
        DecoderSamplingPeriodMicroseconds = PerformanceMetric<long>.Observed(167000),
        ProcessUtilizationQuery = MetricAvailability.Observed,
        ProcessMemoryQuery = MetricAvailability.NotSupported
    };

    private static GpuProcessRaw Joined(int pid, long ticks, int sm, ulong timestamp) =>
        GpuProcessRaw.Join(
            pid,
            GpuIdentityLookup.Observed(ticks),
            timestamp,
            MetricAvailability.Observed,
            PerformanceMetric<int>.Observed(sm),
            PerformanceMetric<int>.Observed(0),
            PerformanceMetric<int>.Observed(0),
            PerformanceMetric<int>.Observed(0),
            PerformanceMetric<long>.NotSupported());

    private static PerformanceRawSample Cpu(DateTimeOffset timestamp, double cpuSeconds, GpuDeviceRaw? device = null)
    {
        var sample = new PerformanceRawSample
        {
            TimestampUtc = timestamp,
            LogicalProcessors = 2,
            SystemCpu = SystemCpuRaw.Observed(0, 30_000_000, 0),
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
                    Responding = true,
                    Priority = MetricAvailability.Observed,
                    PriorityValue = ObservedProcessPriority.Normal
                }
            ],
            ProcessEnumeration = MetricAvailability.Observed,
            ProcessPriorityReader = MetricAvailability.Observed
        };
        return device is null
            ? sample
            : new PerformanceRawSample
            {
                TimestampUtc = sample.TimestampUtc,
                LogicalProcessors = sample.LogicalProcessors,
                SystemCpu = sample.SystemCpu,
                Processes = sample.Processes,
                ProcessEnumeration = sample.ProcessEnumeration,
                ProcessPriorityReader = sample.ProcessPriorityReader,
                Gpu = new GpuRawSample { Reader = MetricAvailability.Observed, Devices = [device] }
            };
    }

    private static DateTimeOffset T(int seconds) =>
        new DateTimeOffset(2026, 10, 5, 8, 0, 0, TimeSpan.Zero).AddSeconds(seconds);

    private static string Repo(params string[] parts)
    {
        var path = Path.GetFullPath(Path.Combine(new[] { AppContext.BaseDirectory, "..", "..", "..", "..", ".." }.Concat(parts).ToArray()));
        Assert.True(File.Exists(path), path);
        return path;
    }

    private sealed class CancelSource : IPerformanceSampleSource
    {
        public PerformanceRawSample Capture(int maxProcesses, CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            return new PerformanceRawSample();
        }
    }
}

public class PerformanceNvmlLiveTests
{
    private readonly ITestOutputHelper _output;

    public PerformanceNvmlLiveTests(ITestOutputHelper output) => _output = output;

    [Fact]
    [SupportedOSPlatform("windows")]
    public void Live_nvml_reader_uses_explicit_states()
    {
        using var reader = new WindowsNvmlGpuReader();
        var sample = reader.Read(CancellationToken.None, WindowsGpuProcessIdentity.Lookup);

        _output.WriteLine($"reader={sample.Reader} initMs={reader.InitializationMilliseconds} readMs={reader.LastReadMilliseconds} devices={sample.Devices.Count} deviceQueries={reader.DeviceQueryCount} processQueries={reader.ProcessQueryCount} driver={sample.DriverVersion} nvml={sample.NvmlVersion}");
        Assert.True(sample.Reader is MetricAvailability.Observed or MetricAvailability.NotSupported or MetricAvailability.Unavailable or MetricAvailability.Unknown);
        if (sample.Reader != MetricAvailability.Observed)
        {
            Assert.Empty(sample.Devices);
            return;
        }

        Assert.NotEmpty(sample.Devices);
        foreach (var device in sample.Devices)
        {
            Assert.False(string.IsNullOrWhiteSpace(device.Uuid));
            AssertExplicit(device.UtilizationPercent);
            AssertExplicit(device.MemoryTotalBytes);
            AssertExplicit(device.MemoryUsedBytes);
            AssertExplicit(device.TemperatureCelsius);
            AssertExplicit(device.PowerDrawMilliwatts);
            AssertExplicit(device.PerformanceState);
            AssertExplicit(device.EncoderUtilizationPercent);
            AssertExplicit(device.DecoderUtilizationPercent);
            if (device.UtilizationPercent.Availability == MetricAvailability.Observed)
                Assert.InRange(device.UtilizationPercent.Value!.Value, 0, 100);
            if (device.MemoryTotalBytes.Availability == MetricAvailability.Observed
                && device.MemoryUsedBytes.Availability == MetricAvailability.Observed)
                Assert.InRange(device.MemoryUsedBytes.Value!.Value, 0, device.MemoryTotalBytes.Value!.Value);
            foreach (var process in device.Processes)
            {
                if (process.ProcessMemoryBytes.Availability == MetricAvailability.Observed)
                    Assert.True(process.ProcessMemoryBytes.Value >= 0);
                else
                    Assert.Null(process.ProcessMemoryBytes.Value);
                if (process.Identity == MetricAvailability.Observed)
                {
                    Assert.Equal(PerformanceIdentity.Key(process.Pid, process.StartTimeUtcTicks!.Value), $"{process.Pid}:{process.StartTimeUtcTicks}");
                    AssertExplicit(process.SmUtilizationPercent);
                }
                else
                {
                    Assert.Null(process.SmUtilizationPercent.Value);
                    Assert.Null(process.StartTimeUtcTicks);
                }
            }

            _output.WriteLine($"gpu{device.Index} {device.Name} {device.Uuid} pci={device.Pci}:{device.PciBusId} util={device.UtilizationPercent.Availability}:{device.UtilizationPercent.Value} mem={device.MemoryUsedBytes.Value}/{device.MemoryTotalBytes.Value} temp={device.TemperatureCelsius.Value} power={device.PowerDrawMilliwatts.Value} pstate={device.PerformanceState.Value} enc={device.EncoderUtilizationPercent.Value} dec={device.DecoderUtilizationPercent.Value} processes={device.Processes.Count} processQuery={device.ProcessUtilizationQuery}/{device.ProcessMemoryQuery}");
            foreach (var process in device.Processes)
                _output.WriteLine($"  pid={process.Pid} identity={process.Identity} ticks={process.StartTimeUtcTicks} sm={process.SmUtilizationPercent.Availability}:{process.SmUtilizationPercent.Value} memUtil={process.MemoryUtilizationPercent.Availability}:{process.MemoryUtilizationPercent.Value} enc={process.EncoderUtilizationPercent.Availability}:{process.EncoderUtilizationPercent.Value} dec={process.DecoderUtilizationPercent.Availability}:{process.DecoderUtilizationPercent.Value} driverTs={process.DriverTimestamp} memory={process.ProcessMemoryBytes.Availability}");
        }
    }

    [Fact]
    [SupportedOSPlatform("windows")]
    public void Live_nvidia_smi_calibration_does_not_replace_nvml_memory()
    {
        using var reader = new WindowsNvmlGpuReader();
        var sample = reader.Read(CancellationToken.None, WindowsGpuProcessIdentity.Lookup);
        if (sample.Reader != MetricAvailability.Observed)
            return;

        var rows = TryQueryNvidiaSmi();
        if (rows.Count == 0)
            return;

        foreach (var device in sample.Devices)
        {
            var match = rows.FirstOrDefault(row => string.Equals(row.Uuid, device.Uuid, StringComparison.OrdinalIgnoreCase));
            Assert.NotNull(match);
            if (device.TemperatureCelsius.Availability == MetricAvailability.Observed && match!.TemperatureCelsius is int smiTemperature)
                Assert.InRange(Math.Abs(device.TemperatureCelsius.Value!.Value - smiTemperature), 0, 20);
            if (device.MemoryUsedBytes.Availability == MetricAvailability.Observed && match!.MemoryUsedMiB is double _)
                _output.WriteLine($"memory-source=NVML bytes={device.MemoryUsedBytes.Value} nvidia-smi-mib={match.MemoryUsedMiB}");
            Assert.Equal("NVML", GpuEvidenceFactory.NvmlMemorySource);
        }
    }

    [Fact]
    [SupportedOSPlatform("windows")]
    public async Task Live_four_samples_do_not_open_auto_candidate()
    {
        using var source = new WindowsPerformanceSampleSource();
        var snapshot = await PerformanceEvidenceCollector.CollectAsync(source, TimeSpan.Zero, 15, CancellationToken.None);
        var diagnosis = PerformanceDiagnosisEngine.Diagnose(snapshot);

        Assert.Equal(4, snapshot.SampleCount);
        Assert.False(PerformanceDiagnosisPolicy.AutoCandidatePermitted());
        Assert.NotEqual(PerformanceAutomationEligibility.AUTO_CANDIDATE, diagnosis.AutomationEligibility);
        Assert.NotEqual(PerformanceCause.GPU_PRESSURE, diagnosis.PrimaryCause);
        Assert.Contains("UNSUPPORTED_DOMAIN_POLICY", diagnosis.PolicyBlockers);
        if (snapshot.Gpu.Reader == MetricAvailability.Observed)
        {
            Assert.All(snapshot.Gpu.Devices, device => Assert.True(device.IdentityStable));
            Assert.Equal("NVML", snapshot.Gpu.MemorySource);
        }
    }

    [Fact]
    [SupportedOSPlatform("windows")]
    public async Task Benchmark_domains_against_nvml_window()
    {
        var without = await Measure(new NoGpuReader());
        using var nvml = new WindowsNvmlGpuReader();
        var with = await Measure(nvml);

        _output.WriteLine($"without-nvml elapsed={without.Elapsed} captures={without.Snapshot.SampleCount} intervals={without.Snapshot.PositiveIntervalCount} duration={without.Snapshot.SampleDurationSeconds.Value} processes={without.Snapshot.ProcessTopConsumers.Count} gpuReads={without.GpuReads} gpuMs={without.GpuMilliseconds}");
        _output.WriteLine($"with-nvml elapsed={with.Elapsed} captures={with.Snapshot.SampleCount} intervals={with.Snapshot.PositiveIntervalCount} duration={with.Snapshot.SampleDurationSeconds.Value} processes={with.Snapshot.ProcessTopConsumers.Count} gpus={with.Snapshot.Gpu.Devices.Count} gpuReads={with.GpuReads} gpuMs={with.GpuMilliseconds} initMs={nvml.InitializationMilliseconds} deviceQueries={nvml.DeviceQueryCount} processQueries={nvml.ProcessQueryCount}");
        Assert.Equal(4, without.Snapshot.SampleCount);
        Assert.Equal(4, with.Snapshot.SampleCount);
        Assert.Equal(3, without.Snapshot.PositiveIntervalCount);
        Assert.Equal(3, with.Snapshot.PositiveIntervalCount);
        Assert.NotEqual(PerformanceAutomationEligibility.AUTO_CANDIDATE, PerformanceDiagnosisEngine.Diagnose(with.Snapshot).AutomationEligibility);
    }

    private static void AssertExplicit<T>(PerformanceMetric<T> metric) where T : struct
    {
        if (metric.Availability == MetricAvailability.Observed)
            Assert.NotNull(metric.Value);
        else
            Assert.Null(metric.Value);
    }

    [SupportedOSPlatform("windows")]
    private static async Task<MeasureResult> Measure(IGpuRawReader gpu)
    {
        using var source = new WindowsPerformanceSampleSource(gpu);
        var watch = Stopwatch.StartNew();
        var snapshot = await PerformanceEvidenceCollector.CollectAsync(source, TimeSpan.FromMilliseconds(200), 15, CancellationToken.None);
        watch.Stop();
        return new MeasureResult(watch.ElapsedMilliseconds, snapshot, source.GpuReadCount, source.GpuReadMillisecondsTotal);
    }

    private static List<SmiRow> TryQueryNvidiaSmi()
    {
        var start = new ProcessStartInfo
        {
            FileName = "nvidia-smi",
            Arguments = "--query-gpu=uuid,temperature.gpu,memory.used,utilization.gpu,power.draw,pstate --format=csv,noheader,nounits",
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true
        };
        try
        {
            using var process = Process.Start(start);
            if (process is null || !process.WaitForExit(8000) || process.ExitCode != 0)
                return [];
            return process.StandardOutput.ReadToEnd()
                .Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
                .Select(ParseSmi)
                .Where(row => row is not null)
                .Cast<SmiRow>()
                .ToList();
        }
        catch (Exception ex) when (ex is InvalidOperationException or System.ComponentModel.Win32Exception)
        {
            return [];
        }
    }

    private static SmiRow? ParseSmi(string line)
    {
        var parts = line.Split(',', StringSplitOptions.TrimEntries);
        if (parts.Length < 6 || string.IsNullOrWhiteSpace(parts[0]))
            return null;
        return new SmiRow(parts[0], Integer(parts[1]), Number(parts[2]), Integer(parts[3]), parts[4], parts[5]);
    }

    private static int? Integer(string text) =>
        text.Contains("N/A", StringComparison.OrdinalIgnoreCase) ? null : int.TryParse(text, out var value) ? value : null;

    private static double? Number(string text) =>
        text.Contains("N/A", StringComparison.OrdinalIgnoreCase) ? null : double.TryParse(text, out var value) ? value : null;

    private sealed record MeasureResult(long Elapsed, PerformanceSnapshot Snapshot, int GpuReads, long GpuMilliseconds);

    private sealed record SmiRow(string Uuid, int? TemperatureCelsius, double? MemoryUsedMiB, int? Utilization, string Power, string PerformanceState);

    private sealed class NoGpuReader : IGpuRawReader
    {
        public GpuRawSample Read(CancellationToken cancellationToken, Func<int, GpuIdentityLookup> lookup)
        {
            cancellationToken.ThrowIfCancellationRequested();
            return GpuRawSample.NotSupported();
        }

        public void Dispose()
        {
        }
    }
}
