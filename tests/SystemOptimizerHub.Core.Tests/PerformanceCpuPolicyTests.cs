using SystemOptimizerHub.Core.Performance;

namespace SystemOptimizerHub.Core.Tests;

public class PerformanceCpuPolicyTests
{
    [Fact]
    public void Boundary_share_at_system_90_matches_without_auto_candidate()
    {
        var diagnosis = Diagnose(90m, 63m, samples: 4, intervals: 3);

        Assert.True(diagnosis.CpuPolicyMatched);
        Assert.Equal(PerformanceCause.CPU_CONTENTION, diagnosis.PrimaryCause);
        Assert.Equal(PerformanceOverallState.CRITICAL, diagnosis.OverallState);
        Assert.Equal(PerformanceAutomationEligibility.HITL_REQUIRED, diagnosis.AutomationEligibility);
        Assert.Equal(["10:100"], diagnosis.CandidateTargets);
        Assert.Contains("WALL_CLOCK_POLICY_UNDECIDED", diagnosis.PolicyBlockers);
        Assert.Contains("COOLDOWN_UNDECIDED", diagnosis.PolicyBlockers);
        Assert.Contains("PROCESS_CLASSIFICATION_UNAVAILABLE", diagnosis.PolicyBlockers);
        Assert.Contains("UNSUPPORTED_DOMAIN_POLICY", diagnosis.PolicyBlockers);
        Assert.NotEqual(PerformanceAutomationEligibility.AUTO_CANDIDATE, diagnosis.AutomationEligibility);
    }

    [Fact]
    public void System_95_and_process_70_match_the_share_gate()
    {
        var diagnosis = Diagnose(95m, 70m, samples: 4, intervals: 3);

        Assert.True(diagnosis.CpuPolicyMatched);
        Assert.Equal(PerformanceAutomationEligibility.HITL_REQUIRED, diagnosis.AutomationEligibility);
    }

    [Fact]
    public void Four_samples_and_three_intervals_are_the_persistence_structure()
    {
        var diagnosis = Diagnose(90m, 63m, samples: 4, intervals: 3);

        Assert.DoesNotContain("INSUFFICIENT_PERSISTENCE", diagnosis.EvidenceReasons);
        Assert.True(diagnosis.CpuPolicyMatched);
    }

    [Fact]
    public void System_just_below_90_is_rejected()
    {
        var diagnosis = Diagnose(89.99m, 80m, samples: 4, intervals: 3);

        Assert.False(diagnosis.CpuPolicyMatched);
        Assert.Contains("SYSTEM_CPU_BELOW_THRESHOLD", diagnosis.EvidenceReasons);
        Assert.NotEqual(PerformanceAutomationEligibility.AUTO_CANDIDATE, diagnosis.AutomationEligibility);
    }

    [Fact]
    public void Process_just_below_40_is_rejected()
    {
        var diagnosis = Diagnose(50m, 39.99m, samples: 4, intervals: 3);

        Assert.False(diagnosis.CpuPolicyMatched);
        Assert.Contains("PROCESS_CPU_BELOW_THRESHOLD", diagnosis.EvidenceReasons);
    }

    [Fact]
    public void Share_just_below_0_70_is_rejected()
    {
        var diagnosis = Diagnose(100m, 69.99m, samples: 4, intervals: 3);

        Assert.False(diagnosis.CpuPolicyMatched);
        Assert.Contains("PROCESS_SHARE_BELOW_THRESHOLD", diagnosis.EvidenceReasons);
    }

    [Fact]
    public void System_90_and_process_40_do_not_meet_the_share_formula()
    {
        var diagnosis = Diagnose(90m, 40m, samples: 4, intervals: 3);

        Assert.False(diagnosis.CpuPolicyMatched);
        Assert.Contains("PROCESS_SHARE_BELOW_THRESHOLD", diagnosis.EvidenceReasons);
    }

