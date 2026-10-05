using System.Text.Json;
using SystemOptimizerHub.Core.Performance;

namespace SystemOptimizerHub.Core.Tests;

public class PerformanceDiagnosisTests
{
    private const long LegacyFakeTotal = 16L * 1024 * 1024 * 1024;
    private const long LegacyFakeAvailable = 4L * 1024 * 1024 * 1024;

    [Fact]
    public void Normal_snapshot_is_normal_with_no_action()
    {
        var diagnosis = PerformanceDiagnosisEngine.Diagnose(Snap(Healthy()));

        Assert.Equal(PerformanceOverallState.NORMAL, diagnosis.OverallState);
        Assert.Equal(PerformanceCause.NONE, diagnosis.PrimaryCause);
        Assert.Equal(PerformanceAutomationEligibility.NO_ACTION, diagnosis.AutomationEligibility);
        Assert.Contains("windowObserved", diagnosis.EvidenceReasons);
        Assert.Contains("stableProcessIdentity", diagnosis.EvidenceReasons);
        Assert.DoesNotContain(diagnosis.AutomationEligibility, new[] { PerformanceAutomationEligibility.AUTO_CANDIDATE });
    }

    [Fact]
    public void Insufficient_cpu_evidence_is_unknown()
    {
        var diagnosis = PerformanceDiagnosisEngine.Diagnose(Snap(
            systemCpu: PerformanceMetric<double>.Unavailable()));

        Assert.Equal(PerformanceOverallState.UNKNOWN, diagnosis.OverallState);
        Assert.Equal(PerformanceCause.UNKNOWN, diagnosis.PrimaryCause);
        Assert.Contains("cpuEvidenceInsufficient", diagnosis.UnknownReasons);
        Assert.NotEqual(PerformanceCause.CPU_CONTENTION, diagnosis.PrimaryCause);
        Assert.Equal(PerformanceAutomationEligibility.NO_ACTION, diagnosis.AutomationEligibility);
    }

    [Fact]
    public void Observed_cpu_utilization_does_not_declare_pressure()
    {
        var row = Healthy();
        row = WithUtilization(row, 99);
        var diagnosis = PerformanceDiagnosisEngine.Diagnose(Snap(
            processes: [row],
            systemCpu: PerformanceMetric<double>.Observed(95)));

        Assert.NotEqual(PerformanceAutomationEligibility.AUTO_CANDIDATE, diagnosis.AutomationEligibility);
        Assert.False(diagnosis.CpuPolicyMatched);
        Assert.Contains("systemCpuObserved", diagnosis.EvidenceReasons);
        Assert.Contains("INSUFFICIENT_PERSISTENCE", diagnosis.EvidenceReasons);
        Assert.Contains("WALL_CLOCK_POLICY_UNDECIDED", diagnosis.PolicyBlockers);
    }

    [Fact]
    public void Cpu_delta_zero_with_responding_true_is_not_a_semi_stall()
    {
        var diagnosis = PerformanceDiagnosisEngine.Diagnose(Snap(DeltaZero(responding: true)));

        Assert.Equal(PerformanceOverallState.NORMAL, diagnosis.OverallState);
        Assert.Equal(PerformanceCause.NONE, diagnosis.PrimaryCause);
        Assert.Contains("cpuTimeNotAdvanced", diagnosis.EvidenceReasons);
        Assert.Contains("respondingObservedTrue", diagnosis.EvidenceReasons);
        Assert.Empty(diagnosis.CandidateTargets);
    }

    [Fact]
    public void Stable_identity_is_recorded()
    {
        var diagnosis = PerformanceDiagnosisEngine.Diagnose(Snap(Healthy(10, 100)));

        Assert.Contains("stableProcessIdentity", diagnosis.EvidenceReasons);
        Assert.DoesNotContain("identityDriftExcluded", diagnosis.EvidenceReasons);
        Assert.Equal(PerformanceCause.NONE, diagnosis.PrimaryCause);
    }

