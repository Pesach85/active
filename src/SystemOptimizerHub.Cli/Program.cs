using System.CommandLine;
using System.CommandLine.Invocation;
using System.Text.Json;
using SystemOptimizerHub.Abstractions;
using SystemOptimizerHub.Core;
using SystemOptimizerHub.Core.Catalog;
using SystemOptimizerHub.Core.Models;
using SystemOptimizerHub.Core.Config;
using SystemOptimizerHub.Core.Defender;
using SystemOptimizerHub.Core.Identify;
using SystemOptimizerHub.Core.Network;
using SystemOptimizerHub.Core.Pressure;
using SystemOptimizerHub.Core.Transparency;
using SystemOptimizerHub.Core.Resolution;
using SystemOptimizerHub.Core.Scoring;
using SystemOptimizerHub.Linux;
using SystemOptimizerHub.Windows;

namespace SystemOptimizerHub.Cli;

internal static class Program
{
    private static readonly JsonSerializerOptions JsonOut = new() { WriteIndented = true };

    public static async Task<int> Main(string[] args)
    {
        var root = new RootCommand("System Optimizer Hub — cross-platform core CLI (migration preview)");

        var versionCmd = new Command("version", "Show hub core and platform version");
        versionCmd.SetHandler(() =>
        {
            var platform = ResolvePlatform();
            var info = platform.GetPlatformInfo();
            Console.WriteLine(JsonSerializer.Serialize(new
            {
                hubCore = HubVersion.Version,
                windowsLegacy = HubVersion.WindowsLegacyVersion,
                linuxPackage = HubVersion.LinuxPackageVersion,
                platform = info
            }, JsonOut));
        });
        root.AddCommand(versionCmd);

        var catalogCmd = new Command("catalog", "Process intelligence catalog operations");
        var classifyCmd = new Command("classify", "Classify process necessity from shared catalog");
        var nameOpt = new Option<string>("--name", "Process name") { IsRequired = true };
        var catalogOpt = new Option<FileInfo?>("--catalog", () => null, "Path to process-intelligence.json");
        classifyCmd.AddOption(nameOpt);
        classifyCmd.AddOption(catalogOpt);
        classifyCmd.SetHandler((name, catalogFile) =>
        {
            var catalogPath = ResolveCatalogPath(catalogFile);
            var catalog = CatalogLoader.LoadFromFile(catalogPath);
            var nec = ProcessNecessityResolver.Resolve(name, catalog);
            Console.WriteLine(JsonSerializer.Serialize(nec, JsonOut));
        }, nameOpt, catalogOpt);
        catalogCmd.AddCommand(classifyCmd);

        var blockCmd = new Command("action-blocked", "Test if catalog blocks an action (parity with PS)");
        var actionOpt = new Option<string>("--action", "Observe|ThrottleBelowNormal|Terminate|...") { IsRequired = true };
        blockCmd.AddOption(nameOpt);
        blockCmd.AddOption(actionOpt);
        blockCmd.AddOption(catalogOpt);
        blockCmd.SetHandler((name, action, catalogFile) =>
        {
            if (!Enum.TryParse<CatalogActionKind>(action, ignoreCase: true, out var kind))
            {
                Console.Error.WriteLine($"Unknown action: {action}");
                Environment.ExitCode = 2;
                return;
            }
            var catalogPath = ResolveCatalogPath(catalogFile);
            var catalog = CatalogLoader.LoadFromFile(catalogPath);
            var nec = ProcessNecessityResolver.Resolve(name, catalog);
            var block = ProcessNecessityResolver.TestCatalogActionBlocked(kind, nec);
            Console.WriteLine(JsonSerializer.Serialize(new { necessity = nec, block }, JsonOut));
        }, nameOpt, actionOpt, catalogOpt);
        catalogCmd.AddCommand(blockCmd);

        var buildEntryCmd = new Command("build-entry", "Build catalog entry draft from cache+hint (parity)");
        var mergeNameOpt = new Option<string>("--name", "Process name") { IsRequired = true };
        var catalogInputOpt = new Option<FileInfo>("--input", "CatalogMergeInput JSON") { IsRequired = true };
        buildEntryCmd.AddOption(mergeNameOpt);
        buildEntryCmd.AddOption(catalogInputOpt);
        buildEntryCmd.SetHandler((name, inputFile) =>
        {
            var input = DeserializeMergeInput(inputFile.FullName);
            var entry = CatalogMergeService.BuildCatalogEntryFromSources(
                name, input.Hint, input.CacheEntry);
            Console.WriteLine(JsonSerializer.Serialize(entry, JsonOut));
        }, mergeNameOpt, catalogInputOpt);

        var hubRootOpt = new Option<string?>("--hub-root", () => null, "Hub repository root");
        var pwdFileOpt = new Option<FileInfo?>("--password-file", () => null, "Password file (temp, deleted after read)");
        var skipAuthOpt = new Option<bool>("--skip-auth", () => false, "Skip auth (smoke/tests only)");
        var sessionTokenOpt = new Option<string?>("--session-token", () => null, "HITL session token (from auth session-start)");

        var mergeDirectCmd = new Command("merge-direct", "Direct catalog merge (parity/smoke, no HITL pipeline gate)");
        mergeDirectCmd.AddOption(mergeNameOpt);
        mergeDirectCmd.AddOption(catalogInputOpt);
        mergeDirectCmd.AddOption(catalogOpt);
        mergeDirectCmd.AddOption(hubRootOpt);
        mergeDirectCmd.SetHandler((name, inputFile, catalogFile, hubRootArg) =>
        {
            var hubRoot = ResolveHubRoot(hubRootArg);
            var input = DeserializeMergeInput(inputFile.FullName);
            var catalogPath = catalogFile?.Exists == true
                ? catalogFile.FullName
                : ResolveCatalogPath(null);
            var entry = CatalogMergeService.BuildCatalogEntryFromSources(
                name, input.Hint, input.CacheEntry);
            var merge = CatalogMergeService.MergeProcessIntoCatalog(
                hubRoot, name, entry, catalogPath, input.Confidence);
            Console.WriteLine(JsonSerializer.Serialize(merge, JsonOut));
            if (!merge.Ok)
                Environment.ExitCode = 1;
        }, mergeNameOpt, catalogInputOpt, catalogOpt, hubRootOpt);

        var mergeCmd = new Command("merge", "Merge operator-identified process into catalog (HITL pipeline)");
        mergeCmd.AddOption(catalogInputOpt);
        mergeCmd.AddOption(catalogOpt);
        mergeCmd.AddOption(hubRootOpt);
        mergeCmd.AddOption(pwdFileOpt);
        mergeCmd.AddOption(skipAuthOpt);
        mergeCmd.SetHandler((inputFile, catalogFile, hubRootArg, pwdFile, skipAuth) =>
        {
            if (!OperatingSystem.IsWindows())
            {
                Console.Error.WriteLine("catalog merge requires Windows for HITL auth.");
                Environment.ExitCode = 2;
                return;
            }

            try
            {
                var hubRoot = ResolveHubRoot(hubRootArg);
                var input = DeserializeMergeInput(inputFile.FullName);
                input.SkipAuth = skipAuth || input.SkipAuth;

                var password = ReadPassword(pwdFile);
                var auth = WindowsOperatorAuth.AssertPassword(password, input.SkipAuth);

                var pkCfg = ProcessKnowledgeConfigLoader.LoadDefault(hubRoot);
                var catalogPath = catalogFile?.Exists == true
                    ? catalogFile.FullName
                    : Path.GetFullPath(Path.Combine(hubRoot, pkCfg.CatalogPath.Replace('/', Path.DirectorySeparatorChar)));

                var pipeline = CatalogMergeService.RunPostIdentifyPipeline(
                    hubRoot, input, pkCfg, catalogPath, auth.Ok && !auth.Skipped);

                if (pipeline.Skipped)
                {
                    Console.WriteLine(JsonSerializer.Serialize(pipeline, JsonOut));
                    if (pipeline.Reason is "auth_failed" or "auth_required_for_catalog_merge")
                        Environment.ExitCode = 1;
                    return;
                }

                Console.WriteLine(JsonSerializer.Serialize(pipeline, JsonOut));
                if (pipeline.CatalogMerge is { Ok: false })
                    Environment.ExitCode = 1;
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine(ex.Message);
                Environment.ExitCode = 1;
            }
            finally
            {
                TryDeletePasswordFile(pwdFile);
            }
        }, catalogInputOpt, catalogOpt, hubRootOpt, pwdFileOpt, skipAuthOpt);

        catalogCmd.AddCommand(buildEntryCmd);
        catalogCmd.AddCommand(mergeDirectCmd);
        catalogCmd.AddCommand(mergeCmd);
        root.AddCommand(catalogCmd);

        var scoreCmd = new Command("score", "Deterministic pressure score (parity helper)");
        var cpuOpt = new Option<double>("--cpu", () => 0, "CPU percent");
        var ramOpt = new Option<double>("--ram-mb", () => 0, "RAM MB");
        var ioOpt = new Option<double>("--io-mb", () => 0, "IO MB/s");
        scoreCmd.AddOption(cpuOpt);
        scoreCmd.AddOption(ramOpt);
        scoreCmd.AddOption(ioOpt);
        scoreCmd.SetHandler((cpu, ram, io) =>
        {
            Console.WriteLine(JsonSerializer.Serialize(new
            {
                dominant = PressureScorer.DominantPressure(cpu, ram, io),
                score = PressureScorer.CompositeScore(cpu, ram, io)
            }, JsonOut));
        }, cpuOpt, ramOpt, ioOpt);
        root.AddCommand(scoreCmd);

        var resolveCmd = new Command("resolve", "Process resolution (migration preview)");
        var advisoryCmd = new Command("advisory", "Build ProcessResolutionAdvisory.v1 (parity with PS)");
        var pidOpt = new Option<int>("--pid", () => 0, "Process ID");
        var ramMbOpt = new Option<double>("--ram-mb", () => 0, "RAM MB");
        var confOpt = new Option<double>("--confidence", () => 0.55, "Knowledge hint confidence");
        var categoryOpt = new Option<string>("--category", () => "Unknown", "Suggested category");
        var trustOpt = new Option<string>("--trust-level", () => "T3_Unknown", "Trust level");
        var whatOpt = new Option<string>("--what-it-is", () => "Unknown process", "WhatItIs hint");
        var opDecOpt = new Option<string?>("--operator-decision", () => null, "WorkNecessary|Unneeded");
        var configOpt = new Option<FileInfo?>("--config", () => null, "process-resolution.json path");

        advisoryCmd.AddOption(nameOpt);
        advisoryCmd.AddOption(pidOpt);
        advisoryCmd.AddOption(ramMbOpt);
        advisoryCmd.AddOption(confOpt);
        advisoryCmd.AddOption(categoryOpt);
        advisoryCmd.AddOption(trustOpt);
        advisoryCmd.AddOption(whatOpt);
        advisoryCmd.AddOption(opDecOpt);
        advisoryCmd.AddOption(catalogOpt);
        advisoryCmd.AddOption(configOpt);

        advisoryCmd.SetHandler((InvocationContext ctx) =>
        {
            var name = ctx.ParseResult.GetValueForOption(nameOpt)!;
            var pid = ctx.ParseResult.GetValueForOption(pidOpt);
            var ramMb = ctx.ParseResult.GetValueForOption(ramMbOpt);
            var confidence = ctx.ParseResult.GetValueForOption(confOpt);
            var category = ctx.ParseResult.GetValueForOption(categoryOpt)!;
            var trustLevel = ctx.ParseResult.GetValueForOption(trustOpt)!;
            var whatItIs = ctx.ParseResult.GetValueForOption(whatOpt)!;
            var operatorDecision = ctx.ParseResult.GetValueForOption(opDecOpt);
            var catalogFile = ctx.ParseResult.GetValueForOption(catalogOpt);
            var configFile = ctx.ParseResult.GetValueForOption(configOpt);

            var catalogPath = ResolveCatalogPath(catalogFile);
            var catalog = CatalogLoader.LoadFromFile(catalogPath);
            var nec = ProcessNecessityResolver.Resolve(name, catalog);

            var configPath = configFile?.Exists == true
                ? configFile.FullName
                : TryResolveConfigPath("process-resolution.json");
            var resCfg = configPath is not null
                ? ResolutionConfigLoader.LoadFromFile(configPath)
                : ResolutionConfigLoader.CreateDefault();

            var snap = new ProcessSnapshotInput(pid, name, ramMb);
            var hint = new KnowledgeHintInput(confidence, trustLevel, whatItIs, category);
            var adv = ResolutionAdvisoryService.BuildAdvisory(snap, hint, resCfg, nec, operatorDecision);
            Console.WriteLine(JsonSerializer.Serialize(adv, JsonOut));
        });

        resolveCmd.AddCommand(advisoryCmd);

        var planCmd = new Command("plan", "Plan resolution outcome (dry-run default; no OS mutation)");
        var actionPlanOpt = new Option<string>("--action", () => "Advisory", "Observe|ThrottleBelowNormal|Terminate|Advisory|...");
        var dryRunOpt = new Option<bool>("--dry-run", () => true, "Plan only (default true)");
        var notRunningOpt = new Option<bool>("--not-running", () => false, "Treat process as not running");
        var confirmOpt = new Option<string?>("--confirm-phrase", () => null, "HITL confirm phrase");
        planCmd.AddOption(actionPlanOpt);
        planCmd.AddOption(dryRunOpt);
        planCmd.AddOption(notRunningOpt);
        planCmd.AddOption(confirmOpt);
        planCmd.AddOption(nameOpt);
        planCmd.AddOption(pidOpt);
        planCmd.AddOption(ramMbOpt);
        planCmd.AddOption(confOpt);
        planCmd.AddOption(categoryOpt);
        planCmd.AddOption(trustOpt);
        planCmd.AddOption(whatOpt);
        planCmd.AddOption(opDecOpt);
        planCmd.AddOption(catalogOpt);
        planCmd.AddOption(configOpt);
        planCmd.AddOption(skipAuthOpt);
        planCmd.SetHandler((InvocationContext ctx) =>
        {
            var action = ctx.ParseResult.GetValueForOption(actionPlanOpt)!;
            var dryRun = ctx.ParseResult.GetValueForOption(dryRunOpt);
            var notRunning = ctx.ParseResult.GetValueForOption(notRunningOpt);
            var confirmPhrase = ctx.ParseResult.GetValueForOption(confirmOpt);
            var name = ctx.ParseResult.GetValueForOption(nameOpt)!;
            var pid = ctx.ParseResult.GetValueForOption(pidOpt);
            var ramMb = ctx.ParseResult.GetValueForOption(ramMbOpt);
            var confidence = ctx.ParseResult.GetValueForOption(confOpt);
            var category = ctx.ParseResult.GetValueForOption(categoryOpt)!;
            var trustLevel = ctx.ParseResult.GetValueForOption(trustOpt)!;
            var whatItIs = ctx.ParseResult.GetValueForOption(whatOpt)!;
            var operatorDecision = ctx.ParseResult.GetValueForOption(opDecOpt);
            var skipAuth = ctx.ParseResult.GetValueForOption(skipAuthOpt);
            var catalogFile = ctx.ParseResult.GetValueForOption(catalogOpt);
            var configFile = ctx.ParseResult.GetValueForOption(configOpt);

            var catalogPath = ResolveCatalogPath(catalogFile);
            var catalog = CatalogLoader.LoadFromFile(catalogPath);
            var nec = ProcessNecessityResolver.Resolve(name, catalog);
            var configPath = configFile?.Exists == true
                ? configFile.FullName
                : TryResolveConfigPath("process-resolution.json");
            var resCfg = configPath is not null
                ? ResolutionConfigLoader.LoadFromFile(configPath)
                : ResolutionConfigLoader.CreateDefault();

            var snap = new ProcessSnapshotInput(pid, name, ramMb, notRunning);
            var hint = new KnowledgeHintInput(confidence, trustLevel, whatItIs, category);
            var adv = ResolutionAdvisoryService.BuildAdvisory(snap, hint, resCfg, nec, operatorDecision);
            var result = ResolutionExecutionService.Plan(
                action, dryRun, snap, adv, nec, resCfg, confirmPhrase, skipAuth, authVerified: skipAuth);
            Console.WriteLine(JsonSerializer.Serialize(result, JsonOut));
            if (result.Outcome is "AuthRequired" or "ConfirmPhraseRequired" or "TerminateBlocked")
                Environment.ExitCode = 1;
        });
        resolveCmd.AddCommand(planCmd);

        var applyCmd = new Command("apply", "Apply resolution action (live; requires HITL session)");
        applyCmd.AddOption(actionPlanOpt);
        applyCmd.AddOption(confirmOpt);
        applyCmd.AddOption(sessionTokenOpt);
        applyCmd.AddOption(nameOpt);
        applyCmd.AddOption(pidOpt);
        applyCmd.AddOption(ramMbOpt);
        applyCmd.AddOption(confOpt);
        applyCmd.AddOption(categoryOpt);
        applyCmd.AddOption(trustOpt);
        applyCmd.AddOption(whatOpt);
        applyCmd.AddOption(opDecOpt);
        applyCmd.AddOption(catalogOpt);
        applyCmd.AddOption(configOpt);
        applyCmd.AddOption(skipAuthOpt);
        applyCmd.SetHandler(async (InvocationContext ctx) =>
        {
            if (!OperatingSystem.IsWindows())
            {
                Console.Error.WriteLine("resolve apply requires Windows.");
                Environment.ExitCode = 2;
                return;
            }

            var action = ctx.ParseResult.GetValueForOption(actionPlanOpt)!;
            var confirmPhrase = ctx.ParseResult.GetValueForOption(confirmOpt);
            var sessionToken = ctx.ParseResult.GetValueForOption(sessionTokenOpt);
            var name = ctx.ParseResult.GetValueForOption(nameOpt)!;
            var pid = ctx.ParseResult.GetValueForOption(pidOpt);
            var ramMb = ctx.ParseResult.GetValueForOption(ramMbOpt);
            var skipAuth = ctx.ParseResult.GetValueForOption(skipAuthOpt);
            var catalogFile = ctx.ParseResult.GetValueForOption(catalogOpt);
            var configFile = ctx.ParseResult.GetValueForOption(configOpt);
            var confidence = ctx.ParseResult.GetValueForOption(confOpt);
            var category = ctx.ParseResult.GetValueForOption(categoryOpt)!;
            var trustLevel = ctx.ParseResult.GetValueForOption(trustOpt)!;
            var whatItIs = ctx.ParseResult.GetValueForOption(whatOpt)!;
            var operatorDecision = ctx.ParseResult.GetValueForOption(opDecOpt);

            var authOk = skipAuth || OperatorHitlSessionStore.TryValidate(sessionToken, out _);
            if (!authOk)
            {
                Console.Error.WriteLine("HITL session expired or missing.");
                Environment.ExitCode = 1;
                return;
            }

            var catalogPath = ResolveCatalogPath(catalogFile);
            var catalog = CatalogLoader.LoadFromFile(catalogPath);
            var nec = ProcessNecessityResolver.Resolve(name, catalog);
            var configPath = configFile?.Exists == true
                ? configFile.FullName
                : TryResolveConfigPath("process-resolution.json");
            var resCfg = configPath is not null
                ? ResolutionConfigLoader.LoadFromFile(configPath)
                : ResolutionConfigLoader.CreateDefault();

            var snap = new ProcessSnapshotInput(pid, name, ramMb);
            var hint = new KnowledgeHintInput(confidence, trustLevel, whatItIs, category);
            var adv = ResolutionAdvisoryService.BuildAdvisory(snap, hint, resCfg, nec, operatorDecision);
            var hubRoot = ResolveHubRoot(null);
            var rollbackDir = Path.Combine(hubRoot, "logs");
            var platform = WindowsPlatform.CreateServices();
            var result = await ResolutionExecutionService.ApplyAsync(
                action, snap, adv, nec, resCfg, platform.ProcessMutator,
                confirmPhrase, skipAuth, authVerified: authOk, rollbackDir);
            Console.WriteLine(JsonSerializer.Serialize(result, JsonOut));
            if (result.Outcome is "AuthRequired" or "ConfirmPhraseRequired" or "TerminateBlocked" or "ActionBlocked")
                Environment.ExitCode = 1;
        });
        resolveCmd.AddCommand(applyCmd);
        root.AddCommand(resolveCmd);

        var analyzeCmd = new Command("analyze", "Process pressure analysis (migration preview)");
        var pressureCmd = new Command("pressure", "Live Windows process pressure report");
        var durationOpt = new Option<int>("--duration", () => 6, "Sample duration seconds (2-30)");
        var topOpt = new Option<int>("--top", () => 8, "Top N processes by score");
        var outOpt = new Option<FileInfo?>("--output", () => null, "Write JSON report to file");
        pressureCmd.AddOption(durationOpt);
        pressureCmd.AddOption(topOpt);
        pressureCmd.AddOption(catalogOpt);
        pressureCmd.AddOption(outOpt);
        pressureCmd.SetHandler(async (duration, top, catalogFile, output) =>
        {
            if (!OperatingSystem.IsWindows())
            {
                Console.Error.WriteLine("analyze pressure requires Windows for live snapshot.");
                Environment.ExitCode = 2;
                return;
            }

            duration = Math.Clamp(duration, 2, 30);
            top = Math.Clamp(top, 3, 30);
            var catalogPath = ResolveCatalogPath(catalogFile);
            var catalog = CatalogLoader.LoadFromFile(catalogPath);

            var first = WindowsProcessPressureSnapshot.Capture();
            await Task.Delay(TimeSpan.FromSeconds(duration));
            var second = WindowsProcessPressureSnapshot.Capture();
            var rows = ProcessPressureAnalyzer.MeasureRows(
                first, second, duration, Environment.ProcessorCount, catalog);
            var report = ProcessPressureAnalyzer.BuildReport(
                rows, duration, Environment.ProcessorCount, top, "Windows", catalogPath);

            var json = JsonSerializer.Serialize(report, JsonOut);
            if (output is not null)
            {
                var dir = output.DirectoryName;
                if (!string.IsNullOrEmpty(dir))
                    Directory.CreateDirectory(dir);
                await File.WriteAllTextAsync(output.FullName, json);
            }
            Console.WriteLine(json);
        }, durationOpt, topOpt, catalogOpt, outOpt);

        var measureCmd = new Command("measure", "Measure pressure from snapshot JSON pairs (parity)");
        var firstOpt = new Option<FileInfo>("--first", "First snapshot JSON") { IsRequired = true };
        var secondOpt = new Option<FileInfo>("--second", "Second snapshot JSON") { IsRequired = true };
        measureCmd.AddOption(firstOpt);
        measureCmd.AddOption(secondOpt);
        measureCmd.AddOption(durationOpt);
        measureCmd.AddOption(topOpt);
        measureCmd.AddOption(catalogOpt);
        measureCmd.SetHandler((firstFile, secondFile, duration, top, catalogFile) =>
        {
            duration = Math.Clamp(duration, 2, 30);
            top = Math.Clamp(top, 3, 30);
            var catalogPath = ResolveCatalogPath(catalogFile);
            var catalog = CatalogLoader.LoadFromFile(catalogPath);

            var first = LoadSnapshotMap(firstFile.FullName);
            var second = LoadSnapshotMap(secondFile.FullName);
            var rows = ProcessPressureAnalyzer.MeasureRows(
                first, second, duration, Environment.ProcessorCount, catalog);
            var report = ProcessPressureAnalyzer.BuildReport(
                rows, duration, Environment.ProcessorCount, top, "Synthetic", catalogPath);
            Console.WriteLine(JsonSerializer.Serialize(report, JsonOut));
        }, firstOpt, secondOpt, durationOpt, topOpt, catalogOpt);

        analyzeCmd.AddCommand(pressureCmd);
        analyzeCmd.AddCommand(measureCmd);
        root.AddCommand(analyzeCmd);

        var transparencyCmd = new Command("transparency", "Transparency report (migration preview)");
        var buildCmd = new Command("build", "Build report from JSON input (parity)");
        var inputOpt = new Option<FileInfo>("--input", "TransparencyBuildInput JSON") { IsRequired = true };
        buildCmd.AddOption(inputOpt);
        buildCmd.SetHandler((inputFile) =>
        {
            var input = JsonSerializer.Deserialize<TransparencyBuildInput>(
                File.ReadAllText(inputFile.FullName),
                new JsonSerializerOptions { PropertyNameCaseInsensitive = true });
            if (input is null)
            {
                Console.Error.WriteLine("Invalid input JSON");
                Environment.ExitCode = 2;
                return;
            }
            var report = TransparencyReportBuilder.Build(input);
            Console.WriteLine(JsonSerializer.Serialize(report, JsonOut));
        }, inputOpt);

        var reportCmd = new Command("report", "Live Windows transparency report (read-only subset)");
        var topRamOpt = new Option<int>("--top", () => 15, "Top RAM consumers");
        reportCmd.AddOption(topRamOpt);
        reportCmd.AddOption(outOpt);
        reportCmd.SetHandler((topRam, output) =>
        {
            if (!OperatingSystem.IsWindows())
            {
                Console.Error.WriteLine("transparency report requires Windows.");
                Environment.ExitCode = 2;
                return;
            }

            topRam = Math.Clamp(topRam, 5, 30);
            var host = WindowsHostResourceProvider.GetSnapshot();
            var consumers = WindowsProcessPressureSnapshot.GetTopRamConsumers(topRam);
            var catalogPath = ResolveCatalogPath(null);
            var catalog = CatalogLoader.LoadFromFile(catalogPath);
            var catalogNames = CatalogLoader.ExtractProcessNames(catalog);

            var input = new TransparencyBuildInput
            {
                HostSnapshot = host,
                Profile = new OptimizationProfile { Name = "feather", Tier = "C", LlmAllowed = false },
                RamConsumers = consumers,
                Agents = TransparencyPolicy.GetAgentRegistry()
                    .Where(a => !string.IsNullOrEmpty(a.Id))
                    .Select(a => new AgentStatusRow
                    {
                        AgentId = a.Id,
                        DisplayName = a.DisplayName,
                        TaskState = "OnDemand",
                        ControlLevel = a.ControlLevel
                    }).ToList(),
                CatalogNames = catalogNames
            };

            var report = TransparencyReportBuilder.Build(input);
            var json = JsonSerializer.Serialize(report, JsonOut);
            if (output is not null)
            {
                var dir = output.DirectoryName;
                if (!string.IsNullOrEmpty(dir))
                    Directory.CreateDirectory(dir);
                File.WriteAllText(output.FullName, json);
            }
            Console.WriteLine(json);
        }, topRamOpt, outOpt);

        transparencyCmd.AddCommand(buildCmd);
        transparencyCmd.AddCommand(reportCmd);
        root.AddCommand(transparencyCmd);

        var authCmd = new Command("auth", "Operator HITL authentication (Windows)");
        var verifyCmd = new Command("verify", "Verify Windows password for HITL gate");
        verifyCmd.AddOption(pwdFileOpt);
        verifyCmd.AddOption(skipAuthOpt);
        verifyCmd.SetHandler((pwdFile, skipAuth) =>
        {
            if (!OperatingSystem.IsWindows())
            {
                Console.Error.WriteLine("auth verify requires Windows.");
                Environment.ExitCode = 2;
                return;
            }

            try
            {
                var password = ReadPassword(pwdFile);
                var result = WindowsOperatorAuth.AssertPassword(password, skipAuth);
                Console.WriteLine(JsonSerializer.Serialize(new
                {
                    ok = result.Ok,
                    skipped = result.Skipped,
                    identity = result.Identity
                }, JsonOut));
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine(ex.Message);
                Environment.ExitCode = 1;
            }
            finally
            {
                TryDeletePasswordFile(pwdFile);
            }
        }, pwdFileOpt, skipAuthOpt);

        var sessionStartCmd = new Command("session-start", "Start HITL session (~45 min; password once)");
        sessionStartCmd.AddOption(pwdFileOpt);
        sessionStartCmd.AddOption(skipAuthOpt);
        sessionStartCmd.SetHandler((pwdFile, skipAuth) =>
        {
            if (!OperatingSystem.IsWindows())
            {
                Console.Error.WriteLine("auth session-start requires Windows.");
                Environment.ExitCode = 2;
                return;
            }

            try
            {
                var password = ReadPassword(pwdFile);
                var token = WindowsOperatorAuth.StartSession(password, skipAuth);
                var identity = WindowsOperatorAuth.GetCurrentIdentity();
                Console.WriteLine(JsonSerializer.Serialize(new
                {
                    ok = true,
                    sessionToken = token,
                    expiresInMinutes = 45,
                    identity
                }, JsonOut));
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine(ex.Message);
                Environment.ExitCode = 1;
            }
            finally
            {
                TryDeletePasswordFile(pwdFile);
            }
        }, pwdFileOpt, skipAuthOpt);

        authCmd.AddCommand(sessionStartCmd);
        authCmd.AddCommand(verifyCmd);
        root.AddCommand(authCmd);

        var defenderCmd = new Command("defender", "Defender extreme necessity (evaluate + HITL apply)");
        var evalCmd = new Command("evaluate", "Evaluate MsMpEng pressure tier from PPI report JSON");
        var defenderInputOpt = new Option<FileInfo?>("--input", () => null, "ProcessPressureReport JSON");
        evalCmd.AddOption(defenderInputOpt);
        evalCmd.AddOption(catalogOpt);
        evalCmd.SetHandler((inputFile, catalogFile) =>
        {
            if (!OperatingSystem.IsWindows())
            {
                Console.Error.WriteLine("defender evaluate requires Windows for platform status.");
                Environment.ExitCode = 2;
                return;
            }

            ProcessPressureReport? report = null;
            if (inputFile is not null && inputFile.Exists)
            {
                report = JsonSerializer.Deserialize<ProcessPressureReport>(
                    File.ReadAllText(inputFile.FullName),
                    new JsonSerializerOptions { PropertyNameCaseInsensitive = true });
            }

            var catalogPath = ResolveCatalogPath(catalogFile);
            var catalog = CatalogLoader.LoadFromFile(catalogPath);
            var row = DefenderExtremeNecessityEvaluator.FindMsMpEngRow(report);
            var status = WindowsDefenderStatusProvider.GetStatus();
            var isAdmin = WindowsDefenderStatusProvider.IsCurrentUserAdmin();
            var eval = DefenderExtremeNecessityEvaluator.Evaluate(
                row, catalog.ExtremeNecessityDefender, status, isAdmin);
            Console.WriteLine(JsonSerializer.Serialize(eval, JsonOut));
        }, defenderInputOpt, catalogOpt);
        defenderCmd.AddCommand(evalCmd);

        var applyDefCmd = new Command("apply", "Apply Defender extreme-necessity tier (HITL; session required)");
        var evalFileOpt = new Option<FileInfo>("--evaluation", "DefenderExtremeNecessityEvaluation JSON") { IsRequired = true };
        var tierOpt = new Option<string>("--tier", "TuneExclusions|TemporaryRealtimeOff|ExtremeServiceDisable") { IsRequired = true };
        var reasonOpt = new Option<string>("--reason-code", () => "DevBuild", "DevBuild|EmergencyPerf|ForensicCapture|VendorSupport");
        var exclusionOpt = new Option<string[]>("--exclusion-path", () => [], "Exclusion paths (TuneExclusions)");
        var reenableOpt = new Option<int>("--auto-reenable-minutes", () => 0, "Scheduled restore delay");
        var dryRunDefOpt = new Option<bool>("--dry-run", () => false, "Plan rollback only");
        var understandOpt = new Option<bool>("--understand-risk", () => false, "HITL: I understand risk");
        var confirmExtremeOpt = new Option<bool>("--confirm-extreme-disable", () => false, "Second gate for ExtremeServiceDisable");
        var defOutOpt = new Option<FileInfo?>("--output", () => null, "Write apply result JSON");
        applyDefCmd.AddOption(evalFileOpt);
        applyDefCmd.AddOption(tierOpt);
        applyDefCmd.AddOption(reasonOpt);
        applyDefCmd.AddOption(exclusionOpt);
        applyDefCmd.AddOption(reenableOpt);
        applyDefCmd.AddOption(dryRunDefOpt);
        applyDefCmd.AddOption(understandOpt);
        applyDefCmd.AddOption(confirmExtremeOpt);
        applyDefCmd.AddOption(defOutOpt);
        applyDefCmd.AddOption(sessionTokenOpt);
        applyDefCmd.AddOption(skipAuthOpt);
        applyDefCmd.SetHandler(async (InvocationContext ctx) =>
        {
            if (!OperatingSystem.IsWindows())
            {
                Console.Error.WriteLine("defender apply requires Windows.");
                Environment.ExitCode = 2;
                return;
            }

            var evalFile = ctx.ParseResult.GetValueForOption(evalFileOpt)!;
            var tier = ctx.ParseResult.GetValueForOption(tierOpt)!;
            var reasonCode = ctx.ParseResult.GetValueForOption(reasonOpt)!;
            var exclusions = ctx.ParseResult.GetValueForOption(exclusionOpt)!;
            var reenable = ctx.ParseResult.GetValueForOption(reenableOpt);
            var dryRun = ctx.ParseResult.GetValueForOption(dryRunDefOpt);
            var understand = ctx.ParseResult.GetValueForOption(understandOpt);
            var confirmExtreme = ctx.ParseResult.GetValueForOption(confirmExtremeOpt);
            var output = ctx.ParseResult.GetValueForOption(defOutOpt);
            var sessionToken = ctx.ParseResult.GetValueForOption(sessionTokenOpt);
            var skipAuth = ctx.ParseResult.GetValueForOption(skipAuthOpt);

            if (!skipAuth && !OperatorHitlSessionStore.TryValidate(sessionToken, out _))
            {
                Console.Error.WriteLine("HITL session expired or missing.");
                Environment.ExitCode = 1;
                return;
            }

            var evaluation = JsonSerializer.Deserialize<DefenderExtremeNecessityEvaluation>(
                await File.ReadAllTextAsync(evalFile.FullName),
                new JsonSerializerOptions { PropertyNameCaseInsensitive = true });
            if (evaluation is null)
            {
                Console.Error.WriteLine("Invalid evaluation JSON.");
                Environment.ExitCode = 1;
                return;
            }

            var hubRoot = ResolveHubRoot(null);
            var options = new DefenderExtremeApplyOptions
            {
                Tier = tier,
                ReasonCode = reasonCode,
                ExclusionPaths = exclusions,
                AutoReenableMinutes = reenable,
                DryRun = dryRun,
                IUnderstandRisk = understand,
                ConfirmExtremeDisable = confirmExtreme,
                RollbackDirectory = Path.Combine(hubRoot, "logs"),
                RestoreScriptPath = Path.Combine(hubRoot, "scripts", "restore-defender-from-rollback.ps1")
            };

            try
            {
                var platform = WindowsPlatform.CreateServices();
                var result = await DefenderExtremeNecessityApplyService.ApplyAsync(
                    evaluation, options, platform.DefenderPolicy,
                    WindowsDefenderStatusProvider.GetStatus);
                var json = JsonSerializer.Serialize(result, JsonOut);
                if (output is not null)
                {
                    var dir = output.DirectoryName;
                    if (!string.IsNullOrEmpty(dir))
                        Directory.CreateDirectory(dir);
                    await File.WriteAllTextAsync(output.FullName, json);
                }
                Console.WriteLine(json);
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine(ex.Message);
                Environment.ExitCode = 1;
            }
        });
        defenderCmd.AddCommand(applyDefCmd);
        root.AddCommand(defenderCmd);

        var networkCmd = new Command("network", "Network transparency + deep scan + HITL actions");
        var netCatalogOpt = new Option<FileInfo?>("--catalog", () => null, "process-intelligence.json");
        var netOutOpt = new Option<FileInfo?>("--output", () => null, "Write JSON output");
        var netMemoryOpt = new Option<bool>("--include-memory", () => false, "Include bounded memory string scan");

        var netSnapshotCmd = new Command("snapshot", "Live network transparency snapshot");
        netSnapshotCmd.AddOption(netCatalogOpt);
        netSnapshotCmd.AddOption(netOutOpt);
        netSnapshotCmd.SetHandler(async (catalogFile, output) =>
        {
            if (!OperatingSystem.IsWindows())
            {
                Console.Error.WriteLine("network snapshot requires Windows.");
                Environment.ExitCode = 2;
                return;
            }
            var names = LoadCatalogProcessNames(ResolveCatalogPath(catalogFile));
            var capture = await WindowsNetworkProbeProvider.CaptureAsync(false);
            var snap = NetworkTransparencyService.BuildSnapshot(capture, names);
            WriteJsonOut(snap, output);
        }, netCatalogOpt, netOutOpt);
        networkCmd.AddCommand(netSnapshotCmd);

        var netDeepCmd = new Command("deep-scan", "Multi-layer network deep scan");
        netDeepCmd.AddOption(netCatalogOpt);
        netDeepCmd.AddOption(netOutOpt);
        netDeepCmd.AddOption(netMemoryOpt);
        netDeepCmd.SetHandler(async (catalogFile, output, includeMemory) =>
        {
            if (!OperatingSystem.IsWindows())
            {
                Console.Error.WriteLine("network deep-scan requires Windows.");
                Environment.ExitCode = 2;
                return;
            }
            var names = LoadCatalogProcessNames(ResolveCatalogPath(catalogFile));
            var capture = await WindowsNetworkProbeProvider.CaptureAsync(includeMemory);
            var result = NetworkDeepScanService.Scan(capture, names, includeMemory);
            WriteJsonOut(result, output);
        }, netCatalogOpt, netOutOpt, netMemoryOpt);
        networkCmd.AddCommand(netDeepCmd);

        var netActionCmd = new Command("action", "Apply HITL network action (kill connection, block IP, terminate)");
        var netActionOpt = new Option<string>("--action", "KillConnection|BlockRemoteIp|TerminateProcess") { IsRequired = true };
        var netPidOpt = new Option<int>("--pid", () => 0, "Owning process ID");
        var netProcOpt = new Option<string>("--process-name", () => "", "Process name");
        var netLocalOpt = new Option<string>("--local-address", () => "", "Local address");
        var netLocalPortOpt = new Option<int>("--local-port", () => 0, "Local port");
        var netRemoteOpt = new Option<string>("--remote-address", () => "", "Remote address");
        var netRemotePortOpt = new Option<int>("--remote-port", () => 0, "Remote port");
        var netDryOpt = new Option<bool>("--dry-run", () => false, "Plan only");
        var netRiskOpt = new Option<bool>("--understand-risk", () => false, "HITL risk acknowledgement");
        var netConfirmOpt = new Option<string?>("--confirm-phrase", () => null, "Required for BlockRemoteIp/TerminateProcess");
        netActionCmd.AddOption(netActionOpt);
        netActionCmd.AddOption(netPidOpt);
        netActionCmd.AddOption(netProcOpt);
        netActionCmd.AddOption(netLocalOpt);
        netActionCmd.AddOption(netLocalPortOpt);
        netActionCmd.AddOption(netRemoteOpt);
        netActionCmd.AddOption(netRemotePortOpt);
        netActionCmd.AddOption(netDryOpt);
        netActionCmd.AddOption(netRiskOpt);
        netActionCmd.AddOption(netConfirmOpt);
        netActionCmd.AddOption(netOutOpt);
        netActionCmd.AddOption(sessionTokenOpt);
        netActionCmd.AddOption(skipAuthOpt);
        netActionCmd.SetHandler(async (InvocationContext ctx) =>
        {
            if (!OperatingSystem.IsWindows())
            {
                Console.Error.WriteLine("network action requires Windows.");
                Environment.ExitCode = 2;
                return;
            }
            var req = new NetworkActionRequest
            {
                Action = ctx.ParseResult.GetValueForOption(netActionOpt)!,
                PID = ctx.ParseResult.GetValueForOption(netPidOpt),
                ProcessName = ctx.ParseResult.GetValueForOption(netProcOpt) ?? "",
                LocalAddress = ctx.ParseResult.GetValueForOption(netLocalOpt) ?? "",
                LocalPort = ctx.ParseResult.GetValueForOption(netLocalPortOpt),
                RemoteAddress = ctx.ParseResult.GetValueForOption(netRemoteOpt) ?? "",
                RemotePort = ctx.ParseResult.GetValueForOption(netRemotePortOpt),
                DryRun = ctx.ParseResult.GetValueForOption(netDryOpt),
                IUnderstandRisk = ctx.ParseResult.GetValueForOption(netRiskOpt),
                ConfirmPhrase = ctx.ParseResult.GetValueForOption(netConfirmOpt)
            };
            var sessionToken = ctx.ParseResult.GetValueForOption(sessionTokenOpt);
            var skipAuth = ctx.ParseResult.GetValueForOption(skipAuthOpt);
            var output = ctx.ParseResult.GetValueForOption(netOutOpt);
            var authOk = skipAuth || OperatorHitlSessionStore.TryValidate(sessionToken, out _);
            var platform = ResolvePlatform();
            var hubRoot = ResolveHubRoot(null);
            var logs = Path.Combine(hubRoot, "logs");

            NetworkActionResult result;
            if (req.DryRun)
                result = NetworkActionService.Plan(req, authOk, skipAuth);
            else
                result = await NetworkActionService.ApplyAsync(
                    req, platform.NetworkMutator, platform.ProcessMutator, authOk, skipAuth, logs);

            WriteJsonOut(result, output);
            if (result.Outcome is "AuthRequired" or "RiskAckRequired" or "ConfirmPhraseRequired" or "BlockDenied")
                Environment.ExitCode = 1;
        });
        networkCmd.AddCommand(netActionCmd);
        root.AddCommand(networkCmd);

        return await root.InvokeAsync(args);
    }