    [Fact]
    public void Fewer_than_four_samples_are_rejected()
    {
        var diagnosis = Diagnose(90m, 63m, samples: 3, intervals: 3);

        Assert.False(diagnosis.CpuPolicyMatched);
        Assert.Contains("INSUFFICIENT_PERSISTENCE", diagnosis.EvidenceReasons);
    }

    [Fact]
    public void Fewer_than_three_positive_intervals_are_rejected()
    {
        var diagnosis = Diagnose(90m, 63m, samples: 4, intervals: 2);

        Assert.False(diagnosis.CpuPolicyMatched);
        Assert.Contains("INSUFFICIENT_PERSISTENCE", diagnosis.EvidenceReasons);
    }

    [Fact]
    public void Identity_drift_is_not_a_cpu_target()
    {
        var diagnosis = Diagnose(90m, 63m, samples: 4, intervals: 3, drift: true);

        Assert.False(diagnosis.CpuPolicyMatched);
        Assert.Contains("IDENTITY_DRIFT", diagnosis.EvidenceReasons);
        Assert.Empty(diagnosis.CandidateTargets);
    }

    [Fact]
    public void Empty_path_is_rejected()
    {
        var diagnosis = Diagnose(90m, 63m, samples: 4, intervals: 3, path: "");

        Assert.False(diagnosis.CpuPolicyMatched);
        Assert.Contains("PATH_MISSING", diagnosis.EvidenceReasons);
    }

    [Fact]
    public void Path_mismatch_is_rejected()
    {
        var diagnosis = Diagnose(90m, 63m, samples: 4, intervals: 3, pathMatches: false);

        Assert.False(diagnosis.CpuPolicyMatched);
        Assert.Contains("IDENTITY_PATH_MISMATCH", diagnosis.EvidenceReasons);
    }

    [Fact]
    public void Cpu_delta_zero_with_not_responding_stays_semi_stall_hitl()
    {
        var row = Row(10, 100, 0m);
        row = new ProcessPerformanceEvidence
        {
            IdentityKey = row.IdentityKey,
            Pid = row.Pid,
            StartTimeUtcTicks = row.StartTimeUtcTicks,
            IdentityPathMatches = true,
            ImagePathState = MetricAvailability.Observed,
            ImagePath = "C:\\worker.exe",
            CpuTimeBaselineSeconds = PerformanceMetric<double>.Observed(5),
            CpuDeltaSeconds = PerformanceMetric<double>.Observed(0),
            CpuUtilizationPercent = PerformanceMetric<double>.Observed(0),
            CpuTimeAdvanced = PerformanceMetric<bool>.Observed(false),
            Responding = PerformanceMetric<bool>.Observed(false),
            PriorityCurrent = PerformanceMetric<ObservedProcessPriority>.Observed(ObservedProcessPriority.Normal)
        };
        var diagnosis = PerformanceDiagnosisEngine.Diagnose(Host(90m, 4, 3, row));

        Assert.Equal(PerformanceCause.PROCESS_SEMI_STALL, diagnosis.PrimaryCause);
        Assert.Equal(PerformanceAutomationEligibility.HITL_REQUIRED, diagnosis.AutomationEligibility);
        Assert.False(diagnosis.CpuPolicyMatched);
        Assert.NotEqual(PerformanceCause.CPU_CONTENTION, diagnosis.PrimaryCause);
    }

    [Fact]
    public void Priority_unavailable_is_rejected()
    {
        var diagnosis = Diagnose(90m, 63m, samples: 4, intervals: 3, priority: PerformanceMetric<ObservedProcessPriority>.Unavailable());

        Assert.False(diagnosis.CpuPolicyMatched);
        Assert.Contains("PRIORITY_UNAVAILABLE", diagnosis.EvidenceReasons);
    }

    [Fact]
    public void Priority_below_normal_is_rejected()
    {
        var diagnosis = Diagnose(
            90m,
            63m,
            samples: 4,
            intervals: 3,
            priority: PerformanceMetric<ObservedProcessPriority>.Observed(ObservedProcessPriority.BelowNormal));

        Assert.False(diagnosis.CpuPolicyMatched);
        Assert.Contains("PRIORITY_BELOW_NORMAL", diagnosis.EvidenceReasons);
    }

