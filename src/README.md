# SystemOptimizerHub — C# Core (migration preview)

Cross-platform domain core replacing PowerShell logic incrementally.

## Version

- **Hub Core / CLI:** 0.5.0
- **Windows PS legacy:** 3.11.x (production until parity gate)
- **Linux package:** 0.5.0

## Build

```bash
dotnet build src/SystemOptimizerHub.sln
dotnet test src/SystemOptimizerHub.sln
```

## CLI

```bash
dotnet run --project src/SystemOptimizerHub.Cli -- version
dotnet run --project src/SystemOptimizerHub.Cli -- catalog classify --name MsMpEng
dotnet run --project src/SystemOptimizerHub.Cli -- analyze measure --first logs/parity-ppi-first.json --second logs/parity-ppi-second.json --duration 6
dotnet run --project src/SystemOptimizerHub.Cli -- transparency build --input logs/parity-transparency-input.json
dotnet run --project src/SystemOptimizerHub.Cli -- analyze pressure --duration 6 --top 8
dotnet run --project src/SystemOptimizerHub.Cli -- catalog merge-direct --name X --input logs/smoke-hub-catalog-merge-input.json --catalog config/process-intelligence.json --hub-root .
dotnet run --project src/SystemOptimizerHub.Cli -- auth verify --skip-auth
```

## Docs

- [ADR-0007](../docs/architecture/adr/ADR-0007-cross-platform-csharp-core.md)
- [Cross-platform core](../docs/architecture/cross-platform-core.md)
- [Migration roadmap](../docs/architecture/migration-roadmap.md)