    private static IPlatformServices ResolvePlatform()
    {
        if (WindowsPlatform.IsCurrentOs())
            return WindowsPlatform.CreateServices();
        if (LinuxPlatform.IsCurrentOs())
            return LinuxPlatform.CreateServices();
        throw new PlatformNotSupportedException("Unsupported OS for platform services.");
    }

    private static string ResolveCatalogPath(FileInfo? catalogFile)
    {
        if (catalogFile is not null && catalogFile.Exists)
            return catalogFile.FullName;

        var candidates = new[]
        {
            Path.Combine(Directory.GetCurrentDirectory(), "config", "process-intelligence.json"),
            Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "..", "config", "process-intelligence.json"),
            Path.Combine(AppContext.BaseDirectory, "config", "process-intelligence.json")
        };

        foreach (var c in candidates)
        {
            var full = Path.GetFullPath(c);
            if (File.Exists(full))
                return full;
        }

        throw new FileNotFoundException("process-intelligence.json not found; pass --catalog");
    }

    private static string? TryResolveConfigPath(string fileName)
    {
        var candidates = new[]
        {
            Path.Combine(Directory.GetCurrentDirectory(), "config", fileName),
            Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "..", "config", fileName),
            Path.Combine(AppContext.BaseDirectory, "config", fileName)
        };

        foreach (var c in candidates)
        {
            var full = Path.GetFullPath(c);
            if (File.Exists(full))
                return full;
        }

        return null;
    }

    private static Dictionary<string, ProcessPressureSnapshotRow> LoadSnapshotMap(string path)
    {
        var json = File.ReadAllText(path);
        var rows = JsonSerializer.Deserialize<List<ProcessPressureSnapshotRow>>(json,
            new JsonSerializerOptions { PropertyNameCaseInsensitive = true }) ?? [];
        return rows.ToDictionary(r => r.Key, StringComparer.Ordinal);
    }

    private static string ResolveHubRoot(string? hubRootArg)
    {
        if (!string.IsNullOrWhiteSpace(hubRootArg))
            return Path.GetFullPath(hubRootArg);

        var candidates = new[]
        {
            Directory.GetCurrentDirectory(),
            Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "..", "..", ".."))
        };

        foreach (var c in candidates)
        {
            if (File.Exists(Path.Combine(c, "config", "process-intelligence.json")))
                return c;
        }

        return Directory.GetCurrentDirectory();
    }

    private static CatalogMergeInput DeserializeMergeInput(string path)
    {
        return JsonSerializer.Deserialize<CatalogMergeInput>(
            File.ReadAllText(path),
            new JsonSerializerOptions { PropertyNameCaseInsensitive = true })
            ?? throw new InvalidOperationException("Invalid catalog merge input JSON.");
    }

    private static string ReadPassword(FileInfo? pwdFile)
    {
        if (pwdFile is not null && pwdFile.Exists)
            return File.ReadAllText(pwdFile.FullName).Trim();
        return string.Empty;
    }

    private static void TryDeletePasswordFile(FileInfo? pwdFile)
    {
        if (pwdFile is null || !pwdFile.Exists)
            return;
        try { File.Delete(pwdFile.FullName); } catch { }
    }

    private static List<string> LoadCatalogProcessNames(string catalogPath)
    {
        var catalog = CatalogLoader.LoadFromFile(catalogPath);
        var names = new List<string>();
        names.AddRange(catalog.VitalExact);
        names.AddRange(catalog.SecurityExact);
        names.AddRange(catalog.KnownApplications.Keys);
        return names.Distinct(StringComparer.OrdinalIgnoreCase).ToList();
    }

    private static void WriteJsonOut(object payload, FileInfo? output)
    {
        var json = JsonSerializer.Serialize(payload, JsonOut);
        if (output is not null)
        {
            var dir = output.Directory;
            if (dir is not null && !dir.Exists)
                dir.Create();
            File.WriteAllText(output.FullName, json);
        }
        Console.WriteLine(json);
    }
}