    [Fact]
    public void Two_qualifying_targets_require_hitl_and_select_neither()
    {
        var diagnosis = PerformanceDiagnosisEngine.Diagnose(Host(
            90m,
            4,
            3,
            Row(10, 100, 63m),
            Row(11, 110, 70m)));

        Assert.False(diagnosis.CpuPolicyMatched);
        Assert.Contains("MULTIPLE_TARGETS", diagnosis.EvidenceReasons);
        Assert.Empty(diagnosis.CandidateTargets);
        Assert.Equal(PerformanceAutomationEligibility.HITL_REQUIRED, diagnosis.AutomationEligibility);
    }

    [Fact]
    public void No_qualifying_target_is_no_action()
    {
        var diagnosis = Diagnose(10m, 12.5m, samples: 2, intervals: 1);

        Assert.Empty(diagnosis.CandidateTargets);
        Assert.Equal(PerformanceAutomationEligibility.NO_ACTION, diagnosis.AutomationEligibility);
        Assert.False(diagnosis.CpuPolicyMatched);
    }

    [Fact]
    public void Unsupported_domains_block_auto_candidate()
    {
        var diagnosis = Diagnose(90m, 63m, samples: 4, intervals: 3);

        Assert.Contains("UNSUPPORTED_DOMAIN_POLICY", diagnosis.PolicyBlockers);
        Assert.NotEqual(PerformanceAutomationEligibility.AUTO_CANDIDATE, diagnosis.AutomationEligibility);
    }

    [Fact]
    public void Missing_process_classification_requires_hitl_when_cpu_policy_matches()
    {
        var diagnosis = Diagnose(90m, 63m, samples: 4, intervals: 3);

        Assert.Contains("PROCESS_CLASSIFICATION_UNAVAILABLE", diagnosis.PolicyBlockers);
        Assert.Equal(PerformanceAutomationEligibility.HITL_REQUIRED, diagnosis.AutomationEligibility);
    }

    [Fact]
    public void Undecided_wall_clock_blocks_auto_candidate()
    {
        var diagnosis = Diagnose(90m, 63m, samples: 4, intervals: 3);

        Assert.False(PerformanceDiagnosisPolicy.WallClockDurationApproved);
        Assert.Contains("WALL_CLOCK_POLICY_UNDECIDED", diagnosis.PolicyBlockers);
        Assert.NotEqual(PerformanceAutomationEligibility.AUTO_CANDIDATE, diagnosis.AutomationEligibility);
    }

    [Fact]
    public void Undecided_cooldown_blocks_auto_candidate()
    {
        var diagnosis = Diagnose(90m, 63m, samples: 4, intervals: 3);

        Assert.False(PerformanceDiagnosisPolicy.CooldownDurationApproved);
        Assert.Contains("COOLDOWN_UNDECIDED", diagnosis.PolicyBlockers);
        Assert.NotEqual(PerformanceAutomationEligibility.AUTO_CANDIDATE, diagnosis.AutomationEligibility);
    }

    [Fact]
    public void Policy_sources_do_not_call_mutators_or_apply()
    {
        var files = new[]
        {
            Repo("src", "SystemOptimizerHub.Core", "Performance", "PerformanceDiagnosis.cs"),
            Repo("src", "SystemOptimizerHub.Core", "Performance", "PerformanceDiagnosisEngine.cs"),
            Repo("src", "SystemOptimizerHub.Core", "Performance", "PerformanceEvidenceCollector.cs"),
            Repo("src", "SystemOptimizerHub.Core", "Performance", "PerformanceEvidenceBuilder.cs"),
            Repo("src", "SystemOptimizerHub.Windows", "WindowsDomainEvidenceReaders.cs")
        };
        var forbidden = new[] { "SetPriorityClass", "PriorityClass =", "ApplyThrottleAsync", "Kill(", "TerminateAsync", "--apply" };
        foreach (var file in files)
        {
            var text = File.ReadAllText(file);
            foreach (var token in forbidden)
                Assert.DoesNotContain(token, text);
        }

        var cli = File.ReadAllText(Repo("src", "SystemOptimizerHub.Cli", "Program.cs"));
        Assert.DoesNotContain("--apply", cli, StringComparison.Ordinal);
        Assert.DoesNotContain("guard apply", cli, StringComparison.Ordinal);
        Assert.DoesNotContain("guard action", cli, StringComparison.Ordinal);

        Assert.False(PerformanceDiagnosisPolicy.AutoCandidatePermitted());
    }

