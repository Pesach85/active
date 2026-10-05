namespace SystemOptimizerHub.Core.Performance;

public static class PerformanceEvidenceBuilder
{
    public static PerformanceSnapshot Build(
        PerformanceRawSample baseline,
        PerformanceRawSample current,
        int maxProcesses) =>
        Build([baseline, current], maxProcesses);

    public static PerformanceSnapshot Build(
        IReadOnlyList<PerformanceRawSample> samples,
        int maxProcesses)
    {
        ArgumentNullException.ThrowIfNull(samples);
        if (samples.Count < 1)
            throw new ArgumentException("At least one captured sample is required.", nameof(samples));
        foreach (var sample in samples)
            ArgumentNullException.ThrowIfNull(sample);
        if (maxProcesses < 1 || maxProcesses > PerformanceEvidenceLimits.HardMaxProcesses)
            throw new ArgumentOutOfRangeException(nameof(maxProcesses));

        var baseline = samples[0];
        var current = samples[^1];
        var duration = Duration(baseline.TimestampUtc, current.TimestampUtc);
        var processors = Processors(current.LogicalProcessors, baseline.LogicalProcessors);
        var retained = samples.Select(sample => SelectBounded(sample.Processes, maxProcesses)).ToArray();
        var keySets = retained.Select(rows => Index(rows)).ToArray();
        var baselineByKey = keySets[0];
        var currentByKey = keySets[^1];
        var drift = IdentityDrift(retained);
        var absent = baselineByKey.Keys.Except(currentByKey.Keys, StringComparer.Ordinal).OrderBy(k => k, StringComparer.Ordinal).ToArray();
        var appeared = currentByKey.Keys.Except(baselineByKey.Keys, StringComparer.Ordinal).OrderBy(k => k, StringComparer.Ordinal).ToArray();
        var intermediateGaps = currentByKey.Keys
            .Where(key => keySets.Any(set => !set.ContainsKey(key)))
            .OrderBy(key => key, StringComparer.Ordinal)
            .ToArray();

        var rows = new List<ProcessPerformanceEvidence>();
        foreach (var key in currentByKey.Keys.OrderBy(k => k, StringComparer.Ordinal))
        {
            currentByKey.TryGetValue(key, out var now);
            baselineByKey.TryGetValue(key, out var before);
            rows.Add(BuildProcess(
                before,
                now!,
                duration,
                processors,
                baseline.ProcessPriorityReader,
                current.ProcessPriorityReader));
        }

        var enumeration = CombineEnumeration(samples.Select(sample => sample.ProcessEnumeration));
        var progress = new ProgressEvidence
        {
            ElapsedSeconds = duration,
            PairedIdentityCount = rows.Count(r => r.CpuTimeBaselineSeconds.Availability == MetricAvailability.Observed),
            CpuTimeAdvancedCount = rows.Count(r => r.CpuTimeAdvanced.Availability == MetricAvailability.Observed && r.CpuTimeAdvanced.Value == true),
            CpuTimeNotAdvancedCount = rows.Count(r => r.CpuTimeAdvanced.Availability == MetricAvailability.Observed && r.CpuTimeAdvanced.Value == false),
            RespondingObservedCount = rows.Count(r => r.Responding.Availability == MetricAvailability.Observed),
            RespondingUnavailableCount = rows.Count(r => r.Responding.Availability == MetricAvailability.Unavailable),
            IdentityDriftCount = drift.Count,
            AbsentFromCurrentSampleCount = absent.Length
        };

        var ram = RamEvidenceFactory.From(current.Ram);
        var cpu = new CpuEvidence
        {
            LogicalProcessors = processors,
            SystemUtilizationPercent = SystemUtilization(baseline.SystemCpu, current.SystemCpu, duration, processors)
        };
        var io = new IoEvidence();
        var gpu = new GpuEvidence();
        return new PerformanceSnapshot
        {
            BaselineTimestampUtc = baseline.TimestampUtc,
            TimestampUtc = current.TimestampUtc,
            SampleCount = samples.Count,
            PositiveIntervalCount = CountPositiveIntervals(samples),
            SampleDurationSeconds = duration,
            Window = duration.Availability == MetricAvailability.Observed
                ? MetricAvailability.Observed
                : MetricAvailability.Unknown,
            Ram = ram,
            Cpu = cpu,
            Io = io,
            Gpu = gpu,
            ProcessEnumeration = enumeration,
            ProcessPriorityReader = CombinePriorityReader(samples.Select(sample => sample.ProcessPriorityReader)),
            ProcessTopConsumers = rows,
            AbsentFromCurrentSample = absent,
            AbsentFromIntermediateSample = intermediateGaps,
            AppearedInCurrentSample = appeared,
            IdentityDrift = drift,
            Progress = progress,
            EvidenceQuality = EvidenceQualityCounter.Count(
                duration,
                ram,
                cpu,
                io,
                gpu,
                enumeration,
                CombinePriorityReader(samples.Select(sample => sample.ProcessPriorityReader)),
                rows),
            MaxProcesses = maxProcesses,
            BaselineIdentityUnreadableSkipped = baseline.IdentityUnreadableSkipped,
            CurrentIdentityUnreadableSkipped = current.IdentityUnreadableSkipped
        };
    }