    [Fact]
    public void Identity_drift_is_not_compared()
    {
        var drifted = Healthy(10, 200);
        var diagnosis = PerformanceDiagnosisEngine.Diagnose(Snap(
            processes: [drifted],
            drift: [new ProcessIdentityDrift { Pid = 10, BaselineStartTimeUtcTicks = 100, CurrentStartTimeUtcTicks = 200 }]));

        Assert.Contains("identityDriftExcluded", diagnosis.EvidenceReasons);
        Assert.DoesNotContain("stableProcessIdentity", diagnosis.EvidenceReasons);
        Assert.Empty(diagnosis.CandidateTargets);
        Assert.NotEqual(PerformanceCause.PROCESS_SEMI_STALL, diagnosis.PrimaryCause);
    }

    [Fact]
    public void Responding_false_without_cpu_stall_is_not_a_cause()
    {
        var row = Healthy();
        var diagnosis = PerformanceDiagnosisEngine.Diagnose(Snap(new ProcessPerformanceEvidence
        {
            IdentityKey = row.IdentityKey,
            Pid = row.Pid,
            StartTimeUtcTicks = row.StartTimeUtcTicks,
            IdentityPathMatches = true,
            CpuTimeBaselineSeconds = PerformanceMetric<double>.Observed(1),
            CpuTimeCurrentSeconds = PerformanceMetric<double>.Observed(3),
            CpuDeltaSeconds = PerformanceMetric<double>.Observed(2),
            CpuTimeAdvanced = PerformanceMetric<bool>.Observed(true),
            CpuUtilizationPercent = PerformanceMetric<double>.Observed(20),
            Responding = PerformanceMetric<bool>.Observed(false)
        }));

        Assert.Equal(PerformanceCause.NONE, diagnosis.PrimaryCause);
        Assert.Contains("respondingObservedFalse", diagnosis.EvidenceReasons);
        Assert.Contains("semiStallRequiresCpuNotAdvanced", diagnosis.EvidenceReasons);
        Assert.Empty(diagnosis.CandidateTargets);
    }

    [Fact]
    public void Responding_unavailable_is_not_treated_as_false()
    {
        var diagnosis = PerformanceDiagnosisEngine.Diagnose(Snap(DeltaZero(responding: null)));

        Assert.NotEqual(PerformanceCause.PROCESS_SEMI_STALL, diagnosis.PrimaryCause);
        Assert.Contains("respondingUnavailable", diagnosis.UnknownReasons);
        Assert.DoesNotContain("respondingObservedFalse", diagnosis.EvidenceReasons);
        Assert.Empty(diagnosis.CandidateTargets);
    }

    [Fact]
    public void Semi_stall_requires_complete_evidence_and_stays_hitl()
    {
        var row = SemiStall(42, 900);
        var diagnosis = PerformanceDiagnosisEngine.Diagnose(Snap(row));

        Assert.Equal(PerformanceOverallState.CRITICAL, diagnosis.OverallState);
        Assert.Equal(PerformanceCause.PROCESS_SEMI_STALL, diagnosis.PrimaryCause);
        Assert.Equal(PerformanceConfidence.HIGH, diagnosis.Confidence);
        Assert.Equal(PerformanceAutomationEligibility.HITL_REQUIRED, diagnosis.AutomationEligibility);
        Assert.Equal(new[] { PerformanceIdentity.Key(42, 900) }, diagnosis.CandidateTargets);
        Assert.Contains("pairedBaselineCpu", diagnosis.EvidenceReasons);
        Assert.Contains("cpuTimeNotAdvanced", diagnosis.EvidenceReasons);
        Assert.Contains("respondingObservedFalse", diagnosis.EvidenceReasons);
        Assert.NotEmpty(diagnosis.EvidenceReasons);
    }

    [Fact]
    public void Absent_from_current_sample_is_not_termination()
    {
        var diagnosis = PerformanceDiagnosisEngine.Diagnose(Snap(
            processes: [Healthy()],
            absent: ["99:100"]));
        var json = JsonSerializer.Serialize(diagnosis);

        Assert.Contains("absentFromRetainedWindowIsNotTermination", diagnosis.EvidenceReasons);
        Assert.DoesNotContain("99:100", diagnosis.CandidateTargets);
        Assert.DoesNotContain("PROCESS_TERMINATED", json);
        Assert.DoesNotContain("\"Terminated\"", json);
        Assert.Equal(PerformanceCause.NONE, diagnosis.PrimaryCause);
    }

