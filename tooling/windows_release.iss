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

; ---- 覆盖升级必须能替换已被占用的 DLL（2026-11-12 实测事故）----
; 现象：旧版还在跑时覆盖安装，会卡在
;   「DeleteFile failed; code 5   拒绝访问   ...\d3dcompiler_47.dll」
; 原因：shunbo.exe 已把 d3dcompiler_47.dll / flutter_windows.dll / libmpv-2.dll
; 映射进自己的地址空间，Windows 不允许删除被映射的映像文件。
; 两道防线缺一不可：
;   1) CloseApplications=force —— 交给 Restart Manager 通知占用进程正常退出（能存盘）；
;   2) [Code].PrepareToInstall 里 taskkill 兜底 —— 多实例 / 崩溃残留 / 无响应窗口
;      Restart Manager 认不出来，只能强杀，并留 1 s 给句柄回收。
CloseApplications=force
CloseApplicationsFilter=*.exe,*.dll
RestartApplications=no

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

[Code]
{ 覆盖安装前确保旧版已退出。
  仅靠 CloseApplications=force 不够：本机实测有两个残留 shunbo.exe（11:04 与 11:25
  各起一个），Restart Manager 没有全部识别，DLL 仍被映射，DeleteFile 返回 code 5。
  taskkill 退出码：0 = 杀到进程；128 = 本就没有该进程（正常）；其余视为失败并重试。 }
function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  ResultCode: Integer;
  Killed: Boolean;
  Attempt: Integer;
begin
  Result := '';
  Killed := False;
  for Attempt := 1 to 3 do
  begin
    if not Exec('taskkill.exe', '/F /IM shunbo.exe', '', SW_HIDE,
                ewWaitUntilTerminated, ResultCode) then
      Break;
    if ResultCode = 0 then
    begin
      Killed := True;
      Break;
    end;
    if ResultCode = 128 then
      Break;
    Sleep(400);
  end;
  { 进程退出到句柄真正释放之间有延迟，紧接着的 DeleteFile 仍可能 code 5 }
  if Killed then
    Sleep(1000);
end;
