using System.Diagnostics;
using System.Text.Json;
using SystemOptimizerHub.Abstractions;

namespace SystemOptimizerHub.Windows;

public sealed class WindowsDefenderPolicyMutator : IDefenderPolicyMutator
{
    public Task AddExclusionPathAsync(string path, CancellationToken ct = default)
    {
        RunPs($"Add-MpPreference -ExclusionPath '{EscapePs(path)}' -ErrorAction Stop");
        return Task.CompletedTask;
    }

    public Task SetRealtimeMonitoringAsync(bool enabled, CancellationToken ct = default)
    {
        var val = enabled ? "$false" : "$true";
        RunPs($"Set-MpPreference -DisableRealtimeMonitoring {val} -ErrorAction Stop");
        return Task.CompletedTask;
    }

    public Task<DefenderServiceState?> GetWinDefendServiceStateAsync(CancellationToken ct = default)
    {
        var json = RunPs("(Get-Service -Name WinDefend -ErrorAction SilentlyContinue | Select-Object Name, StartType, Status | ConvertTo-Json -Compress)");
        if (string.IsNullOrWhiteSpace(json))
            return Task.FromResult<DefenderServiceState?>(null);

        using var doc = JsonDocument.Parse(json);
        var root = doc.RootElement;
        return Task.FromResult<DefenderServiceState?>(new DefenderServiceState(
            root.GetProperty("Name").GetString() ?? "WinDefend",
            root.GetProperty("StartType").GetString() ?? "Unknown",
            root.GetProperty("Status").GetString() ?? "Unknown"));
    }

    public Task StopWinDefendServiceAsync(CancellationToken ct = default)
    {
        RunPs("Stop-Service -Name WinDefend -Force -ErrorAction Stop");
        return Task.CompletedTask;
    }

    public Task SetWinDefendStartupManualAsync(CancellationToken ct = default)
    {
        RunPs("Set-Service -Name WinDefend -StartupType Manual -ErrorAction Stop");
        return Task.CompletedTask;
    }

    public Task RegisterRollbackReenableTaskAsync(
        string rollbackJsonPath, string restoreScriptPath, int delayMinutes, string taskName, CancellationToken ct = default)
    {
        var runAt = DateTime.Now.AddMinutes(delayMinutes);
        var arg = $"-NoProfile -ExecutionPolicy Bypass -File \\\"{restoreScriptPath}\\\" -RollbackJson \\\"{rollbackJsonPath}\\\"";
        var script =
            "$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '" + arg + "'; " +
            $"$trigger = New-ScheduledTaskTrigger -Once -At '{runAt:yyyy-MM-dd HH:mm:ss}'; " +
            $"Register-ScheduledTask -TaskName '{EscapePs(taskName)}' -Action $action -Trigger $trigger -RunLevel Highest -Force | Out-Null";
        RunPs(script);
        return Task.CompletedTask;
    }

    private static string RunPs(string command)
    {
        var psi = new ProcessStartInfo
        {
            FileName = "powershell.exe",
            Arguments = $"-NoProfile -Command \"{command.Replace("\"", "`\"")}\"",
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true
        };
        using var proc = Process.Start(psi) ?? throw new InvalidOperationException("Failed to start PowerShell.");
        var stdout = proc.StandardOutput.ReadToEnd();
        var stderr = proc.StandardError.ReadToEnd();
        proc.WaitForExit(120_000);
        if (proc.ExitCode != 0)
            throw new InvalidOperationException(string.IsNullOrWhiteSpace(stderr) ? stdout : stderr);
        return stdout.Trim();
    }

    private static string EscapePs(string s) => s.Replace("'", "''");
}
