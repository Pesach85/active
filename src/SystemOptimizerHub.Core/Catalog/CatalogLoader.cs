using System.Text.Json;
using SystemOptimizerHub.Core.Models;

namespace SystemOptimizerHub.Core.Catalog;

public static class CatalogLoader
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNameCaseInsensitive = true,
        ReadCommentHandling = JsonCommentHandling.Skip,
        AllowTrailingCommas = true
    };

    public static ProcessIntelligenceCatalog LoadFromFile(string catalogPath)
    {
        if (!File.Exists(catalogPath))
            return CreateDefault();

        var json = File.ReadAllText(catalogPath);
        return JsonSerializer.Deserialize<ProcessIntelligenceCatalog>(json, JsonOptions)
            ?? CreateDefault();
    }

    public static ProcessIntelligenceCatalog CreateDefault() => new()
    {
        SchemaVersion = "ProcessIntelligence.v1",
        VitalExact =
        [
            "System", "csrss", "wininit", "services", "lsass", "svchost", "winlogon", "dwm"
        ],
        SecurityExact = ["MsMpEng", "NisSrv", "Sense"]
    };
}
