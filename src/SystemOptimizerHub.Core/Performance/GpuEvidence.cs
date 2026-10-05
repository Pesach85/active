namespace SystemOptimizerHub.Core.Performance;

/// <summary>
/// Read-only NVML observations. Gauges are not pressure and are not a diagnosis.
/// The driver timestamp is a raw NVML counter, not a <see cref="DateTimeOffset"/>.
/// </summary>
public sealed class GpuEvidence
{
    public MetricAvailability Reader { get; init; } = MetricAvailability.NotSupported;

    public MetricAvailability Utilization { get; init; } = MetricAvailability.NotSupported;

    public MetricAvailability Memory { get; init; } = MetricAvailability.NotSupported;

    public MetricAvailability Engine { get; init; } = MetricAvailability.NotSupported;

    public MetricAvailability Thermal { get; init; } = MetricAvailability.NotSupported;

    /// <summary>Set only when device memory was read from NVML. The external query tool is not a runtime source.</summary>
    public string? MemorySource { get; init; }

    public IReadOnlyList<GpuDeviceEvidence> Devices { get; init; } = [];

    public IReadOnlyList<GpuProcessEvidence> Processes { get; init; } = [];

    public IReadOnlyList<GpuDeviceIdentityDrift> DeviceIdentityDrift { get; init; } = [];

    public IReadOnlyList<GpuProcessIdentityDrift> ProcessIdentityDrift { get; init; } = [];

    public IReadOnlyList<string> ProcessAbsentFromCurrentSample { get; init; } = [];

    public IReadOnlyList<string> ProcessAbsentFromIntermediateSample { get; init; } = [];

    public IReadOnlyList<string> ProcessAppearedInCurrentSample { get; init; } = [];
}

public sealed class GpuDeviceEvidence
{
    public int Index { get; init; }

    public bool IdentityStable { get; init; }

    public MetricAvailability Identity { get; init; } = MetricAvailability.NotSupported;

    public string? Name { get; init; }

    public string? Uuid { get; init; }

    public MetricAvailability Pci { get; init; } = MetricAvailability.NotSupported;

    public string? PciBusId { get; init; }

    public PerformanceMetric<int> UtilizationPercent { get; init; } = PerformanceMetric<int>.NotSupported();

    public PerformanceMetric<long> MemoryTotalBytes { get; init; } = PerformanceMetric<long>.NotSupported();

    public PerformanceMetric<long> MemoryUsedBytes { get; init; } = PerformanceMetric<long>.NotSupported();

    public PerformanceMetric<int> TemperatureCelsius { get; init; } = PerformanceMetric<int>.NotSupported();

    public PerformanceMetric<int> PowerDrawMilliwatts { get; init; } = PerformanceMetric<int>.NotSupported();

    public PerformanceMetric<int> PerformanceState { get; init; } = PerformanceMetric<int>.NotSupported();

    public PerformanceMetric<int> EncoderUtilizationPercent { get; init; } = PerformanceMetric<int>.NotSupported();

    public PerformanceMetric<int> DecoderUtilizationPercent { get; init; } = PerformanceMetric<int>.NotSupported();

    public PerformanceMetric<long> EncoderSamplingPeriodMicroseconds { get; init; } = PerformanceMetric<long>.NotSupported();

    public PerformanceMetric<long> DecoderSamplingPeriodMicroseconds { get; init; } = PerformanceMetric<long>.NotSupported();

    public PerformanceMetric<int> JpegUtilizationPercent { get; init; } = PerformanceMetric<int>.NotSupported();

    public MetricAvailability ProcessUtilizationQuery { get; init; } = MetricAvailability.NotSupported;

    public MetricAvailability ProcessMemoryQuery { get; init; } = MetricAvailability.NotSupported;

    public bool AbsentFromIntermediateSample { get; init; }
}

public sealed class GpuProcessEvidence
{
    public int Pid { get; init; }

    public string? IdentityKey { get; init; }

    public long StartTimeUtcTicks { get; init; }

    public int GpuIndex { get; init; }

    public string? GpuUuid { get; init; }

    public MetricAvailability Identity { get; init; } = MetricAvailability.NotSupported;

    /// <summary>Last raw NVML sample timestamp. Not converted to wall-clock time.</summary>
    public ulong? DriverTimestamp { get; init; }

    public DateTimeOffset CollectorTimestampUtc { get; init; }

    public PerformanceMetric<bool> DriverTimestampAdvanced { get; init; } = PerformanceMetric<bool>.NotSupported();

    public PerformanceMetric<int> SmUtilizationPercent { get; init; } = PerformanceMetric<int>.NotSupported();

    public PerformanceMetric<int> MemoryUtilizationPercent { get; init; } = PerformanceMetric<int>.NotSupported();

