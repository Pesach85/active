namespace SystemOptimizerHub.Core.Performance;

public static class PerformanceDiagnosisEngine
{
    public static PerformanceDiagnosis Diagnose(PerformanceSnapshot snapshot)
    {
        ArgumentNullException.ThrowIfNull(snapshot);

        var evidence = new SortedSet<string>(StringComparer.Ordinal);
        var unknown = new SortedSet<string>(StringComparer.Ordinal);
        var candidates = new SortedSet<string>(StringComparer.Ordinal);
        var positive = new List<PerformanceCause>();

        RecordUnsupportedDomains(snapshot, unknown);
        var windowUsable = snapshot.Window == MetricAvailability.Observed
            && snapshot.SampleCount >= 2
            && snapshot.SampleDurationSeconds.Availability == MetricAvailability.Observed
            && snapshot.SampleDurationSeconds.Value is > 0;

        if (!windowUsable)
        {
            evidence.Add("durationUnknown");
            unknown.Add("durationUnknown");
        }
        else
            evidence.Add("windowObserved");

        if (snapshot.AbsentFromCurrentSample.Count > 0)
            evidence.Add("absentFromRetainedWindowIsNotTermination");

        if (snapshot.IdentityDrift.Count > 0)
        {
            evidence.Add("identityDriftExcluded");
            evidence.Add("IDENTITY_DRIFT");
        }

        var driftedPids = snapshot.IdentityDrift.Select(d => d.Pid).ToHashSet();
        var cpuRows = 0;
        foreach (var row in snapshot.ProcessTopConsumers)
        {
            if (!StableIdentity(row, driftedPids))
                continue;

            evidence.Add("stableProcessIdentity");
            if (row.CpuTimeAdvanced.Availability == MetricAvailability.Observed
                || row.CpuDeltaSeconds.Availability == MetricAvailability.Observed
                || row.CpuUtilizationPercent.Availability == MetricAvailability.Observed)
                cpuRows++;

            if (!windowUsable)
            {
                RecordResponding(row, evidence, unknown);
                continue;
            }

            if (IsSemiStall(row))
            {
                candidates.Add(row.IdentityKey);
                evidence.Add("cpuTimeNotAdvanced");
                evidence.Add("respondingObservedFalse");
                evidence.Add("pairedBaselineCpu");
                continue;
            }

            if (row.CpuTimeAdvanced.Availability == MetricAvailability.Observed && row.CpuTimeAdvanced.Value == false)
                evidence.Add("cpuTimeNotAdvanced");
            else if (row.CpuTimeAdvanced.Availability == MetricAvailability.Observed
                && row.Responding.Availability == MetricAvailability.Observed
                && row.Responding.Value == false)
                evidence.Add("semiStallRequiresCpuNotAdvanced");

            RecordResponding(row, evidence, unknown);
        }

        var systemCpuObserved = snapshot.Cpu.SystemUtilizationPercent.Availability == MetricAvailability.Observed;
        if (systemCpuObserved)
        {
            evidence.Add("systemCpuObserved");
        }
        else if (snapshot.Cpu.SystemUtilizationPercent.Availability == MetricAvailability.NotSupported)
            unknown.Add("systemCpuNotSupported");
        else
            unknown.Add("systemCpuUnusable");

        if (candidates.Count > 0)
            positive.Add(PerformanceCause.PROCESS_SEMI_STALL);

        var blockers = StructuralBlockers(snapshot);
        var cpuTargets = new List<string>();
        var partialCpuPressure = false;
        if (PerformanceDiagnosisPolicy.CpuUtilizationClassificationEnabled && windowUsable)
            partialCpuPressure = EvaluateCpuPolicy(snapshot, driftedPids, evidence, cpuTargets);

        if (cpuTargets.Count == 1 && candidates.Count == 0)
            positive.Add(PerformanceCause.CPU_CONTENTION);
        else if (cpuTargets.Count == 1 && candidates.Count > 0)
            evidence.Add("COMPETING_CAUSE");
        else if (cpuTargets.Count > 1)
            evidence.Add("MULTIPLE_TARGETS");

        var cpuEvidence = cpuRows > 0 || systemCpuObserved;
        if (!cpuEvidence)
        {
            evidence.Add("cpuEvidenceInsufficient");
            unknown.Add("cpuEvidenceInsufficient");
        }

        var primary = ResolvePrimary(positive);
        if (primary == PerformanceCause.NONE && (!windowUsable || !cpuEvidence))
            primary = PerformanceCause.UNKNOWN;

        var matched = primary == PerformanceCause.CPU_CONTENTION && cpuTargets.Count == 1;
        var multipleTargets = cpuTargets.Count > 1;
        var state = ResolveState(primary, windowUsable, cpuEvidence);
        if (matched || multipleTargets)
            state = PerformanceOverallState.CRITICAL;
        else if (partialCpuPressure && state == PerformanceOverallState.NORMAL)
            state = PerformanceOverallState.DEGRADED;

        if (state != PerformanceOverallState.NORMAL && evidence.Count == 0)
            evidence.Add("diagnosisIncomplete");

        var eligibility = Eligibility(primary, matched || multipleTargets);
        string[] targets = primary switch
        {
            PerformanceCause.PROCESS_SEMI_STALL => candidates.ToArray(),
            PerformanceCause.CPU_CONTENTION when matched => [cpuTargets[0]],
            _ => []
        };

        return new PerformanceDiagnosis
        {
            OverallState = state,
            PrimaryCause = primary,
            Confidence = matched ? PerformanceConfidence.HIGH : ConfidenceFor(state, primary),
            EvidenceReasons = evidence.ToArray(),
            CandidateTargets = targets,
            AutomationEligibility = eligibility,
            UnknownReasons = unknown.ToArray(),
            CpuPolicyMatched = matched,
            PolicyBlockers = blockers.ToArray()
        };
    }

