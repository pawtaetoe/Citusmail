; Fmail installer for Windows (Inno Setup 6).
;
; Built in CI from the Windows release build:
;   iscc /DAppVersion=0.1.0 packaging\windows\fmail.iss
;
; Installs for the current user only (no administrator rights), into
; %LOCALAPPDATA%\Programs\Fmail. The installer is not code-signed yet, so
; Windows SmartScreen shows "unknown publisher".
;
; Uninstalling removes the program but keeps the user's local data
; (%APPDATA%\cc.tommykung\Fmail: encrypted mail cache) and the keychain
; entries, so reinstalling keeps accounts.

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif

[Setup]
AppId={{72FE6F92-E5D1-453E-90CD-EC6D87A97B14}
AppName=Fmail
AppVersion={#AppVersion}
AppPublisher=Fmail developers
DefaultDirName={autopf}\Fmail
DefaultGroupName=Fmail
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=..\..\build\packages
OutputBaseFilename=fmail-setup-{#AppVersion}
SetupIconFile=..\..\app\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\fmail.exe
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
LicenseFile=..\..\LICENSE

[Files]
Source: "..\..\app\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
; The AppUserModelID and toast activator must match the app's notification
; settings (lib/src/services/mail_notifier.dart); Windows only shows an
; unpackaged app's notifications through such a shortcut.
Name: "{autoprograms}\Fmail"; Filename: "{app}\fmail.exe"; AppUserModelID: "Fmail.Fmail.Mail"; AppUserModelToastActivatorCLSID: "F3792BC8-AF63-47A7-914B-A8425569FC47"

[Run]
Filename: "{app}\fmail.exe"; Description: "Start Fmail"; Flags: nowait postinstall skipifsilent
