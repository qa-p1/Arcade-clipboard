#ifndef AppVersion
  #define AppVersion "0.2.5"
#endif
#ifndef SourceDir
  #error SourceDir must be the Flutter Windows Release bundle
#endif
#ifndef OutputDir
  #define OutputDir "..\..\dist\packages"
#endif

; Shared per-user receipt, CLI, tasks and Apps & features metadata.
; Keep the existing Inno upgrade identity and release asset name.
#define ARCADE_ID "arcade.clipboard"
#define ARCADE_NAME "Arcade Clipboard"
#define ARCADE_VERSION AppVersion
#define ARCADE_EXE "clipboard.exe"
#define ARCADE_CLI "arcade-clipboard"
#define ARCADE_INSTALLER_ID "dev.arcade.clipboard"
#define ARCADE_CUSTOM_EVENTS
#include "arcade.iss"

[Setup]
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir={#OutputDir}
OutputBaseFilename=Arcade-Clipboard_{#AppVersion}_windows_x64-setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
RestartApplications=no
[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
[Run]
Filename: "{app}\clipboard.exe"; Description: "Open Arcade Clipboard"; Flags: nowait postinstall skipifsilent

[Code]
function ClipboardArcadeRoot: String;
begin
  Result := GetEnv('ARCADE_HOME');
  if Result = '' then Result := ExpandConstant('{localappdata}\Arcade');
end;

procedure QuitRunningClipboard;
var
  Exe: String;
  ExitCode: Integer;
begin
  Exe := ExpandConstant('{app}\{#ARCADE_EXE}');
  if FileExists(Exe) then
    Exec(Exe, '--quit', '', SW_HIDE, ewWaitUntilTerminated, ExitCode);
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  QuitRunningClipboard;
  Result := '';
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then begin
    ArcadeIntegration(True);
    RegDeleteValue(HKCU, 'Software\Microsoft\Windows\CurrentVersion\Run', 'ArcadeClipboard');
  end;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  Receipt: String;
  HadReceipt: Boolean;
begin
  if CurUninstallStep = usUninstall then begin
    Receipt := ClipboardArcadeRoot + '\installs\arcade.clipboard.json';
    HadReceipt := FileExists(Receipt);
    // Exit 10 preserves a successor's receipt. UninstallRun/UninstallDelete
    // Check functions run during setup, before ownership is known, so only
    // clean shared files here after the helper proves this copy owned them.
    ArcadeIntegration(False);
    if HadReceipt and not FileExists(Receipt) then begin
      QuitRunningClipboard;
      DeleteFile(ClipboardArcadeRoot + '\apps\arcade.clipboard.json');
      RegDeleteValue(HKCU, 'Software\Microsoft\Windows\CurrentVersion\Run', 'ArcadeClipboard');
    end;
  end;
end;

function GetCustomSetupExitCode: Integer;
begin
  if ArcadeIntegrationFailed then Result := 1 else Result := 0;
end;