    public PerformanceMetric<int> EncoderUtilizationPercent { get; init; } = PerformanceMetric<int>.NotSupported();

    public PerformanceMetric<int> DecoderUtilizationPercent { get; init; } = PerformanceMetric<int>.NotSupported();

    public PerformanceMetric<long> ProcessMemoryBytes { get; init; } = PerformanceMetric<long>.NotSupported();

    public bool AbsentFromIntermediateSample { get; init; }
}

public sealed class GpuDeviceIdentityDrift
{
    public int Index { get; init; }

    public string? BaselineUuid { get; init; }

    public string? CurrentUuid { get; init; }

    public int ReplacementSampleIndex { get; init; }
}

public sealed class GpuProcessIdentityDrift
{
    public int Pid { get; init; }

    public string? GpuUuid { get; init; }

    public long BaselineStartTimeUtcTicks { get; init; }

    public long CurrentStartTimeUtcTicks { get; init; }

    public int ReplacementSampleIndex { get; init; }
}

public readonly record struct GpuIdentityLookup(MetricAvailability Availability, long? StartTimeUtcTicks)
{
    public static GpuIdentityLookup Observed(long startTimeUtcTicks) =>
        new(MetricAvailability.Observed, startTimeUtcTicks);

    public static GpuIdentityLookup Unavailable() => new(MetricAvailability.Unavailable, null);

    public static GpuIdentityLookup Unknown() => new(MetricAvailability.Unknown, null);
}

public interface IGpuRawReader : IDisposable
{
    GpuRawSample Read(CancellationToken cancellationToken, Func<int, GpuIdentityLookup> lookup);
}

public sealed class GpuRawSample
{
    public MetricAvailability Reader { get; init; } = MetricAvailability.NotSupported;

    public string? DriverVersion { get; init; }

    public string? NvmlVersion { get; init; }

    public IReadOnlyList<GpuDeviceRaw> Devices { get; init; } = [];

    public static GpuRawSample NotSupported() => new();

    public static GpuRawSample Unavailable() => new() { Reader = MetricAvailability.Unavailable };

    public static GpuRawSample Unknown() => new() { Reader = MetricAvailability.Unknown };
}

public sealed class GpuDeviceRaw
{
    public int Index { get; init; }

    public MetricAvailability Identity { get; init; } = MetricAvailability.Unknown;

    public string? Name { get; init; }

    public string? Uuid { get; init; }

    public MetricAvailability Pci { get; init; } = MetricAvailability.NotSupported;

    public string? PciBusId { get; init; }

    public PerformanceMetric<int> UtilizationPercent { get; init; } = PerformanceMetric<int>.NotSupported();

    public PerformanceMetric<long> MemoryTotalBytes { get; init; } = PerformanceMetric<long>.NotSupported();

    public PerformanceMetric<long> MemoryUsedBytes { get; init; } = PerformanceMetric<long>.NotSupported();

    public PerformanceMetric<int> TemperatureCelsius { get; init; } = PerformanceMetric<int>.NotSupported();

    public PerformanceMetric<int> PowerDrawMilliwatts { get; init; } = PerformanceMetric<int>.NotSupported();

    public PerformanceMetric<int> PerformanceState { get; init; } = PerformanceMetric<int>.NotSupported();

    public PerformanceMetric<int> EncoderUtilizationPercent { get; init; } = PerformanceMetric<int>.NotSupported();

    public PerformanceMetric<int> DecoderUtilizationPercent { get; init; } = PerformanceMetric<int>.NotSupported();

    public PerformanceMetric<long> EncoderSamplingPeriodMicroseconds { get; init; } = PerformanceMetric<long>.NotSupported();

    public PerformanceMetric<long> DecoderSamplingPeriodMicroseconds { get; init; } = PerformanceMetric<long>.NotSupported();

    public MetricAvailability ProcessUtilizationQuery { get; init; } = MetricAvailability.NotSupported;

    public MetricAvailability ProcessMemoryQuery { get; init; } = MetricAvailability.NotSupported;

    public IReadOnlyList<GpuProcessRaw> Processes { get; init; } = [];
}

public sealed class GpuProcessRaw
{
    public int Pid { get; init; }

    public MetricAvailability Identity { get; init; } = MetricAvailability.Unavailable;

    public long? StartTimeUtcTicks { get; init; }

    public ulong? DriverTimestamp { get; init; }

    public MetricAvailability DriverTimestampState { get; init; } = MetricAvailability.NotSupported;

    public PerformanceMetric<int> SmUtilizationPercent { get; init; } = PerformanceMetric<int>.NotSupported();

    public PerformanceMetric<int> MemoryUtilizationPercent { get; init; } = PerformanceMetric<int>.NotSupported();

