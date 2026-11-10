; 顺播 shunbo — Windows 桌面安装包（Inno Setup 6）
;
; 用法：
;   "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" tooling\windows_installer.iss
; 产物：E:\TV\dist\Shunbo-Setup-<版本>-x64.exe
;
; 设计说明：
; - **per-user 安装**（PrivilegesRequired=lowest）：不弹 UAC，装到
;   `%LOCALAPPDATA%\Programs\Shunbo`，卸载时也不留系统级残留。这类自用播放器
;   没有任何需要管理员权限的写入点，强行要提权只会让用户多点一次「否」。
; - 版本号与 `pubspec.yaml` 的 version 保持一致，改版本时两处一起改。
; - 不打包任何内容源：安装包里只有程序本体与随包分发的 libmpv（media_kit 依赖）。

#define AppName "顺播 shunbo"
#define AppVersion "1.0.4"
#define AppPublisher "shunbo"
#define AppExe "shunbo.exe"

[Setup]
AppId={{7C1E4B52-9D3A-4F2E-8A61-2B5D9C0E7F14}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher={#AppPublisher}
; 目标目录显式写成「当前用户」路径，不用 {autopf}：
; {autopf} 在非管理员模式下由 Inno 按系统解析，实测本机被解析成 D:\Programs（与
; ProgramFiles 注册表值不一致），装完的位置不可预测。显式落到 %LOCALAPPDATA%\Programs
; 既符合 per-user 语义，也不受系统盘符/Program Files 重定向影响。
DefaultDirName={localappdata}\Programs\Shunbo
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=..\dist
OutputBaseFilename=Shunbo-Setup-{#AppVersion}-x64
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#AppExe}
InfoBeforeFile=installer_readme_zh.txt
; 未做代码签名：自用侧载包，Windows 会提示「未知发布者」，属预期行为。
SignedUninstaller=no

[Languages]
Name: "chinesesimp"; MessagesFile: "ChineseSimplified.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
; Release 目录整体打包：shunbo.exe + flutter_windows.dll + data\ + 随包的 mpv-2.dll /
; d3dcompiler_47.dll（media_kit 的 Windows 原生依赖，缺失会启动即崩）。
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExe}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent
