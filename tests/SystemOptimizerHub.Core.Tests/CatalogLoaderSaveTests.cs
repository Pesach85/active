using System.Text.Json;
using System.Text.Json.Nodes;
using SystemOptimizerHub.Core.Catalog;
using SystemOptimizerHub.Core.Models;

namespace SystemOptimizerHub.Core.Tests;

public class CatalogLoaderSaveTests
{
    [Fact]
    public void SaveToFile_Preserves_Extension_Properties()
    {
        var dir = Path.Combine(Path.GetTempPath(), "hub-catalog-save-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(dir);
        var path = Path.Combine(dir, "catalog.json");
        File.WriteAllText(path, """
            {
              "SchemaVersion": "ProcessIntelligence.v1",
              "vitalExact": ["System"],
              "securityExact": ["MsMpEng"],
              "extremeNecessityDefender": { "neverAutoApply": true },
              "knownApplications": {}
            }
            """);

        try
        {
            var catalog = CatalogLoader.LoadFromFile(path);
            catalog.KnownApplications["testproc"] = new KnownApplicationEntry
            {
                Category = "Other",
                Priority = "Review",
                Description = "test"
            };
            CatalogLoader.SaveToFile(path, catalog);

            var root = JsonNode.Parse(File.ReadAllText(path))!.AsObject();
            Assert.NotNull(root["extremeNecessityDefender"]);
            Assert.NotNull(root["knownApplications"]?["testproc"]);
        }
        finally
        {
            Directory.Delete(dir, true);
        }
    }
}
