using System.Diagnostics;
using System.Text.Json;
using SystemOptimizerHub.Core.Models;

namespace SystemOptimizerHub.Windows;

public static class WindowsDefenderStatusProvider
{
    public static DefenderPlatformStatus GetStatus()
    {
        if (!OperatingSystem.IsWindows())
            return new DefenderPlatformStatus();

        try
        {
            var psi = new ProcessStartInfo
            {
                FileName = "powershell.exe",
                Arguments = "-NoProfile -Command \"Get-MpComputerStatus | ConvertTo-Json -Compress\"",
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
                CreateNoWindow = true
            };
            using var proc = Process.Start(psi);
            if (proc is null)
                return new DefenderPlatformStatus();

            var json = proc.StandardOutput.ReadToEnd();
            proc.WaitForExit(15000);
            if (string.IsNullOrWhiteSpace(json))
                return new DefenderPlatformStatus();

            using var doc = JsonDocument.Parse(json);
            var root = doc.RootElement;
            return new DefenderPlatformStatus
            {
                ModuleAvailable = true,
                RealTimeProtectionEnabled = TryBool(root, "RealTimeProtectionEnabled"),
                TamperProtectionEnabled = TryBool(root, "IsTamperProtected"),
                AmServiceEnabled = TryBool(root, "AMServiceEnabled"),
                AntivirusEnabled = TryBool(root, "AntivirusEnabled"),
                QuickScanAgeHours = TryScanAgeHours(root, "QuickScanStartTime"),
                FullScanAgeHours = TryScanAgeHours(root, "FullScanStartTime")
            };
        }
        catch
        {
            return new DefenderPlatformStatus();
        }
    }

    public static bool IsCurrentUserAdmin()
    {
        try
        {
            var id = System.Security.Principal.WindowsIdentity.GetCurrent();
            var principal = new System.Security.Principal.WindowsPrincipal(id);
            return principal.IsInRole(System.Security.Principal.WindowsBuiltInRole.Administrator);
        }
        catch
        {
            return false;
        }
    }

    private static bool? TryBool(JsonElement root, string name) =>
        root.TryGetProperty(name, out var p) &&
        (p.ValueKind == JsonValueKind.True || p.ValueKind == JsonValueKind.False)
            ? p.GetBoolean()
            : null;

    private static double? TryScanAgeHours(JsonElement root, string name)
    {
        if (!root.TryGetProperty(name, out var p) || p.ValueKind != JsonValueKind.String)
            return null;
        if (!DateTime.TryParse(p.GetString(), out var dt))
            return null;
        return Math.Round((DateTime.Now - dt).TotalHours, 1);
    }
}
