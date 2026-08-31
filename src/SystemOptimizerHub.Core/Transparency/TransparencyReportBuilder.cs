using SystemOptimizerHub.Core.Models;

namespace SystemOptimizerHub.Core.Transparency;

/// <summary>Port of posture + RamConsumers logic from build-transparency-report.ps1.</summary>
public static class TransparencyReportBuilder
{
    public static TransparencyReport Build(TransparencyBuildInput input)
    {
        var catalogNames = input.CatalogNames;
        var hubNames = new HashSet<string>(input.RunningHubScriptNames, StringComparer.OrdinalIgnoreCase);

        var processRows = new List<RamConsumerRow>();
        var unknownHighRam = new List<RamConsumerRow>();
        var totalRamUsedMb = 0.0;

        foreach (var proc in input.RamConsumers)
        {
            var trust = TransparencyPolicy.ResolveProcessTrustLevel(
                proc.Name, proc.ImagePath, catalogNames, hubNames);

            var row = new RamConsumerRow
            {
                Pid = proc.Pid,
                Name = proc.Name,
                RamMb = proc.RamMb,
                CpuSec = proc.CpuSec,
                TrustLevel = trust.Level,
                TrustReason = trust.Reason,
                Responding = proc.Responding
            };
            processRows.Add(row);
            totalRamUsedMb += proc.RamMb;

            if (trust.Level == "T3_Unknown" && proc.RamMb >= input.UnknownRamThresholdMb)
                unknownHighRam.Add(row);
        }

        var posture = 100;
        var postureNotes = new List<string>();

        if (input.HostSnapshot.FreeRamMb < 2048)
        {
            posture -= 25;
            postureNotes.Add("Critical free RAM below 2 GB");
        }
        else if (input.HostSnapshot.FreeRamMb < 4096)
        {
            posture -= 10;
            postureNotes.Add("Low free RAM below 4 GB");
        }

        if (input.HostSnapshot.DriveCFreePercent < 10)
        {
            posture -= 15;
            postureNotes.Add("System drive C: below 10% free");
        }

        foreach (var agent in input.Agents)
        {
            if (agent.TaskState == "Missing" &&
                agent.AgentId is "resource-monitor" or "hub-orchestrator")
            {
                posture -= 5;
                postureNotes.Add($"Expected agent missing: {agent.DisplayName}");
            }
        }

        posture -= Math.Min(30, unknownHighRam.Count * 8);
        if (unknownHighRam.Count > 0)
        {
            postureNotes.Add($"{unknownHighRam.Count} unknown high-RAM process(es) >= {input.UnknownRamThresholdMb} MB");
        }

        if (input.AutoTerminate)
        {
            posture -= 10;
            postureNotes.Add("Monitor AutoTerminate is enabled — review policy");
        }

        if (input.LlmEnabled && !input.Profile.LlmAllowed)
        {
            posture -= 15;
            postureNotes.Add("LLM enabled on Tier C host — misaligned with feather policy");
        }

        if (input.NetworkAvailable)
        {
            if (input.NetworkUnknownTrustCount > 0)
            {
                posture -= Math.Min(20, input.NetworkUnknownTrustCount * 3);
                postureNotes.Add($"{input.NetworkUnknownTrustCount} network connection(s) with T3 trust");
            }

            if (input.NetworkHiddenProcessCount > 0)
            {
                posture -= Math.Min(15, input.NetworkHiddenProcessCount * 5);
                postureNotes.Add($"{input.NetworkHiddenProcessCount} small/hidden process(es) with outbound traffic");
            }
        }
        else if (input.NetworkUnknownTrustCount == 0 && input.NetworkHiddenProcessCount == 0)
        {
            // Only add note when network was attempted but unavailable (parity: PS adds when networkEnabled but not available)
        }

        if (posture < 0)
            posture = 0;

        var grade = posture >= 85 ? "Good" : posture >= 65 ? "Review" : "Alert";

        return new TransparencyReport
        {
            GeneratedAt = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss"),
            Posture = new TransparencyPosture
            {
                Score = posture,
                Grade = grade,
                Notes = postureNotes
            },
            Host = new
            {
                Tier = input.Profile.Tier,
                Profile = input.Profile.Name,
                TotalRamGb = input.HostSnapshot.TotalRamGb,
                FreeRamMb = input.HostSnapshot.FreeRamMb,
                UsedRamMbTopN = Math.Round(totalRamUsedMb, 0),
                DriveCFreePercent = input.HostSnapshot.DriveCFreePercent,
                LogicalProcessors = input.HostSnapshot.LogicalProcessors
            },
            RamConsumers = processRows,
            UnknownHighRam = unknownHighRam,
            RegisteredAgents = input.Agents,
            DelegationManifest = TransparencyPolicy.BuildDelegationManifest(
                continuousOptimizationEnabled: false,
                autoApplySafeActions: false,
                llmEnabled: input.LlmEnabled),
            ControlLevels = new Dictionary<string, string>
            {
                ["T0_Observed"] = TransparencyPolicy.GetControlLevelLabel("T0_Observed"),
                ["T1_Delegated"] = TransparencyPolicy.GetControlLevelLabel("T1_Delegated"),
                ["T2_Review"] = TransparencyPolicy.GetControlLevelLabel("T2_Review"),
                ["T3_Unknown"] = TransparencyPolicy.GetControlLevelLabel("T3_Unknown")
            }
        };
    }
}
