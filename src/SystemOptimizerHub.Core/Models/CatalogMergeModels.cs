using System.Text.Json.Serialization;

namespace SystemOptimizerHub.Core.Models;

public sealed class CatalogMergeCacheEntry
{
    [JsonPropertyName("ProcessName")]
    public string ProcessName { get; set; } = string.Empty;

    [JsonPropertyName("WhatItIs")]
    public string WhatItIs { get; set; } = string.Empty;

    [JsonPropertyName("WhatItDoes")]
    public string WhatItDoes { get; set; } = string.Empty;

    [JsonPropertyName("SuggestedCategory")]
    public string SuggestedCategory { get; set; } = "Unknown";

    [JsonPropertyName("SuggestedPriority")]
    public string SuggestedPriority { get; set; } = "Review";

    [JsonPropertyName("ResourceProfile")]
    public string ResourceProfile { get; set; } = "Mixed";

    [JsonPropertyName("BusinessHint")]
    public string BusinessHint { get; set; } = string.Empty;

    [JsonPropertyName("ImagePath")]
    public string ImagePath { get; set; } = string.Empty;
}

public sealed class CatalogHintInput
{
    [JsonPropertyName("WhatItIs")]
    public string WhatItIs { get; set; } = string.Empty;

    [JsonPropertyName("WhatItDoes")]
    public string WhatItDoes { get; set; } = string.Empty;

    [JsonPropertyName("SuggestedCategory")]
    public string SuggestedCategory { get; set; } = string.Empty;

    [JsonPropertyName("SuggestedPriority")]
    public string SuggestedPriority { get; set; } = string.Empty;

    [JsonPropertyName("ResourceProfile")]
    public string ResourceProfile { get; set; } = string.Empty;

    [JsonPropertyName("BusinessHint")]
    public string BusinessHint { get; set; } = string.Empty;

    [JsonPropertyName("Sources")]
    public List<string> Sources { get; set; } = [];

    [JsonPropertyName("SuggestedCatalogEntry")]
    public KnownApplicationEntry? SuggestedCatalogEntry { get; set; }
}

public sealed class CatalogMergeInput
{
    [JsonPropertyName("ProcessName")]
    public string ProcessName { get; set; } = string.Empty;

    [JsonPropertyName("CacheEntry")]
    public CatalogMergeCacheEntry CacheEntry { get; set; } = new();

    [JsonPropertyName("Hint")]
    public CatalogHintInput? Hint { get; set; }

    [JsonPropertyName("Confidence")]
    public double Confidence { get; set; } = 0.98;

    [JsonPropertyName("SkipAuth")]
    public bool SkipAuth { get; set; }
}

public sealed class CatalogMergeResult
{
    [JsonPropertyName("Ok")]
    public bool Ok { get; init; }

    [JsonPropertyName("Reason")]
    public string Reason { get; init; } = string.Empty;

    [JsonPropertyName("ProcessName")]
    public string ProcessName { get; init; } = string.Empty;

    [JsonPropertyName("CatalogPath")]
    public string CatalogPath { get; init; } = string.Empty;

    [JsonPropertyName("RollbackPath")]
    public string RollbackPath { get; init; } = string.Empty;

    [JsonPropertyName("WasUpdate")]
    public bool WasUpdate { get; init; }

    [JsonPropertyName("Confidence")]
    public double Confidence { get; init; }

    [JsonPropertyName("TrustLevel")]
    public string TrustLevel { get; init; } = "T1_Delegated";
}

public sealed class PostIdentifyPipelineResult
{
    [JsonPropertyName("Skipped")]
    public bool Skipped { get; init; }

    [JsonPropertyName("Reason")]
    public string Reason { get; init; } = string.Empty;

    [JsonPropertyName("CatalogMerge")]
    public CatalogMergeResult? CatalogMerge { get; init; }
}

public sealed record OperatorAuthResult(bool Ok, bool Skipped, OperatorIdentity Identity);

public sealed record OperatorIdentity(string FullName, string UserName, string Domain, bool IsAdmin);
