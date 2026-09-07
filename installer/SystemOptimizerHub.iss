; System Optimizer Hub — Inno Setup script (optional production installer)
; Build: iscc installer\SystemOptimizerHub.iss
; Dev phase: prefer scripts\install-windows-app.ps1 -DevSync

#define MyAppName "System Optimizer Hub"
#define MyAppVersion "0.8.0"
#define MyAppPublisher "SystemOptimizerHub"
#define MyAppURL "https://github.com/Pesach85/active"
#define MyDist "..\dist\WindowsOptimizer"

[Setup]
AppId={{A1B2C3D4-E5F6-7890-ABCD-EF1234567890}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
DefaultDirName={localappdata}\Programs\SystemOptimizerHub\app
DisableProgramGroupPage=yes
OutputDir=..\dist\installer
OutputBaseFilename=SystemOptimizerHub-Setup-{#MyAppVersion}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "italian"; MessagesFile: "compiler:Languages\Italian.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"
Name: "quicklaunch"; Description: "Quick launch icon"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#MyDist}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\Launch-Hub.bat"; WorkingDir: "{app}"
Name: "{autoprograms}\Hub Transparency Web"; Filename: "{app}\Launch-Transparency-Web.bat"; WorkingDir: "{app}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\Launch-Hub.bat"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{app}\Launch-Hub.bat"; Description: "Launch {#MyAppName}"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
Type: filesandordirs; Name: "{localappdata}\Programs\SystemOptimizerHub"
