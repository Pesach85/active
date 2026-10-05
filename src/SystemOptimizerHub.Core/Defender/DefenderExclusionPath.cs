namespace SystemOptimizerHub.Core.Defender;

/// <summary>
/// Compares Defender exclusion paths without treating a longer path as a match.
/// </summary>
public static class DefenderExclusionPath
{
    public static string Normalize(string? path)
    {
        if (string.IsNullOrWhiteSpace(path))
            return string.Empty;

        var value = path.Trim().Replace('/', '\\');
        while (value.Length > 3 && value.EndsWith('\\'))
            value = value[..^1];
        return value;
    }

    public static bool Equivalent(string? requested, string? actual)
    {
        var left = Normalize(requested);
        var right = Normalize(actual);
        if (left.Length == 0 || right.Length == 0)
            return false;
        return string.Equals(left, right, StringComparison.OrdinalIgnoreCase);
    }

    public static bool ListContains(IEnumerable<string> actual, string requested) =>
        actual.Any(path => Equivalent(requested, path));
}