    public PerformanceMetric<int> EncoderUtilizationPercent { get; init; } = PerformanceMetric<int>.NotSupported();

    public PerformanceMetric<int> DecoderUtilizationPercent { get; init; } = PerformanceMetric<int>.NotSupported();

    public PerformanceMetric<long> ProcessMemoryBytes { get; init; } = PerformanceMetric<long>.NotSupported();

    public static GpuProcessRaw Join(
        int pid,
        GpuIdentityLookup identity,
        ulong? driverTimestamp,
        MetricAvailability driverTimestampState,
        PerformanceMetric<int> smUtilizationPercent,
        PerformanceMetric<int> memoryUtilizationPercent,
        PerformanceMetric<int> encoderUtilizationPercent,
        PerformanceMetric<int> decoderUtilizationPercent,
        PerformanceMetric<long> processMemoryBytes)
    {
        if (identity.Availability != MetricAvailability.Observed || identity.StartTimeUtcTicks is not > 0)
        {
            var state = identity.Availability == MetricAvailability.Unknown
                ? MetricAvailability.Unknown
                : MetricAvailability.Unavailable;
            return new GpuProcessRaw
            {
                Pid = pid,
                Identity = state,
                DriverTimestampState = state,
                SmUtilizationPercent = WithoutValue(smUtilizationPercent, state),
                MemoryUtilizationPercent = WithoutValue(memoryUtilizationPercent, state),
                EncoderUtilizationPercent = WithoutValue(encoderUtilizationPercent, state),
                DecoderUtilizationPercent = WithoutValue(decoderUtilizationPercent, state),
                ProcessMemoryBytes = processMemoryBytes.Availability == MetricAvailability.Observed
                    ? WithoutValue(processMemoryBytes, state)
                    : processMemoryBytes
            };
        }

        return new GpuProcessRaw
        {
            Pid = pid,
            Identity = MetricAvailability.Observed,
            StartTimeUtcTicks = identity.StartTimeUtcTicks,
            DriverTimestamp = driverTimestampState == MetricAvailability.Observed ? driverTimestamp : null,
            DriverTimestampState = driverTimestampState,
            SmUtilizationPercent = smUtilizationPercent,
            MemoryUtilizationPercent = memoryUtilizationPercent,
            EncoderUtilizationPercent = encoderUtilizationPercent,
            DecoderUtilizationPercent = decoderUtilizationPercent,
            ProcessMemoryBytes = processMemoryBytes
        };
    }

    private static PerformanceMetric<T> WithoutValue<T>(PerformanceMetric<T> source, MetricAvailability state) where T : struct
    {
        _ = source;
        return state switch
        {
            MetricAvailability.Unknown => PerformanceMetric<T>.Unknown(),
            MetricAvailability.NotSupported => PerformanceMetric<T>.NotSupported(),
            _ => PerformanceMetric<T>.Unavailable()
        };
    }
}

public static class NvmlReturn
{
    public const int Success = 0;
    public const int Uninitialized = 1;
    public const int InvalidArgument = 2;
    public const int NotSupported = 3;
    public const int NoPermission = 4;
    public const int AlreadyInitialized = 5;
    public const int NotFound = 6;
    public const int InsufficientSize = 7;
    public const int DriverNotLoaded = 9;
    public const int LibraryNotFound = 12;
    public const int GpuIsLost = 15;
    public const int VersionMismatch = 18;
    public const int Unknown = 999;

    public const ulong ProcessMemoryNotAvailable = ulong.MaxValue;

    public const int UnknownPerformanceState = 32;

    public static MetricAvailability Map(int code) => code switch
    {
        Success or AlreadyInitialized => MetricAvailability.Observed,
        NotSupported or LibraryNotFound => MetricAvailability.NotSupported,
        Uninitialized or NoPermission or NotFound or DriverNotLoaded or GpuIsLost => MetricAvailability.Unavailable,
        _ => MetricAvailability.Unknown
    };

    public static MetricAvailability Session(bool libraryLoaded, bool entryPointsPresent, int initCode)
    {
        if (!libraryLoaded)
            return MetricAvailability.NotSupported;
        if (!entryPointsPresent)
            return MetricAvailability.Unknown;
        if (initCode == Success || initCode == AlreadyInitialized)
            return MetricAvailability.Observed;
        return Map(initCode);
    }

    public static PerformanceMetric<int> Percent(int code, uint value)
    {
        var availability = Map(code);
        if (availability != MetricAvailability.Observed)
            return Blank<int>(availability);
        if (value > 100)
            return PerformanceMetric<int>.Unknown();
        return PerformanceMetric<int>.Observed((int)value);
    }

