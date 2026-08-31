using System.Text.Json.Serialization;

namespace SystemOptimizerHub.Core.Models;

public sealed class ProcessIntelligenceCatalog
{
    [JsonPropertyName("SchemaVersion")]
    public string SchemaVersion { get; set; } = "ProcessIntelligence.v1";

    [JsonPropertyName("vitalExact")]
    public List<string> VitalExact { get; set; } = [];

    [JsonPropertyName("vitalPatterns")]
    public List<string> VitalPatterns { get; set; } = [];

    [JsonPropertyName("securityExact")]
    public List<string> SecurityExact { get; set; } = [];

    [JsonPropertyName("platformServicePatterns")]
    public List<string> PlatformServicePatterns { get; set; } = [];

    [JsonPropertyName("optionalBackgroundPatterns")]
    public List<string> OptionalBackgroundPatterns { get; set; } = [];

    [JsonPropertyName("knownApplications")]
    public Dictionary<string, KnownApplicationEntry> KnownApplications { get; set; } = new(StringComparer.OrdinalIgnoreCase);
}

public sealed class KnownApplicationEntry
{
    [JsonPropertyName("category")]
    public string Category { get; set; } = "Unknown";

    [JsonPropertyName("priority")]
    public string Priority { get; set; } = "Review";

    [JsonPropertyName("displayName")]
    public string? DisplayName { get; set; }

    [JsonPropertyName("description")]
    public string? Description { get; set; }
}
