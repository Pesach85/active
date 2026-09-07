namespace SystemOptimizerHub.Windows;

/// <summary>In-process HITL session tokens (GUI/CLI same process). Not persisted across restarts.</summary>
public static class OperatorHitlSessionStore
{
    private static readonly object Gate = new();
    private static readonly Dictionary<string, SessionEntry> Sessions = new(StringComparer.Ordinal);

    public sealed record SessionEntry(
        string Token,
        string IdentityFullName,
        DateTime ExpiresAt,
        bool RiskAcknowledged);

    public static string Start(string identityFullName, TimeSpan ttl, bool riskAcknowledged = true)
    {
        var token = Guid.NewGuid().ToString("N");
        var entry = new SessionEntry(token, identityFullName, DateTime.UtcNow.Add(ttl), riskAcknowledged);
        lock (Gate)
        {
            PurgeExpiredLocked();
            Sessions[token] = entry;
        }
        return token;
    }

    public static bool TryValidate(string? token, out SessionEntry? entry)
    {
        entry = null;
        if (string.IsNullOrWhiteSpace(token))
            return false;

        lock (Gate)
        {
            PurgeExpiredLocked();
            if (!Sessions.TryGetValue(token, out var e))
                return false;
            if (e.ExpiresAt <= DateTime.UtcNow)
            {
                Sessions.Remove(token);
                return false;
            }
            entry = e;
            return true;
        }
    }

    public static void Clear(string? token)
    {
        if (string.IsNullOrWhiteSpace(token))
            return;
        lock (Gate)
            Sessions.Remove(token);
    }

    private static void PurgeExpiredLocked()
    {
        var now = DateTime.UtcNow;
        foreach (var key in Sessions.Where(kv => kv.Value.ExpiresAt <= now).Select(kv => kv.Key).ToList())
            Sessions.Remove(key);
    }
}