    public static IReadOnlyList<ProcessRawObservation> SelectBounded(
        IReadOnlyList<ProcessRawObservation> processes,
        int maxProcesses)
    {
        var identified = processes.Where(p => p.StartTimeUtcTicks is > 0).ToList();
        identified.Sort(CompareRetention);
        if (identified.Count > maxProcesses)
            identified.RemoveRange(maxProcesses, identified.Count - maxProcesses);
        return identified;
    }

    private static int CompareRetention(ProcessRawObservation x, ProcessRawObservation y)
    {
        var byWorkingSet = (y.WorkingSetBytes ?? long.MinValue).CompareTo(x.WorkingSetBytes ?? long.MinValue);
        if (byWorkingSet != 0)
            return byWorkingSet;
        return x.Pid.CompareTo(y.Pid);
    }

    private static Dictionary<string, ProcessRawObservation> Index(IReadOnlyList<ProcessRawObservation> rows)
    {
        var map = new Dictionary<string, ProcessRawObservation>(StringComparer.Ordinal);
        foreach (var row in rows)
        {
            if (row.StartTimeUtcTicks is not > 0)
                continue;
            map[PerformanceIdentity.Key(row.Pid, row.StartTimeUtcTicks.Value)] = row;
        }

        return map;
    }

    private static ProcessPerformanceEvidence BuildProcess(
        ProcessRawObservation? before,
        ProcessRawObservation now,
        PerformanceMetric<double> duration,
        PerformanceMetric<int> processors,
        MetricAvailability baselinePriorityReader,
        MetricAvailability currentPriorityReader)
    {
        var start = now.StartTimeUtcTicks!.Value;
        var baselineCpu = MetricDouble(before?.CpuTimeSeconds);
        var currentCpu = MetricDouble(now.CpuTimeSeconds);
        var delta = Delta(baselineCpu, currentCpu);
        var advanced = Advanced(delta);
        var utilization = Utilization(delta, duration, processors);
        var priorityBaseline = PriorityMetric(before, baselinePriorityReader);
        var priorityCurrent = PriorityMetric(now, currentPriorityReader);
        var pathState = now.ImagePath is null ? MetricAvailability.Unavailable : MetricAvailability.Observed;
        var pathMatches = before is null
            || string.IsNullOrEmpty(before.ImagePath)
            || string.IsNullOrEmpty(now.ImagePath)
            || string.Equals(before.ImagePath, now.ImagePath, StringComparison.OrdinalIgnoreCase);

        return new ProcessPerformanceEvidence
        {
            IdentityKey = PerformanceIdentity.Key(now.Pid, start),
            Pid = now.Pid,
            StartTimeUtcTicks = start,
            ProcessName = now.ProcessName,
            ImagePathState = pathState,
            ImagePath = pathState == MetricAvailability.Observed ? now.ImagePath : null,
            IdentityPathMatches = pathMatches,
            CpuTimeBaselineSeconds = baselineCpu,
            CpuTimeCurrentSeconds = currentCpu,
            CpuDeltaSeconds = delta,
            CpuUtilizationPercent = utilization,
            CpuTimeAdvanced = advanced,
            WorkingSetBytesBaseline = MetricLong(before?.WorkingSetBytes),
            WorkingSetBytes = MetricLong(now.WorkingSetBytes),
            PrivateBytes = MetricLong(now.PrivateBytes),
            Responding = now.Responding is null
                ? PerformanceMetric<bool>.Unavailable()
                : PerformanceMetric<bool>.Observed(now.Responding.Value),
            PriorityBaseline = priorityBaseline,
            PriorityCurrent = priorityCurrent,
            PriorityPairComplete = PriorityPair(priorityBaseline, priorityCurrent)
        };
    }

