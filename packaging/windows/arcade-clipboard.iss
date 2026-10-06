#ifndef AppVersion
  #define AppVersion "0.1.0"
#endif
#ifndef SourceDir
  #error SourceDir must be the Flutter Windows Release bundle
#endif
#ifndef OutputDir
  #define OutputDir "..\..\dist\packages"
#endif
[Setup]
AppId=dev.arcade.clipboard
AppName=Arcade Clipboard
AppVersion={#AppVersion}
AppPublisher=Arcade
DefaultDirName={localappdata}\Programs\Arcade Clipboard
DefaultGroupName=Arcade Clipboard
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir={#OutputDir}
OutputBaseFilename=Arcade-Clipboard_{#AppVersion}_windows_x64-setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
RestartApplications=no
UninstallDisplayIcon={app}\clipboard.exe
[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
[Icons]
Name: "{group}\Arcade Clipboard"; Filename: "{app}\clipboard.exe"
[Run]
Filename: "{app}\clipboard.exe"; Description: "Open Arcade Clipboard"; Flags: nowait postinstall skipifsilent
[UninstallRun]
Filename: "{app}\clipboard.exe"; Parameters: "--quit"; Flags: runhidden skipifdoesntexist; RunOnceId: "QuitClipboard"
[UninstallDelete]
Type: files; Name: "{localappdata}\Arcade\apps\arcade.clipboard.json"
