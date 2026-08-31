namespace SystemOptimizerHub.Core.Scoring;

/// <summary>Deterministic pressure scoring (parity with process-pressure-core.ps1 weights).</summary>
public static class PressureScorer
{
    public const double DefaultMemoryCapMb = 8192.0;
    public const double DefaultIoCapMbPerSec = 400.0;
    public const double CpuWeight = 0.50;
    public const double MemoryWeight = 0.30;
    public const double IoWeight = 0.20;

    public static string DominantPressure(
        double cpuPercent,
        double workingSetMb,
        double ioMbPerSec,
        double memoryCapMb = DefaultMemoryCapMb,
        double ioCapMbPerSec = DefaultIoCapMbPerSec)
    {
        var cpuN = Math.Clamp(cpuPercent, 0, 100) / 100.0;
        var memN = Math.Clamp(workingSetMb, 0, memoryCapMb) / memoryCapMb;
        var ioN = Math.Clamp(ioMbPerSec, 0, ioCapMbPerSec) / ioCapMbPerSec;

        if (cpuN >= memN && cpuN >= ioN) return "CPUBound";
        if (memN >= cpuN && memN >= ioN) return "MemoryHeavy";
        if (ioN >= cpuN && ioN >= memN) return "IOHeavy";
        return "Mixed";
    }

    public static double CompositeScore(
        double cpuPercent,
        double workingSetMb,
        double ioMbPerSec,
        double memoryCapMb = DefaultMemoryCapMb,
        double ioCapMbPerSec = DefaultIoCapMbPerSec)
    {
        var cpu = Math.Clamp(cpuPercent, 0, 100);
        var mem = Math.Clamp(workingSetMb, 0, memoryCapMb);
        var io = Math.Clamp(ioMbPerSec, 0, ioCapMbPerSec);
        var score = cpu * CpuWeight
            + (mem / memoryCapMb) * 100.0 * MemoryWeight
            + (io / ioCapMbPerSec) * 100.0 * IoWeight;
        return Math.Round(Math.Min(100.0, score), 2);
    }
}