    private static bool EvaluateCpuPolicy(
        PerformanceSnapshot snapshot,
        HashSet<int> driftedPids,
        SortedSet<string> evidence,
        List<string> cpuTargets)
    {
        var persistence = snapshot.SampleCount >= PerformanceDiagnosisPolicy.ApprovedMinimumSamples
            && snapshot.PositiveIntervalCount >= PerformanceDiagnosisPolicy.ApprovedMinimumPositiveIntervals;
        if (!persistence)
            evidence.Add("INSUFFICIENT_PERSISTENCE");

        var system = snapshot.Cpu.SystemUtilizationPercent;
        decimal? systemPercent = system.Availability == MetricAvailability.Observed && system.Value is not null
            ? (decimal)system.Value.Value
            : null;
        var systemOk = systemPercent is >= PerformanceDiagnosisPolicy.ApprovedSystemCpuPercent;
        if (systemPercent is not null && !systemOk)
            evidence.Add("SYSTEM_CPU_BELOW_THRESHOLD");

        var partial = systemOk;
        foreach (var row in snapshot.ProcessTopConsumers)
        {
            if (!KeyStable(row, driftedPids) || IsSemiStall(row))
                continue;
            if (row.CpuUtilizationPercent.Availability != MetricAvailability.Observed || row.CpuUtilizationPercent.Value is null)
                continue;

            var processPercent = (decimal)row.CpuUtilizationPercent.Value.Value;
            var processOk = processPercent >= PerformanceDiagnosisPolicy.ApprovedProcessCpuPercent;
            if (!processOk)
                evidence.Add("PROCESS_CPU_BELOW_THRESHOLD");
            else
                partial = true;

            var shareOk = false;
            if (systemPercent is > 0)
            {
                var share = processPercent / systemPercent.Value;
                shareOk = share >= PerformanceDiagnosisPolicy.ApprovedProcessShareOfBusy;
                if (!shareOk)
                    evidence.Add("PROCESS_SHARE_BELOW_THRESHOLD");
            }

            if (!systemOk || !processOk || !shareOk || !persistence)
                continue;
            if (!CpuTargetGates(row, evidence))
                continue;
            cpuTargets.Add(row.IdentityKey);
        }

        if (systemOk && cpuTargets.Count == 0)
            evidence.Add("NO_TARGET");
        return partial;
    }

