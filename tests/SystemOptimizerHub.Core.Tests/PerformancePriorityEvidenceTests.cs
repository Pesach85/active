using System.Diagnostics;
using System.Runtime.Versioning;
using System.Text.Json;
using SystemOptimizerHub.Core.Performance;
using SystemOptimizerHub.Linux;
using SystemOptimizerHub.Windows;

namespace SystemOptimizerHub.Core.Tests;

public class PerformancePriorityEvidenceTests
{
    [Fact]
    [SupportedOSPlatform("windows")]
    public void Windows_priority_read_is_observed()
    {
        var read = WindowsProcessPriorityReader.Read(Process.GetCurrentProcess());

        Assert.Equal(MetricAvailability.Observed, read.Availability);
        Assert.NotNull(read.Value);
        Assert.True(Enum.IsDefined(read.Value.Value));
        Assert.NotEqual(0, (int)read.Value.Value);
    }

    [Fact]
    [SupportedOSPlatform("windows")]
    public void Windows_priority_read_failure_is_unavailable_and_has_no_value()
    {
        using var process = ExitedProcess();
        var read = WindowsProcessPriorityReader.Read(process);
        var snapshot = Pair(Row(4, 40, MetricAvailability.Unavailable, null), Row(4, 40, MetricAvailability.Unavailable, null));
        var row = Assert.Single(snapshot.ProcessTopConsumers);
        var json = JsonSerializer.Serialize(row);

        Assert.Equal(MetricAvailability.Unavailable, read.Availability);
        Assert.Null(read.Value);
        Assert.Equal(MetricAvailability.Unavailable, row.PriorityCurrent.Availability);
        Assert.Null(row.PriorityCurrent.Value);
        Assert.Null(row.PriorityBaseline.Value);
        Assert.DoesNotContain("\"PriorityBaseline\":{\"Availability\":\"Unavailable\",\"Value\"", json, StringComparison.Ordinal);
        Assert.DoesNotContain("\"PriorityCurrent\":{\"Availability\":\"Unavailable\",\"Value\"", json, StringComparison.Ordinal);
        Assert.DoesNotContain("Normal", json, StringComparison.Ordinal);
    }

    [Fact]
    public void Linux_priority_is_not_supported()
    {
        var baseline = new LinuxPerformanceSampleSource().Capture(3, CancellationToken.None);
        var current = new LinuxPerformanceSampleSource().Capture(3, CancellationToken.None);
        if (current.TimestampUtc <= baseline.TimestampUtc)
            current = new PerformanceRawSample
            {
                TimestampUtc = baseline.TimestampUtc.AddSeconds(1),
                LogicalProcessors = baseline.LogicalProcessors,
                Ram = baseline.Ram,
                SystemCpu = baseline.SystemCpu,
                Processes = baseline.Processes,
                ProcessEnumeration = baseline.ProcessEnumeration,
                ProcessPriorityReader = baseline.ProcessPriorityReader
            };
        var snapshot = PerformanceEvidenceBuilder.Build(baseline, current, 3);
        var json = JsonSerializer.Serialize(snapshot);

        Assert.Equal(MetricAvailability.NotSupported, baseline.ProcessPriorityReader);
        Assert.Equal(MetricAvailability.NotSupported, snapshot.ProcessPriorityReader);
        Assert.Empty(snapshot.ProcessTopConsumers);
        Assert.Equal(MetricAvailability.NotSupported, snapshot.ProcessPriorityReader);
        Assert.DoesNotContain("BelowNormal", json, StringComparison.Ordinal);
        Assert.DoesNotContain("\"ProcessPriorityReader\":\"Observed\"", json, StringComparison.Ordinal);
    }

    [Fact]
    public void Stable_identity_keeps_both_priority_samples()
    {
        var snapshot = Pair(
            Row(10, 100, MetricAvailability.Observed, ObservedProcessPriority.BelowNormal),
            Row(10, 100, MetricAvailability.Observed, ObservedProcessPriority.BelowNormal));
        var row = Assert.Single(snapshot.ProcessTopConsumers);

        Assert.Equal("10:100", row.IdentityKey);
        Assert.Equal(ObservedProcessPriority.BelowNormal, row.PriorityBaseline.Value);
        Assert.Equal(ObservedProcessPriority.BelowNormal, row.PriorityCurrent.Value);
        Assert.Equal(MetricAvailability.Observed, row.PriorityPairComplete.Availability);
        Assert.True(row.PriorityPairComplete.Value);
    }