    [Fact]
    public void Observed_ram_without_an_approved_threshold_is_not_memory_pressure()
    {
        var diagnosis = PerformanceDiagnosisEngine.Diagnose(Snap(
            processes: [Healthy()],
            ram: ObservedRam(LegacyFakeTotal, LegacyFakeAvailable)));

        Assert.NotEqual(PerformanceCause.MEMORY_PRESSURE, diagnosis.PrimaryCause);
        Assert.Contains("memoryClassificationInactive", diagnosis.UnknownReasons);
        Assert.DoesNotContain("17179869184", JsonSerializer.Serialize(diagnosis));
    }

    [Fact]
    public void Unavailable_ram_is_not_a_negative_pressure_finding()
    {
        var diagnosis = PerformanceDiagnosisEngine.Diagnose(Snap(processes: [Healthy()], ram: new RamEvidence()));

        Assert.Contains("ramUnavailable", diagnosis.UnknownReasons);
        Assert.NotEqual(PerformanceCause.MEMORY_PRESSURE, diagnosis.PrimaryCause);
        Assert.DoesNotContain("memoryPressureFalse", diagnosis.EvidenceReasons);
    }

    [Fact]
    public void Io_not_supported_is_not_zero_pressure()
    {
        var diagnosis = PerformanceDiagnosisEngine.Diagnose(Snap(processes: [Healthy()], io: new IoEvidence()));

        Assert.Contains("ioNotSupported", diagnosis.UnknownReasons);
        Assert.NotEqual(PerformanceCause.IO_PRESSURE, diagnosis.PrimaryCause);
        Assert.DoesNotContain("ioPressureFalse", diagnosis.UnknownReasons);
    }

    [Fact]
    public void Gpu_not_supported_is_not_zero_pressure()
    {
        var diagnosis = PerformanceDiagnosisEngine.Diagnose(Snap(processes: [Healthy()], gpu: new GpuEvidence()));

        Assert.Contains("gpuNotSupported", diagnosis.UnknownReasons);
        Assert.NotEqual(PerformanceCause.GPU_PRESSURE, diagnosis.PrimaryCause);
        Assert.DoesNotContain("gpuPressureFalse", diagnosis.UnknownReasons);
    }

    [Fact]
    public void Partial_conflicting_signals_do_not_select_a_cause()
    {
        var advancingButUnresponsive = Healthy(1, 10, responding: false);
        var quietButResponsive = DeltaZero(responding: true, pid: 2, ticks: 20);
        var diagnosis = PerformanceDiagnosisEngine.Diagnose(Snap(advancingButUnresponsive, quietButResponsive));

        Assert.Equal(PerformanceCause.NONE, diagnosis.PrimaryCause);
        Assert.NotEqual(PerformanceCause.CPU_CONTENTION, diagnosis.PrimaryCause);
        Assert.NotEqual(PerformanceCause.PROCESS_SEMI_STALL, diagnosis.PrimaryCause);
        Assert.NotEqual(PerformanceCause.MIXED, diagnosis.PrimaryCause);
        Assert.Empty(diagnosis.CandidateTargets);
        Assert.Equal(PerformanceAutomationEligibility.NO_ACTION, diagnosis.AutomationEligibility);
    }

    [Fact]
    public void Two_positive_causes_resolve_to_mixed_without_ranking()
    {
        var primary = PerformanceDiagnosisEngine.ResolvePrimary(
            [PerformanceCause.PROCESS_SEMI_STALL, PerformanceCause.MEMORY_PRESSURE]);

        Assert.Equal(PerformanceCause.MIXED, primary);
    }

    [Fact]
    public void Unknown_duration_blocks_stall_and_utilization_inference()
    {
        var diagnosis = PerformanceDiagnosisEngine.Diagnose(Snap(
            processes: [SemiStall(7, 70)],
            window: MetricAvailability.Unknown,
            duration: null));

        Assert.Equal(PerformanceOverallState.UNKNOWN, diagnosis.OverallState);
        Assert.Equal(PerformanceCause.UNKNOWN, diagnosis.PrimaryCause);
        Assert.Contains("durationUnknown", diagnosis.EvidenceReasons);
        Assert.Empty(diagnosis.CandidateTargets);
        Assert.NotEqual(PerformanceCause.PROCESS_SEMI_STALL, diagnosis.PrimaryCause);
        Assert.NotEqual(PerformanceCause.CPU_CONTENTION, diagnosis.PrimaryCause);
    }