    private static bool CpuTargetGates(ProcessPerformanceEvidence row, SortedSet<string> evidence)
    {
        var open = true;
        if (row.CpuTimeAdvanced.Availability != MetricAvailability.Observed || row.CpuTimeAdvanced.Value != true)
        {
            evidence.Add("PROCESS_CPU_NOT_ADVANCING");
            open = false;
        }

        if (row.ImagePathState != MetricAvailability.Observed || string.IsNullOrWhiteSpace(row.ImagePath))
        {
            evidence.Add("PATH_MISSING");
            open = false;
        }
        else if (!row.IdentityPathMatches)
        {
            evidence.Add("IDENTITY_PATH_MISMATCH");
            open = false;
        }

        if (row.PriorityCurrent.Availability != MetricAvailability.Observed || row.PriorityCurrent.Value is null)
        {
            evidence.Add("PRIORITY_UNAVAILABLE");
            open = false;
        }
        else if (row.PriorityCurrent.Value == ObservedProcessPriority.BelowNormal)
        {
            evidence.Add("PRIORITY_BELOW_NORMAL");
            open = false;
        }

        return open;
    }

    private static SortedSet<string> StructuralBlockers(PerformanceSnapshot snapshot)
    {
        var blockers = new SortedSet<string>(StringComparer.Ordinal);
        if (!PerformanceDiagnosisPolicy.WallClockDurationApproved)
            blockers.Add("WALL_CLOCK_POLICY_UNDECIDED");
        if (!PerformanceDiagnosisPolicy.CooldownDurationApproved)
            blockers.Add("COOLDOWN_UNDECIDED");
        if (!PerformanceDiagnosisPolicy.ProcessClassificationAvailable)
            blockers.Add("PROCESS_CLASSIFICATION_UNAVAILABLE");
        if (!PerformanceDiagnosisPolicy.UnsupportedDomainCpuOnlyPermitted
            || snapshot.Io.DiskLatency != MetricAvailability.Observed
            || snapshot.Io.QueueDepth != MetricAvailability.Observed
            || snapshot.Io.ProcessIoBytes != MetricAvailability.Observed
            || snapshot.Gpu.Utilization != MetricAvailability.Observed
            || snapshot.Gpu.Memory != MetricAvailability.Observed
            || snapshot.Gpu.Thermal != MetricAvailability.Observed
            || snapshot.Ram.PagefileTotalBytes.Availability != MetricAvailability.Observed)
            blockers.Add("UNSUPPORTED_DOMAIN_POLICY");
        return blockers;
    }

    public static PerformanceCause ResolvePrimary(IReadOnlyCollection<PerformanceCause> positiveCauses)
    {
        var distinct = positiveCauses.Where(c => c is not PerformanceCause.NONE and not PerformanceCause.UNKNOWN).Distinct().ToArray();
        if (distinct.Length == 0)
            return PerformanceCause.NONE;
        if (distinct.Length > 1)
            return PerformanceCause.MIXED;
        return distinct[0];
    }

    private static void RecordUnsupportedDomains(PerformanceSnapshot snapshot, SortedSet<string> unknown)
    {
        if (snapshot.Ram.TotalBytes.Availability == MetricAvailability.Observed
            && snapshot.Ram.AvailableBytes.Availability == MetricAvailability.Observed)
        {
            if (!PerformanceDiagnosisPolicy.MemoryPressureClassificationEnabled)
                unknown.Add("memoryClassificationInactive");
        }
        else
            unknown.Add("ramUnavailable");

        if (snapshot.Ram.PagefileTotalBytes.Availability == MetricAvailability.NotSupported)
            unknown.Add("pagingNotSupported");
        else if (snapshot.Ram.PagefileTotalBytes.Availability != MetricAvailability.Observed
            || !PerformanceDiagnosisPolicy.PagingPressureClassificationEnabled)
            unknown.Add(snapshot.Ram.PagefileTotalBytes.Availability == MetricAvailability.Observed
                ? "pagingClassificationInactive"
                : "pagingUnavailable");

        if (snapshot.Io.DiskLatency == MetricAvailability.Observed
            && snapshot.Io.QueueDepth == MetricAvailability.Observed
            && snapshot.Io.ProcessIoBytes == MetricAvailability.Observed)
        {
            // No approved I/O pressure rule exists. Observed counters stay unexplained as pressure.
            unknown.Add("ioClassificationInactive");
        }
        else if (snapshot.Io.DiskLatency == MetricAvailability.NotSupported
            || snapshot.Io.QueueDepth == MetricAvailability.NotSupported
            || snapshot.Io.ProcessIoBytes == MetricAvailability.NotSupported)
            unknown.Add("ioNotSupported");
        else
            unknown.Add("ioUnavailable");

        if (snapshot.Gpu.Utilization == MetricAvailability.Observed && snapshot.Gpu.Memory == MetricAvailability.Observed)
            unknown.Add("gpuClassificationInactive");
        else if (snapshot.Gpu.Utilization == MetricAvailability.NotSupported
            || snapshot.Gpu.Memory == MetricAvailability.NotSupported)
            unknown.Add("gpuNotSupported");
        else
            unknown.Add("gpuUnavailable");
    }

