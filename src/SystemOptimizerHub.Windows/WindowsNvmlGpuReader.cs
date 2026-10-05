using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using System.Text;
using SystemOptimizerHub.Core.Performance;

namespace SystemOptimizerHub.Windows;

[SupportedOSPlatform("windows")]
public static class WindowsGpuProcessIdentity
{
    public static GpuIdentityLookup Lookup(int pid)
    {
        if (pid <= 0)
            return GpuIdentityLookup.Unknown();
        try
        {
            using var process = Process.GetProcessById(pid);
            long ticks;
            try
            {
                ticks = process.StartTime.ToUniversalTime().Ticks;
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                return GpuIdentityLookup.Unavailable();
            }

            return ticks > 0 ? GpuIdentityLookup.Observed(ticks) : GpuIdentityLookup.Unknown();
        }
        catch (ArgumentException)
        {
            return GpuIdentityLookup.Unavailable();
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            return GpuIdentityLookup.Unavailable();
        }
    }
}

/// <summary>
/// Loads nvml.dll at runtime. The external command-line query tool is not invoked. A missing library is NotSupported, not a crash.
/// </summary>
[SupportedOSPlatform("windows")]
public sealed class WindowsNvmlGpuReader : IGpuRawReader
{
    private const int MaxDevices = 64;
    private IntPtr _module;
    private bool _attempted;
    private bool _disposed;
    private bool _ownsShutdown;
    private MetricAvailability _session = MetricAvailability.NotSupported;
    private InitDelegate? _init;
    private ShutdownDelegate? _shutdown;
    private CountDelegate? _count;
    private HandleDelegate? _handle;
    private NameDelegate? _name;
    private NameDelegate? _uuid;
    private PciDelegate? _pci;
    private TemperatureDelegate? _temperature;
    private UtilizationDelegate? _utilization;
    private MemoryDelegate? _memory;
    private PowerDelegate? _power;
    private PStateDelegate? _pState;
    private EngineDelegate? _encoder;
    private EngineDelegate? _decoder;
    private ProcessUtilizationDelegate? _processUtilization;
    private ProcessListDelegate? _computeProcesses;
    private ProcessListDelegate? _graphicsProcesses;
    private VersionDelegate? _driverVersion;
    private VersionDelegate? _nvmlVersion;

    public long InitializationMilliseconds { get; private set; }

    public long LastReadMilliseconds { get; private set; }

    public int DeviceQueryCount { get; private set; }

    public int ProcessQueryCount { get; private set; }

    public GpuRawSample Read(CancellationToken cancellationToken, Func<int, GpuIdentityLookup> lookup)
    {
        ArgumentNullException.ThrowIfNull(lookup);
        cancellationToken.ThrowIfCancellationRequested();
        var watch = Stopwatch.StartNew();
        try
        {
            Ensure();
            if (_disposed)
                return GpuRawSample.Unavailable();
            if (_session != MetricAvailability.Observed)
                return new GpuRawSample { Reader = _session };
            return Query(cancellationToken, lookup);
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            return GpuRawSample.Unknown();
        }
        finally
        {
            watch.Stop();
            LastReadMilliseconds = watch.ElapsedMilliseconds;
        }
    }

    public void Dispose()
    {
        if (_disposed)
            return;
        _disposed = true;
        if (_ownsShutdown && _shutdown is not null)
        {
            try
            {
                _shutdown();
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
            }
        }

        if (_module != IntPtr.Zero)
        {
            FreeLibrary(_module);
            _module = IntPtr.Zero;
        }
    }

