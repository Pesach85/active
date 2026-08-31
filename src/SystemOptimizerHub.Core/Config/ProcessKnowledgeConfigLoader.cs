using System.Text.Json;
using System.Text.Json.Serialization;

namespace SystemOptimizerHub.Core.Config;

public sealed class ProcessKnowledgeConfig
{
    [JsonPropertyName("AutoMergeCatalogOnIdentify")]
    public bool AutoMergeCatalogOnIdentify { get; set; } = true;

    [JsonPropertyName("AutoRebuildTransparencyReport")]
    public bool AutoRebuildTransparencyReport { get; set; } = true;

    [JsonPropertyName("RequireAuthForCatalogMerge")]
    public bool RequireAuthForCatalogMerge { get; set; } = true;

    [JsonPropertyName("CatalogMergeMinConfidence")]
    public double CatalogMergeMinConfidence { get; set; } = 0.85;

    [JsonPropertyName("CatalogPath")]
    public string CatalogPath { get; set; } = "config/process-intelligence.json";
}

public static class ProcessKnowledgeConfigLoader
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNameCaseInsensitive = true,
        ReadCommentHandling = JsonCommentHandling.Skip,
        AllowTrailingCommas = true
    };

    public static ProcessKnowledgeConfig LoadFromFile(string path)
    {
        if (!File.Exists(path))
            return new ProcessKnowledgeConfig();

        var json = File.ReadAllText(path);
        return JsonSerializer.Deserialize<ProcessKnowledgeConfig>(json, JsonOptions)
            ?? new ProcessKnowledgeConfig();
    }

    public static ProcessKnowledgeConfig LoadDefault(string hubRoot)
    {
        var candidates = new[]
        {
            Path.Combine(hubRoot, "config", "process-knowledge.json"),
            Path.Combine(Directory.GetCurrentDirectory(), "config", "process-knowledge.json")
        };
        foreach (var c in candidates)
        {
            if (File.Exists(c))
                return LoadFromFile(c);
        }
        return new ProcessKnowledgeConfig();
    }
}
