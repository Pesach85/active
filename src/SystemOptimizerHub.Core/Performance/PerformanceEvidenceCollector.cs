namespace SystemOptimizerHub.Core.Performance;

public static class PerformanceEvidenceCollector
{
    public static async Task<PerformanceSnapshot> CollectAsync(
        IPerformanceSampleSource source,
        TimeSpan interval,
        int maxProcesses,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(source);
        if (interval < TimeSpan.Zero)
            throw new ArgumentOutOfRangeException(nameof(interval));
        if (maxProcesses < 1 || maxProcesses > PerformanceEvidenceLimits.HardMaxProcesses)
            throw new ArgumentOutOfRangeException(nameof(maxProcesses));

        cancellationToken.ThrowIfCancellationRequested();
        var baseline = source.Capture(maxProcesses, cancellationToken);
        if (interval > TimeSpan.Zero)
            await Task.Delay(interval, cancellationToken).ConfigureAwait(false);
        cancellationToken.ThrowIfCancellationRequested();
        var current = source.Capture(maxProcesses, cancellationToken);
        return PerformanceEvidenceBuilder.Build(baseline, current, maxProcesses);
    }
}
