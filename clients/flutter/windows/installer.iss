; Inno Setup Script for Liza Messenger
; Requires Inno Setup 6+ (https://jrsoftware.org/isinfo.php)

#define MyAppName "Liza"
#define MyAppPublisher "Prodamus"
#define MyAppURL "https://liza.laba.prodamus.tech"
#define MyAppExeName "liza.exe"
#define BuildDir "..\build\windows\x64\runner\Release"

[Setup]
AppId={{B8F3D2A1-7C4E-4A9B-8D5F-1E6A2B3C4D5E}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
OutputDir=..\build\windows\installer
; Имя = файл в папке Я.Диска «Liza | Установщики»; версия — в свойствах файла.
OutputBaseFilename=Liza
VersionInfoVersion={#MyAppVersion}
VersionInfoProductName={#MyAppName}
SetupIconFile=runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
ArchitecturesInstallIn64BitMode=x64compatible
ArchitecturesAllowed=x64compatible
MinVersion=10.0
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
; Закрыть запущенную Лизу, даже зависшую (заявка №61: процесс 3789 висел после
; закрытия окна вместе с окном mini App и держал liza.exe).
CloseApplications=force

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "russian"; MessagesFile: "compiler:Languages\Russian.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#BuildDir}\liza.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#BuildDir}\*.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#BuildDir}\data\*"; DestDir: "{app}\data"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
; AppUserModelID на ярлыке ДОЛЖЕН совпадать с AUMID процесса (main.cpp) и
; AppConfig.appId — иначе Windows не сопоставит всплывающие уведомления с
; приложением (LABA-1891: «на винде уведомлений нет вовсе»).
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; AppUserModelID: "com.prodamus.laba.liza"
Name: "{group}\{cm:UninstallProgram,{#MyAppName}}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; AppUserModelID: "com.prodamus.laba.liza"; Tasks: desktopicon

[Registry]
; Регистрация URL-схемы liza:// для приёма deep-link-ов из браузера
; (callback регистрации ProdamusID и пр.). Per-user (HKCU) при
; PrivilegesRequired=lowest, удаляется при деинсталляции.
Root: HKA; Subkey: "Software\Classes\liza"; ValueType: string; ValueName: ""; ValueData: "URL:Liza Protocol"; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\Classes\liza"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""
Root: HKA; Subkey: "Software\Classes\liza\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: "{app}\{#MyAppExeName},0"
Root: HKA; Subkey: "Software\Classes\liza\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\{#MyAppExeName}"" ""%1"""

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent
