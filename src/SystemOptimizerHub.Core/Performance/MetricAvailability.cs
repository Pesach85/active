using System.Text.Json.Serialization;

namespace SystemOptimizerHub.Core.Performance;

/// <summary>
/// Observed: the reader returned a real value.
/// Unavailable: a reader exists, but this sample failed or a field could not be read.
/// NotSupported: this build has no reader for the metric.
/// Unknown: inputs were present but not usable (non-positive elapsed time, incoherent counters).
/// Unavailable and NotSupported never substitute a numeric zero.
/// </summary>
[JsonConverter(typeof(JsonStringEnumConverter))]
public enum MetricAvailability
{
    Observed,
    Unavailable,
    NotSupported,
    Unknown
}
