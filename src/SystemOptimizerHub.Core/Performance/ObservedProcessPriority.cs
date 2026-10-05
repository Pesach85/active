using System.Text.Json.Serialization;

namespace SystemOptimizerHub.Core.Performance;

/// <summary>
/// Windows priority class names, published only when a read succeeds.
/// Zero is not a priority. Linux nice is not translated into these names.
/// </summary>
[JsonConverter(typeof(JsonStringEnumConverter))]
public enum ObservedProcessPriority
{
    Idle = 1,
    BelowNormal = 2,
    Normal = 3,
    AboveNormal = 4,
    High = 5,
    RealTime = 6
}