    public static PerformanceMetric<int> TemperatureCelsius(int code, uint value)
    {
        var availability = Map(code);
        if (availability != MetricAvailability.Observed)
            return Blank<int>(availability);
        if (value > 250)
            return PerformanceMetric<int>.Unknown();
        return PerformanceMetric<int>.Observed((int)value);
    }

    public static PerformanceMetric<int> PowerMilliwatts(int code, uint value)
    {
        var availability = Map(code);
        if (availability != MetricAvailability.Observed)
            return Blank<int>(availability);
        return PerformanceMetric<int>.Observed((int)value);
    }

    public static PerformanceMetric<int> PerformanceState(int code, int value)
    {
        var availability = Map(code);
        if (availability != MetricAvailability.Observed)
            return Blank<int>(availability);
        if (value == UnknownPerformanceState || value < 0 || value > 15)
            return PerformanceMetric<int>.Unknown();
        return PerformanceMetric<int>.Observed(value);
    }

    public static (PerformanceMetric<int> Utilization, PerformanceMetric<long> Period) Engine(int code, uint utilization, uint periodMicroseconds)
    {
        var availability = Map(code);
        if (availability != MetricAvailability.Observed)
            return (Blank<int>(availability), Blank<long>(availability));
        if (utilization > 100)
            return (PerformanceMetric<int>.Unknown(), PerformanceMetric<long>.Unknown());
        return (PerformanceMetric<int>.Observed((int)utilization), PerformanceMetric<long>.Observed(periodMicroseconds));
    }

    public static (PerformanceMetric<long> Total, PerformanceMetric<long> Used) Memory(int code, ulong total, ulong used)
    {
        var availability = Map(code);
        if (availability != MetricAvailability.Observed)
            return (Blank<long>(availability), Blank<long>(availability));
        if (total > long.MaxValue || used > long.MaxValue || used > total)
            return (PerformanceMetric<long>.Unknown(), PerformanceMetric<long>.Unknown());
        return (PerformanceMetric<long>.Observed((long)total), PerformanceMetric<long>.Observed((long)used));
    }

    public static PerformanceMetric<long> ProcessMemory(int code, ulong value)
    {
        if (code == NotSupported || (Map(code) == MetricAvailability.Observed && value == ProcessMemoryNotAvailable))
            return PerformanceMetric<long>.NotSupported();
        var availability = Map(code);
        if (availability != MetricAvailability.Observed)
            return Blank<long>(availability);
        if (value > long.MaxValue)
            return PerformanceMetric<long>.Unknown();
        return PerformanceMetric<long>.Observed((long)value);
    }

    private static PerformanceMetric<T> Blank<T>(MetricAvailability availability) where T : struct => availability switch
    {
        MetricAvailability.NotSupported => PerformanceMetric<T>.NotSupported(),
        MetricAvailability.Unavailable => PerformanceMetric<T>.Unavailable(),
        MetricAvailability.Observed => PerformanceMetric<T>.Unknown(),
        _ => PerformanceMetric<T>.Unknown()
    };
}

public static class NvmlBufferQuery
{
    public const int MaxCount = 4096;

    public readonly record struct FirstResult(MetricAvailability Availability, int Count, bool CallAgain);

    public static FirstResult First(int code, uint count)
    {
        if (code == NvmlReturn.Success && count == 0)
            return new FirstResult(MetricAvailability.Observed, 0, false);
        if (code == NvmlReturn.Success)
            return new FirstResult(MetricAvailability.Unknown, 0, false);
        if (code != NvmlReturn.InsufficientSize)
            return new FirstResult(NvmlReturn.Map(code), 0, false);
        if (count == 0 || count > MaxCount)
            return new FirstResult(MetricAvailability.Unknown, 0, false);
        return new FirstResult(MetricAvailability.Observed, (int)count, true);
    }

    public static MetricAvailability Second(int code, uint count, int allocated)
    {
        if (code != NvmlReturn.Success)
            return NvmlReturn.Map(code);
        if (count > allocated)
            return MetricAvailability.Unknown;
        return MetricAvailability.Observed;
    }
}

public static class GpuEvidenceFactory
{
    public const string NvmlMemorySource = "NVML";

