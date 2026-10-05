#ifndef AppVersion
  #error AppVersion must be supplied by the release workflow
#endif
#ifndef SourceDir
  #define SourceDir "..\..\build\windows\x64\runner\Release"
#endif

[Setup]
AppId={{15DE508E-BC77-4B03-B57E-9C8B7B83986A}
AppName=TrueNavo
AppVersion={#AppVersion}
AppPublisher=Theorvane
AppPublisherURL=https://github.com/Theorvane
AppSupportURL=https://github.com/Theorvane/TrueNavo/issues
DefaultDirName={localappdata}\Programs\TrueNavo
DefaultGroupName=TrueNavo
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64
ArchitecturesInstallIn64BitMode=x64
OutputDir=..\..\..\..\dist
OutputBaseFilename=truenavo-windows-x64-setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
UninstallDisplayName=TrueNavo
UninstallDisplayIcon={app}\truenavo.exe

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\TrueNavo"; Filename: "{app}\truenavo.exe"
Name: "{autodesktop}\TrueNavo"; Filename: "{app}\truenavo.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\truenavo.exe"; Description: "{cm:LaunchProgram,TrueNavo}"; Flags: nowait postinstall skipifsilent