    [Fact]
    public void Stable_identity_preserves_a_priority_change()
    {
        var snapshot = Pair(
            Row(10, 100, MetricAvailability.Observed, ObservedProcessPriority.Normal),
            Row(10, 100, MetricAvailability.Observed, ObservedProcessPriority.BelowNormal));
        var row = Assert.Single(snapshot.ProcessTopConsumers);

        Assert.Equal(ObservedProcessPriority.Normal, row.PriorityBaseline.Value);
        Assert.Equal(ObservedProcessPriority.BelowNormal, row.PriorityCurrent.Value);
        Assert.True(row.PriorityPairComplete.Value);
        Assert.NotEqual(row.PriorityBaseline.Value, row.PriorityCurrent.Value);
    }

    [Fact]
    public void Identity_drift_does_not_copy_priority_across_identities()
    {
        var snapshot = Pair(
            Row(10, 100, MetricAvailability.Observed, ObservedProcessPriority.High),
            Row(10, 200, MetricAvailability.Observed, ObservedProcessPriority.BelowNormal));
        var row = Assert.Single(snapshot.ProcessTopConsumers);

        Assert.Equal("10:200", row.IdentityKey);
        Assert.Equal(MetricAvailability.Unavailable, row.PriorityBaseline.Availability);
        Assert.Null(row.PriorityBaseline.Value);
        Assert.Equal(ObservedProcessPriority.BelowNormal, row.PriorityCurrent.Value);
        Assert.Equal(MetricAvailability.Unknown, row.PriorityPairComplete.Availability);
        Assert.Contains("10:100", snapshot.AbsentFromCurrentSample);
        Assert.Equal(10, Assert.Single(snapshot.IdentityDrift).Pid);
    }

    [Fact]
    public void Absent_process_priority_is_not_attached_to_the_survivor()
    {
        var start = Stamp();
        var snapshot = PerformanceEvidenceBuilder.Build(
            Sample(start,
                Row(7, 70, MetricAvailability.Observed, ObservedProcessPriority.RealTime, workingSet: 10),
                Row(8, 80, MetricAvailability.Observed, ObservedProcessPriority.Normal, workingSet: 20)),
            Sample(start.AddSeconds(1),
                Row(8, 80, MetricAvailability.Observed, ObservedProcessPriority.Normal, workingSet: 20)),
            15);
        var row = Assert.Single(snapshot.ProcessTopConsumers);

        Assert.Equal("8:80", row.IdentityKey);
        Assert.Equal(ObservedProcessPriority.Normal, row.PriorityCurrent.Value);
        Assert.Equal(new[] { "7:70" }, snapshot.AbsentFromCurrentSample);
        Assert.DoesNotContain(snapshot.ProcessTopConsumers, item => item.PriorityCurrent.Value == ObservedProcessPriority.RealTime);
    }

    [Fact]
    public void Priority_does_not_change_bounded_retention()
    {
        var start = Stamp();
        var baseline = Enumerable.Range(1, 20)
            .Select(pid => Row(pid, 1000 + pid, MetricAvailability.Observed, ObservedProcessPriority.RealTime, workingSet: pid * 10))
            .ToArray();
        var current = baseline.Select(row => Row(
            row.Pid,
            row.StartTimeUtcTicks!.Value,
            MetricAvailability.Observed,
            ObservedProcessPriority.Idle,
            row.WorkingSetBytes)).ToArray();
        var snapshot = PerformanceEvidenceBuilder.Build(Sample(start, baseline), Sample(start.AddSeconds(1), current), 3);

        Assert.Equal(new[] { 18, 19, 20 }, snapshot.ProcessTopConsumers.Select(p => p.Pid).OrderBy(pid => pid).ToArray());
    }