    [Fact]
    public void Automation_eligibility_stays_fail_closed()
    {
        var cases = new[]
        {
            PerformanceDiagnosisEngine.Diagnose(Snap(SemiStall(1, 1))),
            PerformanceDiagnosisEngine.Diagnose(Snap(systemCpu: PerformanceMetric<double>.Unavailable())),
            PerformanceDiagnosisEngine.Diagnose(Snap(processes: [Healthy()], io: new IoEvidence(), gpu: new GpuEvidence())),
            PerformanceDiagnosisEngine.Diagnose(Snap(UnkeyedStall())),
            PerformanceDiagnosisEngine.Diagnose(Snap(processes: [Healthy()], window: MetricAvailability.Unknown, duration: null))
        };

        Assert.All(cases, diagnosis =>
            Assert.NotEqual(PerformanceAutomationEligibility.AUTO_CANDIDATE, diagnosis.AutomationEligibility));
        Assert.Equal(PerformanceAutomationEligibility.HITL_REQUIRED, cases[0].AutomationEligibility);
        Assert.Contains(PerformanceAutomationEligibility.NO_ACTION, cases.Select(c => c.AutomationEligibility));
    }

    [Fact]
    public void Candidate_target_uses_stable_identity()
    {
        var diagnosis = PerformanceDiagnosisEngine.Diagnose(Snap(SemiStall(1234, 638472)));

        Assert.Equal(["1234:638472"], diagnosis.CandidateTargets);
    }

    [Fact]
    public void Row_without_stable_identity_is_not_a_candidate()
    {
        var diagnosis = PerformanceDiagnosisEngine.Diagnose(Snap(UnkeyedStall(), Healthy()));

        Assert.Empty(diagnosis.CandidateTargets);
        Assert.NotEqual(PerformanceCause.PROCESS_SEMI_STALL, diagnosis.PrimaryCause);
    }

    [Fact]
    public void Same_snapshot_produces_the_same_diagnosis()
    {
        var snapshot = Snap(SemiStall(4, 40), Healthy(5, 50));
        var first = JsonSerializer.Serialize(PerformanceDiagnosisEngine.Diagnose(snapshot));
        var second = JsonSerializer.Serialize(PerformanceDiagnosisEngine.Diagnose(snapshot));

        Assert.Equal(first, second);
    }

    [Fact]
    public void Non_normal_states_have_evidence_reasons()
    {
        PerformanceDiagnosis[] diagnoses =
        [
            PerformanceDiagnosisEngine.Diagnose(Snap(SemiStall(1, 1))),
            PerformanceDiagnosisEngine.Diagnose(Snap(systemCpu: PerformanceMetric<double>.Unavailable())),
            PerformanceDiagnosisEngine.Diagnose(Snap(processes: [Healthy()], window: MetricAvailability.Unknown, duration: null))
        ];

        Assert.All(diagnoses, diagnosis =>
        {
            Assert.NotEqual(PerformanceOverallState.NORMAL, diagnosis.OverallState);
            Assert.NotEmpty(diagnosis.EvidenceReasons);
        });
    }

    [Fact]
    public void Diagnosis_does_not_use_the_legacy_memory_fallback()
    {
        var engine = File.ReadAllText(SourcePath("PerformanceDiagnosisEngine.cs"));
        var contract = File.ReadAllText(SourcePath("PerformanceDiagnosis.cs"));

        Assert.DoesNotContain("17179869184", engine);
        Assert.DoesNotContain("4294967296", engine);
        Assert.DoesNotContain("HostResourceSnapshot", engine + contract);
        Assert.False(PerformanceDiagnosisPolicy.MemoryPressureClassificationEnabled);

        var diagnosis = PerformanceDiagnosisEngine.Diagnose(Snap(
            processes: [Healthy()],
            ram: ObservedRam(LegacyFakeTotal, LegacyFakeAvailable)));
        Assert.NotEqual(PerformanceCause.MEMORY_PRESSURE, diagnosis.PrimaryCause);
        Assert.NotEqual(PerformanceCause.PAGING_PRESSURE, diagnosis.PrimaryCause);
    }