    private static bool StableIdentity(ProcessPerformanceEvidence row, HashSet<int> driftedPids) =>
        KeyStable(row, driftedPids) && row.IdentityPathMatches;

    private static bool KeyStable(ProcessPerformanceEvidence row, HashSet<int> driftedPids)
    {
        if (row.StartTimeUtcTicks <= 0 || string.IsNullOrEmpty(row.IdentityKey))
            return false;
        if (!string.Equals(row.IdentityKey, PerformanceIdentity.Key(row.Pid, row.StartTimeUtcTicks), StringComparison.Ordinal))
            return false;
        return !driftedPids.Contains(row.Pid);
    }

    private static void RecordResponding(
        ProcessPerformanceEvidence row,
        SortedSet<string> evidence,
        SortedSet<string> unknown)
    {
        if (row.Responding.Availability == MetricAvailability.Observed && row.Responding.Value == false)
            evidence.Add("respondingObservedFalse");
        else if (row.Responding.Availability == MetricAvailability.Observed && row.Responding.Value == true)
            evidence.Add("respondingObservedTrue");
        else if (row.Responding.Availability == MetricAvailability.Unavailable)
            unknown.Add("respondingUnavailable");
    }

    private static bool IsSemiStall(ProcessPerformanceEvidence row) =>
        row.CpuTimeBaselineSeconds.Availability == MetricAvailability.Observed
        && row.CpuTimeAdvanced.Availability == MetricAvailability.Observed
        && row.CpuTimeAdvanced.Value == false
        && row.CpuDeltaSeconds.Availability == MetricAvailability.Observed
        && row.CpuDeltaSeconds.Value == 0
        && row.Responding.Availability == MetricAvailability.Observed
        && row.Responding.Value == false;

    private static PerformanceOverallState ResolveState(PerformanceCause primary, bool windowUsable, bool cpuEvidence)
    {
        if (primary == PerformanceCause.MIXED || primary == PerformanceCause.UNKNOWN)
            return PerformanceOverallState.UNKNOWN;
        if (primary is PerformanceCause.PROCESS_SEMI_STALL or PerformanceCause.CPU_CONTENTION)
            return PerformanceOverallState.CRITICAL;
        if (!windowUsable || !cpuEvidence)
            return PerformanceOverallState.UNKNOWN;
        return PerformanceOverallState.NORMAL;
    }

    private static PerformanceConfidence ConfidenceFor(PerformanceOverallState state, PerformanceCause primary)
    {
        if (state == PerformanceOverallState.UNKNOWN || primary == PerformanceCause.UNKNOWN)
            return PerformanceConfidence.NONE;
        if (primary == PerformanceCause.PROCESS_SEMI_STALL)
            return PerformanceConfidence.HIGH;
        return PerformanceConfidence.LIMITED;
    }

    private static PerformanceAutomationEligibility Eligibility(PerformanceCause primary, bool cpuAttention)
    {
        if (cpuAttention)
            return PerformanceAutomationEligibility.HITL_REQUIRED;
        if (primary is PerformanceCause.PROCESS_SEMI_STALL
            or PerformanceCause.MEMORY_PRESSURE
            or PerformanceCause.PAGING_PRESSURE
            or PerformanceCause.IO_PRESSURE
            or PerformanceCause.GPU_PRESSURE
            or PerformanceCause.MIXED)
            return PerformanceAutomationEligibility.HITL_REQUIRED;
        return PerformanceAutomationEligibility.NO_ACTION;
    }
}