    private void Ensure()
    {
        if (_attempted)
            return;
        _attempted = true;
        var watch = Stopwatch.StartNew();
        try
        {
            if (Marshal.SizeOf<ProcessSample>() != 32 || Marshal.SizeOf<ProcessInfo>() != 24)
            {
                _session = MetricAvailability.Unknown;
                return;
            }

            _module = LoadLibrary("nvml.dll");
            if (_module == IntPtr.Zero)
            {
                _session = NvmlReturn.Session(false, false, 0);
                return;
            }

            _init = Bind<InitDelegate>("nvmlInit_v2");
            _shutdown = Bind<ShutdownDelegate>("nvmlShutdown");
            _count = Bind<CountDelegate>("nvmlDeviceGetCount_v2");
            _handle = Bind<HandleDelegate>("nvmlDeviceGetHandleByIndex_v2");
            var entryPoints = _init is not null && _shutdown is not null && _count is not null && _handle is not null;
            if (!entryPoints)
            {
                _session = NvmlReturn.Session(true, false, 0);
                return;
            }

            _name = Bind<NameDelegate>("nvmlDeviceGetName");
            _uuid = Bind<NameDelegate>("nvmlDeviceGetUUID");
            _pci = Marshal.SizeOf<PciInfo>() == 68 ? Bind<PciDelegate>("nvmlDeviceGetPciInfo_v3") : null;
            _temperature = Bind<TemperatureDelegate>("nvmlDeviceGetTemperature");
            _utilization = Bind<UtilizationDelegate>("nvmlDeviceGetUtilizationRates");
            _memory = Bind<MemoryDelegate>("nvmlDeviceGetMemoryInfo");
            _power = Bind<PowerDelegate>("nvmlDeviceGetPowerUsage");
            _pState = Bind<PStateDelegate>("nvmlDeviceGetPerformanceState");
            _encoder = Bind<EngineDelegate>("nvmlDeviceGetEncoderUtilization");
            _decoder = Bind<EngineDelegate>("nvmlDeviceGetDecoderUtilization");
            _processUtilization = Bind<ProcessUtilizationDelegate>("nvmlDeviceGetProcessUtilization");
            _computeProcesses = Bind<ProcessListDelegate>("nvmlDeviceGetComputeRunningProcesses_v3");
            _graphicsProcesses = Bind<ProcessListDelegate>("nvmlDeviceGetGraphicsRunningProcesses_v3");
            _driverVersion = Bind<VersionDelegate>("nvmlSystemGetDriverVersion");
            _nvmlVersion = Bind<VersionDelegate>("nvmlSystemGetNVMLVersion");

            var initCode = _init!();
            _ownsShutdown = initCode == NvmlReturn.Success;
            _session = NvmlReturn.Session(true, true, initCode);
        }
        finally
        {
            watch.Stop();
            InitializationMilliseconds = watch.ElapsedMilliseconds;
        }
    }

    private GpuRawSample Query(CancellationToken cancellationToken, Func<int, GpuIdentityLookup> lookup)
    {
        uint count = 0;
        var countCode = _count!(ref count);
        DeviceQueryCount++;
        var countState = NvmlReturn.Map(countCode);
        var driver = ReadVersion(_driverVersion);
        var nvml = ReadVersion(_nvmlVersion);
        if (countState != MetricAvailability.Observed)
            return new GpuRawSample { Reader = countState, DriverVersion = driver, NvmlVersion = nvml };
        if (count == 0)
            return new GpuRawSample { Reader = MetricAvailability.Observed, DriverVersion = driver, NvmlVersion = nvml };
        if (count > MaxDevices)
            return GpuRawSample.Unknown();

        var devices = new List<GpuDeviceRaw>((int)count);
        for (var index = 0; index < count; index++)
        {
            cancellationToken.ThrowIfCancellationRequested();
            devices.Add(ReadDevice(index, cancellationToken, lookup));
        }

        return new GpuRawSample
        {
            Reader = MetricAvailability.Observed,
            DriverVersion = driver,
            NvmlVersion = nvml,
            Devices = devices
        };
    }

