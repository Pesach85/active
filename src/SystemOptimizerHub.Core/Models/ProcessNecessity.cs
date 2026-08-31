namespace SystemOptimizerHub.Core.Models;

public sealed record ProcessNecessity(
    string Level,
    string Priority,
    string Category,
    string Notes);

public enum CatalogActionKind
{
    Observe,
    ThrottleBelowNormal,
    Terminate,
    MarkWorkNecessary,
    MarkUnneeded
}

public sealed record CatalogActionBlockResult(bool Blocked, string Reason);