    public static GpuEvidence Build(IReadOnlyList<PerformanceRawSample> samples)
    {
        ArgumentNullException.ThrowIfNull(samples);
        if (samples.Count == 0 || samples.All(sample => ReaderOf(sample) == MetricAvailability.NotSupported))
            return new GpuEvidence();

        var reader = CombineReader(samples);
        if (reader != MetricAvailability.Observed)
        {
            return new GpuEvidence
            {
                Reader = reader,
                Utilization = reader,
                Memory = reader,
                Engine = reader,
                Thermal = reader
            };
        }

        var devices = BuildDevices(samples, out var deviceDrift);
        var driftedDevices = deviceDrift.Select(item => item.Index).ToHashSet();
        var processes = BuildProcesses(samples, driftedDevices, out var processDrift, out var absent, out var intermediate, out var appeared);
        var memoryObserved = devices.Any(device =>
            device.IdentityStable
            && (device.MemoryTotalBytes.Availability == MetricAvailability.Observed
                || device.MemoryUsedBytes.Availability == MetricAvailability.Observed));
        return new GpuEvidence
        {
            Reader = MetricAvailability.Observed,
            MemorySource = memoryObserved ? NvmlMemorySource : null,
            Utilization = Summarize(devices, device => device.UtilizationPercent.Availability),
            Memory = Summarize(devices, device => Both(device.MemoryTotalBytes.Availability, device.MemoryUsedBytes.Availability)),
            Engine = Summarize(devices, device => EitherEngine(device.EncoderUtilizationPercent.Availability, device.DecoderUtilizationPercent.Availability)),
            Thermal = Summarize(devices, device => device.TemperatureCelsius.Availability),
            Devices = devices,
            Processes = processes,
            DeviceIdentityDrift = deviceDrift,
            ProcessIdentityDrift = processDrift,
            ProcessAbsentFromCurrentSample = absent,
            ProcessAbsentFromIntermediateSample = intermediate,
            ProcessAppearedInCurrentSample = appeared
        };
    }

    private static List<GpuDeviceEvidence> BuildDevices(
        IReadOnlyList<PerformanceRawSample> samples,
        out List<GpuDeviceIdentityDrift> drift)
    {
        drift = [];
        var indexes = samples
            .SelectMany(sample => sample.Gpu.Devices)
            .Select(device => device.Index)
            .Distinct()
            .OrderBy(index => index)
            .ToArray();
        var devices = new List<GpuDeviceEvidence>(indexes.Length);
        foreach (var index in indexes)
        {
            if (samples.Any(sample => sample.Gpu.Devices.Count(device => device.Index == index) > 1))
            {
                devices.Add(Invalidated(index));
                continue;
            }

            var series = samples
                .Select(sample => sample.Gpu.Devices.FirstOrDefault(device => device.Index == index))
                .ToArray();
            var present = series.Where(device => device is not null).Cast<GpuDeviceRaw>().ToArray();
            var uuids = present
                .Select(device => device.Uuid)
                .Where(uuid => !string.IsNullOrWhiteSpace(uuid))
                .Distinct(StringComparer.Ordinal)
                .ToArray();
            if (uuids.Length > 1)
            {
                string? previous = null;
                for (var sampleIndex = 0; sampleIndex < series.Length; sampleIndex++)
                {
                    var uuid = series[sampleIndex]?.Uuid;
                    if (string.IsNullOrWhiteSpace(uuid))
                        continue;
                    if (previous is not null && !string.Equals(previous, uuid, StringComparison.Ordinal))
                    {
                        drift.Add(new GpuDeviceIdentityDrift
                        {
                            Index = index,
                            BaselineUuid = previous,
                            CurrentUuid = uuid,
                            ReplacementSampleIndex = sampleIndex + 1
                        });
                    }

                    previous = uuid;
                }

                devices.Add(Invalidated(index));
                continue;
            }

            if (uuids.Length != 1)
            {
                devices.Add(Invalidated(index));
                continue;
            }

            var uuidStable = uuids[0];
            var gap = series.Length >= 3
                && series[0] is not null
                && series[^1] is not null
                && series.Skip(1).Take(series.Length - 2).Any(device => device is null);
            var current = series[^1];
            if (current is null || !string.Equals(current.Uuid, uuidStable, StringComparison.Ordinal))
            {
                devices.Add(UnavailableDevice(index, uuidStable, present[0].Name, series.Any(device => device is null)));
                continue;
            }

            devices.Add(Copy(current, gap));
        }

        return devices;
    }

    private static GpuDeviceEvidence UnavailableDevice(int index, string? uuid, string? name, bool gap) => new()
    {
        Index = index,
        IdentityStable = true,
        Identity = MetricAvailability.Unavailable,
        Name = name,
        Uuid = uuid,
        Pci = MetricAvailability.Unavailable,
        UtilizationPercent = PerformanceMetric<int>.Unavailable(),
        MemoryTotalBytes = PerformanceMetric<long>.Unavailable(),
        MemoryUsedBytes = PerformanceMetric<long>.Unavailable(),
        TemperatureCelsius = PerformanceMetric<int>.Unavailable(),
        PowerDrawMilliwatts = PerformanceMetric<int>.Unavailable(),
        PerformanceState = PerformanceMetric<int>.Unavailable(),
        EncoderUtilizationPercent = PerformanceMetric<int>.Unavailable(),
        DecoderUtilizationPercent = PerformanceMetric<int>.Unavailable(),
        EncoderSamplingPeriodMicroseconds = PerformanceMetric<long>.Unavailable(),
        DecoderSamplingPeriodMicroseconds = PerformanceMetric<long>.Unavailable(),
        JpegUtilizationPercent = PerformanceMetric<int>.NotSupported(),
        ProcessUtilizationQuery = MetricAvailability.Unavailable,
        ProcessMemoryQuery = MetricAvailability.Unavailable,
        AbsentFromIntermediateSample = gap
    };