    private GpuDeviceRaw ReadDevice(int index, CancellationToken cancellationToken, Func<int, GpuIdentityLookup> lookup)
    {
        DeviceQueryCount++;
        var handleCode = _handle!(index, out var device);
        if (NvmlReturn.Map(handleCode) != MetricAvailability.Observed || device == IntPtr.Zero)
        {
            return new GpuDeviceRaw
            {
                Index = index,
                Identity = MetricAvailability.Unavailable,
                UtilizationPercent = PerformanceMetric<int>.Unavailable(),
                MemoryTotalBytes = PerformanceMetric<long>.Unavailable(),
                MemoryUsedBytes = PerformanceMetric<long>.Unavailable(),
                TemperatureCelsius = PerformanceMetric<int>.Unavailable(),
                PowerDrawMilliwatts = PerformanceMetric<int>.Unavailable(),
                PerformanceState = PerformanceMetric<int>.Unavailable(),
                EncoderUtilizationPercent = PerformanceMetric<int>.Unavailable(),
                DecoderUtilizationPercent = PerformanceMetric<int>.Unavailable(),
                EncoderSamplingPeriodMicroseconds = PerformanceMetric<long>.Unavailable(),
                DecoderSamplingPeriodMicroseconds = PerformanceMetric<long>.Unavailable()
            };
        }

        var (identity, name, uuid) = ReadIdentity(device);
        var (pciState, pci) = ReadPci(device);
        var utilization = ReadUtilization(device);
        var (total, used) = ReadMemory(device);
        var temperature = ReadTemperature(device);
        var power = ReadPower(device);
        var pState = ReadPState(device);
        var (encoder, encoderPeriod) = ReadEngine(_encoder, device);
        var (decoder, decoderPeriod) = ReadEngine(_decoder, device);
        cancellationToken.ThrowIfCancellationRequested();
        var (processQuery, processes) = ReadProcesses(device, cancellationToken, lookup);
        return new GpuDeviceRaw
        {
            Index = index,
            Identity = identity,
            Name = name,
            Uuid = uuid,
            Pci = pciState,
            PciBusId = pci,
            UtilizationPercent = utilization.Gpu,
            MemoryTotalBytes = total,
            MemoryUsedBytes = used,
            TemperatureCelsius = temperature,
            PowerDrawMilliwatts = power,
            PerformanceState = pState,
            EncoderUtilizationPercent = encoder,
            DecoderUtilizationPercent = decoder,
            EncoderSamplingPeriodMicroseconds = encoderPeriod,
            DecoderSamplingPeriodMicroseconds = decoderPeriod,
            ProcessUtilizationQuery = processQuery.Utilization,
            ProcessMemoryQuery = processQuery.Memory,
            Processes = processes
        };
    }

    private (MetricAvailability Identity, string? Name, string? Uuid) ReadIdentity(IntPtr device)
    {
        var name = ReadText(_name, device, 96);
        var uuid = ReadText(_uuid, device, 80);
        if (name.State == MetricAvailability.Observed && uuid.State == MetricAvailability.Observed)
            return (MetricAvailability.Observed, name.Text, uuid.Text);
        if (name.State == MetricAvailability.NotSupported || uuid.State == MetricAvailability.NotSupported)
            return (MetricAvailability.NotSupported, name.Text, uuid.Text);
        if (name.State == MetricAvailability.Unknown || uuid.State == MetricAvailability.Unknown)
            return (MetricAvailability.Unknown, null, null);
        return (MetricAvailability.Unavailable, null, null);
    }

    private (MetricAvailability State, string? BusId) ReadPci(IntPtr device)
    {
        if (_pci is null)
            return (MetricAvailability.NotSupported, null);
        var info = new PciInfo();
        var code = _pci(device, ref info);
        var state = NvmlReturn.Map(code);
        if (state != MetricAvailability.Observed)
            return (state, null);
        var bus = string.IsNullOrWhiteSpace(info.BusId) ? info.BusIdLegacy : info.BusId;
        return string.IsNullOrWhiteSpace(bus)
            ? (MetricAvailability.Unknown, null)
            : (MetricAvailability.Observed, bus.Trim());
    }

    private (PerformanceMetric<int> Gpu, PerformanceMetric<int> Memory) ReadUtilization(IntPtr device)
    {
        if (_utilization is null)
            return (PerformanceMetric<int>.NotSupported(), PerformanceMetric<int>.NotSupported());
        var code = _utilization(device, out var rates);
        return (NvmlReturn.Percent(code, rates.Gpu), NvmlReturn.Percent(code, rates.Memory));
    }

    private (PerformanceMetric<long> Total, PerformanceMetric<long> Used) ReadMemory(IntPtr device)
    {
        if (_memory is null)
            return (PerformanceMetric<long>.NotSupported(), PerformanceMetric<long>.NotSupported());
        var code = _memory(device, out var memory);
        return NvmlReturn.Memory(code, memory.Total, memory.Used);
    }

    private PerformanceMetric<int> ReadTemperature(IntPtr device)
    {
        if (_temperature is null)
            return PerformanceMetric<int>.NotSupported();
        var code = _temperature(device, 0, out var value);
        return NvmlReturn.TemperatureCelsius(code, value);
    }

    private PerformanceMetric<int> ReadPower(IntPtr device)
    {
        if (_power is null)
            return PerformanceMetric<int>.NotSupported();
        var code = _power(device, out var value);
        return NvmlReturn.PowerMilliwatts(code, value);
    }

    private PerformanceMetric<int> ReadPState(IntPtr device)
    {
        if (_pState is null)
            return PerformanceMetric<int>.NotSupported();
        var code = _pState(device, out var value);
        return NvmlReturn.PerformanceState(code, value);
    }

