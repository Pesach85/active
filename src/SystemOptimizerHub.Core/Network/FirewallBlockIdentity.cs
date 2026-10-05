using System.Net;
using System.Net.Sockets;
using SystemOptimizerHub.Core.Models;

namespace SystemOptimizerHub.Core.Network;

/// <summary>
/// BlockRemoteIp identity: one remote IP, proven by the named outbound Block rule.
/// A prefix other than a single host, or a different address, is not that target.
/// </summary>
public static class FirewallBlockIdentity
{
    public static bool IsSingleIp(string? address)
    {
        if (string.IsNullOrWhiteSpace(address))
            return false;
        if (!string.Equals(address, address.Trim(), StringComparison.Ordinal))
            return false;
        if (address.Contains('/') || address.Contains(',') || address.Contains(' ') ||
            address.Contains('-') || address.Contains('%'))
            return false;
        return IPAddress.TryParse(address, out _);
    }

    public static bool IsProvenBlock(FirewallBlockObservation? observed, string ruleName, string remoteAddress)
    {
        if (observed is not { Found: true, Enabled: true })
            return false;
        if (!string.Equals(observed.RuleName, ruleName, StringComparison.Ordinal))
            return false;
        if (!observed.Direction.Equals("Outbound", StringComparison.OrdinalIgnoreCase))
            return false;
        if (!observed.Action.Equals("Block", StringComparison.OrdinalIgnoreCase))
            return false;
        return RemoteAddressMatches(observed.RemoteAddress, remoteAddress);
    }

    public static bool RemoteAddressMatches(string? observed, string? requested)
    {
        if (string.IsNullOrWhiteSpace(observed) || string.IsNullOrWhiteSpace(requested))
            return false;
        var parts = observed.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        if (parts.Length != 1)
            return false;

        var token = parts[0];
        var slash = token.IndexOf('/');
        if (slash < 0)
            return NetworkConnectionIdentity.AddressEquals(token, requested);

        if (!IPAddress.TryParse(requested, out var requestedIp))
            return false;
        var ip = token[..slash];
        var prefix = token[(slash + 1)..];
        if (!NetworkConnectionIdentity.AddressEquals(ip, requested))
            return false;
        if (requestedIp.AddressFamily == AddressFamily.InterNetwork)
            return prefix is "32" or "255.255.255.255";
        if (requestedIp.AddressFamily == AddressFamily.InterNetworkV6)
            return prefix is "128";
        return false;
    }
}
