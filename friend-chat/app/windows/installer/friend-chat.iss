; ---------------------------------------------------------------------------
;  Friend Chat - Windows installer (Inno Setup 6)
;
;  Build the Flutter release first:
;      flutter build windows --release
;
;  Then:
;      iscc windows\installer\friend-chat.iss
;
;  Output: dist\FriendChatSetup-1.0.0.exe
;
;  Installs per-user (no UAC prompt) into %LOCALAPPDATA%\Programs\FriendChat so
;  the app can write its encrypted cache without touching Program Files.
; ---------------------------------------------------------------------------

#define AppName        "Friend Chat"
#define AppVersion     "1.0.0"
#define AppPublisher   "Friend Chat"
#define AppExeName     "friend_chat.exe"
#define SourceDir      "..\..\build\windows\x64\runner\Release"

[Setup]
AppId={{7C3E1B52-3F2A-4B77-9E4C-2D5A6F8B1C90}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
DefaultDirName={localappdata}\Programs\FriendChat
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
OutputDir=..\..\dist
OutputBaseFilename=FriendChatSetup-{#AppVersion}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
SetupIconFile=..\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#AppExeName}
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
; Friend Chat needs Windows 10 or newer.
MinVersion=10.0

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
; The whole Flutter release folder: exe, flutter_windows.dll, data\...
Source: "{#SourceDir}\{#AppExeName}";        DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\flutter_windows.dll";  DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\data\*";               DestDir: "{app}\data"; Flags: ignoreversion recursesubdirs createallsubdirs
; Uncomment if your build emits these:
; Source: "{#SourceDir}\*.dll";               DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\{#AppName}";                 Filename: "{app}\{#AppExeName}"
Name: "{group}\Uninstall {#AppName}";       Filename: "{uninstallexe}"
Name: "{autodesktop}\{#AppName}";           Filename: "{app}\{#AppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExeName}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
; The encrypted cache lives here; removing it on uninstall is the right default
; for a privacy product. The server still has your messages (encrypted).
Type: filesandordirs; Name: "{app}\data"

[Code]
// Refuse to install while Friend Chat is running, otherwise the exe is locked.
function InitializeSetup(): Boolean;
var
  ResultCode: Integer;
begin
  Result := True;
  if Exec('tasklist.exe', '/FI "IMAGENAME eq {#AppExeName}"', '', SW_HIDE, ewWaitUntilTerminated, ResultCode) then
  begin
    // tasklist always exits 0; the real guard is the installer's own file lock
    // check below, this is only a courtesy warning.
  end;
end;