    private static (PerformanceMetric<int> Utilization, PerformanceMetric<long> Period) ReadEngine(EngineDelegate? engine, IntPtr device)
    {
        if (engine is null)
            return (PerformanceMetric<int>.NotSupported(), PerformanceMetric<long>.NotSupported());
        var code = engine(device, out var utilization, out var period);
        return NvmlReturn.Engine(code, utilization, period);
    }

    private (ProcessQueries Query, IReadOnlyList<GpuProcessRaw> Processes) ReadProcesses(
        IntPtr device,
        CancellationToken cancellationToken,
        Func<int, GpuIdentityLookup> lookup)
    {
        var utilization = ReadProcessUtilization(device);
        var memory = ReadProcessMemory(device);
        ProcessQueryCount += utilization.Calls + memory.Calls;
        var memoryKeys = memory.ByPid?.Keys ?? Enumerable.Empty<int>();
        var pids = utilization.ByPid.Keys.Concat(memoryKeys).Distinct().OrderBy(pid => pid).ToArray();
        var rows = new List<GpuProcessRaw>(pids.Length);
        foreach (var pid in pids)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var hasUtil = utilization.ByPid.TryGetValue(pid, out var util);
            var mem = PerformanceMetric<long>.Unavailable();
            var hasMemory = memory.ByPid is not null && memory.ByPid.TryGetValue(pid, out mem);
            if (!hasMemory || mem is null)
                mem = PerformanceMetric<long>.Unavailable();
            var utilState = utilization.Query;
            var sm = utilState == MetricAvailability.Observed
                ? hasUtil ? util.Sm : PerformanceMetric<int>.Unavailable()
                : Blank<int>(utilState);
            var memUtil = utilState == MetricAvailability.Observed
                ? hasUtil ? util.Memory : PerformanceMetric<int>.Unavailable()
                : Blank<int>(utilState);
            var enc = utilState == MetricAvailability.Observed
                ? hasUtil ? util.Encoder : PerformanceMetric<int>.Unavailable()
                : Blank<int>(utilState);
            var dec = utilState == MetricAvailability.Observed
                ? hasUtil ? util.Decoder : PerformanceMetric<int>.Unavailable()
                : Blank<int>(utilState);
            var timestampState = utilState == MetricAvailability.Observed
                ? hasUtil ? util.TimestampState : MetricAvailability.Unavailable
                : utilState;
            var processMemory = memory.Query == MetricAvailability.Observed
                ? mem
                : Blank<long>(memory.Query);
            rows.Add(GpuProcessRaw.Join(
                pid,
                lookup(pid),
                hasUtil ? util.Timestamp : null,
                timestampState,
                sm,
                memUtil,
                enc,
                dec,
                processMemory));
        }