    private static PerformanceMetric<ObservedProcessPriority> PriorityMetric(
        ProcessRawObservation? row,
        MetricAvailability reader)
    {
        if (reader == MetricAvailability.NotSupported)
            return PerformanceMetric<ObservedProcessPriority>.NotSupported();
        if (row is null)
            return PerformanceMetric<ObservedProcessPriority>.Unavailable();

        return row.Priority switch
        {
            MetricAvailability.Observed when row.PriorityValue is { } value =>
                PerformanceMetric<ObservedProcessPriority>.Observed(value),
            MetricAvailability.Observed => PerformanceMetric<ObservedProcessPriority>.Unknown(),
            MetricAvailability.NotSupported => PerformanceMetric<ObservedProcessPriority>.NotSupported(),
            MetricAvailability.Unknown => PerformanceMetric<ObservedProcessPriority>.Unknown(),
            _ => PerformanceMetric<ObservedProcessPriority>.Unavailable()
        };
    }

    private static PerformanceMetric<bool> PriorityPair(
        PerformanceMetric<ObservedProcessPriority> baseline,
        PerformanceMetric<ObservedProcessPriority> current)
    {
        if (baseline.Availability == MetricAvailability.NotSupported
            && current.Availability == MetricAvailability.NotSupported)
            return PerformanceMetric<bool>.NotSupported();
        if (baseline.Availability == MetricAvailability.Observed
            && current.Availability == MetricAvailability.Observed)
            return PerformanceMetric<bool>.Observed(true);
        if (baseline.Availability == MetricAvailability.Unavailable
            && current.Availability == MetricAvailability.Unavailable)
            return PerformanceMetric<bool>.Unavailable();
        return PerformanceMetric<bool>.Unknown();
    }

    private static MetricAvailability CombinePriorityReader(IEnumerable<MetricAvailability> states)
    {
        MetricAvailability? combined = null;
        foreach (var state in states)
        {
            if (combined is null)
                combined = state;
            else if (combined != state)
                return MetricAvailability.Unknown;
        }

        return combined ?? MetricAvailability.Unknown;
    }

    private static int CountPositiveIntervals(IReadOnlyList<PerformanceRawSample> samples)
    {
        var positive = 0;
        for (var index = 1; index < samples.Count; index++)
        {
            var step = Duration(samples[index - 1].TimestampUtc, samples[index].TimestampUtc);
            if (step.Availability == MetricAvailability.Observed && step.Value is > 0)
                positive++;
        }

        return positive;
    }

    private static List<ProcessIdentityDrift> IdentityDrift(IReadOnlyList<IReadOnlyList<ProcessRawObservation>> retained)
    {
        var latestTicks = new Dictionary<int, long>();
        var latestPath = new Dictionary<int, string?>();
        var drift = new List<ProcessIdentityDrift>();
        for (var index = 0; index < retained.Count; index++)
        {
            foreach (var row in retained[index].OrderBy(item => item.Pid))
            {
                if (row.StartTimeUtcTicks is not > 0)
                    continue;
                var ticks = row.StartTimeUtcTicks.Value;
                if (latestTicks.TryGetValue(row.Pid, out var previous) && previous != ticks)
                {
                    drift.Add(new ProcessIdentityDrift
                    {
                        Pid = row.Pid,
                        BaselineStartTimeUtcTicks = previous,
                        CurrentStartTimeUtcTicks = ticks,
                        ReplacementSampleIndex = index + 1,
                        BaselineImagePath = latestPath[row.Pid],
                        CurrentImagePath = row.ImagePath
                    });
                }

                latestTicks[row.Pid] = ticks;
                latestPath[row.Pid] = row.ImagePath;
            }
        }

        return drift;
    }

    private static PerformanceMetric<double> MetricDouble(double? value) =>
        value is null ? PerformanceMetric<double>.Unavailable() : PerformanceMetric<double>.Observed(value.Value);

    private static PerformanceMetric<long> MetricLong(long? value) =>
        value is null ? PerformanceMetric<long>.Unavailable() : PerformanceMetric<long>.Observed(value.Value);

    private static PerformanceMetric<double> Delta(
        PerformanceMetric<double> baseline,
        PerformanceMetric<double> current)
    {
        if (baseline.Availability != MetricAvailability.Observed || current.Availability != MetricAvailability.Observed)
            return PerformanceMetric<double>.Unavailable();
        var delta = current.Value!.Value - baseline.Value!.Value;
        if (delta < 0)
            return PerformanceMetric<double>.Unknown();
        return PerformanceMetric<double>.Observed(delta);
    }

