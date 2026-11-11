; 顺播 1.0.4 Windows x64 安装脚本（仓库内可复现版本）
;
; 与 tooling/windows_installer.iss 的区别：
;   旧脚本直接从 build\windows\x64\runner\Release 打包，输出 Shunbo-Setup-<版本>-x64.exe，
;   带 installer_readme_zh.txt 首屏说明与简体中文语言包；本次 1.0.4 实测出包用的是
;   「先组装目录、再打包」的方式，故单独留一份，避免把未经实测的路径混进通用脚本。
;
; 重建顺序（在仓库根目录执行）：
;   1. bash tooling/fetch_windows_kits.sh
;   2. flutter build windows --release
;   3. 把 build\windows\x64\runner\Release\. 整个复制到 dist\windows\Shunbo-1.0.4\，
;      并补齐 VC++ 运行库 DLL（msvcp140.dll / vcruntime140.dll / vcruntime140_1.dll）——
;      缺任意一个，安装到没装过 VC++ 运行库的机器上就会启动即崩。
;   4. ISCC.exe tooling\windows_release.iss
;   5. 便携包：把同一目录压成 dist\Shunbo-1.0.4-windows-x64-portable.zip
;
; 实测约束（都是踩过的坑）：
;   - ArchitecturesAllowed 用 x64compatible：Inno Setup 6 里 x64 已弃用，写 x64 会编译报错。
;   - PrivilegesRequired=lowest：per-user 安装，不弹 UAC。
;   - 别用 Git Bash 直接传 /VERYSILENT，MSYS 会把它改写成 C:/Program Files/Git/VERYSILENT；
;     用 PowerShell 或设 MSYS2_ARG_CONV_EXCL='*'。
;   - 未做代码签名，Windows 会提示「未知发布者」，属预期行为。
;   - 本文件须保存为 UTF-8 BOM + CRLF，否则 Inno 按 ANSI 解析中文会乱码。

#define MyAppName "顺播"
#define MyAppVersion "1.0.4"
#define MyAppExeName "shunbo.exe"
#define SrcDir "..\dist\windows\Shunbo-1.0.4"
#define OutDir "..\dist"
#define IconFile "..\windows\runner\resources\app_icon.ico"

[Setup]
AppId={{8F3C1D6A-5B27-4E19-9C4D-2A7E6B1F0D83}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
AppPublisher=shunbo
AppCopyright=Copyright (C) 2026 shunbo
DefaultDirName={autopf}\Shunbo
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
OutputDir={#OutDir}
OutputBaseFilename=Shunbo-1.0.4-windows-x64-setup
SetupIconFile={#IconFile}
UninstallDisplayIcon={app}\{#MyAppExeName}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequired=lowest
VersionInfoVersion=1.0.4.5
VersionInfoCompany=shunbo
VersionInfoDescription=顺播 Windows 桌面版安装程序
VersionInfoProductName=顺播
VersionInfoProductVersion=1.0.4
VersionInfoProductTextVersion=1.0.4+5

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "创建桌面快捷方式"; GroupDescription: "附加任务:"; Flags: unchecked

[Files]
Source: "{#SrcDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{group}\卸载 {#MyAppName}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "启动 顺播"; Flags: nowait postinstall skipifsilent