    [Fact]
    public void Not_supported_domains_are_not_treated_as_zero()
    {
        var diagnosis = PerformanceDiagnosisEngine.Diagnose(Snap(Healthy()));
        var json = JsonSerializer.Serialize(diagnosis);

        Assert.Contains("ioNotSupported", diagnosis.UnknownReasons);
        Assert.Contains("gpuNotSupported", diagnosis.UnknownReasons);
        Assert.Contains("pagingNotSupported", diagnosis.UnknownReasons);
        Assert.DoesNotContain("IO_PRESSURE", json);
        Assert.DoesNotContain("GPU_PRESSURE", json);
        Assert.DoesNotContain("PAGING_PRESSURE", json);
        Assert.DoesNotContain("\"Value\":0", json);
        Assert.DoesNotContain("\"Value\":0.0", json);
    }

    [Fact]
    public void Diagnosis_sources_do_not_invoke_mutators()
    {
        var forbidden = new[]
        {
            "ApplyThrottleAsync",
            "TerminateAsync",
            "ResolutionExecutionService",
            "Defender",
            "Firewall",
            "Process.Kill",
            "Kill(",
            "HostResourceSnapshot",
            "GlobalMemoryStatusEx",
            "GetSystemTimes"
        };
        var files = Directory.EnumerateFiles(PerformanceDirectory(), "*.cs").ToArray();
        Assert.NotEmpty(files);
        foreach (var file in files)
        {
            var text = File.ReadAllText(file);
            foreach (var token in forbidden)
                Assert.DoesNotContain(token, text);
        }

        Assert.True(PerformanceDiagnosisPolicy.CpuUtilizationClassificationEnabled);
        Assert.Equal(90m, PerformanceDiagnosisPolicy.ApprovedSystemCpuPercent);
        Assert.Equal(40m, PerformanceDiagnosisPolicy.ApprovedProcessCpuPercent);
        Assert.Equal(0.70m, PerformanceDiagnosisPolicy.ApprovedProcessShareOfBusy);
        Assert.False(PerformanceDiagnosisPolicy.WallClockDurationApproved);
        Assert.False(PerformanceDiagnosisPolicy.CooldownDurationApproved);
        Assert.False(PerformanceDiagnosisPolicy.AutoCandidatePermitted());
        var engine = File.ReadAllText(SourcePath("PerformanceDiagnosisEngine.cs"));
        Assert.DoesNotContain("85", engine);
        Assert.DoesNotContain("95", engine);
        Assert.DoesNotContain("SetPriorityClass", engine);
    }

    private static ProcessPerformanceEvidence Healthy(int pid = 10, long ticks = 100, bool responding = true) => new()
    {
        IdentityKey = PerformanceIdentity.Key(pid, ticks),
        Pid = pid,
        StartTimeUtcTicks = ticks,
        ProcessName = "worker",
        IdentityPathMatches = true,
        ImagePathState = MetricAvailability.Observed,
        ImagePath = "C:\\worker.exe",
        CpuTimeBaselineSeconds = PerformanceMetric<double>.Observed(1),
        CpuTimeCurrentSeconds = PerformanceMetric<double>.Observed(2),
        CpuDeltaSeconds = PerformanceMetric<double>.Observed(1),
        CpuUtilizationPercent = PerformanceMetric<double>.Observed(12.5),
        CpuTimeAdvanced = PerformanceMetric<bool>.Observed(true),
        Responding = PerformanceMetric<bool>.Observed(responding)
    };

    private static ProcessPerformanceEvidence WithUtilization(ProcessPerformanceEvidence row, double percent) => new()
    {
        IdentityKey = row.IdentityKey,
        Pid = row.Pid,
        StartTimeUtcTicks = row.StartTimeUtcTicks,
        IdentityPathMatches = true,
        CpuTimeBaselineSeconds = row.CpuTimeBaselineSeconds,
        CpuTimeCurrentSeconds = row.CpuTimeCurrentSeconds,
        CpuDeltaSeconds = row.CpuDeltaSeconds,
        CpuUtilizationPercent = PerformanceMetric<double>.Observed(percent),
        CpuTimeAdvanced = row.CpuTimeAdvanced,
        Responding = row.Responding
    };

