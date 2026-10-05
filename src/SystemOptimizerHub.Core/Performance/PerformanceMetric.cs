using System.Text.Json.Serialization;

namespace SystemOptimizerHub.Core.Performance;

public sealed record PerformanceMetric<T> where T : struct
{
    public MetricAvailability Availability { get; init; }

    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public T? Value { get; init; }

    public static PerformanceMetric<T> Observed(T value) => new()
    {
        Availability = MetricAvailability.Observed,
        Value = value
    };

    public static PerformanceMetric<T> Unavailable() => new()
    {
        Availability = MetricAvailability.Unavailable
    };

    public static PerformanceMetric<T> NotSupported() => new()
    {
        Availability = MetricAvailability.NotSupported
    };

    public static PerformanceMetric<T> Unknown() => new()
    {
        Availability = MetricAvailability.Unknown
    };
}