    [Fact]
    public void Priority_reader_uses_the_single_existing_enumeration()
    {
        var text = File.ReadAllText(RepoFile("src", "SystemOptimizerHub.Windows", "WindowsPerformanceSampleSource.cs"));

        Assert.Equal(1, Count(text, "Process.GetProcesses("));
        Assert.Contains("WindowsProcessPriorityReader.Read(process)", text, StringComparison.Ordinal);
        Assert.Contains("process.PriorityClass", text, StringComparison.Ordinal);
    }

    [Fact]
    public void Priority_serialization_is_deterministic_and_omits_absent_values()
    {
        var start = Stamp();
        var first = PerformanceEvidenceBuilder.Build(
            Sample(start,
                Row(2, 20, MetricAvailability.Unavailable, null),
                Row(1, 10, MetricAvailability.Observed, ObservedProcessPriority.BelowNormal)),
            Sample(start.AddSeconds(1),
                Row(2, 20, MetricAvailability.Unavailable, null),
                Row(1, 10, MetricAvailability.Observed, ObservedProcessPriority.BelowNormal)),
            15);
        var second = PerformanceEvidenceBuilder.Build(
            Sample(start,
                Row(1, 10, MetricAvailability.Observed, ObservedProcessPriority.BelowNormal),
                Row(2, 20, MetricAvailability.Unavailable, null)),
            Sample(start.AddSeconds(1),
                Row(1, 10, MetricAvailability.Observed, ObservedProcessPriority.BelowNormal),
                Row(2, 20, MetricAvailability.Unavailable, null)),
            15);
        var options = new JsonSerializerOptions { WriteIndented = false };
        var jsonA = JsonSerializer.Serialize(first, options);
        var jsonB = JsonSerializer.Serialize(second, options);

        Assert.Equal(jsonA, jsonB);
        Assert.Contains("\"Value\":\"BelowNormal\"", jsonA, StringComparison.Ordinal);
        Assert.Contains("\"Availability\":\"Unavailable\"", jsonA, StringComparison.Ordinal);
        Assert.DoesNotContain("\"PriorityCurrent\":{\"Availability\":\"Unavailable\",\"Value\"", jsonA, StringComparison.Ordinal);
        Assert.DoesNotContain("\"PriorityBaseline\":{\"Availability\":\"Unavailable\",\"Value\"", jsonA, StringComparison.Ordinal);
        Assert.DoesNotContain("16384", jsonA, StringComparison.Ordinal);
    }

    [Fact]
    public void Missing_priority_value_is_not_replaced_with_a_default()
    {
        var snapshot = Pair(
            Row(3, 30, MetricAvailability.Observed, null),
            Row(3, 30, MetricAvailability.Unavailable, null));
        var row = Assert.Single(snapshot.ProcessTopConsumers);
        var json = JsonSerializer.Serialize(row);

        Assert.Equal(MetricAvailability.Unknown, row.PriorityBaseline.Availability);
        Assert.Null(row.PriorityBaseline.Value);
        Assert.Equal(MetricAvailability.Unavailable, row.PriorityCurrent.Availability);
        Assert.Null(row.PriorityCurrent.Value);
        Assert.Equal(MetricAvailability.Unknown, row.PriorityPairComplete.Availability);
        Assert.False(WindowsProcessPriorityMapper.TryMap((ProcessPriorityClass)0, out _));
        Assert.DoesNotContain("\"Normal\"", json, StringComparison.Ordinal);
    }

    [Fact]
    public void One_sided_priority_does_not_invent_the_other_sample()
    {
        var snapshot = Pair(
            Row(6, 60, MetricAvailability.Unavailable, null),
            Row(6, 60, MetricAvailability.Observed, ObservedProcessPriority.AboveNormal));
        var row = Assert.Single(snapshot.ProcessTopConsumers);

        Assert.Null(row.PriorityBaseline.Value);
        Assert.Equal(ObservedProcessPriority.AboveNormal, row.PriorityCurrent.Value);
        Assert.Equal(MetricAvailability.Unknown, row.PriorityPairComplete.Availability);
        Assert.Null(row.PriorityPairComplete.Value);
    }