        return (new ProcessQueries(utilization.Query, memory.Query), rows);
    }

    private UtilizationRead ReadProcessUtilization(IntPtr device)
    {
        if (_processUtilization is null)
            return UtilizationRead.Closed(MetricAvailability.NotSupported, 0);
        uint count = 0;
        var first = _processUtilization(device, IntPtr.Zero, ref count, 0);
        var plan = NvmlBufferQuery.First(first, count);
        if (!plan.CallAgain)
            return UtilizationRead.Closed(plan.Availability, 1);
        var buffer = new ProcessSample[plan.Count];
        var pin = GCHandle.Alloc(buffer, GCHandleType.Pinned);
        int second;
        try
        {
            second = _processUtilization(device, pin.AddrOfPinnedObject(), ref count, 0);
        }
        finally
        {
            pin.Free();
        }

        var state = NvmlBufferQuery.Second(second, count, buffer.Length);
        if (state != MetricAvailability.Observed)
            return UtilizationRead.Closed(state, 2);
        var byPid = new Dictionary<int, UtilRow>();
        var usable = (int)count;
        for (var i = 0; i < usable; i++)
        {
            var sample = buffer[i];
            if (sample.Pid == 0 || sample.Pid > int.MaxValue)
            {
                return UtilizationRead.Closed(MetricAvailability.Unknown, 2);
            }

            var row = new UtilRow(
                sample.TimeStamp,
                MetricAvailability.Observed,
                NvmlReturn.Percent(NvmlReturn.Success, sample.SmUtil),
                NvmlReturn.Percent(NvmlReturn.Success, sample.MemUtil),
                NvmlReturn.Percent(NvmlReturn.Success, sample.EncUtil),
                NvmlReturn.Percent(NvmlReturn.Success, sample.DecUtil));
            if (!byPid.TryGetValue((int)sample.Pid, out var existing) || sample.TimeStamp >= existing.Timestamp)
                byPid[(int)sample.Pid] = row;
        }

        return new UtilizationRead(MetricAvailability.Observed, byPid, 2);
    }

    private MemoryRead ReadProcessMemory(IntPtr device)
    {
        var compute = ReadProcessList(_computeProcesses, device);
        var graphics = ReadProcessList(_graphicsProcesses, device);
        var calls = compute.Calls + graphics.Calls;
        if (compute.Query == MetricAvailability.NotSupported && graphics.Query == MetricAvailability.NotSupported)
            return MemoryRead.Closed(MetricAvailability.NotSupported, calls);
        if (compute.Query == MetricAvailability.Unknown || graphics.Query == MetricAvailability.Unknown)
            return MemoryRead.Closed(MetricAvailability.Unknown, calls);
        if (compute.Query != MetricAvailability.Observed && graphics.Query != MetricAvailability.Observed)
            return MemoryRead.Closed(MetricAvailability.Unavailable, calls);

        var byPid = new Dictionary<int, PerformanceMetric<long>>();
        MergeMemory(byPid, compute);
        MergeMemory(byPid, graphics);
        return new MemoryRead(MetricAvailability.Observed, byPid, calls);
    }

    private static void MergeMemory(Dictionary<int, PerformanceMetric<long>> byPid, MemoryRead read)
    {
        if (read.Query != MetricAvailability.Observed || read.ByPid is null)
            return;
        foreach (var pair in read.ByPid)
        {
            if (!byPid.TryGetValue(pair.Key, out var existing))
            {
                byPid[pair.Key] = pair.Value;
                continue;
            }

            if (existing.Availability == MetricAvailability.Observed && pair.Value.Availability == MetricAvailability.Observed
                && existing.Value != pair.Value.Value)
                byPid[pair.Key] = PerformanceMetric<long>.Unknown();
            else if (existing.Availability != MetricAvailability.Observed)
                byPid[pair.Key] = pair.Value;
        }
    }

    private MemoryRead ReadProcessList(ProcessListDelegate? call, IntPtr device)
    {
        if (call is null)
            return MemoryRead.Closed(MetricAvailability.NotSupported, 0);
        uint count = 0;
        var first = call(device, ref count, IntPtr.Zero);
        var plan = NvmlBufferQuery.First(first, count);
        if (!plan.CallAgain)
            return MemoryRead.Closed(plan.Availability, 1);
        var buffer = new ProcessInfo[plan.Count];
        var pin = GCHandle.Alloc(buffer, GCHandleType.Pinned);
        int second;
        try
        {
            second = call(device, ref count, pin.AddrOfPinnedObject());
        }
        finally
        {
            pin.Free();
        }

        var state = NvmlBufferQuery.Second(second, count, buffer.Length);
        if (state != MetricAvailability.Observed)
            return MemoryRead.Closed(state, 2);
        var byPid = new Dictionary<int, PerformanceMetric<long>>();
        for (var i = 0; i < count; i++)
        {
            var info = buffer[i];
            if (info.Pid == 0 || info.Pid > int.MaxValue)
                return MemoryRead.Closed(MetricAvailability.Unknown, 2);
            byPid[(int)info.Pid] = NvmlReturn.ProcessMemory(NvmlReturn.Success, info.UsedGpuMemory);
        }

        return new MemoryRead(MetricAvailability.Observed, byPid, 2);
    }

    private (MetricAvailability State, string? Text) ReadText(NameDelegate? call, IntPtr device, int length)
    {
        if (call is null)
            return (MetricAvailability.NotSupported, null);
        var buffer = new byte[length];
        var code = call(device, buffer, (uint)buffer.Length);
        var state = NvmlReturn.Map(code);
        if (state != MetricAvailability.Observed)
            return (state, null);
        var end = Array.IndexOf(buffer, (byte)0);
        if (end < 0)
            return (MetricAvailability.Unknown, null);
        var text = Encoding.ASCII.GetString(buffer, 0, end).Trim();
        return string.IsNullOrWhiteSpace(text) ? (MetricAvailability.Unknown, null) : (MetricAvailability.Observed, text);
    }

    private string? ReadVersion(VersionDelegate? call)
    {
        if (call is null || _session != MetricAvailability.Observed)
            return null;
        var buffer = new byte[80];
        var code = call(buffer, (uint)buffer.Length);
        return ReadTextResult(code, buffer);
    }

    private static string? ReadTextResult(int code, byte[] buffer)
    {
        if (NvmlReturn.Map(code) != MetricAvailability.Observed)
            return null;
        var end = Array.IndexOf(buffer, (byte)0);
        if (end < 0)
            return null;
        var text = Encoding.ASCII.GetString(buffer, 0, end).Trim();
        return string.IsNullOrWhiteSpace(text) ? null : text;
    }

    private T? Bind<T>(string name) where T : Delegate
    {
        var address = GetProcAddress(_module, name);
        return address == IntPtr.Zero ? null : Marshal.GetDelegateForFunctionPointer<T>(address);
    }

    private static PerformanceMetric<T> Blank<T>(MetricAvailability availability) where T : struct => availability switch
    {
        MetricAvailability.NotSupported => PerformanceMetric<T>.NotSupported(),
        MetricAvailability.Unavailable => PerformanceMetric<T>.Unavailable(),
        _ => PerformanceMetric<T>.Unknown()
    };

    [StructLayout(LayoutKind.Sequential)]
    private struct UtilizationRates
    {
        public uint Gpu;
        public uint Memory;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MemoryInfo
    {
        public ulong Total;
        public ulong Free;
        public ulong Used;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Ansi)]
    private struct PciInfo
    {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 16)]
        public string BusIdLegacy;

        public uint Domain;
        public uint Bus;
        public uint Device;
        public uint PciDeviceId;
        public uint PciSubSystemId;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
        public string BusId;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ProcessSample
    {
        public uint Pid;
        public ulong TimeStamp;
        public uint SmUtil;
        public uint MemUtil;
        public uint EncUtil;
        public uint DecUtil;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ProcessInfo
    {
        public uint Pid;
        public ulong UsedGpuMemory;
        public uint GpuInstanceId;
        public uint ComputeInstanceId;
    }

    private readonly record struct ProcessQueries(MetricAvailability Utilization, MetricAvailability Memory);

    private readonly record struct UtilRow(
        ulong Timestamp,
        MetricAvailability TimestampState,
        PerformanceMetric<int> Sm,
        PerformanceMetric<int> Memory,
        PerformanceMetric<int> Encoder,
        PerformanceMetric<int> Decoder);

    private sealed record UtilizationRead(MetricAvailability Query, Dictionary<int, UtilRow> ByPid, int Calls)
    {
        public static UtilizationRead Closed(MetricAvailability query, int calls) =>
            new(query, new Dictionary<int, UtilRow>(), calls);
    }

    private sealed record MemoryRead(MetricAvailability Query, Dictionary<int, PerformanceMetric<long>>? ByPid, int Calls)
    {
        public static MemoryRead Closed(MetricAvailability query, int calls) => new(query, null, calls);
    }

    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    private delegate int InitDelegate();

    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    private delegate int ShutdownDelegate();

    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    private delegate int CountDelegate(ref uint count);

    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    private delegate int HandleDelegate(int index, out IntPtr device);

    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    private delegate int NameDelegate(IntPtr device, byte[] buffer, uint length);

    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    private delegate int PciDelegate(IntPtr device, ref PciInfo pci);

    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    private delegate int TemperatureDelegate(IntPtr device, uint sensor, out uint temperature);

    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    private delegate int UtilizationDelegate(IntPtr device, out UtilizationRates rates);

    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    private delegate int MemoryDelegate(IntPtr device, out MemoryInfo memory);

    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    private delegate int PowerDelegate(IntPtr device, out uint milliwatts);

    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    private delegate int PStateDelegate(IntPtr device, out int state);

    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    private delegate int EngineDelegate(IntPtr device, out uint utilization, out uint periodMicroseconds);

    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    private delegate int ProcessUtilizationDelegate(IntPtr device, IntPtr samples, ref uint count, ulong lastSeenTimestamp);

    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    private delegate int ProcessListDelegate(IntPtr device, ref uint count, IntPtr infos);

    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    private delegate int VersionDelegate(byte[] buffer, uint length);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr LoadLibrary(string fileName);

    [DllImport("kernel32.dll", CharSet = CharSet.Ansi, SetLastError = true)]
    private static extern IntPtr GetProcAddress(IntPtr module, string name);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool FreeLibrary(IntPtr module);
}
