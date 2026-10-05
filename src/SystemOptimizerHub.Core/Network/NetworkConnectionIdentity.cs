using System.Globalization;
using System.Net;
using SystemOptimizerHub.Core.Models;

namespace SystemOptimizerHub.Core.Network;

/// <summary>
/// TCP connection identity already present on <see cref="NetworkTcpMapRow"/>:
/// local address, local port, remote address, remote port, and owning PID.
/// The snapshot source is TCP-only. State is not part of the key.
/// </summary>
public static class NetworkConnectionIdentity
{
    public static bool TryParseEndpoint(string? endpoint, out string address, out int port)
    {
        address = "";
        port = 0;
        if (string.IsNullOrWhiteSpace(endpoint))
            return false;

        var idx = endpoint.LastIndexOf(':');
        if (idx <= 0)
            return false;
        if (!int.TryParse(endpoint[(idx + 1)..], NumberStyles.Integer, CultureInfo.InvariantCulture, out port) || port <= 0)
            return false;

        address = endpoint[..idx].Trim();
        return address.Length > 0;
    }

    /// <summary>
    /// Same IP address. IPv4 and IPv6 are never equivalent, including IPv4-mapped IPv6.
    /// </summary>
    public static bool AddressEquals(string? left, string? right)
    {
        var a = (left ?? "").Trim();
        var b = (right ?? "").Trim();
        if (IPAddress.TryParse(a, out var ia) && IPAddress.TryParse(b, out var ib))
            return ia.Equals(ib);
        return string.Equals(a, b, StringComparison.OrdinalIgnoreCase);
    }

    /// <summary>
    /// <paramref name="pid"/> null matches the endpoint only. A value, including 0, must equal the row PID.
    /// </summary>
    public static bool SameConnection(
        NetworkTcpMapRow? row,
        string? localAddress,
        int localPort,
        string? remoteAddress,
        int remotePort,
        int? pid)
    {
        if (row is null || localPort <= 0 || remotePort <= 0)
            return false;
        if (!TryParseEndpoint(row.Local, out var local, out var localEndpointPort))
            return false;
        if (!TryParseEndpoint(row.Remote, out var remote, out var remoteEndpointPort))
            return false;
        if (localEndpointPort != localPort || remoteEndpointPort != remotePort)
            return false;
        if (!AddressEquals(local, localAddress) || !AddressEquals(remote, remoteAddress))
            return false;
        if (pid is int required && row.PID != required)
            return false;
        return true;
    }

    public static List<NetworkTcpMapRow> Find(
        IReadOnlyList<NetworkTcpMapRow> rows,
        string? localAddress,
        int localPort,
        string? remoteAddress,
        int remotePort,
        int? pid)
    {
        var matches = new List<NetworkTcpMapRow>();
        foreach (var row in rows)
        {
            if (SameConnection(row, localAddress, localPort, remoteAddress, remotePort, pid))
                matches.Add(row);
        }
        return matches;
    }
}
