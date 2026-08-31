using System.Text.RegularExpressions;

namespace SystemOptimizerHub.Core.Catalog;

internal static partial class ProcessNameMatcher
{
    public static bool Matches(string processName, IEnumerable<string> exact, IEnumerable<string> patterns)
    {
        foreach (var e in exact)
        {
            if (string.Equals(processName, e, StringComparison.OrdinalIgnoreCase))
                return true;
        }

        foreach (var pattern in patterns)
        {
            if (string.IsNullOrWhiteSpace(pattern))
                continue;
            try
            {
                if (Regex.IsMatch(processName, pattern, RegexOptions.IgnoreCase | RegexOptions.CultureInvariant))
                    return true;
            }
            catch (RegexParseException)
            {
                // PS allows invalid patterns silently; skip on parse failure
            }
        }

        return false;
    }
}
