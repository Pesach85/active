# SystemOptimizerHub — C# Core (migration preview)

Cross-platform domain core replacing PowerShell logic incrementally.

## Version

- **Hub Core / CLI:** 0.2.0
- **Windows PS legacy:** 3.11.x (production until parity gate)
- **Linux package:** 0.2.0

## Build

```bash
dotnet build src/SystemOptimizerHub.sln
dotnet test src/SystemOptimizerHub.sln
```

## CLI

```bash
dotnet run --project src/SystemOptimizerHub.Cli -- version
dotnet run --project src/SystemOptimizerHub.Cli -- catalog classify --name MsMpEng
```

## Docs

- [ADR-0007](../docs/architecture/adr/ADR-0007-cross-platform-csharp-core.md)
- [Cross-platform core](../docs/architecture/cross-platform-core.md)
- [Migration roadmap](../docs/architecture/migration-roadmap.md)
