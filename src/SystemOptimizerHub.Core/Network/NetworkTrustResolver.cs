using SystemOptimizerHub.Core.Models;

namespace SystemOptimizerHub.Core.Network;

public static class NetworkTrustResolver
{
    private static readonly HashSet<string> OsCoreNames = new(StringComparer.OrdinalIgnoreCase)
    {
        "System", "svchost", "lsass", "services", "dns", "SearchApp"
    };

    private static readonly HashSet<string> ToolchainNames = new(StringComparer.OrdinalIgnoreCase)
    {
        "Cursor", "Code", "chrome", "msedge", "firefox", "pwsh", "powershell", "WindowsOptimizer", "SystemOptimizer"
    };

    public static (string Level, string Reason, string AgentId) Resolve(
        string remoteAddress,
        int remotePort,
        int localPort,
        string state,
        string processName,
        IReadOnlyCollection<string> catalogNames)
    {
        if (localPort == 8765 || remotePort == 8765)
            return ("T1_Delegated", "Hub transparency web (localhost)", "transparency-web");
        if (localPort == 11434 || remotePort == 11434)
            return ("T2_Review", "Ollama local advisory port", "ollama-advisory");
        if (IsLoopback(remoteAddress))
            return ("T0_Observed", "Loopback-only traffic", "loopback");

        if (catalogNames.Contains(processName, StringComparer.OrdinalIgnoreCase))
        {
            var level = IsPrivate(remoteAddress) ? "T1_Delegated" : "T2_Review";
            return (level, "Catalog process with network I/O", "ppi-catalog");
        }

        if (OsCoreNames.Contains(processName))
            return ("T0_Observed", "OS core networking", "trusted-os");

        if (ToolchainNames.Contains(processName))
        {
            var level = IsPrivate(remoteAddress) ? "T0_Observed" : "T2_Review";
            return (level, "Operator toolchain network", "trusted-toolchain");
        }

        if (IsPrivate(remoteAddress))
            return ("T2_Review", "Private LAN endpoint - verify business need", "");

        if (remotePort is 80 or 443 && state.Equals("Established", StringComparison.OrdinalIgnoreCase))
            return ("T2_Review", "Outbound web - verify destination", "");

        return ("T3_Unknown", "Unattributed network I/O", "");
    }

    public static bool IsLoopback(string address) =>
        address is "127.0.0.1" or "::1" or "0.0.0.0" or "::" or "" ||
        address.StartsWith("127.", StringComparison.Ordinal);

    public static bool IsPrivate(string address)
    {
        if (IsLoopback(address)) return true;
        if (address.StartsWith("10.", StringComparison.Ordinal)) return true;
        if (address.StartsWith("192.168.", StringComparison.Ordinal)) return true;
        if (address.StartsWith("fe80:", StringComparison.OrdinalIgnoreCase)) return true;
        if (address.StartsWith("fd", StringComparison.OrdinalIgnoreCase)) return true;
        if (address.StartsWith("172.", StringComparison.Ordinal))
        {
            var parts = address.Split('.');
            if (parts.Length >= 2 && int.TryParse(parts[1], out var second))
                return second is >= 16 and <= 31;
        }
        return false;
    }
}