    private static ProcessPerformanceEvidence DeltaZero(bool? responding, int pid = 10, long ticks = 100) => new()
    {
        IdentityKey = PerformanceIdentity.Key(pid, ticks),
        Pid = pid,
        StartTimeUtcTicks = ticks,
        IdentityPathMatches = true,
        CpuTimeBaselineSeconds = PerformanceMetric<double>.Observed(5),
        CpuTimeCurrentSeconds = PerformanceMetric<double>.Observed(5),
        CpuDeltaSeconds = PerformanceMetric<double>.Observed(0),
        CpuUtilizationPercent = PerformanceMetric<double>.Observed(0),
        CpuTimeAdvanced = PerformanceMetric<bool>.Observed(false),
        Responding = responding is null
            ? PerformanceMetric<bool>.Unavailable()
            : PerformanceMetric<bool>.Observed(responding.Value)
    };

    private static ProcessPerformanceEvidence SemiStall(int pid, long ticks) =>
        DeltaZero(responding: false, pid, ticks);

    private static ProcessPerformanceEvidence UnkeyedStall() => new()
    {
        IdentityKey = string.Empty,
        Pid = 8,
        StartTimeUtcTicks = 0,
        IdentityPathMatches = false,
        CpuTimeBaselineSeconds = PerformanceMetric<double>.Observed(1),
        CpuTimeCurrentSeconds = PerformanceMetric<double>.Observed(1),
        CpuDeltaSeconds = PerformanceMetric<double>.Observed(0),
        CpuTimeAdvanced = PerformanceMetric<bool>.Observed(false),
        Responding = PerformanceMetric<bool>.Observed(false)
    };

    private static RamEvidence ObservedRam(long total, long available) => new()
    {
        TotalBytes = PerformanceMetric<long>.Observed(total),
        AvailableBytes = PerformanceMetric<long>.Observed(available),
        UsedBytes = PerformanceMetric<long>.Observed(total - available),
        CommitLimitBytes = PerformanceMetric<long>.Observed(total),
        CommitAvailableBytes = PerformanceMetric<long>.Observed(available),
        CommitUsedBytes = PerformanceMetric<long>.Observed(total - available),
        PagefileTotalBytes = PerformanceMetric<long>.NotSupported(),
        PagefileAvailableBytes = PerformanceMetric<long>.NotSupported()
    };

    private static PerformanceSnapshot Snap(
        params ProcessPerformanceEvidence[] processes) =>
        Snap(processes, MetricAvailability.Observed, 1, null, null, null, null, null, null);

    private static PerformanceSnapshot Snap(
        ProcessPerformanceEvidence[]? processes = null,
        MetricAvailability window = MetricAvailability.Observed,
        double? duration = 1,
        PerformanceMetric<double>? systemCpu = null,
        RamEvidence? ram = null,
        IoEvidence? io = null,
        GpuEvidence? gpu = null,
        string[]? absent = null,
        ProcessIdentityDrift[]? drift = null) => new()
    {
        BaselineTimestampUtc = DateTimeOffset.Parse("2026-10-05T08:00:00Z"),
        TimestampUtc = DateTimeOffset.Parse("2026-10-05T08:00:01Z"),
        SampleCount = 2,
        SampleDurationSeconds = duration is null
            ? PerformanceMetric<double>.Unknown()
            : PerformanceMetric<double>.Observed(duration.Value),
        Window = window,
        Ram = ram ?? ObservedRam(32L << 30, 8L << 30),
        Cpu = new CpuEvidence
        {
            LogicalProcessors = PerformanceMetric<int>.Observed(8),
            SystemUtilizationPercent = systemCpu ?? PerformanceMetric<double>.Observed(10)
        },
        Io = io ?? new IoEvidence(),
        Gpu = gpu ?? new GpuEvidence(),
        ProcessEnumeration = MetricAvailability.Observed,
        ProcessTopConsumers = processes ?? [],
        AbsentFromCurrentSample = absent ?? [],
        IdentityDrift = drift ?? []
    };

    private static string PerformanceDirectory()
    {
        var dir = Path.GetFullPath(Path.Combine(
            AppContext.BaseDirectory, "..", "..", "..", "..", "..", "src", "SystemOptimizerHub.Core", "Performance"));
        Assert.True(Directory.Exists(dir), dir);
        return dir;
    }

    private static string SourcePath(string file) => Path.Combine(PerformanceDirectory(), file);
}