    private static PerformanceMetric<bool> Advanced(PerformanceMetric<double> delta)
    {
        if (delta.Availability != MetricAvailability.Observed || delta.Value is null)
            return delta.Availability == MetricAvailability.Unknown
                ? PerformanceMetric<bool>.Unknown()
                : PerformanceMetric<bool>.Unavailable();
        return PerformanceMetric<bool>.Observed(delta.Value.Value > 0);
    }

    private static PerformanceMetric<double> Utilization(
        PerformanceMetric<double> delta,
        PerformanceMetric<double> duration,
        PerformanceMetric<int> processors)
    {
        if (delta.Availability != MetricAvailability.Observed
            || duration.Availability != MetricAvailability.Observed
            || processors.Availability != MetricAvailability.Observed
            || duration.Value is not > 0
            || processors.Value is not > 0)
            return PerformanceMetric<double>.Unknown();

        var percent = delta.Value!.Value / duration.Value.Value / processors.Value.Value * 100.0;
        return PerformanceMetric<double>.Observed(percent);
    }

    private static PerformanceMetric<double> Duration(DateTimeOffset baseline, DateTimeOffset current)
    {
        if (current <= baseline)
            return PerformanceMetric<double>.Unknown();
        return PerformanceMetric<double>.Observed((current - baseline).TotalSeconds);
    }

    private static PerformanceMetric<int> Processors(int? current, int? baseline)
    {
        var value = current is > 0 ? current : baseline;
        if (value is not > 0)
            return PerformanceMetric<int>.Unknown();
        return PerformanceMetric<int>.Observed(value.Value);
    }

    private static PerformanceMetric<double> SystemUtilization(
        SystemCpuRaw baseline,
        SystemCpuRaw current,
        PerformanceMetric<double> duration,
        PerformanceMetric<int> processors)
    {
        if (baseline.Availability == MetricAvailability.NotSupported || current.Availability == MetricAvailability.NotSupported)
            return PerformanceMetric<double>.NotSupported();
        if (baseline.Availability != MetricAvailability.Observed || current.Availability != MetricAvailability.Observed)
            return PerformanceMetric<double>.Unavailable();
        if (duration.Availability != MetricAvailability.Observed
            || processors.Availability != MetricAvailability.Observed
            || duration.Value is not > 0
            || processors.Value is not > 0)
            return PerformanceMetric<double>.Unknown();

        var busy = Busy(current) - Busy(baseline);
        if (busy < 0)
            return PerformanceMetric<double>.Unknown();
        var seconds = busy / 10_000_000.0;
        return PerformanceMetric<double>.Observed(seconds / duration.Value.Value / processors.Value.Value * 100.0);
    }

    private static long Busy(SystemCpuRaw sample) =>
        (sample.Kernel100Ns - sample.Idle100Ns) + sample.User100Ns;

    private static MetricAvailability CombineEnumeration(IEnumerable<MetricAvailability> states)
    {
        var sawSample = false;
        var unavailable = false;
        foreach (var state in states)
        {
            sawSample = true;
            if (state == MetricAvailability.NotSupported)
                return MetricAvailability.NotSupported;
            if (state == MetricAvailability.Unavailable)
                unavailable = true;
        }

        if (!sawSample)
            return MetricAvailability.Unknown;
        return unavailable ? MetricAvailability.Unavailable : MetricAvailability.Observed;
    }
}

public static class RamEvidenceFactory
{
    public static RamEvidence From(RamSample? sample)
    {
        sample ??= RamSample.Unread();
        var physical = Physical(sample);
        var commit = Commit(sample);
        var pagefile = Pagefile(sample);
        return new RamEvidence
        {
            TotalBytes = physical.Total,
            AvailableBytes = physical.Available,
            UsedBytes = physical.Used,
            CommitLimitBytes = commit.Limit,
            CommitAvailableBytes = commit.Available,
            CommitUsedBytes = commit.Used,
            PagefileTotalBytes = pagefile.Total,
            PagefileAvailableBytes = pagefile.Available
        };
    }

    private static (PerformanceMetric<long> Total, PerformanceMetric<long> Available, PerformanceMetric<long> Used) Physical(RamSample sample)
    {
        if (!sample.PhysicalObserved)
            return (PerformanceMetric<long>.Unavailable(), PerformanceMetric<long>.Unavailable(), PerformanceMetric<long>.Unavailable());
        if (sample.TotalBytes < 0 || sample.AvailableBytes < 0 || sample.AvailableBytes > sample.TotalBytes)
            return (PerformanceMetric<long>.Unknown(), PerformanceMetric<long>.Unknown(), PerformanceMetric<long>.Unknown());
        return (
            PerformanceMetric<long>.Observed(sample.TotalBytes),
            PerformanceMetric<long>.Observed(sample.AvailableBytes),
            PerformanceMetric<long>.Observed(sample.TotalBytes - sample.AvailableBytes));
    }