    [Fact]
    [SupportedOSPlatform("windows")]
    public void Cancelled_capture_does_not_read_priority()
    {
        using var cts = new CancellationTokenSource();
        cts.Cancel();
        var source = new WindowsPerformanceSampleSource();

        Assert.Throws<OperationCanceledException>(() => source.Capture(3, cts.Token));
    }

    [Fact]
    public void Priority_evidence_path_does_not_mutate()
    {
        var files = new[]
        {
            RepoFile("src", "SystemOptimizerHub.Core", "Performance", "ObservedProcessPriority.cs"),
            RepoFile("src", "SystemOptimizerHub.Core", "Performance", "PerformanceRawSample.cs"),
            RepoFile("src", "SystemOptimizerHub.Core", "Performance", "PerformanceSnapshot.cs"),
            RepoFile("src", "SystemOptimizerHub.Core", "Performance", "PerformanceEvidenceBuilder.cs"),
            RepoFile("src", "SystemOptimizerHub.Windows", "WindowsPerformanceSampleSource.cs"),
            RepoFile("src", "SystemOptimizerHub.Linux", "LinuxPerformanceSampleSource.cs")
        };
        var forbidden = new[]
        {
            "SetPriorityClass",
            "PriorityClass =",
            "ApplyThrottleAsync",
            "Process.Kill",
            "Kill(",
            "Terminate",
            "renice"
        };

        foreach (var file in files)
        {
            var text = File.ReadAllText(file);
            foreach (var token in forbidden)
                Assert.DoesNotContain(token, text);
        }

        var linux = File.ReadAllText(RepoFile("src", "SystemOptimizerHub.Linux", "LinuxPerformanceSampleSource.cs"));
        Assert.DoesNotContain("PriorityClass", linux, StringComparison.Ordinal);
        Assert.DoesNotContain("nice", linux, StringComparison.OrdinalIgnoreCase);
    }

    private static PerformanceSnapshot Pair(ProcessRawObservation baseline, ProcessRawObservation current)
    {
        var start = Stamp();
        return PerformanceEvidenceBuilder.Build(Sample(start, baseline), Sample(start.AddSeconds(1), current), 15);
    }

    private static PerformanceRawSample Sample(DateTimeOffset timestamp, params ProcessRawObservation[] processes) => new()
    {
        TimestampUtc = timestamp,
        LogicalProcessors = 2,
        Ram = RamSample.Unread(),
        SystemCpu = SystemCpuRaw.NotSupported(),
        Processes = processes,
        ProcessEnumeration = MetricAvailability.Observed,
        ProcessPriorityReader = MetricAvailability.Observed
    };

    private static ProcessRawObservation Row(
        int pid,
        long startTicks,
        MetricAvailability priority,
        ObservedProcessPriority? value,
        long? workingSet = 1024) => new()
    {
        Pid = pid,
        StartTimeUtcTicks = startTicks,
        ProcessName = "worker",
        ImagePath = "C:\\worker.exe",
        CpuTimeSeconds = 1,
        WorkingSetBytes = workingSet,
        PrivateBytes = workingSet,
        Responding = true,
        Priority = priority,
        PriorityValue = value
    };

    [SupportedOSPlatform("windows")]
    private static Process ExitedProcess()
    {
        var process = new Process
        {
            StartInfo = new ProcessStartInfo
            {
                FileName = "cmd.exe",
                Arguments = "/c exit",
                UseShellExecute = false,
                CreateNoWindow = true
            }
        };
        Assert.True(process.Start());
        Assert.True(process.WaitForExit(10000));
        return process;
    }

    private static DateTimeOffset Stamp() => new(2026, 10, 5, 8, 0, 0, TimeSpan.Zero);

    private static string RepoFile(params string[] parts)
    {
        var path = Path.GetFullPath(Path.Combine(new[] { AppContext.BaseDirectory, "..", "..", "..", "..", ".." }.Concat(parts).ToArray()));
        Assert.True(File.Exists(path), path);
        return path;
    }

    private static int Count(string text, string token)
    {
        var count = 0;
        var index = 0;
        while ((index = text.IndexOf(token, index, StringComparison.Ordinal)) >= 0)
        {
            count++;
            index += token.Length;
        }

        return count;
    }
}
