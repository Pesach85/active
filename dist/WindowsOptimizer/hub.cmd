@echo off
setlocal
set HUB_DIR=%~dp0hub
dotnet "%HUB_DIR%\SystemOptimizerHub.Cli.dll" %*
