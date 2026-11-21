#define AppName "Sweep"

[Setup]
AppId=Sweep.Arkwae99
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher=Arkwae99
AppPublisherURL=https://github.com/Arkwae99/sweep
DefaultDirName={localappdata}\Programs\Sweep
DisableProgramGroupPage=yes
UninstallDisplayIcon={app}\Sweep.exe
PrivilegesRequired=lowest
ArchitecturesAllowed={#AppArch}
ArchitecturesInstallIn64BitMode={#AppArch}
MinVersion=10.0.22000
OutputBaseFilename=Sweep-Windows-{#AppArch}-Setup
SetupIconFile=..\Sweep.App\Sweep.ico
Compression=lzma2
SolidCompression=yes
WizardStyle=modern

[Files]
Source: "{#AppSource}\*"; DestDir: "{app}"; Excludes: "*.pdb"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "..\..\LICENSE"; DestDir: "{app}"; DestName: "LICENSE.txt"; Flags: ignoreversion

[Icons]
Name: "{userprograms}\Sweep"; Filename: "{app}\Sweep.exe"

[Run]
Filename: "{app}\Sweep.exe"; Description: "Launch Sweep"; Flags: nowait postinstall skipifsilent