    private static (PerformanceMetric<long> Limit, PerformanceMetric<long> Available, PerformanceMetric<long> Used) Commit(RamSample sample)
    {
        if (!sample.CommitObserved)
            return (PerformanceMetric<long>.Unavailable(), PerformanceMetric<long>.Unavailable(), PerformanceMetric<long>.Unavailable());
        if (sample.CommitLimitBytes < 0 || sample.CommitAvailableBytes < 0 || sample.CommitAvailableBytes > sample.CommitLimitBytes)
            return (PerformanceMetric<long>.Unknown(), PerformanceMetric<long>.Unknown(), PerformanceMetric<long>.Unknown());
        return (
            PerformanceMetric<long>.Observed(sample.CommitLimitBytes),
            PerformanceMetric<long>.Observed(sample.CommitAvailableBytes),
            PerformanceMetric<long>.Observed(sample.CommitLimitBytes - sample.CommitAvailableBytes));
    }

    private static (PerformanceMetric<long> Total, PerformanceMetric<long> Available) Pagefile(RamSample sample)
    {
        if (sample.Pagefile == MetricAvailability.NotSupported)
            return (PerformanceMetric<long>.NotSupported(), PerformanceMetric<long>.NotSupported());
        if (sample.Pagefile == MetricAvailability.Unavailable)
            return (PerformanceMetric<long>.Unavailable(), PerformanceMetric<long>.Unavailable());
        if (sample.Pagefile != MetricAvailability.Observed
            || sample.PagefileTotalBytes < 0
            || sample.PagefileAvailableBytes < 0
            || sample.PagefileAvailableBytes > sample.PagefileTotalBytes)
            return (PerformanceMetric<long>.Unknown(), PerformanceMetric<long>.Unknown());
        return (
            PerformanceMetric<long>.Observed(sample.PagefileTotalBytes),
            PerformanceMetric<long>.Observed(sample.PagefileAvailableBytes));
    }
}

static class EvidenceQualityCounter
{
    public static EvidenceQuality Count(
        PerformanceMetric<double> duration,
        RamEvidence ram,
        CpuEvidence cpu,
        IoEvidence io,
        GpuEvidence gpu,
        MetricAvailability processEnumeration,
        MetricAvailability processPriorityReader,
        IReadOnlyList<ProcessPerformanceEvidence> processes)
    {
        var counts = new int[4];
        void Add<T>(PerformanceMetric<T> metric) where T : struct => counts[(int)metric.Availability]++;
        void AddState(MetricAvailability availability) => counts[(int)availability]++;

        Add(duration);
        Add(ram.TotalBytes);
        Add(ram.AvailableBytes);
        Add(ram.UsedBytes);
        Add(ram.CommitLimitBytes);
        Add(ram.CommitAvailableBytes);
        Add(ram.CommitUsedBytes);
        Add(ram.PagefileTotalBytes);
        Add(ram.PagefileAvailableBytes);
        Add(cpu.LogicalProcessors);
        Add(cpu.SystemUtilizationPercent);
        AddState(io.DiskLatency);
        AddState(io.QueueDepth);
        AddState(io.ProcessIoBytes);
        AddState(gpu.Utilization);
        AddState(gpu.Memory);
        AddState(gpu.Engine);
        AddState(gpu.Thermal);
        AddState(processEnumeration);
        AddState(processPriorityReader);
        foreach (var row in processes)
        {
            AddState(row.ImagePathState);
            Add(row.CpuTimeBaselineSeconds);
            Add(row.CpuTimeCurrentSeconds);
            Add(row.CpuDeltaSeconds);
            Add(row.CpuUtilizationPercent);
            Add(row.CpuTimeAdvanced);
            Add(row.WorkingSetBytesBaseline);
            Add(row.WorkingSetBytes);
            Add(row.PrivateBytes);
            Add(row.Responding);
            Add(row.PriorityBaseline);
            Add(row.PriorityCurrent);
            Add(row.PriorityPairComplete);
        }

        return new EvidenceQuality
        {
            ObservedCount = counts[(int)MetricAvailability.Observed],
            UnavailableCount = counts[(int)MetricAvailability.Unavailable],
            NotSupportedCount = counts[(int)MetricAvailability.NotSupported],
            UnknownCount = counts[(int)MetricAvailability.Unknown]
        };
    }
}