    private static GpuDeviceEvidence Invalidated(int index) => new()
    {
        Index = index,
        IdentityStable = false,
        Identity = MetricAvailability.Unknown,
        Pci = MetricAvailability.Unknown,
        UtilizationPercent = PerformanceMetric<int>.Unknown(),
        MemoryTotalBytes = PerformanceMetric<long>.Unknown(),
        MemoryUsedBytes = PerformanceMetric<long>.Unknown(),
        TemperatureCelsius = PerformanceMetric<int>.Unknown(),
        PowerDrawMilliwatts = PerformanceMetric<int>.Unknown(),
        PerformanceState = PerformanceMetric<int>.Unknown(),
        EncoderUtilizationPercent = PerformanceMetric<int>.Unknown(),
        DecoderUtilizationPercent = PerformanceMetric<int>.Unknown(),
        EncoderSamplingPeriodMicroseconds = PerformanceMetric<long>.Unknown(),
        DecoderSamplingPeriodMicroseconds = PerformanceMetric<long>.Unknown(),
        JpegUtilizationPercent = PerformanceMetric<int>.NotSupported(),
        ProcessUtilizationQuery = MetricAvailability.Unknown,
        ProcessMemoryQuery = MetricAvailability.Unknown
    };

    private static GpuDeviceEvidence Copy(GpuDeviceRaw current, bool gap) => new()
    {
        Index = current.Index,
        IdentityStable = true,
        Identity = MetricAvailability.Observed,
        Name = current.Name,
        Uuid = current.Uuid,
        Pci = current.Pci,
        PciBusId = current.Pci == MetricAvailability.Observed ? current.PciBusId : null,
        UtilizationPercent = current.UtilizationPercent,
        MemoryTotalBytes = current.MemoryTotalBytes,
        MemoryUsedBytes = current.MemoryUsedBytes,
        TemperatureCelsius = current.TemperatureCelsius,
        PowerDrawMilliwatts = current.PowerDrawMilliwatts,
        PerformanceState = current.PerformanceState,
        EncoderUtilizationPercent = current.EncoderUtilizationPercent,
        DecoderUtilizationPercent = current.DecoderUtilizationPercent,
        EncoderSamplingPeriodMicroseconds = current.EncoderSamplingPeriodMicroseconds,
        DecoderSamplingPeriodMicroseconds = current.DecoderSamplingPeriodMicroseconds,
        JpegUtilizationPercent = PerformanceMetric<int>.NotSupported(),
        ProcessUtilizationQuery = current.ProcessUtilizationQuery,
        ProcessMemoryQuery = current.ProcessMemoryQuery,
        AbsentFromIntermediateSample = gap
    };

