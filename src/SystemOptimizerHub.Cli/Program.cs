using System.CommandLine;
using System.CommandLine.Invocation;
using System.Text.Json;
using SystemOptimizerHub.Abstractions;
using SystemOptimizerHub.Core;
using SystemOptimizerHub.Core.Catalog;
using SystemOptimizerHub.Core.Models;
using SystemOptimizerHub.Core.Config;
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
        root.AddCommand(resolveCmd);

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
}
