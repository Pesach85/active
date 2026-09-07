using System.Text.Json;
using System.Text.Json.Nodes;
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

    public static void SaveToFile(string catalogPath, ProcessIntelligenceCatalog catalog)
    {
        var dir = Path.GetDirectoryName(catalogPath);
        if (!string.IsNullOrEmpty(dir))
            Directory.CreateDirectory(dir);

        JsonObject root;
        if (File.Exists(catalogPath))
        {
            root = JsonNode.Parse(File.ReadAllText(catalogPath))?.AsObject()
                ?? new JsonObject();
        }
        else
        {
            root = new JsonObject();
        }

        // Update managed fields only; preserve extensions (extremeNecessityDefender, safeActionDefinitions, ...).
        root["SchemaVersion"] = catalog.SchemaVersion;
        root["vitalExact"] = JsonSerializer.SerializeToNode(catalog.VitalExact, JsonOptions);
        root["vitalPatterns"] = JsonSerializer.SerializeToNode(catalog.VitalPatterns, JsonOptions);
        root["securityExact"] = JsonSerializer.SerializeToNode(catalog.SecurityExact, JsonOptions);
        root["platformServicePatterns"] = JsonSerializer.SerializeToNode(catalog.PlatformServicePatterns, JsonOptions);
        root["optionalBackgroundPatterns"] = JsonSerializer.SerializeToNode(catalog.OptionalBackgroundPatterns, JsonOptions);
        root["knownApplications"] = JsonSerializer.SerializeToNode(catalog.KnownApplications, new JsonSerializerOptions
        {
            PropertyNameCaseInsensitive = true,
            DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull
        });

        var outJson = root.ToJsonString(new JsonSerializerOptions { WriteIndented = true });
        File.WriteAllText(catalogPath, outJson);
    }

    public static List<string> ExtractProcessNames(ProcessIntelligenceCatalog catalog)
    {
        var names = new List<string>();
        names.AddRange(catalog.VitalExact);
        names.AddRange(catalog.SecurityExact);
        foreach (var key in catalog.KnownApplications.Keys)
            names.Add(key);
        return names.Distinct(StringComparer.OrdinalIgnoreCase).ToList();
    }
}