    private static List<GpuProcessEvidence> BuildProcesses(
        IReadOnlyList<PerformanceRawSample> samples,
        HashSet<int> driftedDeviceIndexes,
        out List<GpuProcessIdentityDrift> drift,
        out string[] absent,
        out string[] intermediate,
        out string[] appeared)
    {
        drift = [];
        var latestTicks = new Dictionary<string, long>(StringComparer.Ordinal);
        var observations = new List<(int SampleIndex, int DeviceIndex, string? Uuid, GpuProcessRaw Process)>();
        for (var sampleIndex = 0; sampleIndex < samples.Count; sampleIndex++)
        {
            foreach (var device in samples[sampleIndex].Gpu.Devices)
            {
                if (driftedDeviceIndexes.Contains(device.Index) || string.IsNullOrWhiteSpace(device.Uuid))
                    continue;
                foreach (var process in device.Processes.OrderBy(item => item.Pid))
                {
                    observations.Add((sampleIndex, device.Index, device.Uuid, process));
                    if (process.Identity != MetricAvailability.Observed || process.StartTimeUtcTicks is not > 0)
                        continue;
                    var scope = Scope(device.Uuid, process.Pid);
                    var ticks = process.StartTimeUtcTicks.Value;
                    if (latestTicks.TryGetValue(scope, out var previous) && previous != ticks)
                    {
                        drift.Add(new GpuProcessIdentityDrift
                        {
                            Pid = process.Pid,
                            GpuUuid = device.Uuid,
                            BaselineStartTimeUtcTicks = previous,
                            CurrentStartTimeUtcTicks = ticks,
                            ReplacementSampleIndex = sampleIndex + 1
                        });
                    }

                    latestTicks[scope] = ticks;
                }
            }
        }

        var joined = observations
            .Where(item => item.Process.Identity == MetricAvailability.Observed && item.Process.StartTimeUtcTicks is > 0)
            .Select(item => new Joined(item.SampleIndex, item.DeviceIndex, item.Uuid!, item.Process))
            .ToArray();
        var lastIndex = samples.Count - 1;
        var keysBySample = samples.Select(_ => new HashSet<string>(StringComparer.Ordinal)).ToArray();
        foreach (var item in joined)
            keysBySample[item.SampleIndex].Add(Key(item));

        var currentKeys = keysBySample[lastIndex];
        var baselineKeys = keysBySample[0];
        absent = baselineKeys.Except(currentKeys, StringComparer.Ordinal).OrderBy(key => key, StringComparer.Ordinal).ToArray();
        appeared = currentKeys.Except(baselineKeys, StringComparer.Ordinal).OrderBy(key => key, StringComparer.Ordinal).ToArray();
        intermediate = currentKeys
            .Where(key => keysBySample.Any(set => !set.Contains(key)))
            .OrderBy(key => key, StringComparer.Ordinal)
            .ToArray();

        var rows = new List<GpuProcessEvidence>();
        foreach (var key in currentKeys.OrderBy(value => value, StringComparer.Ordinal))
        {
            var matches = joined.Where(item => Key(item) == key).ToArray();
            var last = matches.Last(item => item.SampleIndex == lastIndex);
            var first = matches[0];
            rows.Add(ToEvidence(last, first, samples[last.SampleIndex].TimestampUtc, intermediate.Contains(key, StringComparer.Ordinal)));
        }

        foreach (var process in observations.Where(item => item.SampleIndex == lastIndex && item.Process.Identity != MetricAvailability.Observed))
        {
            rows.Add(new GpuProcessEvidence
            {
                Pid = process.Process.Pid,
                GpuIndex = process.DeviceIndex,
                GpuUuid = process.Uuid,
                Identity = process.Process.Identity,
                CollectorTimestampUtc = samples[lastIndex].TimestampUtc,
                DriverTimestampAdvanced = BlankBool(process.Process.Identity),
                SmUtilizationPercent = BlankInt(process.Process.Identity),
                MemoryUtilizationPercent = BlankInt(process.Process.Identity),
                EncoderUtilizationPercent = BlankInt(process.Process.Identity),
                DecoderUtilizationPercent = BlankInt(process.Process.Identity),
                ProcessMemoryBytes = process.Process.ProcessMemoryBytes.Availability == MetricAvailability.Observed
                    ? BlankLong(process.Process.Identity)
                    : process.Process.ProcessMemoryBytes
            });
        }

        return rows;
    }

    private static GpuProcessEvidence ToEvidence(Joined last, Joined first, DateTimeOffset collectorTimestampUtc, bool gap)
    {
        var timestamp = TimestampAdvance(first.Process, last.Process);
        return new GpuProcessEvidence
        {
            Pid = last.Process.Pid,
            IdentityKey = PerformanceIdentity.Key(last.Process.Pid, last.Process.StartTimeUtcTicks!.Value),
            StartTimeUtcTicks = last.Process.StartTimeUtcTicks!.Value,
            GpuIndex = last.DeviceIndex,
            GpuUuid = last.Uuid,
            Identity = MetricAvailability.Observed,
            DriverTimestamp = last.Process.DriverTimestampState == MetricAvailability.Observed ? last.Process.DriverTimestamp : null,
            CollectorTimestampUtc = collectorTimestampUtc,
            DriverTimestampAdvanced = timestamp,
            SmUtilizationPercent = last.Process.SmUtilizationPercent,
            MemoryUtilizationPercent = last.Process.MemoryUtilizationPercent,
            EncoderUtilizationPercent = last.Process.EncoderUtilizationPercent,
            DecoderUtilizationPercent = last.Process.DecoderUtilizationPercent,
            ProcessMemoryBytes = last.Process.ProcessMemoryBytes,
            AbsentFromIntermediateSample = gap
        };
    }

