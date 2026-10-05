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

        var samples = new List<PerformanceRawSample>(PerformanceDiagnosisPolicy.ApprovedMinimumSamples);
        for (var index = 0; index < PerformanceDiagnosisPolicy.ApprovedMinimumSamples; index++)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (index > 0 && interval > TimeSpan.Zero)
                await Task.Delay(interval, cancellationToken).ConfigureAwait(false);
            cancellationToken.ThrowIfCancellationRequested();
            samples.Add(source.Capture(maxProcesses, cancellationToken));
        }

        return PerformanceEvidenceBuilder.Build(samples, maxProcesses);
    }
}
