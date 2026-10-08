; Compile with /DAppVersion=1.0.0 /DReleaseTag=v1.0.0.
; Keep AppId stable for all future upgrades.
#ifndef AppVersion
  #error AppVersion must be supplied by the packaging script
#endif
#ifndef ReleaseTag
  #define ReleaseTag AppVersion
#endif
#ifndef BundleDir
  #define BundleDir "..\app\build\windows\x64\runner\Release"
#endif
#ifndef OutputDir
  #define OutputDir "..\app\dist"
#endif
#ifndef InstallerAppId
  #define InstallerAppId "{{0B776376-6C81-4E22-A7BE-536AB042D5DC}"
#endif
#ifndef InstallPrivileges
  #define InstallPrivileges "admin"
#endif
#ifndef RunningMutex
  #define RunningMutex "Global\AVNetworkToolbag.Running"
#endif

[Setup]
AppId={#InstallerAppId}
AppName=AV Network Toolbag
AppVersion={#AppVersion}
AppPublisher=AV Network Toolbag contributors
AppPublisherURL=https://github.com/mefranklin6/AV-Network-Toolbag
AppSupportURL=https://github.com/mefranklin6/AV-Network-Toolbag/issues
AppUpdatesURL=https://github.com/mefranklin6/AV-Network-Toolbag/releases/latest
DefaultDirName={autopf}\AV Network Toolbag
DefaultGroupName=AV Network Toolbag
DisableProgramGroupPage=yes
DisableDirPage=auto
PrivilegesRequired={#InstallPrivileges}
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
OutputDir={#OutputDir}
OutputBaseFilename=AV-Network-Toolbag-{#ReleaseTag}-windows-x64-Setup
SetupIconFile=..\assets\avnt.ico
UninstallDisplayIcon={app}\av_network_toolbag.exe
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
AppMutex={#RunningMutex}
SetupMutex=Global\AVNetworkToolbag.Setup
CloseApplications=no
RestartApplications=no

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; Flags: unchecked

[Files]
Source: "{#BundleDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\AV Network Toolbag"; Filename: "{app}\av_network_toolbag.exe"; WorkingDir: "{app}"
Name: "{autodesktop}\AV Network Toolbag"; Filename: "{app}\av_network_toolbag.exe"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{app}\av_network_toolbag.exe"; Description: "Open AV Network Toolbag"; WorkingDir: "{app}"; Flags: nowait postinstall skipifsilent runascurrentuser

[UninstallDelete]
Type: files; Name: "{app}\installed.location"

[Code]
procedure CurStepChanged(CurStep: TSetupStep);
var
  Location: TArrayOfString;
begin
  if CurStep = ssPostInstall then
  begin
    SetArrayLength(Location, 1);
    Location[0] := ExpandConstant('{app}');
    if not SaveStringsToUTF8File(ExpandConstant('{app}\installed.location'),
        Location, False) then
      RaiseException('Could not record the installation location. Please run Setup again.');
  end;
end;