    private static PerformanceDiagnosis Diagnose(
        decimal system,
        decimal process,
        int samples,
        int intervals,
        bool drift = false,
        string path = "C:\\worker.exe",
        bool pathMatches = true,
        PerformanceMetric<ObservedProcessPriority>? priority = null)
    {
        var row = Row(10, 100, process, path, pathMatches, priority);
        return PerformanceDiagnosisEngine.Diagnose(Host(system, samples, intervals, drift, row));
    }

    private static PerformanceSnapshot Host(decimal system, int samples, int intervals, params ProcessPerformanceEvidence[] rows) =>
        Host(system, samples, intervals, false, rows);

    private static PerformanceSnapshot Host(
        decimal system,
        int samples,
        int intervals,
        bool drift,
        params ProcessPerformanceEvidence[] rows) => new()
    {
        BaselineTimestampUtc = DateTimeOffset.Parse("2026-10-05T08:00:00Z"),
        TimestampUtc = DateTimeOffset.Parse("2026-10-05T08:00:01Z"),
        SampleCount = samples,
        PositiveIntervalCount = intervals,
        SampleDurationSeconds = PerformanceMetric<double>.Observed(1),
        Window = MetricAvailability.Observed,
        Ram = new RamEvidence(),
        Cpu = new CpuEvidence
        {
            LogicalProcessors = PerformanceMetric<int>.Observed(8),
            SystemUtilizationPercent = PerformanceMetric<double>.Observed((double)system)
        },
        ProcessEnumeration = MetricAvailability.Observed,
        ProcessTopConsumers = rows,
        IdentityDrift = drift
            ? [new ProcessIdentityDrift { Pid = rows[0].Pid, BaselineStartTimeUtcTicks = 1, CurrentStartTimeUtcTicks = rows[0].StartTimeUtcTicks }]
            : []
    };

    private static ProcessPerformanceEvidence Row(
        int pid,
        long ticks,
        decimal processCpu,
        string path = "C:\\worker.exe",
        bool pathMatches = true,
        PerformanceMetric<ObservedProcessPriority>? priority = null) => new()
    {
        IdentityKey = PerformanceIdentity.Key(pid, ticks),
        Pid = pid,
        StartTimeUtcTicks = ticks,
        ProcessName = "worker",
        IdentityPathMatches = pathMatches,
        ImagePathState = string.IsNullOrWhiteSpace(path) ? MetricAvailability.Unavailable : MetricAvailability.Observed,
        ImagePath = string.IsNullOrWhiteSpace(path) ? null : path,
        CpuTimeBaselineSeconds = PerformanceMetric<double>.Observed(1),
        CpuDeltaSeconds = PerformanceMetric<double>.Observed(1),
        CpuUtilizationPercent = PerformanceMetric<double>.Observed((double)processCpu),
        CpuTimeAdvanced = PerformanceMetric<bool>.Observed(true),
        Responding = PerformanceMetric<bool>.Observed(true),
        PriorityCurrent = priority ?? PerformanceMetric<ObservedProcessPriority>.Observed(ObservedProcessPriority.Normal)
    };

    private static string Repo(params string[] parts)
    {
        var path = Path.GetFullPath(Path.Combine(new[] { AppContext.BaseDirectory, "..", "..", "..", "..", ".." }.Concat(parts).ToArray()));
        Assert.True(File.Exists(path), path);
        return path;
    }
}
