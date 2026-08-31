using System.Text.Json;
using SystemOptimizerHub.Core.Models;

namespace SystemOptimizerHub.Core.Config;

public static class ResolutionConfigLoader
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNameCaseInsensitive = true,
        ReadCommentHandling = JsonCommentHandling.Skip,
        AllowTrailingCommas = true
    };

    public static ProcessResolutionConfig LoadFromFile(string path)
    {
        if (!File.Exists(path))
            return CreateDefault();

        var json = File.ReadAllText(path);
        return JsonSerializer.Deserialize<ProcessResolutionConfig>(json, JsonOptions) ?? CreateDefault();
    }

    public static ProcessResolutionConfig CreateDefault() => new();
}