    private static PerformanceMetric<bool> TimestampAdvance(GpuProcessRaw first, GpuProcessRaw last)
    {
        if (ReferenceEquals(first, last) && first.DriverTimestampState == MetricAvailability.Observed)
            return PerformanceMetric<bool>.Unavailable();
        if (first.DriverTimestampState != MetricAvailability.Observed || last.DriverTimestampState != MetricAvailability.Observed
            || first.DriverTimestamp is null || last.DriverTimestamp is null)
        {
            if (first.DriverTimestampState == MetricAvailability.NotSupported && last.DriverTimestampState == MetricAvailability.NotSupported)
                return PerformanceMetric<bool>.NotSupported();
            if (first.DriverTimestampState == MetricAvailability.Unknown || last.DriverTimestampState == MetricAvailability.Unknown)
                return PerformanceMetric<bool>.Unknown();
            return PerformanceMetric<bool>.Unavailable();
        }

        if (last.DriverTimestamp.Value < first.DriverTimestamp.Value)
            return PerformanceMetric<bool>.Unknown();
        return PerformanceMetric<bool>.Observed(last.DriverTimestamp.Value > first.DriverTimestamp.Value);
    }

    private static MetricAvailability Summarize(
        IReadOnlyList<GpuDeviceEvidence> devices,
        Func<GpuDeviceEvidence, MetricAvailability> select)
    {
        if (devices.Count == 0)
            return MetricAvailability.Unavailable;
        var stable = devices.Where(device => device.IdentityStable).ToArray();
        if (stable.Length == 0)
            return MetricAvailability.Unknown;
        var states = stable.Select(select).ToArray();
        if (states.Any(state => state == MetricAvailability.Observed))
            return MetricAvailability.Observed;
        if (states.Any(state => state == MetricAvailability.Unknown))
            return MetricAvailability.Unknown;
        if (states.Any(state => state == MetricAvailability.Unavailable))
            return MetricAvailability.Unavailable;
        return MetricAvailability.NotSupported;
    }

    private static MetricAvailability Both(MetricAvailability left, MetricAvailability right)
    {
        if (left == MetricAvailability.Observed && right == MetricAvailability.Observed)
            return MetricAvailability.Observed;
        if (left == MetricAvailability.Unknown || right == MetricAvailability.Unknown)
            return MetricAvailability.Unknown;
        if (left == MetricAvailability.Unavailable || right == MetricAvailability.Unavailable)
            return MetricAvailability.Unavailable;
        return MetricAvailability.NotSupported;
    }

    private static MetricAvailability EitherEngine(MetricAvailability encoder, MetricAvailability decoder)
    {
        if (encoder == MetricAvailability.Observed || decoder == MetricAvailability.Observed)
            return MetricAvailability.Observed;
        if (encoder == MetricAvailability.Unknown || decoder == MetricAvailability.Unknown)
            return MetricAvailability.Unknown;
        if (encoder == MetricAvailability.Unavailable || decoder == MetricAvailability.Unavailable)
            return MetricAvailability.Unavailable;
        return MetricAvailability.NotSupported;
    }

    private static MetricAvailability CombineReader(IReadOnlyList<PerformanceRawSample> samples)
    {
        var unavailable = false;
        foreach (var sample in samples)
        {
            var state = ReaderOf(sample);
            if (state is MetricAvailability.Unknown or MetricAvailability.NotSupported)
                return MetricAvailability.Unknown;
            if (state == MetricAvailability.Unavailable)
                unavailable = true;
            else if (state != MetricAvailability.Observed)
                return MetricAvailability.Unknown;
        }

        return unavailable ? MetricAvailability.Unavailable : MetricAvailability.Observed;
    }

    private static MetricAvailability ReaderOf(PerformanceRawSample sample) =>
        sample.Gpu?.Reader ?? MetricAvailability.NotSupported;

    private static string Scope(string? uuid, int pid) => $"{uuid}|{pid}";

    private static string Key(Joined item) =>
        $"{item.Uuid}|{PerformanceIdentity.Key(item.Process.Pid, item.Process.StartTimeUtcTicks!.Value)}";

    private static PerformanceMetric<int> BlankInt(MetricAvailability state) => state switch
    {
        MetricAvailability.Unknown => PerformanceMetric<int>.Unknown(),
        MetricAvailability.NotSupported => PerformanceMetric<int>.NotSupported(),
        _ => PerformanceMetric<int>.Unavailable()
    };

    private static PerformanceMetric<long> BlankLong(MetricAvailability state) => state switch
    {
        MetricAvailability.Unknown => PerformanceMetric<long>.Unknown(),
        MetricAvailability.NotSupported => PerformanceMetric<long>.NotSupported(),
        _ => PerformanceMetric<long>.Unavailable()
    };

    private static PerformanceMetric<bool> BlankBool(MetricAvailability state) => state switch
    {
        MetricAvailability.Unknown => PerformanceMetric<bool>.Unknown(),
        MetricAvailability.NotSupported => PerformanceMetric<bool>.NotSupported(),
        _ => PerformanceMetric<bool>.Unavailable()
    };

    private sealed record Joined(int SampleIndex, int DeviceIndex, string Uuid, GpuProcessRaw Process);
}
