# 顺播 shunbo — 功能实现检查清单（2026-11-05）

> 检查范围：`/e/TV/shunbo` 全量源码（lib / android 原生 / tooling 回归与验收脚本），
> 对照三份输入：设计稿 V1.4 第 2.2 节功能矩阵、README 各里程碑的自述、以及代码里
> 已经声明但**没有调用方**的接口。
>
> 判定口径（刻意从严，不用「大致实现」糊过去）：
> - **完整**：有实现、有调用方、有可复现断言；或已编译产物可核验。
> - **部分**：契约/主干在，但缺一侧（缺原生侧、缺 UI 入口、缺持久化、缺真机数据）。
> - **未实现**：只有设计文字，代码里搜不到。
> - 只看「代码里有没有真的接上」，不看注释里写了什么。

---

## 一、总览

| 分类 | 数量 | 说明 |
|---|---|---|
| 完整 | 33 | 含本轮补全 5 项 |
| 部分 | 11 | 多为「需真机 / 需插件 / 需外部账号」 |
| 未实现 | 21 | 直播、收藏、字幕等 P1/MVP 未开工项 |
| 合计 | 65 | 逐项见第二节 |

**本轮补全 5 项**（详见第三节）：

1. 自动连播（下一集编排）—— 之前只有回调、没有消费方。
2. Windows/Linux/macOS 真实播放内核 —— 之前桌面端是 Mock，不出画面。
3. 结束投屏回本机 —— `stopCasting()` 之前全工程无调用方。
4. `PlayerController.initialize()` 调用 —— 之前声明了但没人调。
5. 数据目录持久化 —— 之前落 `%TEMP%`，桌面临时目录会被清，进度会「莫名消失」。

---

## 二、逐项检查结果

### 2.1 工程与验证基线

| # | 功能点 | 来源 | 状态 | 证据 / 缺口 |
|---|---|---|---|---|
| 1 | 分层骨架（core/data/ui） | 设计稿 4.6 | 完整 | `lib/` 三层 + `main.dart` 组装 |
| 2 | 统一门禁（analyze + 回归 + Python） | 自建 | 完整 | `dart run tooling/verify_all.dart` → **35 步 / 3089 断言全通过（约 1.8 分钟）** |
| 3 | 门禁自身防假成功（自检） | 自建 | 完整 | `--selftest` 6/6：静默通过、FAIL 但退出 0 等都被判失败 |
| 4 | CI 工作流 | 自建 | 部分 | `../.github/workflows/verify.yml` 已写，仓库未初始化、未推送 |
| 5 | `flutter test` | Flutter 默认 | 部分 | 本机 flutter_tester 握手失败（环境限制），已全部改用 `dart run tooling/verify_*` |

### 2.2 M0 换源对齐（最高风险项）

| # | 功能点 | 来源 | 状态 | 证据 |
|---|---|---|---|---|
| 6 | 内容坐标 ↔ 源原始坐标（集数偏移 / 广告插入 / 用户校准） | 设计稿 5.7 | 完整 | `scheduler/alignment.dart`；Python 原型 6/6 与 Dart 语义 1:1 |
| 7 | 换源后位置守恒 | 设计稿 5.6 | 完整 | `switchSource` + `verify_logic` 断言「650s 内容 → 目标源 680s 物理」 |

### 2.3 E2 源适配层

| # | 功能点 | 来源 | 状态 | 证据 / 缺口 |
|---|---|---|---|---|
| 8 | 适配器契约 + 数据模型 + 平台裁剪 | 设计稿 5.1/6.6 | 完整 | `source_adapter.dart` / `source_registry.dart` |
| 9 | Dart 解析 + 真实 HTTP 取数（超时/状态码/体积/SSRF/请求头/路径模板） | 设计稿 6.2 | 完整 | `dart_backend.dart`；`verify_live_http` 43/43 真实 socket |
| 10 | 规则驱动解析（regex/json/ReDoS/实体/scheme/相对地址） | 设计稿 6.6 | 完整 | `site_rule.dart` + `rule_source_parser.dart` |
| 11 | 跨 origin 白名单 + 凭据隔离 | 设计稿 6.5 风险 | 完整 | `allowedOrigins` 逐跳复检；`verify_cross_origin` 63/63 |
| 12 | jar 爬虫后端 | 设计稿 6.5 | 部分 | Dart 侧 `jar_backend.dart` + 通道契约就绪；**Android 原生实现未写** |
| 13 | QuickJS 脚本源 | 设计稿 6.5 | 未实现 | 白名单已能识别并拒绝（`quickjs` 键需显式授权），无执行后端 |
| 14 | 真实站点 `SiteRule` 校准 | 设计稿 6.7 | 部分 | 三套预设跑本地样本站点；真实站点结构未实测校准 |
| 15 | 系统文件选择器 | 设计稿 7.4 | 未实现 | 当前是路径输入框；需 `file_selector`/`file_picker` 类插件 |
| 16 | 源订阅与自动维护 | 设计稿 6.7 | 未实现 | 无定时体检、无订阅更新 |

### 2.4 E3 播放内核

| # | 功能点 | 来源 | 状态 | 证据 / 缺口 |
|---|---|---|---|---|
| 17 | `PlayerController` 抽象（物理播放 / 坐标只做原始） | 设计稿 4.2 | 完整 | `player_controller.dart`；`load(url, episode, rawSeconds, headers)` |
| 18 | Android 原生通道 + 渲染面 + 内存探针 | 设计稿 4.4/5.13 | 完整（待真机） | `MainActivity.kt` / `MpvMethodHandler.kt` / `ExoPlayerEngine.kt` / `PlayerSurfaceFactory.kt`；APK 已编译并核验通道名与权限 |
| 19 | 桌面端真实内核 | 设计稿 4.4 | **完整（本轮补全）** | 新增 `media_kit_player_controller.dart` + `ui/media_kit_surface.dart`，libmpv 随包分发 |
| 20 | FFI 直连 libmpv + `mpv_render_context_create` 渲染面 | 设计稿 4.4 | 部分 | `mpv_ffi_bindings.dart`/`mpv_ffi_native.dart` 绑定完整；桌面渲染面不接（已被 media_kit 取代），仅保留 FFI 能力 |
| 21 | 首帧/内存/卡顿三项门禁 + 牵制模型 | 设计稿 5.13 | 完整（逻辑） | `player_metrics.dart` + `metrics_sampler.dart`；平衡解 预解码4帧/缓存24MB/内存76MB |
| 22 | 真机指标校准 | 设计稿 9.1 | 部分 | 系数是初版假设，等真机数据 |
| 23 | 事件循环 / property 观察 / 指标管线 | 设计稿 5.13 | 部分 | 逻辑与回归齐备；Android 运行期未消费（当前 `sampleMetrics` 同步取），`createMpvEventPipeline` 无人调用 |
| 24 | `initialize()` 生命周期 | 接口定义 | **完整（本轮补全）** | `main()` 里 `await player.initialize()`；之前原生侧靠 `ensureEngine()` 惰性兜底 |
| 25 | 断点续播 | 设计稿 2.2 | 完整 | 见 2.6 |
| 26 | 硬解/软解切换 | 设计稿 2.2 | 未实现 | Android 走 media3 默认策略；桌面 media_kit 默认硬解 |
| 27 | 倍速 / 多音轨 / 外挂字幕 / 画面比例 | 设计稿 2.2 | 未实现 | 内核层能力已具备（libmpv），没有 UI 与通道方法 |
| 28 | 清晰度选择与锁定 | 设计稿 2.2 | 未实现 | 目前只按 `qualityRank` 自动取最高 |
| 29 | 画质实测与标称校验 | 设计稿 5.12 | 未实现 | 无分辨率/码率采样与排序 |
| 30 | 手势与快捷键 | 设计稿 2.2 | 未实现 | 无滑动调亮度/音量、无键盘映射 |

### 2.5 E5 投屏

| # | 功能点 | 来源 | 状态 | 证据 / 缺口 |
|---|---|---|---|---|
| 31 | 投屏状态机 + 六条降级路径 | 设计稿 5.9 | 完整 | `cast_fallback.dart`；`verify_dlna_cast` 61/61 |
| 32 | 真实 DLNA（SSDP + 描述 + SOAP AVTransport） | 设计稿 2.2 | 完整 | `dlna/dlna_transport.dart`；含私网限制/同 origin/体积上限/Seek 退化 |
| 33 | 结束投屏回本机 | 交互闭环 | **完整（本轮补全）** | 新增 UI 入口 + `_stopCasting()`；`stopCasting()` 之前无调用方 |
| 34 | 主动结束的文案语义 | 细节 | **完整（本轮修正）** | 新增 `CastFailureReason.userStopped`，不再把「用户主动结束」说成「连接中断」 |
| 35 | Chromecast / 厂商私有协议 | 设计稿 2.2 | 未实现 | 仅 DLNA |
| 36 | 真机 SSDP 校准（AP 隔离/组播过滤） | 设计稿 9.3 | 部分 | 本机回环回归 61 项；真实路由器未测 |

### 2.6 E6 续播 / 同步 / 连播

| # | 功能点 | 来源 | 状态 | 证据 / 缺口 |
|---|---|---|---|---|
| 37 | 续播记录只存规范内容坐标 | 设计稿 8.1 | 完整 | `resume_record.dart`（含 `finished`） |
| 38 | 原子写 + 损坏容错 | 设计稿 8.1 | 完整 | `file_resume_store.dart` / `file_config_store.dart` |
| 39 | 播放中进度落盘（采样/节流/单写者/epoch） | 设计稿 2.2 | 完整 | `progress_reporting.dart`；`verify_progress` 102/102 |
| 40 | 片尾判定（90s/300s） | 设计稿 2.2 | 完整 | 同上，含写失败重试、回拖撤销 |
| 41 | 自动连播下一集 | 设计稿 2.2「自动连播可关闭」 | **完整（本轮补全）** | 新增 `playback_queue.dart` + UI 开关；`verify_queue` 28/28 |
| 42 | 跨端同步（Lamport + 墓碑 + 离线队列） | 设计稿 2.2 | 完整 | `data/sync/`；时钟回拨/删除复活两坑已固化 |
| 43 | 云账号同步 | 设计稿 12.3 | 未实现 | 只有共享目录 `FileSyncTransport`；需先定账号体系 |
| 44 | 设备身份 | 设计稿 12.3 | 部分 | `deviceId` 硬编码 `demo-desktop`，未做设备注册 |
| 45 | 节流/片尾阈值真机校准 | 设计稿 9.1 | 部分 | 5s/10s/5s 与 90s/300s 是初值 |

### 2.7 E7 韧性 / 诊断

| # | 功能点 | 来源 | 状态 | 证据 / 缺口 |
|---|---|---|---|---|
| 46 | 失效建模 + 唯一重试决策点 | 设计稿 5.9 | 完整 | `playback_failure.dart` + `source_failover.dart` |
| 47 | 全失效可执行兜底 | 设计稿 5.9 | 完整 | UI 两个演示入口 + `failoverExhausted` 埋点 |
| 48 | 诊断 JSONL 落盘 + 轮转 + 串行写 | 设计稿 9.4 | 完整 | `file_diagnostic_sink.dart` |
| 49 | 远端日志聚合 | 设计稿 9.4 | 未实现 | 需上报端点与脱敏策略 |
| 50 | 源健康度模型 / 批量源体检 | 设计稿 5.3 / 2.2 | 未实现 | 代码中无 health 相关实现；只有即时失效处理，没有历史评分与降权 |

### 2.8 E9 引导 / 安全

| # | 功能点 | 来源 | 状态 | 证据 / 缺口 |
|---|---|---|---|---|
| 51 | 源配置安全白名单 | 设计稿 12.1 | 完整 | `source_config_validator.dart`（禁脚本键/scheme/深度/条目/长度） |
| 52 | 引导状态机 + 持久化 | 设计稿 7.1 | 完整 | `onboarding_flow.dart` + `FileConfigStore`；未接受免责不可导入 |
| 53 | 导入（粘贴 / 文件 / https 链接） | 设计稿 6.1 | 完整 | 三条入口共用同一净化链路；37/84/60 项回归 |
| 54 | 导出 / 备份（.shunbo-bak + 原子换名） | 设计稿 2.2 | 完整 | 46/46，含导出→导入往返 |
| 55 | URL 来源可信度 / 签名校验 | 设计稿 12.1 | 未实现 | 只保证传输安全，不认证发布者 |
| 56 | 数据目录持久化 | 工程正确性 | **完整（本轮补全）** | 新增 `data/app_paths.dart`：桌面 `%LOCALAPPDATA%\Shunbo`，Android 应用私有缓存 |

### 2.9 设计稿功能矩阵中尚未开工的部分

| # | 功能点 | 优先级 | 状态 |
|---|---|---|---|
| 57 | 直播：频道分组 / 台标 / 多源聚合 / 节目单 / 收藏 / 时移 | MVP/P1/P2 | 未实现 |
| 58 | 点播：分类浏览 / 详情页（简介·演职员·多线路） | MVP | 未实现 |
| 59 | 收藏与历史（本地保存、导出迁移） | MVP | 未实现 |
| 60 | 追剧提醒（更新集数） | P2 | 未实现 |
| 61 | 网络设置（代理 / 自定义 UA / 加密 DNS / 域名重写） | P1 | 部分（请求头可配；无代理配置界面、无 DNS/域名重写） |
| 62 | 缓存清理（图片/接口/日志分级） | P1 | 未实现 |
| 63 | 三端布局适配（电视/手机/桌面） | MVP | 未实现（同一套布局 + 手动切平台枚举） |
| 64 | Android 4.4 精简版 | MVP | 未实现（`minSdk 24`，无独立精简渠道包） |
| 65 | 弱网降档不中断 | 非功能 | 未实现 |

---

## 三、本轮补全的 5 项（做了什么 / 为什么之前不算完成 / 怎么验证）

### 3.1 自动连播（`lib/core/scheduler/playback_queue.dart`）

- **之前**：`ProgressReporter.onEpisodeFinished` 定义了、也有回归覆盖回调本身，
  但 `main.dart` 从未给它传回调 —— 用户看完一集停在片尾，`ResumeRecord.finished`
  写对了，播放器却不会进下一集。README 也承认「真正换集编排留给播放列表能力层」。
- **现在**：新增 `PlaybackQueue`，接住片尾事件 → 从剧集表取下一集 → 在当前源起播，
  当前源缺集时按平台可用源换源；关闭开关则只记进度不换集；最后一集返回「已看完」
  而不是重播。三个暗坑都钉住了：迟到事件（换源后旧回调）、重复触发（`_inFlight`）、
  跳集（1、2、5 集时第 2 集接第 5 集）。
- **UI**：播放页新增「看完自动播放下一集」开关，状态落 `config.json`（重启保持）。
- **验证**：`dart run tooling/verify_queue.dart` → **28/28**；已并入 `verify_all` 第 8 步。

### 3.2 桌面端真实播放内核（`media_kit` + 随包 libmpv）

- **之前**：`createPlatformPlayer()` 在非 Android 平台返回 `MockPlayerController`，
  UI 明写「演示内核，不出画面」。装到 Windows 上就是一个不能播的壳。
- **为什么不是自己接 FFI**：Flutter Windows 只暴露 pixel-buffer 纹理注册，没有 GPU
  纹理共享；`mpv_render_context_create` 必须在 C++ 侧建 ANGLE/D3D 上下文再回读像素。
  这属于另一个插件的工程量，而 `media_kit` 已经把这段桥接 + libmpv 打包做完。
- **现在**：`MediaKitPlayerController` 实现同一个 `PlayerController` 契约（物理播放、
  原始坐标、请求头），`ui/media_kit_surface.dart` 提供 `Video` 纹理面；
  编排层/调度层/续播/片尾逻辑**一行没改**。Android 仍走自研平台通道（media3），
  不引 `media_kit_libs_android_video`，避免 APK 体积翻倍。
- **验证**：`flutter build windows --release` 产出可执行目录；安装包见第五节。

### 3.3 结束投屏回本机

- **之前**：`CastFallbackController.stopCasting()` 写好了、也测过，但 UI 没有入口。
  投屏成功后本机是 `pause()` 状态，用户点不回来 —— 只能杀进程。
- **现在**：记录「当前投屏传输 + 设备」，播放页出现「正在投屏到 …」卡片与「结束投屏」；
  结束时先从设备取回真实位置（只进不退）再断开，然后按源画像换算回内容坐标起播。
- **顺带修正**：主动结束原来复用 `connectionLost`，提示语是「投屏连接中断，可检查
  Wi-Fi 后重试」—— 对主动操作来说是错误信息。新增 `CastFailureReason.userStopped`。
- **验证**：`verify_dlna_cast` 61/61 仍全绿；UI 路径走同一 `_settleCast`。

### 3.4 `PlayerController.initialize()` 接通

- **之前**：接口声明了、两个实现都写了，**全工程没有一处调用**。Android 靠
  `ensureEngine()` 惰性兜底所以看不出问题；换成 media_kit 后不初始化就是空指针。
- **现在**：`main()` 在 `runApp` 前 `await player.initialize()`。

### 3.5 数据目录持久化（`lib/data/app_paths.dart`）

- **之前**：进度/配置/诊断全部写 `Directory.systemTemp`。桌面端临时目录会被系统清理
  （Windows 存储感知），「继续观看」会无声消失 —— 恰好砸在最核心的卖点上。
- **现在**：桌面 → `%LOCALAPPDATA%\Shunbo`（macOS/Linux 各有对应目录），
  Android → 应用私有缓存（`systemTemp` 即 cacheDir，卸载即清，语义正确）。
  不引 `path_provider`：桌面靠环境变量即可确定，多一个原生插件不划算。
- **验证**：Windows 安装后 `%LOCALAPPDATA%\Shunbo\resume.json` 生成并可重启回读。

---

## 四、为什么有些「缺失」这轮没补

| 缺口 | 原因（不是「没时间」这种糊弄话） |
|---|---|
| Android jar / QuickJS 原生后端 | 需要真实爬虫 jar 与 QuickJS 运行时做联调；白名单已强制这类后端需显式授权，先补执行器等于把未验证的代码执行面打开 |
| 系统文件选择器 | 需新增平台插件（`file_selector`），会同时改三端构建；本轮优先保证两个安装包可产出 |
| 云账号同步 / 远端日志 / URL 签名 | 都依赖外部决策（账号体系、上报端点、公钥分发），不是代码问题 |
| 直播 / EPG / 收藏 / 详情页 / 字幕 / 倍速 | 设计稿里是 MVP~P2 的完整模块，属下一阶段工作量（评估基线里还有 ~100 人日） |
| 真机三项校准（指标、首帧时序、SSDP 权限弹窗） | 本机无 Android 设备/电视，只能给出「编译通过 + 回环回归」这一层证据 |

---

## 五、三个安装包（2026-11-08 11:18 重打，对应手机横屏布局修复后的最终代码）

| 平台 | 产物 | 体积 | 构建命令 | 说明 |
|---|---|---|---|---|
| Windows x64 | `dist\Shunbo-Setup-0.1.0-x64.exe` | 25 293 752 B ≈ 24.1 MiB | `bash tooling/fetch_windows_kits.sh && flutter build windows --release && signtool sign /fd SHA256 /sha1 <thumb> /s My build\windows\x64\runner\Release\shunbo.exe && ISCC.exe tooling\windows_installer.iss && signtool sign /fd SHA256 /sha1 <thumb> /s My dist\Shunbo-Setup-0.1.0-x64.exe` | Inno Setup 6，per-user 安装到 `%LOCALAPPDATA%\Programs\Shunbo`（`PrivilegesRequired=lowest`，不弹 UAC），已签名 `CN=Shunbo`；简体中文/英文双语；随包 `libmpv-2.dll` / ANGLE（`libEGL.dll`、`libGLESv2.dll`、`d3dcompiler_47.dll`、`vulkan-1.dll`、`vk_swiftshader.dll`、`zlib.dll`） |
| Android 完整版 | `dist\Shunbo-0.1.0-full.apk`（源：`build\app\outputs\flutter-apk\app-full-release.apk`） | 39 346 368 B ≈ 37.5 MiB | `bash tooling/build_android_apks.sh` | `com.shunbo.tv`；minSdk 24 / target 36 / compileSdk 36；arm64-v8a + armeabi-v7a；media3(ExoPlayer) 内核；手机 + 电视 |
| Android 精简版 | `dist\Shunbo-0.1.0-lite.apk`（源：`app-lite-release.apk`） | 20 684 854 B ≈ 19.7 MiB | 同上（`--flavor lite --target-platform android-arm`） | `com.shunbo.tv.lite`；仅 armeabi-v7a，老盒子优先 |

两个 APK 都必须走 `tooling/build_android_apks.sh`：手敲 `flutter build apk --release` 会漏掉
`--target-platform`，产出「全 ABI 通用包」（实测 55 MB 且带 x86_64），和精简版几乎没有差别，
在文件管理器里看不出来，只有装到 1 GB 盒子上才发现「怎么这么大」。

`ISCC` 未在 PATH 时用全路径：`"C:\Program Files (x86)\Inno Setup 6\ISCC.exe" tooling\windows_installer.iss`。
安装包输出目录由 `windows_installer.iss` 的 `OutputDir=..\dist` 决定 → **仓库根下的 `dist\`**
（本机即 `E:\TV\shunbo\dist\`）。APK 的源产物在 `build\app\outputs\flutter-apk\`，已另拷一份到
`dist\`，让两个安装包在同一处交付。

### 5.1 安装包实装验证（不是只看编译成功）

三个产物都做了「装得上、起得来、卸得掉」的闭环（2026-11-07 14:34 首验；R2.2 重打后 18:26 复验，结论一致）：

**Windows**：`/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /DIR=<临时目录>`
→ `ExitCode=0`，`shunbo.exe`（92 160 B）、`libmpv-2.dll`、6 个 ANGLE 依赖、
`data\` 与 `unins000.*` 全部落地；
启动 `shunbo.exe` 后进程 9s 仍存活，`MainWindowTitle=[顺播 shunbo]`，工作集约 1 139 MB
（libmpv + media_kit + Flutter 引擎；较上轮的 406 MB 高，含解码缓冲与显存映射，
未做逐项归因，不作为性能结论）；`unins000.exe /VERYSILENT` → `UninstallExit=0`，
目录被完全删除，残留 0 项。

> 用 Git Bash 直接跑安装包会**假成功**：MSYS 会把 `/VERYSILENT` 当路径改写成
> `C:/Program Files/Git/VERYSILENT`，安装器收到一堆无意义参数后正常退出（exit 0）却什么都没装。
> 必须用 PowerShell `Start-Process` 传参，或设 `MSYS2_ARG_CONV_EXCL='*'`。

**Android**：`aapt2 dump badging` 核验两个包 ——

| | 完整版 | 精简版 |
|---|---|---|
| package / versionName | `com.shunbo.tv` / `0.1.0` | `com.shunbo.tv.lite` / `0.1.0` |
| minSdk / targetSdk / compileSdk | 24 / 36 / 36 | 24 / 36 / 36 |
| application-label | 顺播 | 顺播 |
| native-code | arm64-v8a, armeabi-v7a | armeabi-v7a |
| launchable-activity | `com.shunbo.shunbo.MainActivity`（同时声明 leanback 入口） | 同左 |

九项权限：INTERNET / ACCESS_NETWORK_STATE / ACCESS_WIFI_STATE / CHANGE_WIFI_MULTICAST_STATE /
NEARBY_WIFI_DEVICES(`neverForLocation`) / FOREGROUND_SERVICE / FOREGROUND_SERVICE_MEDIA_PLAYBACK /
POST_NOTIFICATIONS / 自身 `DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION`。
`.so` 只有 `libapp.so` + `libflutter.so`（完整版 2 ABI 共 4 个），**未混入 libmpv** ——
Android 走 ExoPlayer，不引 `media_kit_libs_android_video`，否则包体翻倍。

**新代码确实在包里**（不是「改了没打进去」）：从 `lib\arm64-v8a\libapp.so`（完整版）与
`lib\armeabi-v7a\libapp.so`（精简版）抓 AOT 快照字符串，命中 `shunbo/network`、
`shunbo/network/events`、`x-shunbo-signature`、`udpxy`、`multicast`、`carrierNet`、
`channelSettings`，以及 R2.2 新增的 `StreamPolicy` / `hndyjyfw`（河南 Referer 规则）/
`shortening patience`（探测并行后的耐心收缩日志）/ `error_account_pirated`；
`classes.dex` 命中 `NetworkWatch` 类。
Windows 侧 `data\app.so` 同样命中上述 R2.2 符号（桌面无网络回调通道，属预期）。
本轮手机端布局改动另命中 `channel_rail_tab` / `ChannelRailTab` /
`landscapeRailWidthFor` / `_ChannelEntryButton`（APK `libapp.so` 与 Windows `app.so` 均已核到），
确认「舞台铺满 + 右侧频道入口」真的进了 release，而不是只改了源码。

**校验和**（2026-11-08 11:18 重打：手机横屏铺满 + 右侧频道入口；Windows 已重新签名）：

```
49D443A15EA8D62A7F2165D9B23F9149FBC583E4D87B6A4F88D80803A0838102  Shunbo-0.1.0-full.apk     （39 346 368 B）
B7BF65124CB0E9C85908EA9B8A5B1AD448E030C16639384A1C2412139A3C0302  Shunbo-0.1.0-lite.apk     （20 684 854 B）
26C9BBC8A7BBAA531336F916D77DF048C6F351367053F763E6A08B4D845D0DF5  Shunbo-Setup-0.1.0-x64.exe（25 293 752 B，FileVersion 0.1.0，已签名 CN=Shunbo）
```

> **Windows 正式版的签名与安装路径**（2026-11-07 19:15）：
> `shunbo.exe` 与安装包都用自签代码签名证书 `CN=Shunbo, O=Shunbo, C=CN`
> （EKU=Code Signing，RSA-3072 / SHA-256，至 2031-11-07）签过，`signtool` 零错误、
> `Get-AuthenticodeSignature` = `Valid`；证书已导入本机 `LocalMachine\TrustedPublisher` 与
> `TrustedRoot`，公钥证书 `dist\shunbo-codesign.cer` 随包分发（其它机器导入后可去掉「未知发布者」）。
> `DefaultDirName` 同时由 `{autopf}\Shunbo` 改为 `{localappdata}\Programs\Shunbo`——
> `{autopf}` 在非管理员模式下由 Inno 自行解析，本机实测解析到 `D:\Programs`（与注册表
> `ProgramFilesDir=C:\Program Files` 不一致），装完位置不可预测。

> 上一轮遗留的 `dist/Shunbo-0.1.0-universal.apk`（53 587 220 B，包名 `com.shunbo.shunbo`、
> 三 ABI）是渠道分包改造**之前**的产物，已移入 `dist/archive/`，不再作为交付物。

构建环境上做过的三件事（可复现，不是手工乱改）：

1. **补装 VS BuildTools 的 CMake 组件**：`Microsoft.VisualStudio.Component.VC.CMake.Project`
   （原来只有 MSVC、没有 CMake，`flutter build windows` 直接报
   "Unable to find suitable Visual Studio toolchain"）。
2. **预取 media_kit 的 Windows 原生包**：`tooling/fetch_windows_kits.sh`。
   插件在 CMake configure 阶段用 `file(DOWNLOAD github.com/...)` 下载 libmpv 与 ANGLE，
   国内网络下会得到 0 字节文件并报 "Integrity check failed"；脚本用镜像 + 断点续传
   把包放到 CMake 期望位置并校验 md5。
3. **`windows/runner/main.cpp` 必须保持纯 ASCII**：中文窗口标题写成宽字符转义
   `L"\u987A\u64AD shunbo"`，注释也不能出现中文 —— MSVC 按本地代码页(936)解析源码，
   UTF-8 中文直接触发 `warning C4819`，而 Flutter 的 runner 工程开了 `/WX`，警告即错误
   （`error C2220: 以下警告被视为错误`）。要写中文注释就得给该文件加 BOM 或给工程加 `/utf-8`。

---

## 六、验证证据（可复现）

```bash
dart run tooling/verify_all.dart            # 35 步 / 3089 断言，全通过，约 1.8 分钟（当前终态）
dart run tooling/verify_all.dart --selftest # 门禁自身 6/6
dart run tooling/verify_mobile_layout.dart  # 手机端方向/双栏/全屏铺满/右侧入口/窄屏 145/145
dart run tooling/verify_edge_handles.dart   # 左右伸缩控件 79/79
dart run tooling/verify_carrier_channel.dart # 运营商通道 + 网络事件 + 组播策略 275/275
dart run tooling/verify_source_trust.dart   # 订阅来源 TOFU/HMAC/防降级 80/80
dart run tooling/verify_content_gate.dart   # 黑屏/静帧/纯色/循环垫片判据 46/46
dart run tooling/verify_live_discovery.dart  # 全网检索/高清优先 134/134
dart run tooling/verify_live_failover.dart   # 真实控制器状态机 23/23
dart run tooling/gen_channel_numbering_doc.dart  # 生成频道编号对照表（联网）
flutter analyze                            # No issues found
flutter build windows --release            # 见第五节
bash tooling/build_android_apks.sh         # 见第五节（两个渠道包）
```

下面是**第五轮结束时**的回归明细，保留作历史对照；当前终态见上面的 `verify_all` 汇总。

回归明细（第五轮结束时）：analyze + channel-contract 19 + core-logic 169 + live-http 43 +
multi-source 47 + onboarding 60 + url-import 37 + progress 102 + queue 28 +
live-catalog **107** + live-regions **184** + live-discovery **134** +
live-failover 23 + **channel-numbers 94** + live-selection 37 + live-sources 45 +
file-import 84 + export 46 + cross-origin 63 + dlna-cast 61 + **edge-handles 74** +
Python 6 = **1463**。

### 6.1 第三轮：全网检索 / 高清优先 / 自动切台 / 防崩溃

| 要求 | 实现 | 可复现证据 |
|---|---|---|
| 保留 iptv-org 并扩到全网 | `LiveSourceDescriptor` + 5 份发现源（Guovin `result.txt`、aptv、YueChan、iptv-org 中国全线路表、全球 `index.m3u` 中国收窄）+ 苏州双镜像 / 双格式 | `verify_live_discovery` 134/134；真实探针 **706 频道 / 1248 线路 / 201 台有备用源** |
| 苏州台稳定可检索且线路可用 | `cityOnly` 城市补充 + `parseNameUrl` 第二格式 | 探针苏州 5 台、`csztv1..5` 全 200；安装版 `live-health.json` 中 `csztv1.m3u8` = `ok 2 / fail 0 / start 1588ms` |
| 高清线路更丰富 + 优先加载 | 单台上限 6→10；中文/分组画质词；`normalizeStreams` 高清收口；`rankStreams(preferHd:true)` 把高清档排到健康分之前 | 探针 **244 台 / 362 条高清线路**，`CCTV-1` ranks `[90,90,70,60,60]`；安装版状态栏同步显示 |
| 全线路失败自动切下一台、不卡加载态 | `AutoAdvancePlanner` + `LiveController` 重写：`failed` 终态 → 800ms → `tune(..., manual:false)`；一轮扫完 30s 低频重扫 | `verify_live_failover` 23/23：A 台每条线路只试一次、按序切到 B 台并出画面、全表全灭总载入正好 6 次且落明确终态 |
| 线路切换 / 失败 / 自动切台不闪退 | `AsyncSerialGate` 串行化原生调用、epoch 作废旧结果、Timer try/catch、`_notify()` dispose 守卫 | 同上：并发 tune 无并发 `load`、dispose 后不再通知、`runZonedGuarded` 零未捕获异步异常；安装版冷启动实测经历多条死线后正常出画面 |

**归类退化一并修复**：全网扩展后「其它频道」被 376 个中文地方台冲爆，新增
`explicitGroupOf()` / 台名栏目词 / 中文台名与 `.cn|.tw|.hk|.mo` tvg-id 兜底，
并修正频道 id 身份分组（只在兜底推断时保留原始 group，否则同名不同组会撞 id）。
实测「其它频道」376→**11**、地方 161→404、少儿 9→17、体育 5→15、62 个城市。

**安装版实机走查**（`build/final_failover.png`、`build/failover_local.png`、
`build/failover_suzhou.png`）：冷启动隔离 `LOCALAPPDATA`，画面正常出图、
控制条无溢出；底部状态栏为「全网索引 + 内置（706 个频道 · 201 个台有备用源 ·
244 个台有高清线路）」；央视频道 71 台、体育 15 台可达；左上角「起播 1.6s」
与健康落盘里苏州台的 `start 1588ms` 吻合，即失败切换后成功在苏州地方频道出画面。

`verify_live_regions.dart` 覆盖：购物台剔除、英文卫视归一与多线路合并、
中文 group-title 归类、分类固定顺序与左右导航（含少儿/其它常驻可达）、
城市推断（中文/拼音/行政区划代码）、城市过滤与默认城市优先级、
IP 定位响应（含 GBK 字节含 `0x5C`、JSONP、脏数据、HTTP 降级）、城市偏好原子落盘，
以及**城市台补充索引**（`cityOnly` 过滤、600 条上限截断回归、被过滤条目不占额度、
补充源 404 静默降级、端到端 `load()` 合并后默认城市落在苏州）。

### 6.2 第四轮：左右伸缩控件默认隐藏、按需显示（2026-11-06）

**需求**：截图红框标出左右两条常驻边缘手柄，要求默认隐藏、页面初始加载不显示、
左右两侧行为一致，仅在需要展开或收起时按需出现，且不影响原有布局、内容展示与其它交互。

| 要求 | 实现 | 可复现证据 |
|---|---|---|
| 默认隐藏 / 初始不显示 | 新增纯 Dart `EdgeHandlePolicy`（`visible` 初值 `false`）+ 共享 `EdgeRevealHandle`：`AnimatedOpacity` 归零 + `IgnorePointer` | `verify_edge_handles` **74/74**；`build/edges_idle.png` 与左右 40px 放大图（`edges_left_zoom.png` / `edges_right_zoom.png`）确认无任何胶囊或箭头 |
| 按需显示 + 左右一致 | 两侧共用同一组件、同一 400ms 悬停缓冲、同一 180ms 淡入淡出；移除旧的「划过即展开」，改为「划过淡入 → 悬停 400ms 或点击展开」 | `build/edges_left_wide.png`：只有左缘出现 `>`，右侧仍隐藏；`edges_hover_left2.png` / `edges_right_open.png`：左右各自展开、头部各出现按需收起箭头 |
| 收起入口对称 | 新增 `OnDemandCollapseButton`：左侧导航栏与右侧频道栏都有，仅鼠标停在栏上时淡入，固定 40×40 占位不引起布局跳动 | 上述两张展开态截图：左侧 `<`、右侧 `>` 成对出现 |
| 原有布局 / 内容 / 交互不变 | 初始仍展开、6 秒自动隐藏、离开 1.2 秒收起；全屏与窄屏分支不渲染浮层；热区只在收起态且仅胶囊内可点，不抢画面与控制条点击；`open` 两侧都重排自动隐藏计时 | `build/edges_after_leave.png`：移开后两侧都收起且无残留控件；状态栏仍为「706 个频道 · 201 个台有备用源 · 244 个台有高清线路」，画面正常出图 |

**验收工具同步修正**：`capture_screen.dart` / `click_at.dart` 里的 `SW_RESTORE(9)`
会把最大化窗口缩回 854 宽、误入窄屏布局并丢失 hover 状态，统一改为 `SW_SHOW(5)`
（只显示、不改窗口状态）；新增 `tooling/move_mouse.dart`（只移指针不点击，用于 hover
验收）与 `tooling/bmp_to_png.dart`（纯 Dart BGRA→PNG，支持 `--crop=x,y,w,h,scale`
放大边缘；本机 `System.Drawing` 的 `Add-Type` 被安全策略拦截，ImageMagick 也没有）。

**安装版实机走查**：静默装到 `E:\TV\_accept_edges`（23 个文件），`data/app.so` 与构建
产物同为 `6A83E00915018A498F7D5C5F8FB00D2C9EC4A1E0CCE5DBB17BAD913412EA5789`；
隔离 `LOCALAPPDATA=build/_cold_edges` 冷启动，画面正常出图、控制条无溢出、频道分类
与频道列表（CCTV-1 / CCTV-2 / CCTV-4K 等）完整可达。

**第二轮安装版 UI 走查（上一轮历史记录，383 台 / 53 城市；第三轮最新数据见 6.1）**
（`build/cold_0*.bmp`、`build/walk_0*.bmp`）：
以隔离的 `LOCALAPPDATA` 冷启动（`build/_ipcheck`，无历史城市偏好）验证
IP 定位「苏州」→ 地方频道默认显示「苏州」且列出 5 个苏州台；
城市下拉可见 53 个城市并选中苏州，切换到「上海」后 `live-region.txt` 正确落盘；
分类条从「全部」可连续翻到「少儿」（9 台）与「其它频道」（40 台），末项右箭头置灰；
展开态控制条为**单行**，换线路 / 刷新与快退、上下台、播放/暂停、快进、
音量、缩放、全屏同排，无 `BOTTOM OVERFLOWED` 溢出提示。

### 6.3 第五轮：频道分类来源策略 + 数字编号 + 遥控器按号跳台（2026-11-06）

**需求**：① 新闻 / 少儿 / 体育 三个分类的内容来源覆盖央视、卫视、地方三类频道；
② 纪实分类的内容来源为央视及全网其它视频源；③ 其余来源统一归入「其它」频道；
④ 所有频道及节目分配唯一、稳定的数字编号，**央视一套 = 1**，编号参考主流直播软件
的常规方式；⑤ 安卓 TV 装到电视上后可用遥控器直接输入数字切换频道；
⑥ 隐藏播放器顶部状态行与底部来源说明两处文字；⑦ 卫视频道的中国教育 4 个台改归
央视频道，作为央视的四个台。

| 要求 | 实现 | 可复现证据 |
|---|---|---|
| 分类 ↔ 来源归属 | 新增纯 Dart `channel_taxonomy.dart`：`ChannelSource`（央视 / 卫视 / 地方 / 全网其它视频源）+ `categorySources` 策略表（新闻·少儿·体育·影视·生活 = 央视+卫视+地方；纪实 = 央视+全网其它视频源；其它 = 全网其它视频源）。**分类可叠加**：一个台同时属于「主分类」（按来源）与「内容分类」（按栏目） | `verify_channel_numbers` **94/94**；真实频道表分布：央视频道 61 / 卫视频道 55 / 地方频道 519 / 其它频道 33，叠加后 新闻 104 / 少儿 17 / 体育 20 / 影视 32 / 生活 46 / 纪实 4 |
| 唯一稳定的数字编号 | 新增 `channel_numbering.dart`：号段 **央视 1–99 / 卫视 101–199 / 地方 201–899 / 全网其它视频源 901–999 / 节目 1001–1099 / 分集 1101–1999**；固定表（CCTV-1=1 … CCTV-17=17、CCTV-5+=18、CCTV 4K=19、CGTN=20/21、**中国教育1–4=22–25**、省级卫视按 GB/T 2260 顺序 101–135、苏州 201–205）；其余台首次分配即落盘 `channel-numbers.json`，同一台永远同一个号 | `docs/channel-numbering.md`（生成 1066 行完整对照表：号段 / 分类来源 / 固定编号 / 668 个频道的逐条编号）；实测苏州 = 201–205、CCTV-1 = 1、中国教育1台 = 22 |
| 遥控器按号跳台 | 新增 `ui/widgets/channel_number_input.dart`：`HardwareKeyboard` 全局钩子 + 逐位累积（1.5s 超时提交）+ 确认键立即提交 + 返回键取消 + 「编号 + 台名」浮层；走的是与点台**完全相同**的 `LiveController.tuneByNumber → tune` 流程 | 安装版实机：`[number] 收到数字键 1` → `[number] 提交编号 1 → CCTV-1`，画面切到 CCTV-1（`build/final_osd1.png`）；健康落盘出现 `cctv1hd.m3u8` / `CCTV1`；按 5 后出现 `CCTV5` 线路 |
| 安卓 TV 适配 | `AndroidManifest.xml`：新增 `leanback` / `touchscreen` / `gamepad` 三个 `uses-feature`（非必需）+ 注册 `LEANBACK_LAUNCHER` 分类，电视端可安装、可被启动器检索 | 清单改动已随工程提交（本机无 Android SDK/NDK，未重编 APK） |
| 隐藏两处文字 | 顶部状态行（`无信号 · 索引线路 · 93/383`）与底部来源说明（`公开索引 + 内置（…）`）整体删除，不再显示 | `build/final_list2.png`：画面左上只有台标与频道名，底部控制条只剩按钮 |
| 中国教育 4 台归央视 | 台名归一（`CETV-N` 与 `中国教育N台` 合并）+ `explicitGroupOf` 认定中国教育属央视体系；台标改为「教育1…教育4」以便区分 | 实机频道表：中国教育1–4 台在**央视频道**内，编号 22/23/24/25，线路 2/2/1/1 条（与 CETV 源合并） |

**本轮修掉的一个真 bug**：编号兜底分配原本只用「已按 id 用过的号」，导致英文台
（`Ando TV`）抢走苏州台预留的固定号，把 `苏州新闻综合` 挤到 331、`苏州4k` 挤到 752。
已改为「兜底分配避开前两轮全部已分配号」，并加回归断言「固定编号不被别的台抢走」。

**顺带修掉的旧缺陷**：`verify_live_sources` 有一条断言把恢复用的时钟写死成
`DateTime.now()`，快照时刻一旦离真实时间超过 5 分钟就必然失败（定时炸弹）。
已改为用「同一时刻」的假时钟恢复，与墙上时间无关。

**验收工具**（新增/修正）：
* `tooling/send_key.dart` —— Win32 按键注入（`PostMessage` + `SendInput` 双路径，
  带扫描码；跨线程 `SetFocus` 必须**保持线程附着直到按键发完**，否则焦点立刻被 IDE 抢回，
  Flutter 收不到 `WM_KEYDOWN`）。
* `tooling/gen_channel_numbering_doc.dart` —— 生成 `docs/channel-numbering.md` 完整对照表。
* `tooling/bmp_to_png.dart` 支持 `--crop=x,y,w,h,scale` 放大局部（已在上一轮加入）。

## 五之二、1.0.0 电视端安装兼容版（2026-11-08 12:2x 重打，与 0.1.0 并列保留）

上表三份 0.1.0 产物**原样保留为回退基线**，未覆盖、未改名。本轮只在
`android/app/build.gradle.kts` 的 `signingConfigs.debug` 增加 `enableV1Signing = true`
（保留 v2），其余业务代码、清单、依赖版本、ABI 均未改；版本同步到 pubspec /
`kAppVersionName` / `windows_installer.iss`。证书仍为同一 `debug.keystore`，
证书 SHA-256 `50347d028203789a389a39d87d277ae569d701791e7a70dfc7cd10711cdad6ea`
与 0.1.0 相同，且 `versionCode` 均为 1 → 两版本可**双向直接覆盖安装**，回退无需卸载。

| 产物 | 字节 | SHA-256 |
|---|---|---|
| `dist\Shunbo-1.0.0-full.apk` | 39 359 764 | `b7b173bc753263d40815984367328d049ed172c0dfea8309bba877218d944505` |
| `dist\Shunbo-1.0.0-lite.apk` | 20 698 082 | `edcc90383b91c9d6498debc20b69357bde9ac664adfd35158b973f77b4814b32` |
| `dist\Shunbo-Setup-1.0.0-x64.exe` | 25 294 120 | `61a920bcb0c58382ee24fd861ffc54263667110933d3fb73a3516733248f67c4` |

兼容验收（判据是同一条命令下的前后对照）：

| 判据 | 0.1.0 | 1.0.0 full / lite |
|---|---|---|
| `apksigner verify --min-sdk-version 22 --verbose` | `DOES NOT VERIFY` / `Missing META-INF/MANIFEST.MF` | `Verifies`；v1=true、v2=true |
| `META-INF` 签名三件套 | 0 个 | 各 3 个（MANIFEST.MF / CERT.SF / CERT.RSA） |
| `aapt2 dump badging` | versionName 0.1.0 | versionName 1.0.0 / versionCode 1 / minSdk 24 / target 36 |
| ZIP 完整性 | 通过 | 通过 |

Windows 侧 `shunbo.exe` 与 Setup 按既有流程用 `CN=Shunbo` 重签（Valid，
ProductVersion 1.0.0）；静默装→启动 8s 存活（标题 `顺播 shunbo`）→静默卸，残留 0。
回归 `verify_android_form` 77→**91/91**（新增 R12 的 14 条），全量门禁
**32 步 / 2619 断言 / 101.7s**，`--selftest` 6/6，`flutter analyze` 0 issue。

仍不声称完成：设备真实 `ro.build.version.sdk` 未取得；若 < 24，解析阶段虽已通过，
PackageManager 仍会返回 `INSTALL_FAILED_OLDER_SDK`（Flutter 3.47 引擎 AAR 下限 24，
属另立任务）。详见《顺播_1.0.0_电视端安装兼容适配说明》。

## 五之三、底部控制区自动隐藏 / 悬停唤出（2026-11-08，桌面形态）

| 验点 | 实现 | 证据 |
|---|---|---|
| 默认隐藏 | `AutoHideControlsPolicy.visible` 初值 false；控制条 `bottom: -82` + opacity 0 + `IgnorePointer` | 状态机断言 + 静态护栏 |
| 底部触发区停留唤出 | 底部 96px 触发带、连续停留 260ms | 逐帧时序断言（259ms 不显示 / 260ms 显示） |
| 平滑切换 | 220ms `easeOutCubic` 滑入 + 同步淡入 | 源码护栏（两处共用 `_autoHideAnim`） |
| 快速划过不误触发 | 离开即撤销计时；累计位移 > 120px 重算停留 | 4 组划过场景断言 |
| 离开 / 空闲再隐藏 | 离开延迟 300ms；空闲 3200ms | 299→300ms、3199→3200ms 临界断言 |
| 显示期间可操作 | 控制条 hover 暂停空闲；按钮 / 滑块 / 频道入口点击重置空闲 | 状态机 + 静态护栏 |
| 隐藏不遮挡主要内容 | 滑出屏幕 + `Stack` 裁切 + `IgnorePointer` | 静态护栏 |
| 重复触发与边界 | 隐藏后不重新武装、重复事件幂等、无界高度回退、reset | 幂等 / 边界组断言 |
| 形态保护 | 仅 `!tvMode && !touchInput` 启用；暂停 / 无信号 / 钉住强制显示 | 静态护栏 |

`verify_auto_hide_controls.dart` **147/147**；统一门禁 **33 步 / 2766 断言 / 96.5s**
全绿、`--selftest` 6/6、`flutter analyze` 0 issue。**不声称完成**：`flutter run -d windows`
受 VS 桌面运行时缺失阻塞，本轮 UI 手感未经真机鼠标走查；桌面形态下
「鼠标停在控制条上会暂停空闲隐藏」是刻意的边界决策（优先保证控制项可点），
如需严格「无论停在哪都按时隐藏」，改 `advance` 的 `!_overControls` 条件即可。

## 五之四、运行时版本兼容分支（2026-11-08，乐视 API 18 实测后）

| 要求 | 实现 | 证据 |
|---|---|---|
| 明确比较对象 | `Build.VERSION.SDK_INT`（整数 Android API 等级）；排除应用版本 1.0.0、`RELEASE` 串「4.3」、eUI 8.0 | `version_compat.dart` 常量 + 解析断言 A21–A34 |
| 低版本阈值 | 24，严格 `<`；边界 23→兼容 / 24→默认 / 25→默认 | B01–B05、C-low/C-high 两组、探针分支自检表 |
| 兼容分支范围 | 启动引导 + 能力探测 + 交付判定；播放内核 / 换源 / 投屏 / 续播 / UI / 数据格式 / 清单签名版本产物一律不碰 | G25 锁住 `player_bootstrap.dart` 不含 `legacyCompat`；G33–G36 锁住 minSdk/双签/版本号 |
| 运行时自动判断 | `SystemProbe.kt` 增量回传 `sdkInt` → `SystemChannel` 透明解析 → `main()` 启动时决策一次 | G07–G18 |
| 低于阈值走兼容分支 | 停掉 `shunbo/network` 精确快照与事件流，走既有 `DefaultNetworkStateProvider`；播放主链路不变 | G20–G23 |
| 满足要求保持默认流程 | `NetworkWatch.legacyCompat` 默认 false；非 Android 判 `notApplicable` 直接默认 | G20、E 组 17 条断言 |
| 版本比较清晰可靠 | 唯一整数入口 `compareToThreshold()`；`release` 只进诊断文本不参与比较 | B/C-release 组、G03–G06 |
| 分支切换可靠 | `CompatBranchSelector` 启动锁存一次，`switchCount` 恒 ≤1，重复调用幂等、不翻转 | F01–F12 |
| 检测失败处理 | Android 探测异常 / 缺失 / 非法 → 兼容分支 + `degraded`（保守侧）；非 Android 不适用 → 默认 | D01–D14、E-fail/E-invalid、G12 |
| 边界版本与版本信息缺失 | 1/16/17/18/21/22/23/24/25/26/28/30/36、null、`"4.3"`、`"1.0.0"`、`-1`、`0`、`1001`、NaN/±∞、bool、集合 | A / C / D 三组断言 |
| 跨层定义一致 | Dart / Kotlin / Java 三层共用阈值 24 与保守策略，构建期 7 条一致性断言 | G27–G32、H-consistency |

`verify_version_compat.dart` **227/227**；该轮当时统一门禁 **34 步 /
2993 断言 / 98.2s** 全绿（当前终态见 §五之五：35 步 / 3089）、
`--selftest` 6/6、`flutter analyze` 0 issue；`flutter build apk --release
--flavor full` 真实编译通过（101.1s，`minSdk 24 / 1.0.0 / versionCode 1`，
`apksigner @22` = `Verifies`，v1+v2 true）。探针 min16/min24 重建各 11/11。

**该轮不声称完成**：未实现低版本原生播放器（兼容分支在 API 18 上只保证判定与
原生自检入口可运行）；Flutter 版顺播在这台电视上仍装不上跑不了；无 adb，
真机运行态与兼容分支下运营商识别兜底表现未走查；版本仍 1.0.0+1，
`dist/` 三份 1.0.0 产物未重打（哈希未变）。详见
《顺播_版本兼容分支改动范围与验证结果》。**用户随后已明确选择「路线 B」，
原生播放器兼容分支见 §五之五。**

## 五之五、原生兼容分支 / 路线 B（2026-11-08，独立 APK）

| 验收项 | 要求 | 证据 |
|---|---|---|
| 可安装档位 | `minSdk 16 / target 22 / 仅 v1(JAR,SHA-1) / 仅 armeabi-v7a` | `build_legacy.py` 80 条断言：`apksigner @16/@18` 均 `Verifies`、SHA1-Digest、3 个 so stored 且 `zipalign -c` 全 OK |
| 与主程序隔离 | 独立包名 `com.shunbo.tv.legacy`，不动 gradle / pubspec / lib / 版本 / 既有产物 | 回归 G03/G06/I01–I03；`dist/` 0.1.0 与 1.0.0 全九份产物哈希未变 |
| 清单可解析性 | 同类同构包（min16 探针）已在该电视实测装上运行 | `331.jpg` 自检页；两包同构建链、同证书、同 `targetSdk 22`、同 banner/LEANBACK |
| 版本判定入口路由 | `SDK_INT` / 阈值 24 / 严格小于 / 失败保守 / 启动锁存一次 | `LegacyVersionCompat.java`；Dart-Java-Python 三层交叉断言 + 8 个分支场景 |
| 频道清单同源 | 441 台 / 516 线路，全部 `decodeVerified`，全 `.m3u8`，带拼音索引与台账结论 | `gen_legacy_catalog.dart`；回归 E01–E17 |
| 遥控器与换源 | 五态模式机 / 8 动作控制条 / 台号直达 / 换台合并 / 首帧 12s 超时 / 防绕圈 / 全失败明确提示 | 回归 C01–C12、D01–D12、L01–L16 |
| 收藏与续播 | 收藏 `StringSet` / 上次台号 / 上次线路，私有 `SharedPreferences`，首帧才落盘 | `Prefs.java`；回归 L07–L08 |
| 频道名检索 | 26 字母参差键盘 + 离线拼音索引（428 字）+ 六档评分 + 稳定排序 | `SearchPanel.java`；回归 L11–L13 |
| 可播台账 | 516 条线路全部有探测结论；死线只沉底不删除；清单 `probeAt` 与台账同源 | `probe_legacy_streams.dart` + `probe_ledger.json`；回归 M01–M06、E12–E17 |
| 可复现构建 | 同输入产出字节一致 | 连续两次构建 SHA-256 同为 `e3d3f310…` |
| 门禁 | 新增 `legacy-compat` 一步 | `verify_legacy_compat.dart` **127/127**；统一门禁 **35 步 / 3120 断言 / 108.4s**、`--selftest` 6/6、`flutter analyze` 0 issue |
| 启动入口可解析 | badging 的两个入口名必须在 dex 中命中（防「装得上、打开闪退」） | `build_legacy.py` 新增 3 条 badging→dex 反查断言；回归 A12、J10/J11、K01/K02 |
| 崩溃可观测（无 adb） | 启动失败屏显原因 + 私有文件留痕 + 菜单键回看 | 回归 K03–K10；`CrashReport.java`；`onCreate` 整段 `try/catch(Throwable)` |

产物：`dist/Shunbo-Legacy-1.0.0-armv7a.apk`，3,427,674 B，
SHA-256 `e3d3f3107cdbd2daf3013340485659a556d278ac7a566086a13a8ef090c4b002`，
证书 `50347d02…cd6ea`（与 1.0.0 主包、探针相同），versionName 仍 1.0.0。

### 交互打磨与可播台账（2026-11-08，真机「能播」之后）

| 项 | 结果 |
|---|---|
| 台账总量 | 516 条线路 **478 可达（92.6%）** / 38 死线（7.4%）；441 台 **406 台至少一条可达（92.1%）** / 35 台全失败 |
| 死线归因 | `not m3u8` 14 / `HTTP 403` 8 / `HTTP 404` 5 / `timeout` 8 / 连接关闭 2 / 分片 404 1 |
| 死线处置 | **只沉底、不删除**（PC 侧可达 ≠ 电视侧可达）；排序 `probeOk` 组号 > `probeMs` 升序 > `verified` > `rank` 降序 > http 优先 > 原序号 |
| 1–19 台走查 | 17 台可播；CCTV-5（init 超时）与 河南卫视（HTTP 403）为死线，均单线路无备份 |
| 交互形态 | 五态模式机 + 8 动作控制条 + 右侧分组抽屉 + 台号直达 + 26 字母拼音检索 + 收藏 / 上次观看 |
| 台账边界 | 网络可达性判据，**不等价于解码成功**；PC 网络发起，与电视网络可能不同；超一月须重跑（本轮 `2026-11-08T11:59:35Z`） |

详细数字、1–19 台明细表、35 台全死名单与交互对照见《顺播_兼容版遥控器交互与可播台账》md/html/pdf。

### 首轮真机回填与闪退修复

用户回填：首轮包**安装成功、打开闪退**。根因经 `aapt2 dump badging` 静态确证：
启动入口被拼成 `com.shunbo.tv.legacy.LegacyPlayerActivity`，而 dex 里只有
`com.shunbo.legacy.LegacyPlayerActivity`（清单 package 与 Java 源码包不同名 +
相对 activity 名）。安装阶段不校验类存在，故装得上；打开时 `loadClass` 失败。
修复为 activity 写全限定名（保留包名/versionCode/证书 → 可直接覆盖安装），
并补断言、崩溃自显页与内核失败真实原因展示。旧包备份在 `dist/_broken/`。
**第二轮真机回填：能安装、能播放。** `00c1829f…` 修复版覆盖安装成功、打开不闪退、
正常起播 —— 安装 / 启动 / 起播三项已在乐视 S50 Air 上确证，类名根因修复有效。

**仍不声称完成**：交互改动之后的遥控器**逐键**（↑↓/←→/数字键/OK/菜单/搜索）与换台换线
尚未在真机走查；焦点框可见度、抽屉行高、280ms 换台手感未验收；可播占比已有台账数据
（406/441 台至少一条可达），但「电视侧实际播出比例」仍未知——台账是 PC 网络判据；
252 条 https 在 API 18 上的 native TLS 未验证（有 http 优先 + 连续 3 次失败跳过兜底）；
FFmpeg 软解在 Cortex-A9 上不承诺 1080p/4K；台账与清单保质期超一月须重跑；
投屏 / 跨端续播 / 诊断 / 组播 / 官方源令牌刷新等主程序功能不在本分支范围；
dex 里唯一 API 19+ 引用 `MediaDataSource`（ijkplayer 未使用路径）已登记。
回填记录与剩余走查项见《顺播_兼容版遥控器交互与可播台账》§七。

## 五之六、单包（1.0.1）：一个 APK 同时覆盖 API 16–36

| 验收项 | 要求 | 证据 |
|---|---|---|
| 一个安装包 | 交付物只有 `dist/Shunbo-1.0.1-full.apk`，不再让用户按设备选包 | `tooling/merge_single_apk.py` 24 条内置断言全绿 |
| minSdk 16 | `aapt2 dump badging` 实测 `minSdkVersion:'16'`，targetSdk 保持 36 | merge 报告 `legacy/single/single_report.json`；回归 N07 |
| 入口唯一且会分流 | 桌面/电视两个 category 都指向 `com.shunbo.legacy.RouterActivity` | badging 的 `launchable-activity` 与 `leanback-launchable-activity` 同名；回归 N02/N10 |
| 老系统不碰 Flutter | `classes.dex` 是原生（含 RouterActivity/LegacyPlayerActivity 且不含 `io/flutter`、`androidx`），Flutter 顺延 classes2/3 | 回归 N05/N08；merge 断言「主 dex 不含 Flutter / androidx」 |
| 老系统不加载 androidx Provider | manifest 不声明任何 `<provider>` / `androidx.startup` | 回归 N03；原因写在 `legacy/single/AndroidManifest.xml` 注释 |
| 资源 ID 不被改动 | 新 manifest 用 `--stable-ids` 锁定，`LaunchTheme`/`ic_launcher`/`tv_banner` ID 与 Flutter 产物一致 | merge 断言 + `aapt2 dump resources` 比对 |
| 双签 | v1(JAR/SHA-1) + v2，`apksigner verify --min-sdk-version 16/18` 均 `Verifies` | merge 断言；回归 N06 |
| Flutter 构建链的硬限制被记录 | 改 minSdk 16 会被 `flutter build` 改写回 24（实测），所以单包必须绕开它 | README §16 表格；`DependencyVersionChecker.kt:117` |
| 频道源同一套 | 清单来自主程序运行时导出（`unified_channels.json`），不是另一套子集 | 回归 E01–E03；`sourceKind` 标注来源 |
| **清单真的进了包** | 包内存在 `assets/channels.json` 且与 `legacy/assets/channels.json` **字节一致**、规模一致 | merge 断言；回归 N12（Java `ASSET` 名与打包脚本逐字相同）/ N13（报告 `catalog` 与当前清单同规模） |
| 版本同源 | pubspec `1.0.1+2` / `kAppVersionName` / 安装器 / 单包清单 / 独立包五处一致 | 回归 R12、I01、N09 |

> **归档的坑（已修）**：`flutter build` 的产物里只有 `assets/flutter_assets/**`，
> **没有** `assets/channels.json`。第一版单包只搬 Flutter 的条目，结果原生界面一打开
> 就是「频道清单加载失败」。现在由组装脚本从 `legacy/assets/` 搬运并逐层断言。


**未验证（不声称可用）**：本机无 Android 设备/模拟器，`1.0.1` 单包只在静态层面
确证（minSdk、入口可解析、dex 顺序、签名档位、资源 ID）。API 18 上「装得上、
起得来、原生界面能播」与 API 24+ 上「Flutter 界面照常」都要等真机回填。
首次安装建议：先装单包 → 若老电视能起来但 Flutter 侧在手机上异常，可直接回退到
`dist/_prev/` 里的旧包（归档机制见 §五之五）。

## 五之七、电视端交互修订（1.0.1 同版重打，2026-11-09）

| 验收项 | 要求 | 证据 |
|---|---|---|
| 红标① 去掉 `·N` | 频道行只有「台号 + 台名」 | `ChannelPanel.render()`；回归 O09 |
| 红标② 台号正确 | `CCTV-1..17` = 1..17，`CCTV-2` 显示 2 | 清单 `num` 字段；回归 O01 / O02 |
| 红标③ 切台成功后全屏 | 首帧后隐藏 topBar / 底部提示，交互时再唤出 | `hideOsdForPlayback()`；回归 O10 |
| 4K 归集置顶 | 各列表内 4K 整组在最前，组内顺序稳定，台号不变 | `is4K` 字段 + `filtered.addAll(fourK)`；仿真 O03 / O04 |
| 4K 规则两端同源 | 手机与电视用同一条 `ChannelQuality.is4K` | 回归 O19 |
| 默认只看本地 | 默认江苏·苏州·市模式，苏州 7 台；央视 / 卫视恒可见 | `regions.default*`；仿真 O05 |
| 选省 / 选市 | 选省加载本省全部（江苏 53），选市只加载本市（南京 4） | `RegionPanel` 两列；仿真 O06 / O07 |
| 列表准确清晰 | 选项台数 = 过滤结果台数；切地区后当前台不越界 | 回归 O07 / O12 |
| 不丢频道 | 「其它城市」回捞 599 台未归属台 | 回归 O06；`RegionPanel` 末项 |
| 地区偏好可续 | 落 SharedPreferences，开机先恢复地区再定位上次观看 | 回归 O12 / O13 |
| 缓冲不卡 UI | 主线程不做 stop/reset/release，回调回主线程 | 回归 O15 / O16 |
| 缓冲可恢复 | 首帧超时 + 缓冲看门狗 + IO 超时 + 重连风暴抑制 | 回归 O17 / O18 |
| 主程序同步 | 4K 置顶、默认本地、按省切换 | `live_page.dart` / `live_region.dart`；回归 O19 |
| 版本不漂移 | 仍为 `1.0.1+2`，回退基线保留 | 回归 R12 / I01 / N09 |

> **未验证（不声称可用）**：三项行为均为静态断言 + 数据仿真 + 纯逻辑状态机，
> 未经 API 18 真机走查。缓冲区恢复耗时、软解 4K 表现、遥控器逐键手感需上机回填。

## 五之八、苏州地方台修复与频道栏重设计（1.0.1 同版重打，2026-11-09）

| 验收项 | 判据 | 证据 |
|---|---|---|
| 苏州 7 台不再「全部不可用」 | 369–373 / 618 / 619 每台都至少一条实测可达的明文线路 | `plaintext_mirrors.json` 182/576 通过；`channels.json` 镜像 187 条 / 176 台；构建断言「Suzhou local channels all have plaintext fallback」 |
| 明文镜像不假造 | 只写 m3u8 2xx + 首分片 2xx 的同路径 http，且只补原本无明文的台 | `probe_plaintext_mirrors.dart`；回归 P01–P05 |
| HTTPS 不再永久跳过 | 两遍扫描：优先明文，第二遍仍试完加密线路；手动换线清经验值 | `PlaybackController.openNext/findNext/switchTo/retryAll`；回归 D06/P07/P10 |
| 异常有明确提示与恢复动作 | 原因含 TLS/证书链、已尝试条数；OK 一键重试，控制条有「重试」 | `onAllStreamsFailed(channel, reason)`；回归 P09 |
| 列表背景透明 | 65% 压暗浮层、非焦点行无底色、chip 与状态卡半透明 | `Ui.PANEL_SCRIM` / `CARD_SCRIM`；回归 P11 |
| 下方不再留白 | 行数按屏高计算、行高 weight 均分 | `ChannelPanel.computeRows`；回归 P12 |
| 当前频道与播放状态明确 | 底部状态卡常驻显示台号 / 台名 / 线路 / 播放态 / 地区 / 地方台数 | `setPlaybackState()`；回归 P13 |
| 地区切换入口清晰、步骤少 | 绿键、chip、状态卡、控制条四处入口；三列面板含「最近使用」，选中即应用关闭 | `RegionPanel` / `ControlBar`；回归 P14/P15 |
| 切换稳定、列表准确 | 不重启播放器、不打断画面；省=全省、市=本市、其它城市回捞 | `ChannelCatalog.setRegion` + `playingChannel`；回归 P16/P17 |
| 版本与其它功能不回退 | 仍 `1.0.1+2`；主程序 Dart 侧本轮零改动；频道/台号/原始线路一条没删 | 门禁 35 步 / 3171 断言；`flutter analyze` 0 |

**未验证（不声称可用）**：无 API 18 真机/模拟器。明文线路在电视网络的实际起播、
乐视遥控器绿键键码映射、透明浮层在老屏上的对比度、4K 软解效果均需上机走查。

## 五之九、错误提示收起 / 浮层自动隐藏 / 线路扩容 / 设置中心（1.0.1 同版重打，2026-11-09 14:08）

| 验收项 | 判据 | 证据 |
|---|---|---|
| 切到播不了的台，错误框不再常驻 | 提示按 2/3/5 秒（默认 3）定时清屏，不再停在画面中央 | `failHintTask` / `scheduleFailureDismiss()` / `cancelFailureTasks()`；回归 Q07 |
| 失败后自动回到能播的台 | `lastGoodChannel` 只在 `onFirstFrame()` 出画后记录；提示结束按开关自动回退 | 回归 Q08；`prefs.failFallback()` 默认开 |
| 不跟用户抢遥控器 | 任意按键重置空闲计时并撤销待执行的回退 | `onKeyDown()` 开头 `resetOverlayHide(); cancelFailureTasks();`；回归 Q09 |
| 无操作时频道列表自动隐藏 | 控制条 / 频道栏 / 地区 / 检索共用计时器，默认 5 秒，可设 3/5/8/10 秒或不隐藏 | `scheduleControlHide()` / `resetOverlayHide()`；回归 Q06；设置页刻意不自动收起 |
| 播放源变多（先修误判） | 302 跟随后用最终 URL 解析相对分片；可达 612→1046、有活线台 503→605、CCTV-1 可达 2→7 | `probe_legacy_streams.dart`；回归 Q20/Q23/Q24 |
| 播放源变多（再补新线） | 9 份固化快照、多源轮转、两段实测，197 候选 → 53 条通过 / 24 台 / 8 条高清 | `collect_extra_streams.dart` + `extra_streams.json`；回归 Q15/Q19/Q25 |
| 新增线路不抢首播、不灌死链 | `extra` 单独一层排在原有可达线路之后、死线之前；每条带 `probeOk` / 来源 / 耗时 | `gen_legacy_catalog.dart`；回归 Q16/Q21 |
| CCTV-1 有 720/1080 高清源 | 4 条高清（720P×1、1080P×3），台账可达 2 条；自动档优先清晰度先试可达高清 | `quality` 字段 + `applyQualityPriority()`；回归 Q12/Q17 |
| 设置功能不是装饰 UI | 12 项设置 + 4 个动作全部接线：启动、浮层、失败、播放、手感、动作六组（「顶部信息条」开关已随信息条下线） | `SettingsPanel.java` / `Prefs.SCHEMA=2`；回归 Q01/Q02/Q13/Q14/Q22 |
| 开机自启与启动直达 | `BOOT_COMPLETED` / `QUICKBOOT_POWERON` 读开关拉起 LAUNCHER，extras 经 `RouterActivity` 透传；启动频道三选一 | `BootReceiver.java` + 两个 manifest；回归 Q03/Q04/Q05 |
| 设置入口可达 | 控制条「设置」按钮 + 蓝键 / `KEYCODE_SETTINGS` | `ControlBar.A_SETTINGS`；回归 Q11 |
| 升级不丢数据、其它功能不回退 | `SCHEMA=2` 但收藏 / 上次观看 / 地区旧键名一个没改；主程序 Dart 侧零改动 | 回归 Q22；R12 / I01 / N09 |
| 两个包都是新数据 | 单包内 `assets/channels.json` 与源字节一致（1046 台 / 2135 线路） | 单包 24/24 断言；回归 N13 / J05 |
| 全量门禁 | 35 步 / 3196 断言全绿；`--selftest` 6/6；`flutter analyze` 0 | `verify_all.dart`；兼容分支 203/203、独立包 80/80 |

**未验证（不声称可用）**：仍无 API 18 真机 / 模拟器。开机自启在电视 ROM
白名单下是否放行、蓝键键码映射、设置页焦点框与老屏对比度、扩展线路
**画面内容是否与台名一致**（PC 侧只验可达 + 分片可下载，不验解码与内容）、
4K 软解表现，均需上机走查。超过一个月须重跑台账与扩展线路实测。

## 五之十、地区切换入口改设置 + 浮层自动隐藏默认 30 秒可调（1.0.1 同版重打，2026-11-09 15:17）

| 验收项 | 判据 | 证据 |
|---|---|---|
| 频道列表选台不再误弹省市面板 | 列表内 ↓ 末行不再聚焦底部「切换地区」卡；OK 永远只切台，无「弹省市面板」分支 | `ChannelPanel` 删 `cardFocused` 及全部引用；`DPAD_DOWN` 改 `if (focus < filtered.size() - 1) focus++`；回归 L06 |
| 地区切换入口收进设置 | 设置页新增「地区切换」条目，OK 直接 `setMode(MODE_REGION)` 打开省/市面板，不回退播放态 | `SettingsPanel.ACTION_REGION=4` + `Listener.onRegionFromSettings()`；`LegacyPlayerActivity.onRegionFromSettings()`；回归 P14 / Q06 |
| 默认仍是当前市所有电台 | `Prefs.region` 不变（默认江苏·苏州），`visible` 按地区过滤，切地区不重启播放 | `playingChannel`；回归 P17 |
| 其余入口仍可达 | 绿键 / 导视键、控制条「地区」、底部状态卡触摸点击均可打开地区面板 | `regionLine` 文案 `绿键 / 设置 / 点此卡 切换省·市` |
| 浮层自动隐藏默认 30 秒 | 无操作超过 30 秒才收起回播放态 | `Prefs.K_PANEL_IDLE_MS` 默认 `30000`；`idleHideMs = 30000L`；回归 C03b |
| 停留时长可手动调 | 设置页「浮层自动隐藏」提供 不隐藏/5/10/15/20/30/60 秒 七档 | `SettingsPanel` 选项数组 `{0,5000,10000,15000,20000,30000,60000}`；回归 Q06 |
| 设置页本身不自动收起 | 改值时不被踢回播放态 | `MODE_SETTINGS` 不调 `scheduleControlHide()` |
| 升级不丢数据、功能不回退 | 只动 `legacy/` 与 `tooling/`，主程序 Dart 零改动 | 单包内 `assets/channels.json` 字节一致；回归 N13 / J05 |
| 全量门禁 | 35 步 / 3196 断言全绿；`--selftest` 6/6；`flutter analyze` 0 | `verify_all.dart`；兼容分支 203/203、独立包 80/80、单包 24/24 |

**未验证（不声称可用）**：仍无 API 18 真机 / 模拟器。本次两处改动（地区入口收敛、
浮层隐藏默认 30s）为静态确证 + 仿真 + 回归断言覆盖，未上机实测遥控器手感；自启
白名单、蓝键键码、设置页焦点框与老屏对比度、扩展线路内容是否与台名一致、4K 软解
仍需上机走查。超过一个月须重跑台账与扩展线路实测。

## 五之十一、换台时不再弹出顶部调试信息条（1.0.1 同版重打，2026-11-09 15:36）

| 验收项 | 判据 | 证据 |
|---|---|---|
| 换台（↑↓ / CH± / 数字直达 / 频道键 / 列表选台）不弹顶部调试条 | 换台全程顶部信息条保持隐藏（默认「首帧后隐藏」），只保留画面中央「台号+台名」横幅 | `startChannel()` / `zap()` 改 `if (prefs != null && prefs.showTopBar()) showOsd()`；回归 O17 |
| 首帧后隐藏的设计不变 | 出画后顶部条仍隐藏；唤出交互仍显示它作上下文；失败路径仍弹条暴露错误 | `hideOsdForPlayback()` 与 `setMode()` 的 `showOsd()` 未动 |
| 「顶部信息条 = 常显」用户仍可见 | 设置了常显就照常显示，不受换台影响 | `prefs.showTopBar()` 守卫 |
| 升级不丢数据、功能不回退 | 只动 `legacy/` 与 `tooling/`，主程序 Dart 零改动 | 单包内 `assets/channels.json` 字节一致；回归 N13 / J05 |
| 全量门禁 | 35 步 / 3197 断言全绿；`--selftest` 6/6；`flutter analyze` 0 | `verify_all.dart`；兼容分支 204/204、独立包 80/80、单包 24/24 |

**未验证（不声称可用）**：仍无 API 18 真机 / 模拟器。本次改动（换台不再弹顶部条）为
静态确证 + 仿真 + 回归断言覆盖，未上机实测遥控器手感；自启白名单、蓝键键码、设置页
焦点框与老屏对比度、扩展线路内容是否与台名一致、4K 软解仍需上机走查。超过一个月须
重跑台账与扩展线路实测。

#### ⑫ 频道号改中性白（截图红标）

| 验收点 | 期望 | 证据 |
|---|---|---|
| 顶部信息条频道号不再是亮蓝 | 红框圈住的「71」由亮蓝改为白色，与台名靠字号/字重区分 | `topNumber.setTextColor(Ui.TEXT)`；O18 |
| 换台中央横幅台号不再是亮蓝 | 「台号 + 台名」横幅数字转白，与主流 IPTV 一致 | `numberDigits.setTextColor(Ui.TEXT)`；O18 |
| 数字直达输入复用同一数字视图，表现统一 | 输台号时数字亦为白色 | 同一 `numberDigits` 文本框；O18 |
| 其它强调位（当前播放行、进度）未被波及 | `Ui.ACCENT` 仍用于播放行 / 进度，未全局改色 | `Ui` 常量未动；回归 `row.setTextColor(ACCENT)` |
| 升级不丢数据、功能不回退 | 只动 `legacy/` 与 `tooling/`，主程序 Dart 零改动 | 单包内 `assets/channels.json` 字节一致；回归 N13 / J05 |
| 全量门禁 | 35 步 / 3198 断言全绿；`--selftest` 6/6；`flutter analyze` 0 | `verify_all.dart`；兼容分支 205/205、独立包 80/80、单包 24/24 |

**未验证（不声称可用）**：仍无 API 18 真机 / 模拟器。频道号转白后，在浅色台标 / 浅色
画面（雪景、白底台标）上的可读性、以及遥控器手感，仅静态确证 + 仿真 + 回归断言覆盖，
需上机走查；自启白名单、蓝键键码、设置页对比度、扩展线路内容一致性、4K 软解仍待上机。
超过一个月须重跑台账与扩展线路实测。

#### ⑬ 频道导航栏新增内容分类（地方频道之后，2026-11-09 15:57）

| 验收点 | 期望 | 证据 |
|---|---|---|
| 频道栏在「地方频道」之后依次出现 6 个内容分类 | 新闻、体育、影视、少儿、纪实、生活，顺序严格一致 | `ChannelPanel.buildGroups()` 在 `LOCAL_GROUP` 后 `insertAt` 依次插入 `THEMATIC` 六常量；回归 O19 |
| 新增栏目样式与现有一致 | 复用 `Ui.styleChip` + `rebuildChips`，边框/字号/焦点框/选中态与既有组 chip 完全相同 | 同渲染路径，无新增样式分支 |
| 排序规则与现有一致 | 分类内按 `channels.json` 原序；4K 优先稳定分区不变 | `rebuild()` 仍走既有排序/分区逻辑，仅改过滤条件 |
| 交互逻辑与现有一致 | ←→ 组切换、触摸点击、焦点进入行为不变 | chip 走同一 `rebuildChips` 事件绑定 |
| 内容分类为叠加模型，与手机端对齐 | 同一频道可同时出现在「地方频道」与「新闻」等（如苏州新闻综合） | `ChannelCatalog.inCategory()` 叠加匹配，镜像 Flutter `LiveChannel.inCategory` |
| 主程序 Dart 零改动、单包清单字节一致 | 仅改 `legacy/` 与 `tooling/`；`assets/channels.json` 同源不变（1046 台 / 2135 线路） | 回归 N12 / N13 / J05；单包 24/24 |
| 全量门禁 | 35 步 / 3199 断言全绿；`--selftest` 6/6；`flutter analyze` 0 | `verify_all.dart`；兼容分支 206/206、独立包 80/80、单包 24/24 |

**未验证（不声称可用）**：仍无 API 18 真机 / 模拟器。分类命中依赖台名关键词，召回率
与分类面板实际展开效果仅静态确证 + 仿真 + 回归断言覆盖，未上机实测；台名归一化致少量
「后缀含类型」的台（如 CCTV-13 新闻）少命中「新闻」，与手机端轻微发散；自启白名单、
蓝键键码、设置页对比度、扩展线路内容一致性、4K 软解仍待上机。超过一个月须重跑台账
与扩展线路实测。

#### ⑭ 换台误弹省市面板修复 + 省市面板排版优化 + 升版 1.0.2（2026-11-09 16:20）

| 验收点 | 期望 | 证据 |
|---|---|---|
| 频道栏去掉「地区·苏州 ▾切换」chip（截图红标） | 分组 chip 只剩 全部/收藏/主分类/新闻…生活，不再有地区 chip | `buildGroups()` 删除 `GROUP_REGION` 镜像分组；`!has(channelPanel,'GROUP_REGION')`；P14 |
| 列表内 OK 只切台，第二次/多次换台不再弹省市面板 | OK 永远走 `ChannelPanel.activate()→onChannelPicked`，不会打开省 / 市选择 | 状态卡 `infoCard.setFocusable(false)` 且删除 `setOnClickListener`；P14 |
| 根因消除：状态卡不再吞 OK | 状态卡原 `setFocusable(true)`+clickable 是整窗唯一可聚焦控件，OK 被当点击 → `onRegionRequested()` | `infoCard.setFocusable(false)` / `setClickable(false)`；P14 |
| 地区切换入口仍可用 | 绿键 / 导视键、控制条「地区」、设置「地区切换」三处保留 | `case KEYCODE_PROG_GREEN`、`ControlBar.A_REGION`、`onRegionFromSettings`；P14 |
| 省市面板字号放大 | 省 / 市 / 最近行 15sp → 19sp，表头 17sp，标题 20sp | `RegionPanel.buildColumn` `Ui.text(context, 19, …)`、`(17, …)`；`title=20` |
| 省市面板行距收紧 | 旧 `weight=1` 拉满全屏 → 固定 38dp 顶部紧凑排列 | `new LinearLayout.LayoutParams(MATCH_PARENT, rowHeight)`，`rowHeight=dp(38)` |
| 版本升 1.0.2（versionCode 3）五处同源 | pubspec / kAppVersion / manifest / 单包 / 独立包 / 安装器 / 帮助文案一致 | R12 / I01 / G14 / G36 / A04 / N09 / J03 |
| 单包内清单字节一致、主程序不回退 | 仅改 `legacy/`、`tooling/` 与版本常量；`assets/channels.json` 同源不变（1046 台 / 2135 线路） | N12 / N13 / J05；单包 24/24 |
| 全量门禁 | 35 步 / 3199 断言全绿；`--selftest` 6/6；`flutter analyze` 0 | `verify_all.dart`；兼容分支 206/206、独立包 80/80、单包 24/24 |

**未验证（不声称可用）**：仍无 API 18 真机 / 模拟器。换台不再误弹、省市面板字号 / 行距
为静态确证 + 仿真 + 回归断言覆盖，遥控器逐键手感与状态卡去焦点后的视觉一致性需上机走查；
自启白名单、蓝键键码、设置页对比度、扩展线路内容一致性、4K 软解仍待上机。超过一个月须
重跑台账与扩展线路实测。

### 五之十五、三处界面修正（顶部条彻底移除 / chip 横向滚动 / 省市面板再放大，2026-11-09 17:09）

| 验收点 | 结果 | 证据 |
|---|---|---|
| 顶部诊断条任何时刻都不显示 | 字段 `topBar`/`topNumber`/`topName`/`topMeta`、构建代码、`refreshTop()` 及 15 处调用、`showOsd()` 及调用全部删除 | `LegacyPlayerActivity.buildRootView` 注释块；O10 负向断言 `!has(activity,'topBar')` |
| 换台仍有反馈 | 中央「台号 + 台名」横幅；`zap()` 连按期间立即刷新（横幅优先取 `zapTarget`） | `showChannelBanner()`；O17 |
| 设置项不留无效开关 | 「顶部信息条」条目与 `Prefs.showTopBar()` 删除，`set_show_top_bar` 残留键在恢复默认时清掉 | Q02（12 项）/ Q14；`Prefs.resetSettings` |
| 分组 chip 超出可滚动 | `HorizontalScrollView` + `chips` `WRAP_CONTENT`；分组顺序/样式/点击/←→ 全不变 | `ChannelPanel.chipScroll`；O20 |
| 选中分组自动可见 | `scrollChipIntoView()`：左右各 10dp 余量 `smoothScrollTo`，「其它」不再被截断 | `ChannelPanel.scrollChipIntoView`；O20 |
| 不重演「OK 被抢」 | `chipScroll` / `chip` 均 `setFocusable(false)`，`FOCUS_BLOCK_DESCENDANTS` | O20；对照 §24 状态卡根因 |
| 省市面板字号再放大 | 行 19 → 22sp、列头 17 → 18sp、标题 20 → 21sp | `RegionPanel` `ROW_SP=22f` / `HEAD_SP=18f`；O21 |
| 铺满、不留空白 | 行数按屏高算（`computeRows`，7~14 行），行 `LayoutParams(MATCH_PARENT, 0, 1f)` 均分列高 | `RegionPanel.computeRows`；O21 |
| 层级更清晰 | 名称主字色、台数 `0.82` 相对字号 + 次字色、当前地区「●」+ `ACCENT`、焦点行亮蓝底白字 | `RegionPanel.applyRowStyle`；O21 |
| 放大后不溢出 / 不错位 | 标题 / 提示 / 页脚 / 每行统一 `ellipsize(END)`；提示与页脚文案精简 | `setEllipsize(TextUtils.TruncateAt.END)`；O21 |
| 全量门禁 | 35 步 / **3201** 断言全绿；独立包 80/80、单包 24/24；清单 1046 台 / 2135 线路不变 | `verify_all.dart`；兼容分支 208/208 |

**未验证（不声称可用）**：顶部条删除后的换台反馈是否足够、chip 滚动在遥控器上的手感与
边界、22sp 在 720p 实屏的观感、12 行列表的翻页节奏，均只有静态确证 + 仿真 + 回归断言，
需上机走查；自启白名单、蓝键键码、设置页对比度、扩展线路内容一致性、4K 软解仍待上机。

### 十六、音画不同步（2026-11-09 19:00）

| 点 | 做法 | 证据 |
|---|---|---|
| 起播相位对齐 | `configure()` 加 `sync-av-start=1`；单独回退改回 `0` | `PlaybackController.configure`；独立包 80/80 |
| 视频队列封顶 | `video-pictq-size=3`，掐断「解码慢 → 队列积压 → 延迟累积」 | 同上 |
| 帧率上限保护 | `max-fps=30`，避免 1080i 场率被当帧率硬顶 | 同上 |
| 偏差可观测 | 新增 `clockRate()` = Δ播放位置/Δ墙钟（10 秒窗口）；暂停不刷新、pts 回退窗口丢弃、换线清基准 | `PlaybackController.clockRate` / `resetClockProbe` |
| 诊断页可判读 | 「时钟」行按 1.01 / 0.99 分档给结论；新增「同步策略」行 | `LegacyPlayerActivity.buildHelp` |
| dex 已核对 | `sync-av-start` / `max-fps` / `video-pictq-size` / `clockRate` / 「时钟」「同步策略」均在 `classes.dex` | 包内 dex 字符串比对 |
| 全量门禁 | 35 步 / **3201** 断言全绿；独立包 80/80、单包 24/24 | `verify_all.dart`；`legacy/build_report.json` |

**未验证（不声称有效）**：三项参数在 API 18 真机上的实际效果、`sync-av-start` 对起播耗时的影响、
`max-fps=30` 对 50 场源流畅度的影响、「时钟」读数分档是否可分辨，均需上机；
P1 缓冲后 `seekTo(getCurrentPosition())` 自愈、P2 硬解对照实验尚未实施。

### 十七、央视换台慢 / 播放中缓冲（2026-11-09 19:35）

| 点 | 做法 | 证据 |
|---|---|---|
| 选快源 | 自动档插入 `speedKey(probeMs)` 分档（≤1.2s / ≤2.2s / 慢），顺序＝可达→速度→画质；手动档不变 | `ChannelCatalog.speedKey`；O25 读台账重排 |
| 换台量化改善 | 央视首条 ≤1.2 秒 18→26 台；CCTV-1 2212→116ms、CCTV-11 1632→253ms | O25 `首条快源 x/59 台` |
| 起播少等 | `analyzeduration` 2s→1s、`probesize` 1MB→512KB | `PlaybackController.configure` |
| 坏线快跳 | 首帧超时默认 12s→8s；新增 5 秒快速失败（仅当还有未试候选） | `scheduleQuickFail`；O22 |
| 卡顿止损 | 60 秒 3 次缓冲自动换线（首帧后计数、换线清零） | `noteBufferHit` / `bufferHitsInWindow`；O23 |
| 可验证读数 | 诊断页「最近 60 秒缓冲 N 次」「起播策略」；设置文案写清自动档取舍 | `LegacyPlayerActivity.buildHelp`；O24 |
| 全量门禁 | 35 步 / **3205** 断言全绿；legacy 212/212；单包 24/24 | `verify_all.dart` |

**未验证（不声称有效）**：起播秒数与缓冲次数未实测；`analyzeduration=1s` 对少数源可能不足；
5 秒快速失败会提前放弃 6–8 秒才出画的慢源；扩展线路内容一致性仍未逐条核验。
一档取舍：自动档画质下降（CCTV-1 576P），可在设置里改「1080P 优先」。

### 十八、换台慢 / 换不了台（2026-11-09 19:57）

| 点 | 做法 | 证据 |
|---|---|---|
| 候选判定 | `hasMoreCandidates(int currentIdx)` 排除当前线路与 resolver 线路；最后一条交给总超时 | O26；`PlaybackController` |
| 单线路台不再误杀 | 597 台单线路中 347 台唯一线路不可达，旧判据会在 5 秒判全灭 | O26 + 台账统计 |
| 快速失败窗口 | 5 s → 6 s（老盒子软解 + 跨境源首帧常 5～6 s） | O22 |
| 死台跳过 | `Channel.hasReachableStream()`；换台自动跳过并提示；频道栏 / 数字直达仍可进 | O27；`resolvePlayable` |
| 死台快速判定 | 台账全灭的台首帧只等 4 s，失败原因写明「该台台账无可用线路」 | O27；`DEAD_CHANNEL_TIMEOUT_MS` |
| 探测窗口 | `analyzeduration` 1 s→1.5 s、`probesize` 512 KB→1 MB（压太小会让 HEVC 源识别失败） | O23 |
| 换台回调隔离 | `failCurrent` 延迟重建加代际 + 频道双校验；`invalidatePending()` 换台即作废旧回调 | O28 |
| HTTPS 误判 | 只有内核真错误（`what >= 0`）计入 TLS 失败；超时 / 快速失败 / 卡顿换线不计 | O28 |
| 起播音画一致 | 起播静音至首帧，1.2 s 兜底解静音（防「有画无声」） | O29；`muteForStart` |
| 缓冲后对齐 | 停顿 ≥1.5 s 才 `seekTo(当前位)` 重锚 `frame_timer`；同线路 ≤3 次、间隔 ≥8 s | O29；`alignClockAfterStall` |
| 诊断可判读 | 「换台：上次出画 X ms · 本次线路切换 N 次」「同步：…再对齐 N 次」 | `buildHelp` |
| 全量门禁 | 35 步 / **3209** 断言全绿；legacy 216/216；单包 24/24 | `verify_all.dart` |

**未验证（不声称有效）**：无 API 18 真机；6 秒阈值、4 秒死台等待、静音解锁时点、
再对齐实际观感均未实测；跳过判定依赖台账（`probeAt` 2026-11-09），台账过期可能跳过
其实能播的台；再对齐在个别直播源上可能触发一次重新缓冲。

### 十九、4K 输出门槛（2026-11-09 20:35）

| 点 | 做法 | 证据 |
|---|---|---|
| 版本检测 | `Build.VERSION.SDK_INT >= 24`；API 21 才有 MediaCodecList，故门槛定 24 | O30；`DeviceCapability` |
| 输出宽度 | `Display.getRealSize()` ≥ 3840，1080p 面板不做 4K | O30 |
| 硬解能力 | `areSizeAndRateSupported(3840,2160,24.0)`；排除 `OMX.google.` / `c2.android.` 软解 | O30 |
| 内存 | `totalMem >= 2048 MB` | O30 |
| 软解即不达标 | `qualityCeiling(ctx, hardDecode)`；改解码需重启，设置与诊断均写明 | O32 |
| 载入期剥离 | `ChannelCatalog.load(ctx, maxQuality)`：剥 2160、4K 台整台隐藏、普通台留一条兜底 | O31 |
| 实际影响 | 1046→1031 台 / 2135→2097 线路 / 隐藏 15 个 4K 台 / 苏州 7→5 台 | 台账实算 |
| 诊断可判读 | 「4K：已关闭 · 原因」+ 四条判据读数 + 剥离计数 | `buildHelp`；O32 |
| 构建坑 | `JAVA_SOURCES` 硬编码漏登记新类 → 改为登记表 + 自动补全 | `build_legacy.py` |
| 全量门禁 | 35 步 / **3213** 断言；legacy 220/220；独立包 80/80；单包 24/24 | `verify_all.dart` |

**未验证（不声称有效）**：无 API 18 真机；MediaCodecList 真实读数未实测（ROM 抛异常时退回只判尺寸）；
「软解 4K 必卡」未量化；Flutter 主程序侧未加等价门槛（需 flutter build）。

### 二十、研发计划 PQ-1 / M0：只读探针 + 观感两项（1.0.3+4，2026-11-09 21:15）

| 检查项 | 做法 | 断言 |
|---|---|---|
| 探针只读 | `QualityProbe` 1 秒采样 5 个内核读数，环形 60 条，逐项 try/catch；**类内不得出现 `failCurrent(` / `seekTo(`** | O34 / O35 |
| 探针生命周期 | `startStream` 里 `probe.start(p,s)`；`releaseCurrentPlayer` 里 `probe.stop()`；换线即重建基准 | O35 |
| 失败读数不冒充正常 | 每个派生指标带「样本不够」约定（-1 / `Long.MIN_VALUE`），不用 0 表示正常 | O34 |
| 诊断页 | 4 行读数（码率 / 缓存含 30 秒最低与均值 / 丢帧含 20 秒增量 / 画面含假高清结论）+ 打开时 2 秒刷新 | O35 |
| E1 去抖 | 首帧前照旧提示；再对齐引发的缓冲不提示；播放中延迟 600 ms、显示不少于 400 ms | O36 |
| E2 清屏 | `blackoutView` 在 SurfaceView 之上、浮层之下；`setFocusable(false)` + `setFocusableInTouchMode(false)`；起播前盖、首帧撤、2.5 秒兜底 | O37 |
| 版本 | `1.0.2+3` → `1.0.3+4`；pubspec / Dart 常量 / manifest / build_legacy / merge_single / iss / 三份门禁断言同步 | A04/G03/I01/N09/J03/R12/G14/G36 |
| 产物 | 单包 43,842,035 B `a4d01da9…bb0008`；独立包 3,528,222 B `fc05bc0f…95bcf2`；两包均 code 4 / name 1.0.3 | badging |
| 回退基线 | 1.0.2 两个包移入 `dist/_prev/`，未删除 | — |
| 全量门禁 | 35 步 / **3217** 断言；legacy 224/224；独立包 80/80；单包 24/24 | `verify_all.dart` |

**M0 的硬约束（已满足）**：不改变任何播放行为。判据是「关掉本轮改动 ≈ 1.0.2 行为」——
探针不决策、E1 只影响提示时机、E2 只加一层不接收焦点的黑幕。

**未验证（不声称有效）**：无 API 18 真机。5 个读数是否返回有效值、`blackout` 在 SurfaceView 上
的层级、2.5 秒兜底在慢源上是否露旧帧——均只有静态确证，属 M1 裁决范围。

### 二十一、M1 真机裁决 + M2 三闭环（1.0.3+4，2026-11-10 09:05）

| 检查项 | 做法 | 断言 |
|---|---|---|
| M1 裁决留痕 | 真机读数否掉的两条判据（缓存差 D1、丢帧让路 B2）在代码里有明确「不做」注释，诊断页写明「判据」来源 | O43 |
| 误导读数清理 | 缓存差不再标「偏大，视频侧积压」（实测 +14152 ms 时音画完全同步），改标「两路统计口径不同」 | O43 |
| 阈值集中 | 全部闭环阈值集中在 `Tuning.java`，每个常量注明「实测 / 经验」依据 | O38 |
| A1 假高清 | 判据 = 实测宽度 < 标称 × 0.75；命中**只降权不动播放**（`findNext` 两遍，第二遍仍试） | O39 |
| B1 带宽塌陷 | 30 秒基线 + 8 秒快窗 + 40% + 连续 3 采样 + **近 60 秒已卡一次** + 冷却 60 秒 | O40 |
| D2 时钟偏快 | >1.02 连续 2 个 10 秒窗口 + 有候选 + 冷却 45 秒；换线即重置窗口序号 | O41 |
| 自动换线开关 | 默认开；关掉即 1.0.2 行为（只保留快失败 / 看门狗 / 3 次卡顿） | O42 |
| 产物 | 单包 43,842,035 B `33a2cb59…814c19`；独立包 3,544,606 B `2b9bffdb…c76066a6`；两包 code 4 / name 1.0.3 | badging |
| 全量门禁 | 35 步 / **3223** 断言；legacy 230/230；独立包 80/80；单包 24/24 | `verify_all.dart` |

**未验证**：B1/D2 只有「不该触发时不触发」的样本，缺真实触发样本；A1 缺「720 冒充 1080」正样本。

### 二十二、M3 线路稳定度记忆（1.0.3+4，2026-11-10 10:04）

| 检查项 | 做法 | 断言 |
|---|---|---|
| 存储隔离 | 独立偏好文件 `shunbo_legacy_streams`，键 = hash + 长度；上限 500 条按时间淘汰 | O44 |
| 记忆口径 | 首帧耗时取两次较小值；硬失败（内核报错 / 首帧超时）才计数，慢与抖不算 | O44 / O45 |
| 降权有期限 | 连续 2 次硬失败降权，14 天后自动恢复 | O44 |
| 选线接线 | `open(channel)` 用记忆首选下标；`findNext` 两遍扫描共用降权集合（A1+A2） | O45 |
| 生效边界 | 只在「自动换线开 + 优先清晰度＝自动」；画质地板不得低于台账首条 | O46 |
| 取舍留痕 | C1 由记忆替代（预热连接不可复用）、C2 抢带宽不做、C3 需 A/B 不做 | O47 |
| 诊断页 | `记忆：N 条 · 本台首选第 X 条（上次 Y ms）· 降权 M 条` | O47 |
| 产物 | 单包 43,858,419 B `e19ba325…d9f2a7`；独立包 3,544,604 B `35752acf…07fc11` | badging |
| 全量门禁 | 35 步 / **3227** 断言；legacy 234/234；独立包 80/80；单包 24/24 | `verify_all.dart` |

**未验证**：记忆的收益（「上次最快下次仍最快」在跨境源上未必成立）、2 次降权阈值，均缺真实样本。

### 二十三、诊断页分页（1.0.3+4，2026-11-10 10:22）

| 检查项 | 做法 | 断言 |
|---|---|---|
| 不再裁行 | 按屏高算每页行数 `(屏高dp−110)/26`，1080p 下 23 行/页，内容 37 行分 2 页 | O48 |
| 语义分页 | 「高清/扩展/标清线路」之后插 `\f`：第 1 页=这台是什么，第 2 页=现在播得怎么样 | O48 |
| 翻页交互 | `←→` 翻页、其余键关闭；进入诊断页回到第 1 页；底部提示同步改文案 | O48 |
| 不做滚动 | 不用 ScrollView（遥控器拖滚动条难用，且可聚焦会吞 OK 键） | — |
| 产物 | 单包 43,858,419 B `28429449…db8dbb8`；独立包 3,544,608 B `28e4ef76…a17eeae` | badging |
| 全量门禁 | 35 步 / **3228** 断言；legacy 235/235；独立包 80/80；单包 24/24 | `verify_all.dart` |

### 二十四、停滞盲区修复（1.0.3+4，2026-11-10 10:38）

| 检查项 | 做法 | 断言 |
|---|---|---|
| 分页验证 | 真机两张照片显示第 1/2 页与第 2/2 页，闭环/判据/记忆/内核可见 | O48 |
| B1 基线 | 改用 60 秒内峰值（最忙的 8 秒窗口），不再用 30 秒均值（卡住时均值同步塌到 0） | O40 / O50 |
| 零吞吐 | `bytesStalled()` 把「算出 0」与「样本不足」分开，前者单列为塌陷 | O50 |
| D3 停滞 | 位置增速 <0.50 连续 2 窗口 → 有候选换线（-9）、单线路重连一次 | O49 |
| 重连上限 | `stallGaveUp` 保证每条 URL 只重连一次，第二次提示用户按键 | O49 |
| 暂停不判 | `paused` 时整段巡检早退，暂停/恢复各自停启巡检 | O50 |
| 诊断文案 | 时钟 <0.50 显示「画面停滞」；码率零吞吐显示「近 8 秒无流量增长」 | O51 |
| 产物 | 单包 43,858,419 B `7fdeaa…2d9b588`；独立包 3,544,605 B `7b9f8eb…30ce84` | badging |
| 全量门禁 | 35 步 / **3231** 断言；legacy 238/238；独立包 80/80；单包 24/24 | `verify_all.dart` |

### 二十五、1.0.4：D3 双判据 + M4 硬解（2026-11-10 11:06）

| 检查项 | 做法 | 断言 |
|---|---|---|
| D3 双判据 | 位置不动 **且** 缓存 <1000 ms 才判停滞；缓存充足时明确「疑似分片边界重置，不处置」 | O52 |
| D2 门控 | 快播判据要求 `!cacheBottom`，避免位置跳变误换线 | O52 |
| 解码可配置 | `K_HARD_DECODE` 键名不变、默认 0（软解）、设置页「解码方式」 | O53 |
| 即时生效 | `setHardDecode()` 变化时重建当前线路 | O53 |
| 自动回退 | 解码错误 / 6 秒无首帧 / 首帧超时三处，用软解重开**同一条线路** | O54 |
| 一次性 | `hardDecodeFailed` 置位后本次运行不再试硬解 | O54 |
| 回退落盘 | 界面 `prefs.setSetting(K_HARD_DECODE, 0)` + 提示可改回 | O54 |
| 诊断 | 「解码：实际 … · 设置 … · 回退状态」 | O55 |
| 版本 | 1.0.3+4 → **1.0.4+5**，八处配置 + 三份门禁断言同步 | A04/G03/I01/N09/R12/G14/G36 |
| 产物 | 单包 43,858,419 B `60bc5f55…b53aa1de`；独立包 3,544,605 B `0569e2da…f692341` | badging |
| 全量门禁 | 35 步 / **3235** 断言；legacy 242/242；独立包 80/80；单包 24/24 | `verify_all.dart` |

**未验证**：硬解在本机是否真的能播（M4 的结论必须上机）；三条回退路径谁先触发。

### 二十六、硬解按线路粒度（1.0.4，2026-11-10 11:38）

| 检查项 | 做法 | 断言 |
|---|---|---|
| 粒度 | `currentUseHard = hardDecode && !memory.hardDecodeUnfit(url)`，逐线路决定 | O53 / O56 |
| 回退 | 只记这一条 URL，不改用户设置、不全局关闭 | O54 |
| 记忆 | `StreamMemory` 4 段格式（兼容旧 3 段）、7 天过期、切回硬解时清空 | O56 |
| 即时生效 | `setHardDecode` 重建当前线路 | O53 |
| 诊断 | 分开显示「设置 / 本线路实际 / 多少条不适配」 | O55 |
| 误删恢复 | 6 个 Listener 回调按旧包字节码 1:1 还原（dexdump 对照） | 编译期接口约束 |
| 产物 | 单包 43,858,419 B `55c36e4d…a6e1845`；独立包 3,544,606 B `c5bd8401…26cf7d56` | badging |
| 全量门禁 | 35 步 / **3236** 断言；legacy 243/243；独立包 80/80；单包 24/24 | `verify_all.dart` |

### 二十七、音画延迟：手动对齐 + 兼容模式（1.0.4，2026-11-10 12:23）

| 检查项 | 做法 | 断言 |
|---|---|---|
| 不自动 | 明确不按「缓存差」自动 seek（两份真机读数互相矛盾：+14152 ms 无感 / +2440 ms 有感） | O57 |
| 手动对齐 | `reanchorNow()`：按当前位置 seek，重锚 frame_timer；冷却 3 s；seek 引发缓冲不计入卡顿 | O57 |
| 兼容模式 | `K_SYNC_COMPAT` 默认 0；打开后不设 `max-fps` / `video-pictq-size`；重建当前线路即时生效 | O58 |
| 诊断 | 「同步」行新增「手动对齐 N 次 · 兼容模式 开/关」 | O58 |
| 产物 | 单包 43,858,419 B `4eff2f64…cc2d57`；独立包 3,544,604 B `8c6df5fc…10fca4` | badging |
| 全量门禁 | 35 步 / **3238** 断言；legacy 245/245；独立包 80/80；单包 24/24 | `verify_all.dart` |

### 二十八、音画延迟第二轮：三条路径否证 + 帧率读数（2026-11-10 13:30）

| 检查项 | 做法 | 断言 |
|---|---|---|
| 手动对齐否证 | 真机按 3 次仍在 ⇒ seek 重锚 `frame_timer` 不影响音频位置，消不掉恒定偏移 | 真机读数 |
| 兼容模式否证 | 已开、缓冲 0 次、时钟 0.999、缓存差 +2440→+624，问题依旧 ⇒ `max-fps`/`pictq` 非病因 | 真机读数 |
| 缓存差出局 | 第二次被证否（差收敛 4 倍感知不变）⇒ 该量永久不作判据 | O57 不变 |
| 内核能力核实 | `framedrop=1`(841 行) / `sync-av-start=1`(850 行) 早已设置；SoundTouch 已编入但 `setSpeed` 不改相对偏移；`adelay`/`atempo`/`asetpts`/`setpts`/`apad` 均不存在 | O63 |
| 帧率读数 | `QualityProbe` 新增 `decFpsCenti`/`outFpsCenti`（WINDOW=60，1 s 采样），`summary()` 第 5 行；差 >2 fps 判「正在丢帧追赶音频」，相当判「解码链路没有积压」 | O62 |
| 探针仍只读 | O62 断言 `QualityProbe.java` 内无 `failCurrent` / `seekTo` | O62 |
| 起播策略行动态化 | 按 `compatSyncEnabled()` 输出「帧队列 / 帧率不限（兼容模式）」，不再与下一行「兼容模式 开」自相矛盾 | O59 |
| 码率提示同源 | 提示用 `FAKE_HD_MIN_BPS / 1000000.0`，删掉「1080P 通常需 ≥2.5 Mbps」 | O60 |
| 硬解描述对齐实现 | 「只让这条线路改用软解，本项设置保持不变」，不再说「把这一项改回软解」 | O61 |
| 苏州台换线无效 | 台账里「苏州新闻综合」2 条线路同源（`csztv1.m3u8` 仅 http/https 之别）⇒ 换线路对音画延迟无意义 | 台账 |
| 测量方法纠错 | 「首个音频 PES PTS − 首个视频 PES PTS」有半间隔系统偏差（苏州 176 vs 187、CCTV-1 85.3 vs 110）⇒ 该法不可作证据 | 双源对照 |
| 产物 | 单包 43,858,419 B `3bdea6d9…0cc461`；独立包 3,544,607 B `8ddb0d6a…e7fe0e` | badging |
| 全量门禁 | 35 步 / **3243** 断言；legacy 250/250；独立包 80/80；单包 24/24 | `verify_all.dart` |

### 二十九、帧率读数首次真机出数：口径核实 / 病因 / 撤回错误建议（2026-11-10 13:52）

| 检查项 | 做法 | 断言 |
|---|---|---|
| 真机读数 | 解码 **19.80** · 输出 **7.81**（差 11.99）；丢帧 0.5%；时钟 1.000；缓冲 0；缓存差 +400；1920×1080 / 标称 1080P | 第 2/2 页截图 |
| 口径核实 | `vdps`=`avcodec_receive_frame` 后采样、`vfps`=`SDL_VoutDisplayYUVOverlay` 后采样，共用 `samples[10]` 速度采样器；`drop_frame_rate`=`drop_frame_count/decode_frame_count` **累计值、仅 early drop** | ijkplayer k0.8.8 源码 |
| 矛盾消解 | `video_refresh()` 迟到帧分支 `frame_queue_next`+`goto retry` 既不递增 `frame_drops_late`/`drop_frame_count`，也不触发上屏 ⇒ 被丢帧只进 `vdps`、不进 `vfps`/丢帧率。**三者不矛盾，是同一现象上下游** | 源码逐行 |
| 病因 | 软解 1080P 只解出 19.8 帧/秒 → `frame_timer` 落后 → `framedrop=1` 不停 late drop → 每秒仅 7.81 帧上屏；缓存差小是因帧在上屏阶段已被丢，**落后的是 frame_timer 不是队列深度** | 推理（源帧率待证） |
| 撤回错误建议 | `framedrop=N` = 最多连续 early drop N 帧；late drop 开关是 `>0`，1 与 10 等价 ⇒ 调大只会丢更多帧。§39 第 8 节「可试 5–10」已划掉 | O66 |
| 丢帧行标口径 | 「丢帧：X%（不含上屏前丢帧）」，不再与帧率行看起来打架 | O64 |
| 帧率行中性化 | 「输出比解码少 X，上屏前被丢；与上行丢帧率口径不同」，删掉「正在丢帧追赶音频」 | O64 |
| 内核行动态化 | 显示「本线路 软/硬解 · 设置 软/硬解」，按线路回退时标「本线路已回退」；不再写死「默认 FFmpeg 软解」 | O65 |
| 播放参数不动 | `framedrop` 仍为 1；`skip-loop-filter`/`skip-frame` 经内核字符串核实不存在，codec 透传未验证、不擅自启用 | O66 / O67 |
| 苏州台死结 | 台账「苏州新闻综合」2 条线路 `quality` 全为 1080 且 URL 同源 ⇒ 既不能换源也无低分辨率线路可降；同市 720P 台可作对照 | 台账 |
| 本页条件差异 | 「兼容模式 关 / 手动对齐 0 次 / 码率 1.93」与 §39 那张「开 / 3 次 / 3.18」不同 ⇒ **不可横向相减** | 真机读数 |
| 产物 | 单包 43,858,419 B `891e5ab9…cec74cf`；独立包 3,544,603 B `e6d5714e…acf34c` | badging |
| 全量门禁 | 35 步 / **3247** 断言；legacy 254/254；独立包 80/80；单包 24/24 | `verify_all.dart` |
| 下一步 | 该台切硬解做 A/B：看「内核」行是否本线路硬解、「帧率」两数是否收敛；在此之前不改任何播放参数 | 待真机 |

### 三十、「起播正常、切台回来后不同步」四张真机对照（2026-11-10 14:42）

| 检查项 | 做法 | 断言 |
|---|---|---|
| 成对对照 | 同台（369 苏州新闻综合）/ 同硬解 / 同关兼容模式：起播正常 vs 切回后异常 | 4 张截图 |
| 唯一显著变化 | 帧率 **25.00/25.00 → 26.66/8.54**；视频缓存 **7120 → 16760 ms**（30 秒最低 7120→10080，逐步爬升） | 真机读数 |
| 排除项 | 源（同台同线起播正常）、恒定偏移（起播零延迟）、解码算力（解码反升）、音频时钟（1.000）、缓冲（0 次）、网络（码率 2.62→3.26）、early drop（0.0→0.5%）、设置差异 | 逐项对照 |
| 口径 | `getVideoCachedDuration()` = 解复用后 videoq 包队列时长（`q->duration` 仅在 `packet_queue_get` 扣减），非 pictq 帧队列；解码帧率 26.66 是 `SDL_SpeedSampler` 无新事件不衰减的残留值 | ijk 源码 |
| 病因链条 | 上屏持续 late drop → pictq(3) 满 → 解码线程阻塞 → videoq.duration 只增不减 → 缓存 7→17 s | 推理 |
| 代码走查（嫌疑 A） | `LegacyPlayerActivity:754/:889` 换台不重建 Surface/Controller，共用同一 holder；`PlaybackController:1510/:686` 旧 player 后台单线程**异步**释放、新 player 立即绑定同一 holder（API 18 MediaCodec 敏感） | 行号证据 |
| 代码走查（候选 B） | `PlaybackController:863/:865` `max-fps=30` + `video-pictq-size=3`，硬解异步回传下 3 帧队列偏小 | 行号证据 |
| 代码走查（排除） | `sync-av-start` 是 FFPlayer 实例字段、`decoder_init()` 按实例重置；`QualityProbe:95` `start()` 重置环形数组 ⇒ 既不跨台残留、读数也不串台 | 源码 / 行号 |
| 更正 §39 适用范围 | 「手动对齐 3 次无效」只在恒定偏移条件下成立；这四张图手动对齐全为 0 次，**累积型落后场景下 seek 重锚从没测过** | 文档 |
| 会话读数 | `outputFpsCentiAgo(20)` 同一环形窗口取历史帧率、样本不足返回 −1（O69）；`sessionStarts` 跨台累计不清零 + `streamElapsedSeconds()`（O70）；诊断页新增「会话」行（O68） | O68–O70 |
| 播放逻辑不动 | `framedrop` / pictq / max-fps / sync-av-start 全部原样；只加读数与改过时注释 | O70 |
| 产物 | 单包 43,858,419 B `46f4a4c3…ebe935`；独立包 3,544,606 B `195b6c8f…d04a31` | badging |
| 全量门禁 | 35 步 / **3250** 断言；legacy 257/257；独立包 80/80；单包 24/24 | `verify_all.dart` |
| 下一步 | ① 异常态按一次「音画立即对齐」看帧率是否从 8.54 回到 25；② 装新包复现，拍「会话」+「帧率」两行 | 待真机 |

### 三十一、起播 1 秒暂态页：口径纠错与「对齐 A/B」取证补齐（2026-11-10 15:50）

| 检查项 | 做法 | 断言 |
|---|---|---|
| 真机读数 | 起播 **81 次** · 本线路已播 **1 秒** · 帧率解码 17.04 / 输出 9.61 · 本次线路切换 2 次 · 手动对齐 3 次 · 硬解/兼容模式关 | 第 2/2 页截图 |
| 暂态识别 | 本线路 1 秒 + 时钟「采样中」+ 码率「样本不足」+ 分辨率「判定中（满 8 秒）」+ 缓存最低=均=8081（仅 1 样本）+ 无「20 秒前」趋势 ⇒ **该页退出证据池**，17.04/9.61 是起播追帧暂态 | §39 PES 教训复用 |
| 有效信息 | ① 起播 81 次（高频换台复现，§41 嫌疑 A 仍在桌面，仅旁证）；② 用户确实按了 3 次对齐；③ `reanchorNow()` 只 seekTo 不重建线路，2 次切换来自 open() 候选 | 代码 + 读数 |
| 口径纠错 | `alignSeekCount` 每条线路清零（本线路）；`reanchorCount` **只增不减、进程重启才归零**（累计）；`lastReanchorAt` 不清零（3 秒冷却）；`openedAtMs` 按线路重置 | 逐行核 PlaybackController |
| 取证设计缺口 | §41 让用户「按一次看帧率是否从 8.54 回 25」，但页面**只记次数、不记按前帧率**，按 3 次仍无法回答对齐有没有用 | 自我纠错 |
| 对齐 A/B 读数 | 新增 `reanchorBeforeFpsCenti`（按下前 0~1 秒探针采样值）/ `lastReanchorAtThisStream` / `reanchorThisStream`；`startStream()` 清零；诊断页「对齐：按前 X → 现在 Y（回升/持平/下滑）· 本线路第 N 次 · 距上次 N 秒」，<3 秒标「对齐后未稳」 | O71 / O72 |
| 口径标注 | 「同步」行两个次数分别标「（本线路）」「（累计）」，删旧写法的歧义 | O72 |
| 暂态标注 | 「会话」行本线路 <8 秒追加「起播未稳，勿据此页判读」 | O73 |
| 播放逻辑不动 | `reanchorNow()` 仍只 `seekTo(pos)` 一次；framedrop/pictq/max-fps/sync-av-start 全部原样 | O74 |
| 产物 | 单包 43,858,419 B `6b883c7a…f85d96a5af03`；独立包 3,544,603 B `220670c2…4160e89` | badging |
| 全量门禁 | 35 步 / **3254** 断言；legacy 261/261；独立包 80/80；单包 24/24 | `verify_all.dart` |
| 下一步 | 稳态（>8 秒）异常态按一次对齐等 5 秒：看「对齐」行回升/持平；回升 ⇒ frame_timer 可修，持平 ⇒ 回到嫌疑 A；同时拍「会话」行分开 A/B | 待真机 |

### 三十二、稳态页趋势定案「起播即带病」+ 换台释放时序读数（2026-11-10 16:18）

| 检查项 | 做法 | 断言 |
|---|---|---|
| 真机读数 | 起播 **34 次** · 本线路已播 **21 秒** · 帧率解码 29.41 / 输出 9.85 · 时钟 1.000（窗口 2）· 缓冲 0 · 码率 1.97 · 缓存 7440/6304（差 +1136）· 丢帧 0.5%（+0.4 恶化）· 硬解 / 兼容模式关 · 记忆 123 条 | 第 2/2 页截图 |
| 新包生效 | 出现「对齐」行、两个次数分别标「（本线路）/（累计）」、21 秒 >8 秒无「起播未稳」、仍第 2/2 页且底部未被挤走（§42 分页风险未发生） | 截图 |
| 口径纠错复核 | 「手动对齐 1 次（累计）」但「本线路未按过」⇒ 旧文案会把别的线路按的 1 次误读成本线路 | 截图 |
| **定案：排除候选 B** | 「输出帧率 20 秒前 **11.19** → 现在 **9.85**（持平）」⇒ 起播约 1 秒就病态、21 秒没回到 25，**没有「25 → 8.54」的下滑过程** ⇒ 播放中累积 / frame_timer 漂移被证否；也不是起播追帧暂态（干净起播几秒内应收敛到 25/25，见 §41） | §41 定案规则 |
| **主嫌收窄** | 解码 29.41 正常但上屏恒 9.85、起播即坏、不累积 ⇒ 指向渲染输出通道（Surface / ANativeWindow / MediaCodec buffer 队列）换台交接不干净，即 §41 嫌疑 A；候选 B（`video-pictq-size=3` 累积）出局 | 推理，非确证 |
| 边界留白 | MediaCodec 实例上限 / Surface buffer 队列 / API 18 ANativeWindow 行为同样能产生该读数，**仍是嫌疑不是确证**，故只加读数不改释放策略 | 纪律 |
| 释放时序读数 | `AtomicInteger releasePendingCount`（提交 +1 / `finally` −1，跨线程安全）、`releaseOverlapCount` 跨台不清零、`lastOverlapDepth`、`lastReleaseCostMs`；`startStream()` 在 `setDisplay(holder)` 前读待释放数，>0 记一次重叠 | O76 |
| 诊断页「释放」行 | 「释放：待释放 N 个 · 重叠 M 次 / 起播 K 次（最近队列 D 个） · 上次释放 X ms」 | O75 |
| 不改释放策略 | 仍后台单线程异步、不 join / 不等待、主线程只 `setDisplay(null)`；四个播放参数原样 | O77 |
| 定案规则 | M 随 K 增长且待释放 >0 长期不降 ⇒ 队列堆积坐实嫌疑 A；M 恒 0 却复现 ⇒ 排除释放重叠另开取证；M≈K 但高 K 才复现 ⇒ 每次重叠遗留状态，看队列深度趋势 | 待真机 |
| 产物 | 单包 43,858,419 B `d6d0712a…2bfc8b`；独立包 3,544,601 B `971c88b3…472fe7` | badging |
| 全量门禁 | 35 步 / **3257** 断言；legacy 264/264；独立包 80/80；单包 24/24 | `verify_all.dart` |
| 下一步 | ① **不用新包**：异常态退出 App 重开，第一次直接进该台，看帧率是否回 25/25（钉死进程内状态残留）；② 装新包拍「释放」+「会话」行，按一次对齐等 5 秒看「对齐」行回升/持平 | 待真机 |

### 三十三、「释放」行首次数：证否队列堆积 + 有上限的交接干预（2026-11-10 16:48）

| 检查项 | 做法 | 断言 |
|---|---|---|
| 真机读数 | 起播 **86 次** · 本线路已播 **28 秒** · 帧率解码 24.39 / 输出 10.00 · 20 秒前 9.61 → 10.00（持平）· 时钟 1.000 · 缓冲 0 · 码率 1.90 · 缓存 6000/5632（差 +368）· 丢帧 0.4% · 硬解 / 兼容关 · 记忆 136 条 | 第 2/2 页截图 |
| 「释放」首次数 | **待释放 0 个 · 重叠 83 次 / 起播 86 次（96.5%）· 最近队列 3 个 · 上次释放 62 ms** | 截图 |
| §43 定案规则判定 | 规则 1「待释放 >0 长期不降 ⇒ 队列堆积」**证否**（现存 0、单次 62 ms、不堆积）；规则 2「M 恒 0」不适用；规则 3「M≈K」**命中** | 真机读数 |
| 口径澄清 | 「待释放 0」是拍照瞬时值；「最近队列 3 个」是 `startStream()` 绑 holder 那一刻深度；单线程 3×62≈186 ms 即清空 ⇒ 嫌疑 A 措辞修正为「96.5% 命中的新旧 player 交接窗口」，**不是队列堆积** | 代码 + 读数 |
| 形态复现 | 与 §43（331.jpg）对比：起播 34→86、本线路 21→28 秒、帧率 29.41/9.85→24.39/10.00、20 秒前 11.19→9.85 与 9.61→10.00 都「持平」⇒ 两张稳态页独立复现「起播即带病、不累积」 | 两页对照 |
| 干净态解释 | 96.5% 换台重叠 ⇒ 唯一无重叠的是「进程第一次起播」，与 §41 正常页 25.00/25.00 及用户「起播正常、切回才坏」吻合 | 推理 |
| 数据改变决策 | §43 因「会拖慢换台」不动释放时序；本页把代价钉在 62 ms（出画 720 ms）⇒ 做**可证伪的干预**而非盲改 | 文档 |
| 等待排空 | `Tuning.RELEASE_DRAIN_TIMEOUT_MS = 200L`；`awaitReleaseDrain()` 在 `releaseCurrentPlayer()` 之后、`setDisplay(holder)` 之前；2 ms 短轮询 + deadline，超时照常继续 | O78 |
| 四条边界 | 硬上限 200 ms / 仍 `RELEASE_EXECUTOR.execute()` 不 join 不 `awaitTermination` 不 `Future.get` / 主线程最多多等 200 ms / 旧包可回退 | O78 / O77 |
| 新增读数 | `drainCount` / `drainTimeoutCount` / `lastDrainCostMs` / `maxOverlapDepth`（都跨台不清零）；绑定时仍记 `releaseOverlapCount`，正常情况**不再增长** | O79 |
| 诊断页拆两行 | 「释放：等待 M 次 / 起播 K 次（最近 X ms · 超时 T 次）· **本次无重叠 / 本次重叠 D 个**」+「交接：历史重叠 O 次（最深 P 个）· 现存 N 个 · 上次释放 Y ms」；「本次无重叠」= 干净态自证 | O75 / O79 |
| 页面矛盾修复 | 「丢帧 +0.0 个百分点（正在恶化）」：显示 `%.1f`（0.1 精度）而阈值 30（0.03）⇒ 阈值改 ±100、加「在好转」 | O80 |
| 不改的部分 | 四个播放参数原样、`reanchorNow()` 仍只 `seekTo(pos)`；**没有新增设置项**（避免第 20 项挤压行高，§34 教训） | O81 |
| 判读规则 | 本次无重叠 + 历史重叠 0 + 帧率回 25/25 ⇒ 交接窗口是病因；本次无重叠但仍 ~10 ⇒ 硬排除交接窗口、转 MediaCodec/Surface；超时 T 增长 ⇒ 按「最深 P × 上次释放 Y ms」调常量 | 待真机 |
| 产物 | 单包 43,858,419 B `393a5f6d…478433bce4`；独立包 3,544,604 B `f94f70a8…9561dee4` | badging |
| 全量门禁 | 35 步 / **3261** 断言；legacy 268/268；独立包 80/80；单包 24/24 | `verify_all.dart` |

### 三十四、1.0.5：G2+G3 默认组合 + G1 开放接口（2026-11-11 16:10）

| 项目 | 结论 | 证据 |
|---|---|---|
| 版本 | `1.0.5+6`；`pubspec.yaml` / `system_channel.dart` / `windows_installer.iss` 三处同源，门禁版本断言同步更新且**断言数不减** | H01–H03 / R12 / G14 / G36 / I01 |
| 默认组合 | G2（内置合规片库 + E9 纯数据规则源）+ G3 为默认；G1 默认关闭 | A01–A06 |
| G1 开关 | 默认关闭，关闭时零外部请求、`usesBuiltIn=true`；只开开关不选地址也不产生外部地址 | A04/A05 / D02/D03 |
| 候选地址 | 列表含内置片库 + 《播放接口.txt》6 个点播条目，id 唯一、无内嵌账密；仅可选项数据，不随包请求/注册 | B01–B08、H08 |
| 手动输入 | 设置页 TextField → 添加并使用；上限 12 条、可移除、可恢复默认；非法地址一律拒绝 | G05 / D07–D13 |
| 地址校验 | 仅 https（loopback 可 http）；拒账密 / `file:` / `javascript:` / 超长 / 控制字符；与传输层 `isLoopbackHost` 同口径 | C01–C14 |
| 安全基线 | 不放宽：只接受 dart/regex/json；`shunbo/source_jar` 原生通道未注册、生产 `allowUnsafeBackends` 仍 false ⇒ **不执行外部 jar / JS**；5 条明文 http 候选被明确拒绝 | B09/B10、G07–G10 |
| 落盘 | `FileConfigStore.saveState('vod-source-address')`；坏配置回落关闭默认；save/load/reset 往返可复现 | E01–E06、A07–A10 |
| 1.0.4 隔离 | 空查询返回**原列表引用**、计数文案逐字相同；默认片源仍 `VodCatalog.sourceId`；直播控制器与播放内核零改动 | F02–F04、G12/G13、H07/H09 |
| 回退基线 | 1.0.4 legacy 出包脚本与 Windows 实测 iss 原样保留；本版未动 1.0.4 产物 | H05/H06 |
| 门禁 | `flutter analyze` 0 问题；**37 步 / 3495 断言全绿**（3261 旧断言全保留 + 地址校验 109 + 第三方接入 125）；legacy 268/268 | `verify_all.dart` |
| 缺陷修正 | D17 暴露「反序列化未校验自定义地址格式」⇒ 修 `fromJson` 复用同一校验后再全绿，非改断言 | D17 |
| 出包暴露的过期断言 | N09 原锁死「单包版本 1.0.4 / code 5」，但它读的是每次组装都会覆盖的 `legacy/single/single_report.json`；1.0.5 出包后误报 267/268。改为**与 pubspec 同源**比对（仍精确校验，忘传 `--version-name` 会立刻失败），268/268 恢复 | `verify_legacy_compat.dart` N09 |
| 出包（16:37，**已作废**） | 当时的 3 个 1.0.5 产物不含第三方点播接入代码（改动发生在出包之后），哈希已由 §47.6 重打产物取代，不再分发 | `README.md` §46.7 / §47.6 |
| 未做 | 未提交源码、未推送、未建 tag/Release；GUI 人工走查、G1 真实 https 地址导入实测、三端真机播放验证均空白 | — |

### 三十五、1.0.5 复查：第三方点播数据真接入 + 能播放（2026-11-11 17:05）

| 项 | 结论 | 证据 |
|---|---|---|
| 截图误导线索 | 绿字验的是「当前选中地址」，非输入框；256 KB 来自官方入口 277,018 B HTML，而 `:16/8888` 仅 12,437 B | `vod_source_section.dart` / `source_config_url.dart` + 实测 |
| 硬事实 | `:16/8888` 27 个站点全 `type:3`（26 `csp_*` + jar + `drpy2.min.js`），只是插件注册表，无影片数据 | 配置结构解析 |
| 突破口 | `47.96.82.41:5188/config.json` 的 20 个 `type:1` 是苹果 CMS V10 采集 API，`ac=list` / `ac=detail` 均为普通 HTTP JSON | 实测 11 个可达 |
| 接入形态 | ① 点播数据契约 JSON（`items`）② TVBox 配置里的 `type:1` 采集站；`csp_`/jar/`type:3` 明确跳过 | `third_party_vod.dart` |
| 安全基线 | **未放宽**：不加载 jar / JS / 命令，`allowUnsafeBackends` 生产仍 false，原生 `shunbo/source_jar` 未注册，不内置任何第三方地址 | F01–F04 / F08 |
| 真网结果 | 24 部 / 3 站 / 32.6 s；抽查播放地址 `206 + application/vnd.apple.mpegurl + #EXTM3U` ⇒ 可直接起播 | 17:20 实测 |
| 明确拒绝 | 插件型配置给出「不执行外部代码」原因；不开明文放行给出「请显式打开允许明文 http」原因 | E12/E13/E31/E32 |
| 修掉的缺陷 | ① 输入框实时校验 ② 应用按钮优先消费输入框 + 显示当前选中 ③ 被拒候选不可选中且重启不残留 | G06b/G06c、F10–F13 |
| 修掉的质量缺陷 | 详情一次取 12 部触发 256 KB ⇒ 改 4 部一批；`/share/<hash>` HTML 跳转页 ⇒ `looksLikeDirectMedia()` 只收能直接播的站点 | 真网复测 |
| 明文 http | 新增默认关闭的显式开关，只作用于 G1；E9 导入默认不变。取数「直连优先 + 短超时回退代理」 | E31/E32、F05–F07 |
| 1.0.4 隔离 | 默认片库仍 6 条、默认 sourceId 不变、空查询顺序不变、撞 id 的第三方条目被丢弃、清空外部源可完整回退 | E15–E30、F19–F22 |
| 门禁 | 新增 `verify_third_party_vod.dart` **120/120**（含离线端到端 import→栏目→适配器→可播地址）；旧 G06 如实更新 + G06b/G06c | `verify_all.dart` |
| 未做 | GUI 人工走查、真机起播、三端播放、24 部逐条播放、晚高峰/跨日稳定性；legacy 老电视端无点播栏目 | — |
| 全量门禁（重打前） | `flutter analyze` 0；`verify_all.dart` **37 步 / 3474 断言全绿**；legacy 268/268。重打后复跑 legacy-compat 268 / android-form 91 / third-party-vod 120 / vod-source-address 93 均绿 | 18:20 |
| 重打（18:45，最终） | 单包 44,005,875 B `16bfa551…61f1f`、Windows 安装版 25,775,802 B `da88470f…7ebe`、便携版 33,401,239 B `9ae37d71…4d85`；单包 `badging` = 1.0.5/code 6、minSdk 16、targetSdk 36、24/24 断言；两平台 AOT 均检出 `ThirdPartyVodService` / `parseCmsDetails` / `vod_play_url` / `allowInsecureHttp`；便携包 31 条、`data/app.so` 与分发目录 sha256 一致 | `README.md` §47.6 |
| 出包事故（已修） | `merge_single_apk.py` 版本号是命令行参数（默认 1.0.4/5），漏传 ⇒ 1.0.5 代码被打成 `Shunbo-1.0.4-full.apk` 并覆盖已发布基线。从 `_prev` 按 sha256 `393a5f6d…` 恢复 1.0.4，误标包改名隔离为 `*MISLABELED*`，重传参重打并 `badging` 复核。断言不校验 versionName 与 pubspec 同名，所以不会报错 | `dist/_prev/` |
| 未推送 | 源码（含第三方接入）**未提交、未推送、未建 tag/Release**；等待明确指令 | `git status` |

### 三十六、1.0.5 第二次修：候选地址的闭合失败回路（2026-11-11 19:05）

| 项 | 结论 | 证据 |
|---|---|---|
| 截图病灶 | 当前选中 = 影视仓官方入口（https 合规但 277 KB HTML），报「超过 256 KB 上限」；唯一实测可出片的采集站被画灰、点不动 | 真机截图 |
| 闭合回路 | 点得动的必然失败，能成的一个都点不动；用户没有第三条路 | 候选 × 格式 × 实测三维对照 |
| 误诊点 | 「超过 256 KB」是字节上限，真实原因是返回**网页**而非接口 JSON，用户会以为换个地址就行 | `source_config_url.dart` 原逻辑 |
| 修复① | `VodAvailability`（usable / pluginOnly / htmlPage）+ `isKnownUnusableSource()`：把「实测能否出片」与「格式是否合规」解耦 | B12–B16 |
| 修复② | 点候选 = 选中 + 立即导入；明文 http 弹一次确认框（点击即显式放行，取消则什么都不做）；不可用候选只给原因 | F13 / F13b / F13c |
| 修复③ | `fetchSourceConfigUrl(rejectHtml: false)` **默认关闭**，G1 链路传 true；新增 `htmlPage` 失败原因 + 纯函数 `isHtmlLikePayload` | C15–C22 / F13e / F13f |
| 顺带修的 | `_addCustom` 由「只保存」改为「保存 + 导入」（按钮写的是「添加并使用」）；重启后 selectedUrl 落在不可用候选上回落内置；「当前选中」不再对必失败地址显示绿字 | D18–D20 / F13d |
| 断言改写 | `G06c` 与 `F13` 原锁 `onTap: _busy || disabled ? null`，行为变更后**如实改写**，并拆成三条更细的断言（不是为过而改） | `verify_*.dart` |
| 真网复测 | 采集站 ok，12 部 / 1 站成功 / 13 站失败跳过 / 1 插件站跳过，38 s；抽查地址 `206 + m3u8 + #EXTM3U + 分片`；官方入口明确报「返回的是网页」 | 19:00 |
| 体验修正 | 导入期间显示「通常 20–60 秒」避免被当卡死；`maxSites` 8→14、`itemsPerSite` 8→12（8 站时只捞到 8 部） | `third_party_vod_service.dart` |
| 门禁 | `flutter analyze` 0；全量 **37 步 / 3495 断言全绿**；legacy 268/268 | 19:08 |
| 产物（19:12） | 单包 44,005,875 B `52504ca3…4ee65`、安装版 25,778,585 B `5b8879e4…4d7`、便携版 33,405,139 B `5213dadb…4663`；两平台 AOT 均检出 `isKnownUnusableSource` / `_confirmInsecure` / `_pickCandidate` / `isHtmlLikePayload` | `README.md` §48 |
| 未做 | GUI 人工走查、三端真机播放、逐条播放验证；未提交 / 未推送 | — |

### 三十七、五条点播地址实测与默认加载源（2026-11-11 19:40）

| # | 地址 | 可达 | 形态 | 站点构成 | 采集站 | 片量 | 应用内导入 |
|---|---|---|---|---|---|---|---|
| 1 | `:16/8888` | 200 | JSON | 27 站全 type:3 | 0 | 0 | 失败（全插件型） |
| 2 | `:55316/9981` | 200 | JSON | 117 站全 type:3 | 0 | 0 | 失败（全插件型） |
| 3 | `47.96.82.41/config.json` | 200 | `application/json` | 20 采集 + 1 插件 | 11 可达 / 9 有直链 | 1,197,091 | **成功 12 部 / 1 站** |
| 4 | `:924/924` | 200 | JSON | 2 采集 + 103 插件 | 2 可达 / 0 可播 | 248,507 | 失败（网页 + 分享页） |
| 5 | `:20271/pps.bmp` | 200 | 伪装 BMP 的 JSON | 14 采集 + 136 插件 + 1 | 7 可达 / 6 有直链 | 824,191 | 成功 12 部 / 1 站 |

| 项 | 结论 | 证据 |
|---|---|---|
| 默认源 | `http://47.96.82.41:5188/config.json`：可用站数（9）与片量（119.7 万）双第一 | §49.1 |
| 常量 | `kVodDefaultSourceUrl` + `kVodDefaultSourceCandidate`，候选排内置片库之后 | B17 / B18 |
| 新枚举 | `VodAvailability.noPlayable`：有采集站但只给网页跳转 / 分享页（`:924` 用） | B20 |
| 开关即用 | `_enableWithDefaultSource()`：没选过地址就预选默认源并导入；已选过则不替换 | G15 / G16 |
| 自动加载 | `VodAutoSource`（纯 Dart）：单飞、不重试、只认默认源；三个栏目页共用一次请求 | G01–G10 / G17–G19 |
| 不打扰 | 开关关着 / 选中不是默认源 / 已有外部条目 ⇒ 一个请求都不发；失败只显示原因不弹窗 | G05–G08 |
| 输入框 | 构造无初始值 + `_load()` 显式 clear，标签写「默认留空，不回填当前地址」 | G11–G14 |
| 门禁修正 | 清单原文地址后带中文注释，`[^\s]+` 会把「（119.7」当 URL ⇒ 改用 URL 合法字符集；断言未放松 | B08 |
| 门禁 | analyze 0；全量 **37 步 / 3521 断言全绿**（地址 116 / 第三方 144） | 19:35 |
| 未做 | GUI 逐屏走查、真机起播、逐条播放验证；未提交 / 未推送 | — |

| 产物（19:45） | 单包 44,005,875 B `ba4bba03…ad452`；安装版 25,781,954 B `16722de3…65648`（FV 1.0.5.6）；便携版 33,410,357 B `8ba02779…81f37`（31 条，app.so 一致） | `README.md` §49.6 |

### 三十八、「只加载了 1 个站点」的两个真因（2026-11-11 19:42）

| 项 | 结论 | 证据 |
|---|---|---|
| 现象 | 设置页「1 个站点 / 12 部（13 站失败跳过）」；20 个采集站实测可达 11 个 | 真机截图 |
| 真因① | 网页判定**先看 Content-Type**，而苹果 CMS 站普遍回 `text/html` + JSON 正文 ⇒ 12 个可用站被误杀 | 列表可达 **1/20** |
| 修法① | `isHtmlLikePayload` 改为**正文优先**：`<` → 网页；`{`/`[` → JSON（不看头）；其它才看头 | C23–C26 |
| 修法①b | 判定提前到「首块到达」（新增 `firstSignificantByte`，跳 BOM/空白），277 KB 页面不再先撞 256 KB 上限 | C27 |
| 真因② | `maxSites=14` < 配置里的 20 个 type:1 站点 ⇒ 第 15 名后的 4 个可用站从未被请求 | 代码 |
| 修法② | `maxSites` 14→32、`itemsPerSite` 12→20、`kMaxThirdPartyItems` 60→**240** | C11 |
| 修法②b | 串行改**分批并发**（批内 8 并行）：9 个失败站各等 8s+5s 代理，串行 >100s ⇒ 并发 42s | `_loadCms` |
| 新增③ | `/play/<id>` 播放页可派生 `index.m3u8`（xluuss / jisuzyv / huyall 实测 200+#EXTM3U）；`/share/<hash>` 不行 | D12–D16 |
| 派生纪律 | **必须先验一条**（`_deriveForSite` 取样实测 `#EXTM3U`）才整站改写，否则整站跳过 —— 不拿「猜的地址」填栏目 | D15 |
| 结果 | 站点 1→**9**、条目 12→**180 部**、剧集 78→**5726**（全 m3u8）、耗时 38s→42s | 19:42 真网 |
| 抽样验证 | 4 条（2 派生 + 2 原生）全 `200/206 + application/vnd.apple.mpegurl + #EXTM3U` | `curl -r 0-400` |
| 剩余失败 | 11 站**全是真实失败**：DNS 3、TLS 2、超时 3、反诈重定向 1（`js96110.com.cn`）、真网页 1、`/share/` 3 | 逐站诊断 |
| 门禁 | analyze 0；全量 **37 步 / 3531 断言全绿**（+10：C23–C27 / D12–D16） | 20:05 |
| 未做 | GUI 逐屏走查、真机起播、180 部逐条播放验证；未提交 / 未推送 | — |
| 产物（20:20） | 单包 44,022,259 B `0f5a078d…c8c1b`；安装版 25,782,843 B `977476af…51f0f6`；便携版 33,411,209 B `fde66651…cf9c83`（31 条、app.so 一致）；复跑 legacy 268 / android-form 91 | `README.md` §50.7 |

### 三十九、海报图 / 站点上限 100 / 播放页控制 / 点播缓冲档（2026-11-11 21:10）

| 项 | 结论 | 证据 |
|---|---|---|
| 图片 | 不是加载失败，是**从未发起请求**：`vod_pic` 没解析，卡片只有色块 + 首字 | `_PosterBlock` 旧注释「刻意不引网络海报」 |
| 修法 | `VodItem.posterUrl` + `CmsEntry.pic` / `CmsDetail.poster` + `resolvePosterUrl`（补协议/拼相对/百分号编码/拒非法）+ `Image.network` + `cacheWidth` + 失败回落 | B01–B17 |
| 实测 | 180/180 部带海报；9 个图床 **5 个可下载**（`200 + image/webp|jpeg`），4 个握手被掐（`errno=113`、`read 0 bytes`，http 同样不可达） | 21:00 逐主机探测 |
| 站点上限 | `kMaxThirdPartySites` **32 → 100**（import 默认引用常量）；条目上限 240 → **360**；每站仍 20 部 | C01–C04 |
| 外部代码 | 新增开关**默认开**：`type:3` 且 `api` 是 http(s) 的站点进入探测池（纯数据协议）；`csp_` 仍跳过并计数；本机不跑 jar/JS（无 JVM/JS 引擎） | C05–C17 |
| 插件候选 | `isKnownUnusableSource` 不再一票否决插件型（原来点都点不动），保存后也不再被回落成内置 | D19 / D19b |
| 预算 | 整轮 100 秒预算 + 批内 10 并发；超预算收工、已拿到的照常入库 | D06–D07 |
| 播放页 | `PopScope` 逐级返回；选集抽屉（当前集高亮+自动聚焦）；暂停/播放；±10 秒；上下集（按有序集号，跳号也能接）；可拖进度条；4 秒自动隐藏；←→↑↓/Esc/媒体键 | E01–E10 |
| 确认键 | 焦点在按钮上时 Enter/OK **让给控件**（`node.hasPrimaryFocus`），否则会变成暂停 | `_onKey` |
| 切换慢① | 每秒 `setState` 重建整页 → 改 `ValueNotifier`（只重绘进度条） | `_position` / `_duration` |
| 切换慢② | `inSection` 每次 build 重算 → 分栏缓存 + revision，同栏返回**同一实例** | E18–E21 |
| 切换慢③ | 主线程 `jsonDecode` 上百个 100–400 KB 响应 → >48 KB 走 `Isolate.run`；分批入库 | E22 / D03 |
| 卡顿 | 直播档参数（6s/4s）被点播共用 → 新增 `PlaybackTuner`：点播 30s/15s + `cache-pause` + 断线重连；离开切回直播档 | E11–E17 |
| 边界 | Android 走 ExoPlayer 平台通道，无 mpv 参数链路 ⇒ 这一项只对 Windows 生效；不改原生代码 | `applyOption` 只认 `http-header-fields` |
| 门禁 | analyze 0；全量 **38 步 / 3621 断言**（新增 `vod-playback` 89 条） | 20:58 |
| 未做 | GUI 逐屏走查、真机起播、180 部逐条播放验证；源码未提交 / 未推送 | — |

### 四十、直播串台 / 百万片量只取 180 / 点播页加载慢（2026-11-11 22:10）

| 项 | 结论 | 证据 |
|---|---|---|
| 直播串台① | 不是没暂停：直播失活确已 `controller.stop()`，声音是停的 | `live_page.dart` `didUpdateWidget` |
| 直播串台② | 真因是**渲染面没摘掉**：四个页面在 `IndexedStack` 里保活，`PlatformView`/纹理不随「不绘制」消失 | Android `TextureView` 混入合成；桌面 media_kit 纹理保留末帧 |
| 直播串台③ | 状态漏洞：点播页失活只 `_pauseForLeave()`，`_view` 仍停在 `playing`，`PlayerStage` 还在树上 | 旧 `didUpdateWidget` |
| 修法 | `PlayerStage.attachSurface`（false ⇒ 不建渲染面、给纯黑）+ 两页都传 `widget.active` + 失活走 `_leavePlaying()` 退到详情 + 起播前 `live.stop()` | I01–I06 |
| 陷阱 | `didUpdateWidget` 里 **不能** `setState`（build 期 `markNeedsBuild` 抛断言）⇒ `_leavePlaying(rebuild: false)` | I04 |
| 180 部真因 | 只请求 `?ac=list`（=`pg=1`）并丢弃 `pagecount/total`；实测 dyttzy `pagecount=4255 total=85082`、bfzy `8573/171459` | `parseCmsList` 只读 `list` |
| 修法 | `CmsListing` 分页元信息 + `VodSourcePager` 游标轮转 + 优先 `?ac=detail&pg=N` 合并接口（1 请求 vs 6 请求）+ 跨站去重 | P01–P15 |
| 多播放源 | `vod_play_url` 的 `$$$` 是多源，原来只取第一个 ⇒ 首源 `/share/` 网页的站被整站判死（电影天堂正是如此），改为「取直链最多的源」 | B04 改写 |
| 死站判定 | 超时/DNS 一次即判死（这类站占一半），HTTP 5xx 给两次机会 | P15 |
| 实测吞吐 | 16 批 / 75 秒 → **601 部**去重可播；接口统计从 85,082 读到 **1,322,947** | 22:00 真网 |
| 加载慢真因 | 冷启动每次重跑网络（拉配置 + 20 站列表/详情，30–100 秒），无任何缓存 | 旧 `_ensureDefaultSource` |
| 修法 | `VodLibraryStore` 落盘（含 Referer/海报/剧集，≤2500 条，4 秒节流）+ 12 小时新鲜期内零请求 + 超时收敛 + 检索结果缓存 | C01–C08 |
| 实测冷启动 | 136 条 297 KB ⇒ 读盘 **38 ms**、恢复 **4 ms** | 22:05 探针 |
| 门禁 | analyze 0；**38 步 / 3653 断言**（新增 P/C/I/S 共 32 条） | 22:08 |
| 产物（22:12） | 单包 44,382,707 B `5cf8a0bb…196f0`（badging 1.0.5 / code 6 / min16 / target36、组装 24/24）；安装版 25,832,330 B `db55fc4f…fe266`；便携版 33,477,085 B `9fe6745a…bb30`（31 条，清单与 1.0.4 逐条一致） | `README.md` §52.6 |
| legacy 独立包 | 重跑后 sha256 与 1.0.4 **逐字节相同**（`f94f70a8…`，3,544,604 B）⇒ 本轮改动全在 Flutter 侧，故 `versionName` 仍 1.0.4 / code 5，不跟着改 | §52.6 |
| 未做 | GUI 逐屏走查、真机起播、601 部逐条播放；源码未提交未推送 | — |

### 四十一、左栏底色与右栏统一（1.0.5 同版重打，2026-11-11 22:30）

| 项 | 结论 | 证据 |
|---|---|---|
| 现象 | 截图里左栏整块实心深色、右栏直接是画面本身，两侧底色不一致 | 用户红标截图 406×1670 |
| 取证 | 手写 PNG 探针采样：左栏 x=3…370 全区 `#121821`（**正是 `AppTheme.surface`**）；分界 x=372→376 由 `#121821` 一刀切到 `#5b3b32`，**无渐变无遮罩** | 逻辑 0…185 与 184 宽吻合 |
| 命中哪一个 | 带 `shunbo` 副标 + 收起箭头 `<` ⇒ 宽屏浮层侧栏 `_SideBar`（184）；电视常驻轨 `_buildTvRail`（140）没有这两样 | `app_shell.dart` 两套 rail |
| 修法 | 顶层 `const Color _railBackground = Colors.transparent;`，两处 rail 共用 | `app_shell.dart:45/411/574` |
| 布局不变 | 宽度 140/184、内边距、导航项顺序（`AppSection.values`）、品牌区、设置入口**一字未动** | E 段 7 条断言 |
| 取舍 | 透明后文字压在画面上，亮场景对比度下降；当前项仍保留 `surfaceHigh` 高亮 + 蓝左条。必要时一条常量可换半透明遮罩，但那不再是「透明」 | `README.md` §53.5 |
| 门禁 | analyze 0；**38 步 / 3660 断言**（`verify_mobile_layout` 145→152，新增 E 段 7 条） | 22:28 |
| 产物（22:30） | 单包 44,382,707 B `4b686211…10990eb5`（1.0.5/code 6、组装 24/24）；安装版 25,832,377 B `1d84cee3…5642839e`；便携版 33,477,083 B `e130e832…080b2879`（31 条） | `README.md` §53.7 |
| 指纹 | `libapp.so` 与上一版同尺寸 7,144,328 B、哈希 `73ac65c0…` → `c90a1be2…` ⇒ 只改了一个颜色常量 | 前后对照 |
| legacy | 未重打：本轮 `legacy/` 零改动 | `git status` |
| 未做 | 真机/桌面观感确认（尤其亮画面上的文字对比度）；源码未提交未推送 | — |

### 四十二、左栏改回「与右栏同一档」78% 半透明（1.0.5 同版重打，2026-11-11 22:45）

| 项 | 结论 | 证据 |
|---|---|---|
| 反馈 | §53 的纯透明**太高**，导航文字看不清，要求「参考右栏的背景及透明度」 | 用户当轮消息 |
| 右栏实际值 | 全工程唯一半透明面板：频道栏浮层态 `AppTheme.surface.withValues(alpha: 0.78)`；常驻双栏态全不透明 | `live_page.dart` 原 913 行 |
| 修法 | `AppTheme.panelScrim` 收成唯一出口（`surface.withValues(alpha: 0.78)`），左右两侧栏都引它 | `theme.dart` / `app_shell.dart:44` |
| 为什么 `final` | `panelScrim` 是算出来的，写死 `Color(0xC7121821)` 能 const 但改主题时会失同步 | `README.md` §54.3 |
| 对比度（算过） | 78% 压白画面 ⇒ 底色 `#464B52`、次要文字 3.60:1、主要 7.76:1；典型亮场景 4.65:1/10.02:1；纯黑 7.63:1。纯透明时白画面仅约 2.3:1 | 逐档合成计算 |
| 门禁 | analyze 0；**38 步 / 3664 断言**（E 段 7→11 条：唯一出口 / 两侧都引 / 别处不许写死 0.78 / 仍不画实心底色 / 宽度未变 / **不许退回 `Colors.transparent`**） | 22:44 |
| 产物（22:45） | 单包 44,382,707 B `2f30b7de…34a553c0`（24/24）；安装版 25,832,919 B `9b929ae0…da6de016`；便携版 33,477,369 B `bf3ae6d3…ac731150`（31 条） | `README.md` §54.6 |
| legacy | 未重打：`legacy/` 零改动 | `git status` |
| 未做 | 真机/桌面观感确认；若 78% 仍偏透，一条常量改 0.88 即可（但会偏离「和右栏一致」）；源码未提交未推送 | — |

### 四十三、点播顶部按设计稿重排 + 起播慢/播放卡（1.0.5 同版重打，2026-11-11 23:00）

| 项 | 结论 | 证据 |
|---|---|---|
| 现象 1 | 顶部四样东西散堆：标题 / 接入说明 / 加载更多 / 320 宽搜索框，无层级无筛选 | 用户截图 814×74 |
| 设计稿 | 三层：一级 tab（白字 + 短下划线）／筛选项（深色圆角标签 + 值词）／展开 + 排序 | 爱奇艺电影页 |
| 做了什么 | 标题行（含右对齐 300 宽检索框）→ 源说明 → 加载状态 → 分类 tab 行 → 筛选面板（类型/地区/时间/排序 + 展开） | `vod_page.dart` `_header` |
| **没做什么** | 资费 / 奖项 / 推荐三行**不做**：无对应字段，做出来就是点了永远返回空的死按钮 | `F25` 反向锁：`_filterRow(` 标签集合必须正好四维 |
| 数据层 | `VodItem` 新增 `typeName/area/year`，在 `buildCmsItems` 一次填好；不从 `subtitle` 反解（顺序/分隔符随源站变，错位后表现是「筛了没反应」） | `vod_catalog.dart` |
| 新逻辑 | `vod_facets.dart`：拆词 / 长尾丢弃（<2 次）/ 按命中数降序 / 时间按真实时间倒序 / 分档（>=2020 具体年，更早按年代）/ 三维「与」/ 稳定排序 / `VodFilter` 值相等 / facet 缓存 | 25 条断言 F01–F25 |
| 视觉口径 | 结构与设计稿一致；**颜色不搬爱奇艺绿**，用本项目 accent `#4C8DFF`，否则会出现两套主色 | `theme.dart` |
| 现象 2 根因① | `live.stop()` 后半段 `_gate.run(_safePause)` 排在正在进行的 tune 之后（`AsyncSerialGate` 严格串行），弱源 tune 8–12 秒 ⇒ 起播先干等十几秒 | `live_controller.dart:1447` |
| 修法① | `.timeout(900ms)`：同步部分（epoch/watchdog/phase）早已完成，串台依赖的是「load 覆盖内核 + 失活页不建渲染面」，不依赖 pause 完成 | `I05`/`I07` |
| 现象 2 根因② | 点播档 `demuxer-readahead-secs: 15` 起播阶段抢首帧带宽 | `E13` 改锁 6 |
| 根因③ | `cache-pause-wait: 2` 白等 1 秒 | `E14` 改锁 1 |
| 根因④ | 5 次 `setProperty` 串行 IPC，且每次起播（含连播）都重设 | `E18` 并发 / `E19` 幂等 |
| 根因⑤ | `network-timeout` 默认 60 秒：连接挂死时画面冻一分钟才报错，用户感知是「卡死」 | `E17` 改 10 |
| 卡的另一半 | 缓存低于阈值时 mpv 主动暂停等数据（`cache-pause=yes`）是**正确行为**，关掉只会花屏；根因是源站带宽，参数改不出带宽 —— 如实写进 README | `README.md` §55.二.5 |
| 已澄清 | `demuxer-lavf-o` 的 `reconnect=1` 对 HLS 分片**不生效**（ffmpeg hls demuxer 自建 AVIOContext），上一版就有，本轮未动 | 同上 |
| 黑屏无反馈 | 旧遮罩只看 `_session == null`，而 session 在 load 命令发出后即有值 ⇒ 首帧前纯黑。改盯 `PictureProbe.hasPicture`，出画才撤，15 秒兜底 | `_awaitingPicture` |
| 详情页 | 播放按钮起播时图标换转圈、文案「正在打开…」 | `vod_page.dart` |
| 门禁 | analyze 0；**38 步 / 3693 断言**（3664→3693，+29：E13/E14 改写、E17–E19、I05/I07、F01–F25、G11 改写） | 22:53 |
| 产物（23:00） | 单包 44,399,091 B `8e67e776…cf9cc945`（1.0.5/code 6/minSdk16/targetSdk36、组装 24/24）；安装版 25,840,515 B `09d5aeeb…5cf17721`；便携版 33,489,087 B `c526c7ba…d868d566`（31 条） | `README.md` §55.四 |
| AOT 取证 | APK `libapp.so` 7,144,328 B `d5589f1b…`、桌面 `app.so` 8,274,824 B `17b057ef…`，均含 `正在打开…` / `收起` | 双平台 |
| 重打一次 | 初版打完后补了标题行窄窗口分支（`< 720` 检索框落到第二行，否则 300 宽输入框在手机竖屏横向溢出）⇒ 上面哈希对应补完之后的代码 | F24 |
| legacy | 未重打：`legacy/` 零改动 | `git status` |
| 未做 | **顶部布局只有静态确证 + 门禁，没有真机/桌面观感走查**（未拉起 GUI）；起播改善未做真机计时；源码未提交未推送 | — |

### 四十四、点播底部控制栏重做（1.0.5 同版重打，2026-11-11 23:30）

| 项 | 结论 | 证据 |
|---|---|---|
| 需求 | 参考主流播放器设计底部控制栏：播放暂停 / 进度条（拖动·缓冲·时间提示）/ 时长 / 音量 / 清晰度 / 倍速 / 全屏；悬停与激活反馈、悬浮数值预览、桌面+移动自适应 | 用户当轮消息 |
| 改造前 | 一行 `位置 + Slider + 时长` + `Wrap` 里 7 个 `IconButton` + 10px 提示行 | 旧 `_bottomBar` |
| 结构 | 三段轨（未缓冲白18% / 已缓冲白34% / 已播 `#4C8DFF`）→ 控制行（左：播放簇；右：时间·清晰度·倍速·音量·选集·全屏）→ 提示行 | `player_control_bar.dart` |
| 进度条 | 自绘 `_TrackBar`：`Slider` 画不出缓冲段、拇指 48×48 命中区吃掉视觉长度、气泡无挂点 | `README.md` §56.4.1 |
| 拖动 | 拖动只预览、`onHorizontalDragEnd` 才 seek（弱源连续 seek 会黑一下） | `K16` |
| 悬停预览 | 气泡宽 64，左右夹取防半截跑出栏外；数字 `tabularFigures` 防进位抖动 | `K15` |
| 缓冲夹取 | `vodBufferedProgress` 保证缓冲段不短于已播段（cache 扣减会让 buffered < position） | `K10` |
| 音量 | 宽屏：图标静音 + 悬停展开 88px 滑条；中窄屏：进内联面板（触屏无 hover）。静音记旧值 | `K20` |
| **清晰度** | **只有「自动」一档**：实测 `vod_play_from='dytt$$$dyttm3u8'`（线路名）、每集单地址 ⇒ 接口无画质档位。徽标改显示**实测解码分辨率**，面板如实说明不能切 | `K22` + `README.md` §56.4.4 |
| 倍速 | 0.5/0.75/1.0/1.25/1.5/2.0；内核不支持时**不改 UI**（不假装生效） | `K29` |
| 全屏 | 状态归 `AppShell`（与直播共用），`VodPage` 收 `fullscreen` + `onToggleFullscreen`；`_back()` 先退全屏 | `K25`/`K26` |
| 内联面板 | 不用下拉菜单：电视上弹出层会让焦点跑出播放页、且是两段式 OK 操作 | `README.md` §56.5 |
| 响应式 | 三档：full ≥900 / medium ≥560 / compact <560（按最坏内容宽度倒推，两档会在 700–1000dp 挤成两行） | `K23` |
| 性能 | 五个读数全走 `ValueNotifier` + `Listenable.merge`，只重建控制栏；音量也走 notifier；拖动预览留在控制栏内部 | `K24`/`K30` |
| 顺手修 | 旧的 `IconButton` 水波纹画在 Material 上、被视频盖住 ⇒ 悬停高亮一直不可见。新控件自绘底色 | `K18` |
| 内核 | 新增 `BufferProbe` / `PlaybackRateControl`，`PictureProbe` 补 `pictureWidth/Height`；media_kit 全实现，门禁 `_FakePlayer` 同步 | `K27`/`K28` |
| 门禁 | analyze 0；**38 步 / 3723 断言**（3660→3723，+63；点播门禁 150→180）。改写 E04/E05/E07（随实现如实改，未放宽），新增 K01–K30 | 15:20 |
| 产物（23:30） | 单包 44,448,243 B `7153a972…b1905c4f`（1.0.5/code 6/minSdk16/targetSdk36、组装 24/24）；安装版 25,853,598 B `f549786b…c7ccdd34`；便携版 33,508,950 B `77b0508c…6f5b8d4d`（31 条） | `README.md` §56.11 |
| AOT 取证 | APK `libapp.so` 7,144,328 B `9e919dfd…`、桌面 `app.so` 8,323,976 B `9fb4e286…`，均含 `清晰度`/`播放倍速`/`退出全屏`/`静音` | 双平台 |
| legacy | 未重打：`legacy/` 零改动 | `git status` |
| 未做 | **没拉起 GUI 看观感**；倍速未验真机音画同步；全屏未实际进入观察；源码未提交未推送 | — |

### 四十五、短视频栏目 + 本地内容检索记录（1.0.5 同版重打，2026-11-12 08:2x）

| 项 | 结论 | 证据 |
|---|---|---|
| 需求 | 左栏新增「短视频」并迁移已获取的全部短视频、后续新增统一归入，原菜单与播放不变；接口四字段（片名/类型/年份/地区）持久化为本地记录、可检索、启动优先读、随接口同步、去重去过期，且栏目-记录-检索三者一致 | 用户当轮消息 |
| 真实类目取证 | `bfzy` 58「短剧大全」下挂 59 重生民国 / 61 现代言情 / 68 AI漫剧（`type_pid=58`）；`dyttzy` 36「短剧」；`tyyszy` 54「短剧」/ 73「ai短剧」。`?ac=detail&pg=N` **不带 `class`** ⇒ 分页器并行多请求一次 `?ac=list` 探类目表 | 21 站点实测 |
| 归类三层 | 类目表父链（`CmsCategoryTable.isShortVideo`，`seen` 防自指成环）+ 文本关键词（短视频/短剧/微剧/漫剧/电影解说/预告片/片花/短片/微电影）+ 英文枚举；`normalizeVodItem()` 是接口新数据 / 老缓存恢复 / 记录读回的**唯一归一入口** | `vod_catalog.dart` / `third_party_vod.dart` |
| 父链优先 | 在 `sectionFromCms()` 先短路，`短剧大全` / `AI短剧` 不再被「剧」字归进电视剧 | 同上 |
| 探测不连累内容 | 每站只探一次（`categoriesProbed`）；失败**不调 `_fail()`**，只退化成文本兜底 | `vod_pager.dart` + P14b/P15b |
| 菜单只能追加末尾 | `AppSection.values` 同时决定导航顺序与 `IndexedStack` 下标，插中间会让原四栏整体错位；`shortVideo` / `shortVideos` 都追加在最后，起播仍走 `orchestrator.startPlayback` | `app_shell.dart` + K25 改写 |
| 本地记录单真相 | 沿用 `vod-library.json` v1→v2，**不建第二份索引 / 不上 SQLite**；`VodContentIndex.items` 派生 `VodItem` → 栏目 `VodLibrary.restore()` 与检索 `filterVodItems()`/`search()` 同源，无需事后对齐 | `vod_content_index.dart` |
| 去重 / 更新 / 过期 | `vodContentKey` = `片名\|年份`；`vodContentFingerprint` 变化才就地替换并刷新播放地址表；TTL 30d；同 sourceId 增量 upsert、换源整库重建；`.tmp`→delete→rename 原子落盘 | 同上 + `vod_library_store.dart` |
| 冷启动优先本地 | 记录新鲜 ⇒ 立即渲染 + 后台单批差量（1 批 / 12s / `preserveExisting=true`，**不参与首屏**）；否则走原全量加载。`preserveExisting` 防后台刷新先清空几百张卡片 | `vod_page.dart` / `vod_session.dart` |
| 检索 | `片名:` / `类型:` / `地区:` / `年份:` 等字段前缀 + 自由文本「与」；纯本地不发网络；空查询仍返回原列表引用 | `vod_search.dart` + G 段门禁 |
| 老缓存迁移预演 | 真实 v1 718 条 → 去重 **614**；电影 176 / 电视剧 426 / 纪录片 1 / **短视频 11**；回填 year·area 各 376（**不猜类型**）；`年份:2026`→346、`地区:大陆`→169、`短剧`→10。差的 1 条是 `[电影解说]`，规则生效非漏；首次读回即写回 v2 | 真实 `AppData/Local/Shunbo/vod-library.json` |
| 门禁 | analyze 0；**39 步 / 3826 断言**（3723→3826，+103 = 新增 101 + P14b/P15b 2）；新增 `verify_vod_content_index.dart` A–F 组 101 条接入第 39 步；P14/P15 拆分「翻页」与「类目探测」两套计数、K25 全屏透传 4→5 处，**如实改写未放宽** | `verify_all.dart` |
| 产物（08:2x） | 单包 44,612,083 B `83de6f2a…a075ef30495a7d17`（1.0.5 / code 6 / minSdk16 / targetSdk36，组装 **24/24**）；安装版 25,862,854 B `294e224f…701c`；便携版 33,680,463 B `aa5b91c5…3c`（31 条目、CRC 自检通过） | `README.md` §57.10 |
| AOT 取证 | APK 双 ABI `libapp.so` 与 Windows `data/app.so`（8,356,744 B `a8382006…`）均检出 `VodContentIndex`/`vodContentFingerprint`/`shortVideo`/`parseCmsCategories`/`preserveExisting`/`vod-library.json`；UTF-16LE 中文检出「短视频/片名/本地检索记录/短剧/电影解说」；zip 内 `app.so` 与分发目录逐字节一致 | 包内字节串检索 |
| legacy | 未重打：`legacy/` 零改动（`git status` 为空） | `git status` |
| 未做 | 没拉起 GUI 看短视频栏目观感、未真机起播短视频；差量同步未做「接口新增/改名/下架」长时间实测；源码未提交未推送 | — |

### 四十六、全屏回退 / 栏目图标 / 电影归属 / 一次加载（1.0.5 同版重打，2026-11-12 10:1x）

| 项 | 结论 | 证据 |
|---|---|---|
| 需求（四项） | ①点全屏不得退回上一级，进入后隐藏 Windows 任务栏（真全屏），保留 Esc/F/按钮退出；②按截图补「短视频」标题图标；③电影栏目只展示电影类片源；④取消「加载更多」，初始化一次加载完整目录并持久化，检索优先查本地 | 用户当轮消息 |
| **全屏回退根因** | 不是路由 `pop`，是 `AppShell.build()` 的**两棵树**：旧写法全屏 `return Scaffold(body: content)`、非全屏 `Scaffold(body: Stack([Positioned.fill(content), …rails]))` ⇒ 同位置 widget 类型从 `Stack` 变 `IndexedStack`，Element 无法复用，整棵子树 unmount ⇒ 点播页 `_view`/`_item`/`_query` 全部归零，渲染回初始视图 | `app_shell.dart` §58.1 |
| 修法：树形稳定 | 宽屏恒为 `Stack([Positioned.fill(content), if (!_fullscreen) rails…])`，全屏只让侧栏兄弟不渲染；窄屏恒三槽位 `Scaffold`，全屏只把 `appBar`/`bottomNavigationBar` 传 `null`（**槽位保留**）。不用 `GlobalKey` 硬保 State | 同上 |
| 退全屏三条路径 | ①控制条按钮；②`PopScope` 补 `_applyDisplayMode()`（否则 Android 停在 `immersiveSticky` 且继续锁横屏）；③`HardwareKeyboard` 全局兜底 `Esc`/`F`，**只在直播页 + 已全屏**接管，不抢点播页语义 | `_onGlobalKey` |
| Windows 真全屏三要素 | 去边框 `SetWindowLong(GWL_STYLE & ~WS_OVERLAPPEDWINDOW \| WS_VISIBLE)` + 铺满 `GetMonitorInfo(rcMonitor)`+`SetWindowPos(SWP_FRAMECHANGED)` + 任务栏让位 `ITaskbarList2::MarkFullscreenWindow` | `flutter_window.cpp` |
| 刻意不用 | `SHAppBarMessage(ABM_SETSTATE, ABS_AUTOHIDE)`：改的是用户**全局**任务栏偏好，崩溃/强杀后永久停在自动隐藏；`MarkFullscreenWindow` 只作用于本窗口生命周期 | 同上 |
| 退出还原 | `GWL_STYLE` + `SetWindowPlacement`（最大化进必须最大化出，只还原尺寸会掉成不大不小）；`SWP_FRAMECHANGED` 必须带，否则非客户区等下次 resize 才布局，看着像「卡在全屏」 | 同上 |
| Alt+Enter | `WM_SYSCOMMAND`+`SC_KEYMENU`+`lparam==VK_RETURN` 会被 `DefWindowProc` 当系统菜单吞掉；捕获后**不直接切窗口**，`InvokeMethod("toggleFullscreen")` 回 Dart 统一翻转，避免「窗口切了但 `_fullscreen` 还是 false」双真相 | 同上 |
| 桌面分支前置 | `DisplayMode.apply` 的 `if (isDesktop)` **排在** `if (!onAndroid) return;` 之前 —— 原来那行会把桌面端短路，全屏请求永远发不出去 | `display_mode.dart` |
| 栏目图标 | `_sectionIcon` 覆盖五个 `VodSection`（movie/video_library/public/smart_display/category），22px + `textSecondary`，与标题 22sp/w600 并排不抢戏；`other` 也给图标（检索结果可能落在它上面） | `vod_page.dart:910` |
| **电影混入根因** | 不是筛选错，是归类错：老 `sectionFromName()` 兜底 `return movies`。真实记录电影 470 条中 64「大陆综艺」/52「足球」/46+46 日韩港台综艺/61「现代都市」/9「记录片」全这么混进来 | `vod_catalog.dart` §58.4 |
| 归属三改 | ①新增 `VodSection.other` 追加末尾（枚举序号=导航顺序+`IndexedStack` 下标）；②`vodSectionFromText()` 返回 `null` 表证据不足、**不再兜底电影**，顺序：短视频→纪录片/剧集→排除综艺体育→电影；③`normalizeVodItem()` 唯一归一入口，电影栏目拿不出证据的外部条目迁 `other` | 同上 |
| 判据取舍 | 电影用「以『片』结尾」而非 `contains('片')`（`片花`/`预告片` 是短视频）；**不读 `genre`**（题材标签，真电影也带「纪录片」「喜剧」，会误踢犯罪片）；**不读副标题「正片」**（9 条 NBA/羽毛球赛事正是靠这两个字混进来） | 同上 |
| 最后一道闸 | `isMovieSectionItem()` 防没走过归一的外部安装路径；内置 6 条 `VodCatalog.sourceId` 一律放行（它们本就是「电影栏目非空」的兜底） | 同上 |
| 取消加载更多 | 启动 `main()` 整份读回 `vod-library.json`（几毫秒）→ 首屏直接完整目录；后台 `_revalidateInBackground` 按 `kVodFullSyncMaxBatches`/`Budget` 一次跑完、逐批落盘、`preserveExisting:true` 不清空；`_moreRow()` 只剩状态告知，**按钮已删**；滚到底 `kAutoLoadExtentAfter=800` 顺手接一批 | `vod_page.dart` |
| 检索本地优先 | `_filteredFor()` 先 `localMatches(q)` 拿命中 id，再在栏目列表取交集，最后叠 facet+关键词 ⇒「本地记录→检索结果→栏目卡片」同一份数据，不会搜到却点不开；**不发网络**（否则「优先读本地」名不副实） | 同上 |
| 门禁改写（未放宽） | `edge-handles`「全屏左侧浮层不渲染」改为「浮层不出现 **且** 不另起树」；「窄屏底栏」改为锁「只置空槽位值」；`mobile-layout` 163 条新增桌面分支/窗口下发/两路互斥/槽位传 null/退全屏收系统栏/键盘兜底；`vod-content-index` F13 与 `vod-source-address` G11 改为「本地优先 + 顺序不可颠倒」 | `verify_*.dart` |
| 门禁结果 | `flutter analyze` 0 问题；全量 **39 步 / 3854 断言全绿**（3826→3854，+28） | `verify_all.dart` 104.6s |
| C++ 编译证据 | `flutter build windows --release` **61.7 s** 成功：`MethodChannel<EncodableValue>` 模板实例化、`ITaskbarList2`(ole32)、`GetMonitorInfo`(user32)、shell32 全部链接通过 | 构建输出 |
| **产物（三端同版重打 1.0.5+6）** | `full.apk` 44,612,083 B `ed0f7cdc…6c9a66b6`（组装 24/24）；`windows-x64-setup.exe` 25,873,368 B `070d72cd…a20040c7`（ISCC 27.1 s）；`windows-x64-portable.zip` 33,542,328 B `fb06c9ce…147f3f8`（31 条目、`testzip` 无坏项）。旧包全部归档 `dist/_prev/` | `sha256sum` |
| 新代码进包取证 | APK 双 ABI `libapp.so` 与 Windows `data/app.so` 均检出 `shunbo/window`/`setFullscreen`/`toggleFullscreen`/`window_channel`（英文串走 **UTF-8**，`utf16le=False`）+ `vodSectionFromText`/`normalizeVodItem`/`isMovieSectionItem`/`localMatches`；中文串（UTF-16LE）`短视频`/`电影解说`/`目录已完整`/`后台自动补齐` | 字节检索 |
| Windows 分发目录 | `dist/windows/Shunbo-1.0.5/` **31 文件 / 20 个 DLL**（含 10 个 VC++ CRT）；`shunbo.exe` 131,584 B、`data/app.so` 8,373,128 B 为本轮 10:13 新构建（旧为 08:23 的 92,160 B / 8,356,744 B） | `ls -la` |
| Windows 烟测 | 静默安装 `/VERYSILENT /DIR=dist\_smoke105` 退出码 **0**、落地 **33 文件 / 86,035,530 B**、`data/app.so` 大小一致；静默卸载退出码 **0**、目录彻底移除无残留。**未拉起 GUI** | `Start-Process -Wait` |
| 清理 | 删除未跟踪临时探针 `tooling/_tmp_decode_probe.dart`、`tooling/_tmp_migrate_probe.dart` | `git status` |
| legacy | 零改动 | `git status` |
| 未做 | **没在 Windows 上真进一次全屏看观感**（任务栏是否让位/Alt+Enter 是否触发/退出是否还原最大化），只做编译+静态确证；**没在 Android 真机验证「点全屏不回退」**（Element 复用是运行期行为）；电影归属未拉 GUI 数 470 条实际落点；后台全量同步未做「接口新增/改名/下架」长时间实测；源码未提交未推送 | — |

### 四十七、点播播放中按返回必闪退（Surface use-after-release，1.0.5 同版重打，2026-11-12）

| 项 | 结论 | 证据 |
|---|---|---|
| 需求 | 「影片播放过程中点返回上一级 系统会崩溃并闪退」——不是偶发、不限片子，**只要在播放态按返回就崩** | 用户当轮消息 |
| **崩溃时序链** | 返回 → `PopScope(canPop: _view == browse)` 为 false → `_back()` → `_leavePlaying()`：同步 `setState(_view = detail)` **同一帧**摘掉 `PlayerStage` → `AndroidView` dispose → `PlayerSurface.dispose()` 先 `surface?.release()`，而 `unawaited(_pauseForLeave())` 的 `pause()` 还在飞行中 ⇒ 渲染线程继续往已释放的 native buffer 提交帧 → SIGSEGV，**无 Dart 栈、只有闪退** | `vod_page.dart:273` / `PlayerSurfaceFactory.kt` |
| **根因** | `MpvMethodHandler.detachSurface()` 旧实现只把字段置空，注释写「真正的释放由 dispose 负责」，但 **dispose 也从未调用过 `engine?.setSurface(null)`**（全仓库 `setSurface` 只有 `attachSurface` 那一处）⇒ `ExoPlayerEngine` 长期持有已 `release()` 的 `Surface` | `MpvMethodHandler.kt:60` |
| 已排除①：重复释放 | `surface` 是「先 release 后置 null」，两条销毁路径谁先到谁生效，第二次拿 null 直接跳过。**问题是顺序不是次数** | 同上 |
| 已排除②：Dart `setState` 时机 | 返回时同步改 `_view` 是**正确**的（`didUpdateWidget` 那条 `rebuild: false` 就是为避开 build 期 `setState` 单独写的）。摘渲染面是预期行为，摘的时候没解绑才是 bug | `vod_page.dart:265` |
| 已排除③：`_applyLiveProfile` | `LibMpvPlayerController` 在 Android **没实现 `PlaybackTuner`**，那个 `await` 是 no-op，不构成时序风险 | — |
| 修法①（核心） | `detachSurface()` 改为**先 `engine?.setSurface(null)` 再 `surface = null`**：换集时 `attachSurface` 会重新补上，不影响续播 | `MpvMethodHandler.kt` |
| 修法② | 两条销毁路径统一为「`host.detachSurface()` → `surface?.release()` → `surface = null`」：`onSurfaceTextureDestroyed` 与 `dispose()` 都是 | `PlayerSurfaceFactory.kt` |
| 修法③ | 布局监听从匿名类改为 `private val layoutListener` 字段，`dispose()` 第一步 `removeOnLayoutChangeListener`。旧写法**没有句柄可注销**，销毁过程中仍会 `scale.apply` 到正在销毁的 `TextureView`（源码注释自认「ANR/崩溃风险」） | 同上 |
| 修法④ | `VideoScaleController.apply` 首行加 `if (!view.isAttachedToWindow) return`：`detach()` 只从集合移除，挡不住已在飞行中的 `main.post {}` | `VideoScale.kt` |
| Dart 侧 | **一行没动**：`_leavePlaying()` 签名与 `_view = _item == null ? …` 原样，`I04` 断言继续通过 | `git diff` |
| 门禁新增 | `verify_mobile_layout` D 段 +4 条（`setSurface(null)` 存在 / `detachSurface` 早于 `release` / `layoutListener` 可注销 / `isAttachedToWindow` 守卫），新增 `_orderOf()` 助手专门校验**顺序敏感**逻辑 | 167/167（163→167） |
| `_orderOf` 教训 | 第一版写「全体比较」，把两条销毁路径混在一起直接误报失败。真实代码序列是 `a b a b`，语义必须是**配对**（每个 `b` 就近配一个未配对的 `a`）。**门禁助手本身也要按真实代码形态设计** | 同上 |
| 门禁结果 | `flutter analyze` **0**；`verify_mobile_layout` **167/167**；`verify_channel_contract` **19/19**（方法名集合未变、双向差集仍为空）；全量 **39 步 / 3858 断言全绿**（3854→3858，+4，只追加未放宽） | `verify_all.dart` |
| legacy | 零改动 ⇒ legacy 独立包未重打 | `git status` |
| 未做 | **本机无 adb**，拿不到 logcat，无法本地复现再验证 —— 时序链是**静态推断**（代码路径 + Android Surface 语义），修复按正确时序改写而非「复现后打补丁」；**「播放中按返回现在是否真的不崩」必须用户真机实测**；源码未提交未推送 | — |

### 四十八、内置检索索引 + 启动校验 + 动漫栏目（1.0.5 同版重打，2026-11-12 14:20）

| 项 | 结论 | 证据 |
|---|---|---|
| 需求（三项） | ①`config.json` 索引目录单（约119.7万条）完整进包、按栏目分片压缩、检索按栏目取；②启动校验「用户设定接口」与「内置/已下载索引」是否一致，一致读本地进播放、不一致从接口同步，并明确一致性依据/失败回退/各状态提示/更新覆盖策略；③左侧栏新增「动漫」栏目并说明归类规则 | 用户当轮消息 |
| **口径变更（必须告知用户）** | 内置的**不是完整目录**，是**精简检索索引**。`?ac=detail` 单条实测 **17,216 B**，`vod_play_url` 占 **13,595 B**（79%）⇒ 135 万条 ≈ **21 GB**，不可能打进任何安装包。分工改为：**索引负责「搜得到」，详情接口负责「播得了」**（点开才用 `?ac=detail&ids=` 回源） | 「21 GB」推导见 README §60.0 |
| 索引行格式 | `站点下标 \t vod_id \t 类目字典下标 \t 片名`（文本，非二进制——便于裸 `dart run` 与 Python 双向交叉校验） | `pack`/`builtin_index.dart` |
| 体积压缩四步 | 只存四字段（17,216→约30 B/条，**573×**）+ **片名前端编码**（按片名排序后只存「与上一行公共前缀长度+后缀」，13.24 B/条）+ 按栏目 6 片 + gzip -9 | 同上 |
| 前端编码两侧同口径 | Python 在 **UTF-8 字符边界**回退（不能切多字节中间）；Dart `applyFrontCode` 对越界前缀容错。差一字节的症状是「某些片名搜不到」，极隐蔽 ⇒ 门禁逐片逐行校验 | `B04`/`C03`/`C04` |
| 分片键 | `VodSection.name` 六片：`movies`/`series`/`documentaries`/`shortVideo`/`anime`/`other`；**打包侧与读取侧共用同一套词表**（`sectionFromCms` 顺序=文本短视频→父链短视频→父链动漫→`sectionFromName`），门禁 F03/F04 断言两侧关键词集合逐字一致 | `verify_vod_builtin_index` |
| **一致性依据三档** | ①**接口地址**（`manifest.sourceUrl` vs 用户设定）——故意放最前：地址变了索引里 id 全指向另一个站，先加载再发现用户只会看到点不开的卡片，且这项**离线可判**；②**新鲜度**（`generatedAt` ≤ 7 天，未来时间戳不判过期，防打包机时区错）；③**完整性**（分片读不到 / `records==0`）。只读分片存在性不整片解析（全解 13 MB 会让冷启动多一秒） | `vod_boot_index.dart` |
| 六态与文案 | `idle`/`checking`/`readyBuiltin`/`syncingNetwork`/`fallbackBuiltin`/`incomplete`；每态一句人话**全在状态机里**，页面只显示（避免「诊断页说已加载、页面说正在下载」）。默认（未开外部地址）`allowSync=false` ⇒ 不偷偷联网，落 `fallbackBuiltin` 并说明「未联网校验」 | 同上 + `_bootRow()` |
| **覆盖策略** | 内置比缓存新 ⇒ **覆盖**（升级就为拿新片）；比缓存旧 ⇒ **不覆盖**（降级/重装不能删用户数据）；接口地址变了 ⇒ **覆盖**（旧 id 全错）。只看 `generatedAt`+`sourceUrl`，**不看条数**（站点挂掉条数会少但内容可能更新）⇒ `shouldReplaceCache()` | `main.dart` 缓存恢复段 |
| 启动时机 | 校验挂在**首帧之后**（`addPostFrameCallback`）：本地读完几十毫秒，但判定不一致会触发几秒~几十秒的网络同步，放 `runApp` 前会把首帧钉死 | `main.dart` |
| 检索：按栏目懒加载 | 真机 API18 上 147 万条 `VodItem` 至少 400 MB ⇒ 只做「解 gzip → 按 `\n` 切行 → 命中才建对象」；片名靠「上一行完整片名」滚动变量还原。`BuiltinIndexService` 按 sectionKey 缓存解压文本、`_loading` 并发去重 | `vod_builtin_service.dart` |
| 检索：两段式 | `_filteredFor` 是**同步**的不能 await ⇒ 输入变化 debounce **180 ms** → 异步写 `_indexHits` → 同步合并。`_indexSeq` 保证「先回来的旧结果不覆盖后回来的新结果」；`_indexHitsQuery` 保证「输入变了但结果没回来」时不拼旧结果 | `vod_page.dart` |
| 合并顺序 | 本地命中**在前**、索引命中**在后**（本地已可播、索引还要回源），同名片名去重 ⇒ 不会出现同一部片两个卡片。计数文案同步改口径（`本地 N + 索引 M 条`），否则「30 / 2 部」自相矛盾 | `_mergeIndexHits` / `_countLabel` |
| **回源为何不用 append** | `append()` 发现 `sourceId` 变了会 `_clearExternal()` ⇒「从索引点开一部片」会把已同步的几万条外部目录**整批清空**。这种事故不崩不报错，只是「升级后片库突然空了」，极难反推。新增 `adoptResolved()`：只注册剧集/地址表 + 保证该 sourceId 有适配器，不碰 `_external`、不碰当前外部源指针 | `vod_library.dart` + 门禁 N01–N14 |
| 回源 id 口径 | `源id:站点key:vod_id`，与网络同步**完全一致** ⇒ 同一部片从索引点开 / 从网络同步点开，续播记录是同一条 | `main.dart` `fetchDetail` |
| 回源明文 http | **无条件放行**：索引里的站点地址是打包时固化进安装包的，不是用户输入——与「用户手输地址要显式放行」是两件事；不放行则默认索引点开全黑，等于没有 | 同上 |
| 回源栏目 | 用**索引里已定好**的 `section`（`vodSectionFromKey(hit.section)`），不按 `typeName` 重猜：详情接口不保证回 `type_name`，重猜会把动漫/短剧打回电影栏目 | 同上 |
| 回源条目不进栏目 | 索引十几万条，塞进片库既撑爆一万条上限，也会让「栏目」变成另一个检索结果页 ⇒ **索引只负责搜得到** | `adoptResolved` 注释 |
| 第 3 项：动漫栏目 | `VodSection.anime` 与 `AppSection.anime` 都**追加在枚举末尾** ⇒ `IndexedStack` 下标=枚举序号=导航顺序，**前五项一个都不动**。规则：①短视频优先（`AI漫剧`/`漫剧` 归短视频）②类目父链（`type_pid`，子类目名无「动漫」也能认）③其余归 anime ④证据不足归 other | `app_shell.dart:410` / `vod_catalog.dart` |
| 真实动漫类目 15 个 | `动漫`/`动漫片`/`动漫电影`/`国产动漫`/`日韩动漫`/`欧美动漫`/`港台动漫`/`海外动漫`/`中国动漫`/`日本动漫`/`动画片`/`AI动漫`/`AI漫剧`/`漫剧`/`有声动漫` | 打包侧词表 + 门禁 F03 |
| 门禁新增 3 套 | `vod-builtin-index` **91**（真实产物：manifest 自洽/唯一片名数与每名上限/行数与 sha256/前缀编码还原/词表逐字一致/分片可检索）；`vod-boot-index` **61**（六态全转移图 A–M，含 `shouldReplaceCache` 六条与源码护栏）；`vod-builtin-service` **115**（运行期检索/栏目隔离/limit/缓存/命中反查/回源参数/adoptResolved 不清外部目录/同名归并一张卡/回源失败换源）；全量 **42 步 / 4150 断言**（3858→4150，+292） | `verify_all.dart` |
| K25 如实改写 | 全屏透传断言原写死「直播1+点播4=5」，加动漫栏目后变 6 处 ⇒ 改为「点播页实例数（从 `VodSection.\w+,` 数出）+1」。**未放宽**：加栏目不破门禁，少给某页透传仍会红 | `verify_vod_playback.dart` |
| 门禁踩坑① | `Gate.dart` 的 `expectAssertions` 是 **bool**（只校验「有断言数」），传 int 直接编译错误 —— 条数写在 note 文案里 | `verify_all.dart` |
| 门禁踩坑② | 新门禁 N03 首跑失败，原因是**样本不真实**：测试用 `VodItem` 没给 `typeName`，被电影栏目 `isMovieSectionItem` 整条滤掉；不是 `adoptResolved` 清空了目录。样本必须带 `typeName` 才测得出真问题 | `verify_vod_builtin_service` |
| 门禁踩坑③ | `SourceRegistry` 只有 `get(id)` 没有 `byId`；适配器取址是 `resolvePlayUrl(mediaId, episode)` / `getEpisodes(mediaId)`，都是 **async** | `source_registry.dart` / `source_adapter.dart` |
| **全量抓取实测** | 13 站 / **29,318 页** / **1,473,395 条**原始记录（8 站全程不可用：`wwzy`/`ruyi`/`ffzy`/`wolong`/`dbzy`/`ikun`/`suonizy` + 中途退出的站；`wujin` 中途复活已纳入） | `build/_fetchlog/run5.log` |
| **打包产物** | **605,106 条 / 381,968 唯一片名 / 6.18 MB**（movies 159,715 · series 71,916 · documentaries 14,270 · shortVideo 179,176 · anime 60,281 · other 119,748）；安装包 42.5 → 约 49 MB，仍低于 60 MB 门禁 | `assets/vod_index/` |
| **每名留 2 条（`--keep-per-title`）** | 全留 ⇒ 19 MB 顶满门禁且同片 4 张卡；只留 1 条 ⇒ 4.55 MB 但丢失换源能力。折中：每名最多 2 条且**优先不同站**，8.8 B/条单价把总量压到 6.18 MB，每个片名都有备胎。Dart 侧 = 检索同名归并一张卡（`_alts`）+ 回源失败依次换源（`_tryResolve`） | §60.11 + 门禁 Q01–Q13 |
| 抓取坑①：**按站钳制 pagesize** | `dyttzy`/`bfzy` 支持 100，`tyyszy`/`zuid`/`yinghua`/`wujin` 只给 **20** ⇒ 按请求值算页数会让那几站只抓 20%，且产物自洽不报错 | 探测首屏条数再算页数 + 打包复核「真实条数 ≥ total×90%」 |
| 抓取坑②：**类目表字段方言** | `dyttzy` 用 `type_id/type_pid/type_name`，其余站 `id/pid/name` ⇒ 只认一种则整站类目表为空 | `load_classes()` 同时认两套 |
| 抓取坑③：**缺类目表静默归错栏目** | `dyttzy` 类目表没抓到那轮，8.5 万条全掉「其他」，行数/sha256/总数全对 | 打包**硬检查**：有数据无类目表 ⇒ 直接报错（`--allow-missing-classes` 放行） |
| 抓取坑④：**`dead` 标记误伤已抓数据** | 重启探活 `dyttzy` 被 WAF 回 403 ⇒ 标 `dead` ⇒ 整站 8.5 万条被静默排除 | 可用性改以**本地已抓页**为准：一页都没有才算死站 |
| 明确不做 | ①不在打包时探活排优先级（403 可能是三万请求的临时限流，且让构建不可复现）；②不全量入包（体积）；③回源条目不进栏目（撑爆 1 万条上限） | §60.13 |
| **产物（14:2x 同版重打）** | 单包 `dist/Shunbo-1.0.5-full.apk` **51,149,994 B / 48.78 MB** `b1675cfa84651f44…d07c2ff9b77bff02`；Windows 安装版 **32,374,374 B** `a813b348…0cfb3106`；便携包 **40,054,225 B / 38 条目** `7ffea53f…a9ea3adb`。版本仍 `1.0.5+6`（`aapt2 badging`：versionCode 6 / versionName 1.0.5 / minSdk 16 / targetSdk 36） | `dist/` |
| **进包取证** | 单包内 7 个索引文件与 `assets/vod_index/` **逐字节一致**（6,487,505 B）；`libapp.so` 检出 `assets/vod_index/` / `builtin:` / `builtin-index`（UTF-8）与 `内置索引`/`已加载内置索引`/`正在校验本地索引`/`接口地址与内置索引不一致`（UTF-16LE）；Windows `data/app.so` 同批串；合并单包 24/24 断言全过（channels.json 字节一致 / ijk so 只进 v7a / apksigner @16@18 / 无 androidx.startup） | 取证明细见 README §60.14 |
| 体积账 | 单包 42.5 → **48.78 MB**（+6.28，索引 6.19 MB），距 60 MB 门禁余 11 MB；桌面安装版 25.8 → 30.87 MB；便携包 33.5 → 38.20 MB | 同上 |
| 未验证 | 内置索引真机表现：首屏耗时、6 MB 分片解压内存峰值、检索延迟、点开回源失败率 —— 本机无 adb，只静态确证「资产在包内 + 代码路径存在」 | — |

### 四十九、Windows 覆盖安装卡在 d3dcompiler_47.dll（code 5 拒绝访问，1.0.5 同版重打，2026-11-12 14:5x）

| 项 | 结论 | 证据 |
|---|---|---|
| 现象 | 装 `Shunbo-1.0.5-windows-x64-setup.exe` 到一半弹框：`DeleteFile failed; code 5. 拒绝访问。` 目标 `D:\Programs\Shunbo\d3dcompiler_47.dll`，点 Try again 反复同样报错 | 用户实拍截图 / README §61 |
| **根因（易误判）** | **不是权限/只读属性**，是**映像已被映射**：`shunbo.exe` 把 `d3dcompiler_47.dll`/`flutter_windows.dll`/`libEGL`/`libGLESv2`/`libmpv-2` 作为 image section 载入，进程存活期间内核禁止删除被映射的映像文件（改代码段会让已映射页失效）⇒ `DeleteFile` 直接 `ERROR_ACCESS_DENIED` | 独占打开测试：进程在跑时抛 `being used by another process` |
| 判据（可复用） | 目标文件能否以 `ReadWrite` + `FileShare.None` 独占打开：能 = 锁已释放；抛异常 = 仍被映射。比看任务管理器可靠（僵尸条目会骗人） | 实测脚本 |
| 现场实况 | 4 个进程条目里只有 2 个真身：`2184`（713.9 MB）、`28408`（1365.9 MB）在跑；`9292`（11:04）、`29580`（11:25）已在 0 MB 僵尸态 —— **用户先后起了两个实例都没关**，叠加两个 taskkill 报成功但内核对象未回收的残留 | `Get-CimInstance Win32_Process` |
| **防线一** | `[Setup] CloseApplications=force` + `CloseApplicationsFilter=*.exe,*.dll` + `RestartApplications=no`：交给 Restart Manager 发 WM_CLOSE，程序能正常存盘退出（温和路径）；`RestartApplications=no` 是因为 `[Run]` 段自己会拉新程序，交回 Inno 会开两份 | 三份 iss |
| **防线二（不可省）** | `[Code] PrepareToInstall` 里 `taskkill /F /IM shunbo.exe` 兜底：Restart Manager 对多实例 / 僵尸 / 无响应窗口会漏。退出码 `0`=杀到、`128`=本来没进程、其余重试 3 次（间隔 400 ms）；**杀到后必须 `Sleep(1000)`** —— 进程退出到句柄真正释放有延迟，省掉就是「偶发」code 5 | 同上 |
| 为何不用 `restartreplace` | 它把被占文件登记进 `PendingFileRenameOperations`（HKLM），per-user `PrivilegesRequired=lowest` 写不进去；且要重启才生效，用户会以为装完了其实没换 | — |
| 为何不用 `AppMutex` | 干净但要求 `shunbo.exe` 原生入口创建互斥体，得改 `windows/runner/main.cpp`；为装包给运行时加全局约束，收益不抵改动面 | — |
| 改动位置（3 份同步） | `dist/windows/Shunbo-1.0.5.iss`（**实际出包用这份**）、`tooling/windows_installer.iss`（通用）、`tooling/windows_release.iss`（1.0.4 留档） | 均已含 `CloseApplications` + `[Code]` |
| 编码约束（踩过） | iss 必须 **UTF-8 BOM + CRLF**，否则 Inno 按 ANSI 解析、中文全乱码。脚本改写后逐份复验 `BOM=True / LF-only=0` | 三份复验通过（119/108/119 行 CRLF，LF-only 全 0） |
| **实测（最坏场景）** | 先起两个真实实例把 DLL 占死（独占测试确认"being used"）→ `setup /VERYSILENT /SUPPRESSMSGBOXES /NORESTART` → **EXITCODE 0**，两个真实进程双双消失，只剩僵尸条目 | 安装日志「Installation process succeeded / Need to restart Windows? No」 |
| 实测（文件完整性） | 逐字节比对 `dist/windows/Shunbo-1.0.5` ↔ `D:\Programs\Shunbo`：**38/38 一致（sha256）**，缺失 0、不符 0；索引 7 分片 **6,487,505 B** 与 APK 内同批一致 | 比对脚本输出 |
| 实测（GUI 启动） | 装完启动：PID 存活、52 线程、主窗口标题「顺播 shunbo」、加载索引后工作集 1332.6 MB（与旧版同量级，非本次引入） | `Get-Process` |
| 副产品：tmp 残留 | 失败/中断安装会在 `{app}` 留 `is-XXXXXXXXXX.tmp`（先写临时名再改真名的中间态），本次残留 `is-D962JD8YVR.tmp`（=unins000.exe 尺寸）与 `is-PYKVLLUB4H.tmp`（=libmpv-2.dll 尺寸），**不会被下次安装自动清理**，已手工删 | 目录列表 |
| 产物 | `dist/Shunbo-1.0.5-windows-x64-setup.exe` **32,374,781 B** `c01f62c7d886bd…e6b0360b`；修复前 `a813b348…0cfb3106` 存 `_prev/…before-lockfix.exe`。版本仍 `1.0.5+6` | `sha256sum` |
| 现场救济（给用户的） | 任务管理器结束所有 `shunbo.exe` → 回向导点 Try again。**先解当下再补脚本** —— 顺序反了会让人以为「重装就能好」 | 本次实际处置顺序 |
| 未验证 | 只在 per-user（`PrivilegesRequired=lowest`）路径实测；提权安装（`{autopf}` 到受保护目录）未测。多用户会话切换场景未测 | — |

### 五十、「类型」全是国家名 + 有内置索引还在同步（1.0.5 同版重打，2026-11-12 15:2x）

| 项 | 结论 | 证据 |
|---|---|---|
| 现象 1 | 「类型」筛选行是 `欧美剧 / 国产剧 / 日本剧 / 韩国剧`——一排国家名，和「地区」行撞车；顶部快捷 tab 行是同一批词，一屏出现三遍 | 用户截图 1 |
| 现象 2 | 顶部写「已加载内置索引 60.5 万条（2026-11-12 打包）」，下一行却是「目录同步中：已加载 10000 部，接口统计 1475989 部」 | 用户截图 2 |
| **根因 A（取词层）** | `vodTypesOf()` 读 `item.typeName`（采集站栏目类目），**从没读 `item.genre`**（`vod_class` 真题材）。栏目类目本身就是「地区 + 体裁」写法，所以「类型」行必然长成国家名 | `vod_facets.dart` 旧代码 `final raw = item.typeName;`；`vod_catalog.dart:360` 注释早写着「`type_name` 是栏目类目，`vod_class` 才是用户理解的类型」 |
| **根因 B（数据层）** | 列表接口（`?ac=list`）不返回 `vod_class`，只有详情接口返回 | 本机 1 万条缓存实测：`type` 空值 **0%**（78 值）、`genre` 空值 **71.5%**（128 词）|
| **根因 C（索引层）** | manifest 只存 78 个类目 **ID**，没存名字；回填写 `typeName: hit.typeId` ⇒ 从索引点开的片，类型显示成「25」 | 旧 manifest `types:["25",…]`；打包脚本 `pack_vod_index.py` 其实已拿到类目名，只是没写出 |
| **修法 1：类型取词** | `genre` 优先；为空才回落 `typeName`，且用 `isNonGenreLabel()` 剔掉「地区 + 体裁」与纯体裁词。**不纯用 `genre`**：71.5% 条目没有它，纯用会让七成条目点了没反应 | `vod_facets.dart` `vodTypesOf` / `isNonGenreLabel` |
| 剔除判据（可复用） | 剥掉体裁后缀（`电视剧/网络剧/动画片/纪录片/动漫/动画/综艺/电影/短剧/剧场/节目/视频/片/剧`）后：核心是地区词 ⇒ 剔（`欧美剧`→欧美）；核心为空 ⇒ 纯体裁剔（`电影`/`剧`）；否则保留（`动作片`/`篮球`/`纪录片`） | 同上 |
| **修法 2：地区脏值** | 有些站把 `vod_area` 当更新状态用，「地区」行冒出 `已完结`/`全80集（合全集）`/`正片`。新增 `looksLikeVodArea()`：含数字、含 `集/完结/更新/正片/预告/花絮/抢先`、含 `HD/BD/TC`、长度>8 ⇒ 不进地区行 | 改后地区行：大陆/内地/中国大陆/美国/日本/韩国/泰国/台湾/英国/中国台湾/加拿大/印度 |
| **修法 3：索引补名字** | manifest 增 `typeNames`（中文名）+ `typeSites`（该项属于哪个站），523 项 | `pack_vod_index.py` payload |
| **为什么必须带站点** | `type_id` 是**各站自己的编号**。第一版按裸 `type_id` 建全局表，实测 **314,179 行**同名冲突（`1` 在 A 站=电影、B 站=电视剧），会把「电视剧」标到一部电影上——不报错，只是标错。改成 `(站点, type_id)` 后**站内冲突 0 行** | 打包日志：`类目字典 523 项（站点 × 类目）/ 无名字 5 项 / 站内同名冲突 0 行` |
| 查不到名字怎么办 | 返回**空串**，绝不回退成 id —— 宁可这条没有类型，也不要用户看到「25」 | `typeNameOf()` + 门禁 A21 |
| **根因 D（同步）** | 两条链路互不通气：A 启动校验（13 次修，首帧后跑）判 `readyBuiltin` 不联网；B 后台全量同步（11 次修，`initState` 就跑）只看「开关开 + 默认源」，判据里**没有 `vodBoot`** | `vod_page.dart` `_ensureDefaultSource` |
| 时序是死结 | B 在首帧前跑、A 在首帧后跑 ⇒ B 读 `hasLocalIndex` 时 phase 还是 `idle`，**即使加了判据也会判错** | 同上，故必须引入 `settled` |
| 这条同步永远追不上 | 单次上限 `kVodCacheMaxItems=10000` vs 接口 1,475,989 部 ⇒ 覆盖率 **0.68%**；每轮 240 批/5 分钟，每批重写 16 MB JSON；游标纯内存不持久化 ⇒ 冷启动从第 1 页重来 | `third_party_vod.dart` 常量 |
| **修法 4：三道闸** | ①`VodBootController` 新增 `settled`（未开始时立刻返回，不挂住）；②`_ensureDefaultSource` 先 `await boot.settled` 再判 `hasLocalIndex`，够用直接 return；③`_revalidateInBackground` 进入前 + 每批循环里都复查 `!boot.hasLocalIndex` | `vod_boot_index.dart` / `vod_page.dart` |
| **修法 5：文案** | 旧「目录同步中：已加载 N 部，接口统计 1475989 部」——分母注定追不到。新「后台增量同步中：已加载 N 部 · 内置索引 60.5 万条已可直接检索」；内置索引就绪时整行不显示 | `_moreRow()` / `_wanCount()` |
| **实测（真实数据）** | 本机真实 1 万条缓存：改前类型行 `AI漫剧/短剧/爽文短剧/现代都市/篮球/国产动漫/欧美剧/足球/国产剧/大陆综艺…`；改后 `AI漫剧/剧情/爽文短剧/现代都市/篮球/奇幻/古装/足球/喜剧/爱情…`。类型词 36 个，仍有类型词的条目 **74.8%**（改前 100%，但七成是错的） | 临时探针（已删）|
| 实测（体积） | 索引 6,482,828 → **6,613,466 B**（6.18→6.31 MB，+130 KB）。下标 78 项→523 项，数字位变宽压缩率略降；仍在 60 MB 门禁内 | 打包日志 |
| 门禁 | `flutter analyze` 0 issue；**42 步 / 4186 断言**（上轮 4150，+36）：`vod-playback` F03a–F03i(+9)、`vod-builtin-index` A15–A21/F07–F08(+9)、`vod-boot-index` N01–N06/S01–S06(+12)、`vod-builtin-service` H09–H12(+6) | `dart run tooling/verify_all.dart` |
| 产物（三件） | APK `dist/Shunbo-1.0.5-full.apk` **51,297,450 B** `b0e9491132ff6e09…428ffb72`（单包 24/24 断言过）；Windows setup **32,509,706 B** `8e2c2b36a197a4e8…b13346193`；portable zip **40,190,250 B** `a79cf3f190d829bf…fdb4c8572`。版本仍 `1.0.5+6` | `sha256sum` |
| 进包取证（APK） | 7 个索引文件与仓库逐字节一致，合计 **6,634,112 B**；APK 内 manifest `total=605106 类目=523 名字=523 站点=523`；`libapp.so`(arm64) 检出 `assets/vod_index/`、`typeNames`、`typeSites`、`条已可直接检索`、`后台增量同步中`（中文按 UTF-16LE） | zipfile 取证脚本 |
| 进包取证（Windows） | 静默覆盖安装 EXITCODE **0**（上一轮补的 `CloseApplications`+`taskkill` 防线生效）；`dist/windows/Shunbo-1.0.5` ↔ `D:\Programs\Shunbo` **38/38 逐字节一致**；GUI 启动存活、51 线程、窗口「顺播 shunbo」、工作集 1269.8 MB | 安装日志 + 比对脚本 |
| 未验证 | ①真机（API18/armv7a）上 `settled` 的冷启动耗时、内置索引点开后的类型显示；②「大陆/内地/中国大陆」仍是三个词未归一；③同站内同名不同义类目仍会合并（实测 0 行，暂不处理） | — |
| 教训 | ①**字段注释写对了、代码没读它**——注释不是实现，门禁要断言行为不是断言注释；②**新能力上线必须回头收敛旧调用点**（13 次修的内置索引没有回头管 11 次修的全量同步）；③**时序也是判据**：在 A 之后才成立的结论，B 在 A 之前读一定会读错，得给个「等结论」的入口；④**同名不同义的主键必须先加维度**（`type_id` 单靠自己是跨站唯一的幻觉） | — |

### 五十一、进入点播即加载索引片源 + 接口校验五态（1.0.5 同版重打，2026-11-12 16:2x）

| 项 | 结论 | 证据 |
|---|---|---|
| 需求 | 进入点播先查「已保存索引是否有有效片源 + 记录的接口与当前设定是否匹配」；匹配直接把索引片源灌进播放列表；不通过走接口输入流程（初次必弹）；提交地址后同址直接加载、异址重新获取并生成新索引目录文件（沿用默认目录处理规则）。要求状态可分、来源唯一、列表与最终索引一致 | 用户第十六次修需求 |
| **修前落差** | 内置索引**只在搜索框里存在**：`vodBoot.readyBuiltin` 只表示「可检索」；`_buildBrowse` 读 `VodLibrary.inSection`（外部目录缓存）；`BuiltinIndexService.search()` 空 query 直接返回空；界面写「已加载 60.5 万条」而网格一条索引片源都没有 | README §63.1 |
| 五态状态机 | `vod_index_gate.dart`：`checking/ready/needAddress/building/failed`，纯 Dart 无 IO。判据顺序不可换：接口未设定（离线可判，保证初次必弹）→ 生成目录匹配 → 内置目录匹配 → 其余 `needAddress` 且区分「索引缺失」/「地址不匹配」 | `evaluateVodIndexGate` |
| 有效片源判据 | `total > 0 && sourceUrl.trim().isNotEmpty`：缺地址的历史文件不能算有效，否则会「和任何地址都匹配」 | `VodIndexSnapshot.matches` |
| 提交两分支 | `loadExisting`（地址一致，**零网络**，初次填默认源地址秒开 60.5 万条）/ `rebuild`（异址取片源 → 写 `vod-index.json` → 重跑完整校验）。`submit()` 先落设定再重跑校验，不硬塞临时结论 | `decideVodIndexSubmit` |
| **来源唯一三道锁** | ①`origin` 单值枚举、非 ready 恒 null（门禁 B19）；②`_buildBrowse` 的 `sameSource` 守卫同时比 `_poolOrigin == gate.activeOrigin` 与 `_poolSourceUrl == gate.lastUrl`；③离开 ready 即 `_resetIndexPool()` 且 `_poolSeq++` 作废在途结果 | `vod_page.dart` |
| 列表不再混用 | `vodLibrary.inSection(` 从列表路径移除（门禁 F14a 反向锁死）；旧 F14 改写成 F14 / F14a–c 四条**等价强度**新断言，不是删除或放宽 | `verify_third_party_vod.dart` 152 项 |
| **等距采样** | `BuiltinIndexScanner.collect()`：`stride = ceil(分片条数/每页)`，命中 `行号>=offset && (行号-offset)%stride==0`，续载 offset+1 取「每段下一张卡」。**不能顺序取前 N 行**：按片名排序后 movies 前 20 行里 18 行是 `#`/`0.`/`&quot;` 开头符号片名。前端编码必须逐行维护 `previous`，不命中也要走完 | 真实分片探针：首屏 120 条、解压 2.53 MB 文本、续载 120 条零重复 |
| 新索引目录 | 数据目录 `vod-index.json`，与内置 manifest 同构（`version/sourceUrl/generatedAt/total/sections/items`），同地址判据、同按栏目加载、同 `.tmp`+rename 原子写盘；条目自带 `episodes`，点开即播 | `vod_index_directory_store.dart` |
| 能力边界 | `rebuild` = `VodSession.start(autoBatches: 12, budget: 90s)`，受 `kVodCacheMaxItems = 10000`，是「本次取回的目录」不是接口 147 万全量；全量抓取是打包侧 Python（30,169 页）的事 | README §63.6 |
| 四处配套 | `VodLibrary.adoptMany()` 批量挂播放链路（只 notify 一次）；`_filteredFor` 把 `vodMatches(i,q)` 池内匹配并进 id 集合（否则列表条目不进 VodLibrary，搜索全空）；六页共享 gate ⇒ `_onIndexGateChanged` 加 `if (!widget.active) return` 防止一次解 6 个分片；generated 模式检索改查同一份目录 | 同上 |
| 后台同步退场 | `_ensureDefaultSource` 先 `await vodIndexGate.settled`，ready/needAddress/building/failed 全提前 return。理由：单次 1 万条 vs 接口 147 万 = 0.68%，每批重写 16 MB JSON，游标不持久化，且属于**另一个来源** | README §63.8 |
| 冻结前四处修补 | ①`rebuild` 硬编码 `allowExternalCode:true` ⇒ 三参数透传（门禁 D26/H26）；②「60.5 万 条」多空格；③非激活页不加载分片；④换来源清空旧 `_indexHits` 且 generated 检索同源 | 探针 + 复核，产物重打两次 |
| 门禁 | `flutter analyze` 0 issue；**43 步 / 4321 断言**（上轮 42 / 4186，+1 步 +135）。新增 `verify_vod_index_gate.dart` **132 项**（A 值对象 / B 全转移 / C 两分支 / D 控制器 / E 编解码 / F 等距采样 / G 浏览入口 / H 静态护栏） | 冻结源码复跑 `verify_all.dart` 104.9 s |
| 产物（三件） | APK `dist/Shunbo-1.0.5-full.apk` **51,412,138 B** `59778307…07f5f4`（单包 24/24 断言过）；setup **32,527,590 B** `65fb99f9…c9895`；portable **40,214,643 B** `404a30e2…5a7f6`。版本仍 `1.0.5+6` | `sha256sum` |
| **最终 setup 实测** | `/VERYSILENT /SUPPRESSMSGBOXES /NORESTART` **EXITCODE 0**，`Installation process succeeded / Need to restart Windows? No`（十四次修两道防线生效）；`dist/windows/Shunbo-1.0.5` ↔ `D:\Programs\Shunbo` **38/38 逐字节一致**（缺失 0 / 不符 0），索引 7 分片 **6,634,112 B**，manifest `total=605106 / sections=6 / typeNames=523`；`data/app.so` 检出 `vod-index.json`/`VodIndexGatePhase`/`loadExisting`/`allowExternalCode` 与中文串「正在校验片源索引目录」（UTF-16LE）；GUI PID 1316 / 55 线程 / 窗口「顺播 shunbo」/ 1187.9 MB | 安装日志 + 哈希比对 + `Get-Process` |
| 收尾 | README §63（63.1–63.12，含最终门禁数与产物指纹）、CHECKLIST 五十一、当日日志与长期 `MEMORY.md` 铁律已同步；临时探针 `tooling/_tmp_gate_probe.dart` 已删 | — |
| 未验证 | ①真机 API18/armv7a：等距采样解 6 MB 分片的内存峰值、首屏 120 卡滚动帧率、生成目录条目点开即播；②异址 `rebuild` 未用真实第三接口跑完整 GUI 流程（只做逻辑门禁 D09–D13 + 临时目录写读往返）；③`assets/vod_index/` 仍未被 git 跟踪，将来提交必须一并纳入，否则干净克隆打包缺内置索引 | — |
| 纪律 | 未提交、未推送；`legacy/` 零改动；不改播放参数；版本 `1.0.5+6` | `git status` |

### 五十二、可见条目海报异步补齐 + 检索条件目录级 + 统计数与手动刷新（1.0.5 同版重打，2026-11-12 18:2x）

| 项 | 结论 | 证据 |
|---|---|---|
| 需求 | ①本地/索引片源列表卡片要有背景图，在线按条目取对应海报；新增 / 刷新 / 切换片源时图与条目准确匹配；②只对当前页可见条目异步取图，翻页继续取；缺失 / 失败 / 加载中不得阻塞列表；③检索条件改为从检索目录动态加载，完整覆盖目录内全部可筛项，目录变化同步更新；④目录为空 / 异常要在检索区给明确空态或错误反馈，且不阻断列表与检索；⑤（追加）「全部」后面加统计数据 + 手动刷新 | 用户第十七次修需求（含两张截图） |
| **修前落差** | 索引条目 `posterUrl` 恒空 ⇒ 卡片全色块；`?ac=detail` 带 `vod_pic` 但只在点开详情时才取。筛选条件由 `VodFacetsCache.of(revision, all)` 统计**当前已加载的 120 条**，再叠 `minCount=2`/`maxTypes=36`/`take(9)`/`take(18)` 四层截断 | README §64.1 / §64.4 |
| 实测口径 | 内置索引电影栏目 **159,715 条 / 23 个类目名**，旧 UI 只显示 8 个词；地区与时间整行消失（精简索引无 `vod_area`/`vod_year`）且不说明原因 | 真实分片统计 |
| 海报服务 | `vod_poster_service.dart`（纯 Dart）：`request()` 同步入队 + 60 ms 合并窗口 + 每批 8 条 / 3 批在途；装配层按站点分组、每组 10 条一次 `?ac=detail&ids=`；失败记 `_dead` 不重试；缓存上限 2000 | `verify_vod_posters_facets.dart` C 组 |
| 只看可见条目 | 请求由 `_Poster.initState` 发出，网格是 `SliverChildBuilderDelegate` ⇒ 只有进视口的卡片才 build；翻页 / 续载自然触发新一批 | 同上 D07 / D10 |
| 图与条目不串 | 缓存键 `scope \u0000 item.id`；`scope` = 来源 + 接口地址 + 目录时间戳 + 条数；`switchScope()` 清缓存并 `_generation++` 让在途批次作废；回填按 `hit.id`（含站点下标）不按 `vod_id` | 同上 C09 / D08 / D12 |
| 不阻塞 | `loadingBuilder` / `errorBuilder` / 无图都回落到同一个色块 `_fallback()`；条目文字与点击行为不变 | 同上 D09 |
| 条件目录 | `vod_facet_directory.dart`（纯 Dart）：内置索引 `facetOptionsFromShard()` 只累加 `int`（不建 60 万对象），生成目录 `facetOptionsFromItems()` 遍历条目四维；`minCount=1`、无上限、UI 不再 `take(9)` | 同上 A / D04 / D16 |
| 变更同步 | 缓存键 `目录身份 \u0000 栏目`；目录一换即新键自动重载；旧条件里不存在的选中值自动清除并提示 | 同上 B06 / D06 |
| 空 / 异常反馈 | 五态 `idle/loading/ready/empty/error`；三种非就绪态都有明确文案 + 「重试」，且固定写「列表与检索可继续使用」；缺维度写「本目录未提供地区 / 时间字段」不静默隐藏 | 同上 D03 / D05 |
| 「全部」统计数 | 取**本栏目整份目录条数**（内置=分片 `records`；生成=文档该栏目条目数），弱化小字跟在「全部」后；目录未就绪时不显示而不是显示 0 | 同上 D21 / D22（反向锁死不许用 `_indexPool.length`） |
| 手动刷新 | 同行右端常驻「刷新」，依次 force 重取条件 → 重算条数 → `_loadIndexPage(restart:true)` 重排列表 → `switchScope()` 重取海报；刷新中禁点、旧列表继续显示；失败文案带「列表保持原样，可重试」 | 同上 D23 / D24 |
| 门禁 | `flutter analyze` 0 issue；**44 步 / 4397 断言**（上轮 43 / 4321，+1 步 +76）。新增 `verify_vod_posters_facets.dart` **76 项**；旧 `G11` 按惯例改写为等价强度新断言（仍纯 Dart + `localMatches(q)`，条件改 `catalogFor(`） | `verify_all.dart` 130.9 s |
| 产物（三件） | APK **51,461,290 B** `b61a1854…b5ff4`（单包 24/24 断言）；setup **32,543,376 B** `7d82e6b6…ae6e3`；portable **40,237,048 B** `569a3622…de0e3`。上一版归档 `dist/_prev/1.0.5-fix16/` | `sha256sum` |
| 安装实测 | `/VERYSILENT /SUPPRESSMSGBOXES /NORESTART` **EXITCODE 0**；`dist/windows/Shunbo-1.0.5` ↔ `D:/Programs/Shunbo` **38/38 逐字节一致**；索引 7 分片 6,634,112 B；`app.so` 检出「全部」「刷新中」「检索条件已从片源索引目录载入」等中文串（UTF-16LE）与 `_manualRefresh`/`VodPosterService`/`facetOptionsFromShard`；GUI PID 30196 / 82 线程 / 1,038.3 MB | 安装日志 + 哈希比对 + `Get-Process` |
| 未验证 | ①真机 API18/armv7a：120 张卡海报批量请求的弱网耗时与内存峰值、`facetOptionsFromShard` 解 6 MB 分片耗时；②生成目录分支四维全量统计未用真实第三接口跑过；③「刷新」按钮遥控器可达性未上真机走查 | — |
| **红标收尾（18:5x）** | 标题行「内置索引 · 已展示 480 / 60.5 万条」整段去除；「全部」后面那排类型词（剧情片…理论片）去除（与下方「类型」整行完全重复）；片源统计挪到「全部」右侧显示为 `共 60.5万条`。`_countLabel()` 在 ready 时返回空串、`_titleBar()` 空串连同前置间距一起不渲染；`_typeTabs()` 只留 `全部` + 统计 + 右端刷新；`_bigCount()` 去掉「万」前空格，避免拼成「60.5 万 条」 | README §64.9 |
| **二次重打（18:56–18:58）** | `flutter analyze` 0 issue；**44 步 / 4399 断言**（+2）；`vod-posters-facets` 76 → **78 项**（`D04` / `D21` 按新口径改写，新增 `D25` 标题行不重复统计、`D26` 一级条不含 `facets.types`）。产物：APK 51,461,290 B `5b531b83…1460c`、setup 32,542,472 B `38a71553…a2a92`、portable 40,236,026 B `5a451dab…582cd`；覆盖安装 **EXITCODE 0**（安装前有一个活着的 49 线程 `shunbo.exe` 被 `taskkill` 兜住）、38/38 逐字节一致、GUI PID 21808 / 49 线程 / 1036.9 MB。上一版归档 `dist/_prev/1.0.5-fix17/` | `sha256sum` + 安装日志 |
| 纪律 | 未提交、未推送；`legacy/` 零改动；不改播放参数；版本 `1.0.5+6` | `git status` |

### 五十三、切栏目自动带图 + 栏目分桶缓存 + 检索框数字键被吞（1.0.5 同版重打，2026-11-12 19:1x）

| 项 | 结论 | 证据 |
|---|---|---|
| 需求 | ①点播栏目之间切换时自动加载对应片源背景图并缓存，**切回已访问过的栏目无需重新加载**；②修复检索条无法输入数字（例如搜 2020 年份的电视剧） | 用户第十八次修需求（含检索框截图） |
| **修前落差 A** | `VodPosterService.kCacheCap = 2000`，写入超限就 `_urls.clear()` + `_dead.clear()` —— 六个栏目各 120 张首屏，划两屏即撞上限，一撞把**所有栏目**的图一起清掉 | README §65.1 |
| **修前落差 B** | 切回栏目时 `didUpdateWidget` → `_enterIndexGate()` → `gate.check()` 广播 → `_onIndexGateChanged()` **无条件** `_loadIndexPage(restart: true)` → `_resetIndexPool()`，120 张卡全部重建 | 同上 |
| **修前落差 C（数字键）** | `ChannelNumberInput` 用 `HardwareKeyboard.instance.addHandler` 全局钩子，挂在 `LivePage` 而 `LivePage` 在 `IndexedStack` 里保活 ⇒ 只要你打开过直播页，这个 handler 就一直注册着；数字键被它 `return true` 吃掉后，Windows 引擎不再 `TranslateMessage` ⇒ 没有 `WM_CHAR` ⇒ `TextField` 收不到数字 | README §65.4 |
| 分桶缓存 | 存储改 `Map<bucketId, _PosterBucket>`，桶 ID = `目录身份 \u0000 栏目`（`bucketKeyOf`）。每桶上限 `kGroupCap = 600`，**超限只清本桶**；桶数上限 `kMaxGroups = 24`，按 `tick` 做 LRU | `verify_vod_posters_facets.dart` E 组 |
| 切栏目不清图 | `switchScope()` 收窄为「只丢弃不属于新目录身份的桶」，同身份直接 `return` —— 切栏目等于空操作，切回必然命中 | 同上 E04 |
| 切回不重灌列表 | 新增 `_poolStamp` + `_poolMatchesCurrentSource()`（来源枚举 / 接口地址 / 目录时间戳三条都对得上才复用），`_onIndexGateChanged()` 只在不等时 `restart`；`batch.isEmpty` 也写这三个字段，避免空栏目每次广播都解压分片 | 同上 D28 |
| 页面接线 | `_VodCard` 新增 `posterGroup`、`_Poster` 新增 `group`，一律传 `widget.section.name`；`didUpdateWidget` 把 `old.group != widget.group` 也算需要重新对齐 | 同上 D27 |
| 数字键修复 | ①`live_page.dart`：`enabled: widget.active`；②`channel_number_input.dart`：`_onKey` 开头 `if (_editingText) return false;`，`_editingText` 用 `primaryFocus.context` 判 `EditableText`（含祖先查找） | 同上 D30 |
| 检索框本身 | 没有任何 `inputFormatters`、`keyboardType` 也没设死；门禁 D31 **反向锁死**「不许出现 `FilteringTextInputFormatter`」 | 同上 D31 |
| 门禁 | `flutter analyze` 0 issue；**44 步 / 4413 断言**（上轮 44 / 4399，+14）。`vod-posters-facets` 78 → **92 项**：新增 E 组 9 条（纯 Dart，含「切回命中缓存不发请求」「超限只清本桶」「LRU」「在途批次不污染」）、D27–D31 5 条；`D07`/`D08` 按新签名改写，`C14` 收紧到 `kGroupCap` | `verify_all.dart` 116.5 s |
| 产物（三件） | APK **51,461,290 B** `390f1fe6…b9d48e`（full 46,998,476 / lite 27,878,043，单包 24/24 断言）；setup **32,544,503 B** `268edbf0…7af34`；portable **40,236,767 B** `0ab12df6…ea7`。上一版归档 `dist/_prev/1.0.5-fix17b/` | `sha256sum` |
| 安装实测 | `/VERYSILENT /SUPPRESSMSGBOXES /NORESTART` **EXITCODE 0**；`dist/windows/Shunbo-1.0.5` ↔ `D:/Programs/Shunbo` **38/38 逐字节一致**；索引 7 分片 6,634,112 B；`app.so` 检出 `bucketKeyOf` / `_poolMatchesCurrentSource` / `_editingText` 与中文串「检索条件已从片源索引目录载入」；GUI PID 24532 / 52 线程 / 1056.5 MB | 安装日志 + 哈希比对 + `Get-Process` |
| 未验证 | ①真机「电影 → 电视剧 → 电影」来回切的命中率与 `ImageCache` 淘汰后重解码；②直播页数字键在 `enabled: widget.active` 改动后未真机复验；③「点一下输入框但焦点还没落进去就按数字」的竞态未覆盖 | — |
| 纪律 | 未提交、未推送；`legacy/` 零改动；不改播放参数；版本 `1.0.5+6` | `git status` |

### 五十四、全目录检索与筛选 + 条件维度补全 + 海报两处根因 + 点播起播慢（1.0.5 同版重打，2026-11-12 22:0x）

| 项 | 结论 | 证据 |
|---|---|---|
| 需求 | ①卡片海报仍不显示；②检索要在**当前栏目的整份目录**里查；③按红标去掉刷新提示语；④可筛选条件太少（参考同类站截图）；⑤点播播放时加载慢、卡顿，排查原因 | 用户第十九次修需求（截图红标 + 追加一条） |
| **检索口径** | 原来 `search` 只 `limit` 截断返回 `List`，页面 `_indexHitsTotal` 取的是**已加载那一池**的长度。现在 `BuiltinIndexScanner.scan` 返回 `BuiltinScanResult`，`searchDetailed` / `filterSection` 返回 `(hits, total)`，一次扫完整片只为拿真实总数；检索同时匹配**片名 / 年份 / 地区 / 类目名** | README §66.1 |
| 筛选口径 | 页面新增 `_facetHits` / `_facetHitsKey` / `_facetHitsTotal` / `_facetScanSeq`，build 里 microtask 触发 `_runFacetScan`，`_mergeFacetHits` 合并后**整体重排**；`_indexHitLimit` 200 → 400 | `verify_vod_posters_facets.dart` D34/D35 |
| 去提示语 | `_gateRow()` ready 且非 busy → `SizedBox.shrink()`；`_facetStatus` 只在 `_facetResetNotice` 非空时显示；`_refreshAction` **成功不播报**、失败才留一行；删 `_missingFacetNote` | 同上 D32/D33 |
| **条件太少根因** | `facetOptionsFromShard` 把类目名过 `vodTypeWordsFromLabel` → `isNonGenreLabel`，把「国产剧 / 欧美剧 / 香港剧 / 日本剧」判成非体裁词剔掉：电视剧 22 → 10 | README §66.3 |
| 条件现状 | 按**原始类目名**统计：电影 23 / 电视剧 22 / 短视频 28 / 动漫 16 / 其他 33 / 纪录片 2；地区 20 项；时间 4 档 | 同上 D37 |
| **索引升 v2** | 地区与年份索引里本来没有 ⇒ 改抓 `?ac=detail`（带 `vod_area` / `vod_year`）：30,178 页 / 1,458,263 条 / 4,974 s；164 页三次重试后仍 502 但不阻塞。7 段列式 + 20 项地区词表（Python `AREA_ALIASES` ↔ Dart `_kAreaAliases` 逐字镜像，门禁 F09）；v1 五段仍可解析 | `verify_vod_builtin_index.dart` A22/A23/B10/B11/E09/E10/F09/F10 |
| 索引现状 | **7.23 MB / 602,413 条 / 6 片**（原 6.31 MB）。年份/地区覆盖：movies 99.4/99.6、series 98.1/99.7、documentaries 99.5/99.0、shortVideo 92.4/75.4、anime 99.5/86.9、other 57.4/33.9 | manifest `withYear` / `withArea` |
| **海报根因一（应用层，已修）** | 批量取海报 10 连 + 8 s 超时，超时与「确实没图」共用空结果 ⇒ `bucket.dead.add` **永久判死**。实测同一 10 连请求 2.3 s 与 24.4 s 都出现过 ⇒ 一次超时那批卡此后永不出图 | README §66.4 |
| **海报根因二（网络层，修不了）** | 图床直连实测 12 站样本：`xl.xltupian.com` SocketException、`ok.zuidapic.com` / `pic.youkupic.com` HandshakeException、`p.bfvp26.com` 时通时断（占电影栏目 25.8%）、`mtzy2.com` 单张 271 KB / 6.6 s | Dart `HttpClient` + `findProxy DIRECT` 实测 |
| 海报修法 | 10 连 → **4 连**（单批 ~170 KB → ~11 KB）、超时 8 → **12 s**、站内与站间**双并发**；`VodPosterFetch` 回包改 `VodPosterBatch{urls, failed}`，网络失败隔 1.2 s 重排一次（`kMaxRetry=1`），只有「解析成功但确实没图」才 dead；加载中加细转圈 `_loadingFallback`；图片层 `_dead` 改 `Map<url,时刻>` + 60 s TTL | 同上 D38/D39/D40、C11a/C11b |
| 4 连 vs 10 连实测 | dyttzy 3.96/1.90/2.91 s（32,931 B）→ 0.97/0.81/1.00 s（11,701 B）；bfzy 3.44/1.21/2.16 s（30,371 B）→ 1.29/3.46/1.26 s（10,820 B） | curl 各 3 次 |
| **播放慢定性** | 详情回源 bfzy 2.4–2.6 s / dyttzy 0.7 s（响应仅 3 KB）；m3u8 ttfb 1.2–2.6 s / 35 KB / 7000+ 分片（中文路径）；单 `.ts` 404–529 KB / 4.9–14.3 s；3 片并发吞吐 **≈50–100 KB/s**，8 s 目标时长需 ~55 KB/s ⇒ **源站带宽 + 中文路径重定向，不是客户端缓冲**。项目无 `LoadControl` 类可调项 ⇒ **本轮不动任何播放参数** | README §66.5 |
| 点开卡片不再干等 | `_openDetail` 原阻塞（`await resolve` 期间只 `_busy=true`）。改乐观进详情页：`_resolving` / `_resolveError` / `_resolveSeq` 代次隔离 + `_resolveNotice` 常驻条（转圈 / 原因 + 重试，不退回列表）+ `_resumeOrPlay` 空剧集守卫 | 同上 H27/H28/H29 |
| 门禁 | `flutter analyze` 0 issue；**44 步 / 4444 断言**（上轮 44/4436，+8）。`vod-posters-facets` 102 → **107**（C11 拆 C11/C11a/C11b + D38–D40）、`vod-index-gate` 132 → **135**（H27–H29） | `verify_all.dart` 160.0 s |
| 产物（三件） | APK **52,427,946 B** `95cb13d8…609c15c`（full 47,965,401 / lite 28,844,969，单包 24/24 断言）；setup **33,513,307 B** `821dcd4d…7dcd7f2`；portable **41,207,947 B / 38 文件** `eee2a910…7885f5c`。上一版归档 `dist/_prev/1.0.5-full.20261112-220051.390f1fe6.apk.bak` | `sha256sum` |
| 安装实测 | `/VERYSILENT /SUPPRESSMSGBOXES /NORESTART` **EXITCODE 0**（安装前有 5 个活着的 `shunbo.exe`，被 `CloseApplications` + `PrepareToInstall` 的 taskkill 兜住）；`dist/windows/Shunbo-1.0.5` ↔ `D:/Programs/Shunbo` **38/38 逐字节一致**；`data/app.so` 8,553,352 B；索引目录 **7,601,062 B**；`app.so` 检出 `VodPosterBatch` / `_loadingFallback` / `_resolveNotice`（UTF-8）与「正在获取播放地址」「暂时取不到播放地址」「全目录命中」「正在按整份栏目目录筛选」（UTF-16LE） | 安装日志 + 哈希比对 + AOT 串取证 |
| 未验证 | ①真机 120 卡实际出图率与弱网重试收益（本机无 adb，只到桌面与 `dart run` 层）；②三家 TLS 被中断的图床无替代源；③播放卡顿只定性到「源站吞吐不足」，没做换源 A/B（要多源改 `parseVodPlayUrl` 策略，属播放链路，需单独开一轮）；④`_facetHits` 整片扫描耗时未上真机（桌面几十毫秒级） | — |
| 纪律 | 未提交、未推送；`legacy/` 零改动；不改播放参数；版本 `1.0.5+6` | `git status` |

### 五十五、播放页单出口 + 切栏目清搜索 + 去除常驻刷新 + 类型/分类拆分 + 爱奇艺式海报网格（1.0.5 同版重打，2026-11-13 09:3x）

| 项 | 结论 | 证据 |
|---|---|---|
| 需求 | 五张截图：①播放页去「返回」「选集」，改「关闭」（关播放 + 回上一页）；②切栏目时搜索框清空恢复初始；③「去除」标注的刷新按钮；④「类型不对」；⑤每行卡片间距太宽，参考爱奇艺调整 | 用户第二十次修红标 |
| **播放页按钮** | `_topBar` 删左上 `IconButton(tooltip:'返回（Esc / 返回键）')` 与右上「选集」，改唯一「关闭」→ `_closePlayback()` = 全屏先退 + `_leavePlaying()`（停播、收选集浮层、回详情 / 无条目时回列表）。Esc / 物理返回键仍走 `_back()` 分层返回；控制条「选集（M）」保留 | README §67.1；`verify_vod_playback.dart` E02 改口径、`D41/D42` 反向锁死 |
| **切栏目清搜索** | 六页在 `IndexedStack` 保活、各自持 controller ⇒ `didUpdateWidget` 里 `widget.active` 翻转调 `_resetSearchOnSectionSwitch()`：清 `_search.text` / `_query`、`_indexSeq++`、`_indexTimer?.cancel()`、清 `_indexHits/_indexHitsQuery/_indexHitsTotal/_filterQuery`。**不 setState**（父级 build 期间会炸）；筛选项保留 | §67.2；`D43/D44` |
| **去除刷新** | 常驻「⟳ 刷新」按钮整个去掉，一级条只剩「全部 + 共 N 条」。手动重读能力移到 `_facetStatus` 非就绪态「重试」→ 完整 `_manualRefresh()`（条件+条数+列表+海报），禁点与「处理中」保留；失败文案改「重试失败：…（列表保持原样，可再试）」，成功静默 | §67.3；`D24/D26/D33/D45` 反向锁死 |
| **「类型不对」根因** | 十九次修为凑条件数，把 `facetOptionsFromShard` 从 `vodTypeWordsFromLabel`（剔地区型类目）改回**原始类目名原样统计** ⇒ 电视剧类型行变成一排「国产剧 / 欧美剧 / 香港剧 / 日剧 / 韩剧 / 港剧 / 台剧」，是地区/来源不是体裁，且与「地区」行重复 | README §67.4；`D37` 口径反转 |
| **拆成两个维度** | 「类型」= `vodTypeWordsFromLabel()` 体裁词；「分类」= 站点原始类目名。`VodFacets.categories` / `VodFilter.category` 参与 `isActive`/`activeCount`/`==`/`hashCode`/`copyWith`；「全部」清空、`_facetKey()`、`filterSection` 缓存键、`_onFacetDirectoryChanged` 过期值清理全部贯通；`applyVodFilter` 按 `typeName` 精确比、`filterSection` 按 `label == category`，类型匹配改走体裁词 | §67.4；`D46/D47/D51`、`F25/F28` |
| 补单字地区简称 | `_kAreaCores` 增 `日/韩/港/台/泰/马泰/港澳`。第一轮改完类型行还留着「日剧 / 韩剧 / 港剧 / 台剧 / 马泰剧」（采集站把「日本剧」简写成「日剧」，剥「剧」只剩单字） | `F29`；真实目录复查 |
| 真实目录实测（v2） | 类型/分类：电影 22/23、**电视剧 3/22**、纪录片 2/2、短视频 27/28、动漫 8/16、其他 28/33；地区 19–20、时间 14–16。电视剧类型只剩 `反转爽剧 / 连续剧 / Netflix自制剧`——数据事实（站点只按地区分类），分类行完整保留 22 项，条件总量 22 → 25 没变少 | `dart run build/shot20/probe.dart`；`A09c/A09c3/A09f` 真实分片断言 |
| **海报间距根因** | 不是 `crossAxisSpacing`：`mainAxisExtent` 钉死 186 + `Column(crossAxisAlignment:start)` 给宽松宽约束 ⇒ `Image.network` 只按「固定高 × 图片比例」取宽（约 90 px），槽位约 325 px，左右各空一大块 | §67.5；`D48/D49` |
| 网格改法 | `_VodCard` 改 `stretch` 让海报吃满槽位；`posterHeight=(cardWidth-8)*1.5`、`mainAxisExtent=posterHeight+47`（2:3 不裁切）；列数 5/4/3/2 → 6/5/4/3；spacing 14 → 10、padding 6 → 4、海报与片名 8 → 6。1920 窗口示例：海报 90×135 → 264×396，横向空白 ~235 px → 10 px，一屏 4–5 行 → 2–3 行 | §67.5 |
| 门禁 | `flutter analyze` 0 issue；**44 步 / 4460 断言**（上轮 44/4444，+16）。`vod-posters-facets` 107 → **121**（A07/A07b 改口径、A07f/A09c3/A09f 真实分片、D24/D26/D33/D37 反向锁死、D41–D51 五条红标逐条钉死）；`vod-playback` 193 → **195**（E02、F25 改口径 + F28/F29） | `verify_all.dart` 112.0 s |
| 产物（三件） | APK **52,444,330 B** `8e905bbb…cf8ad86`（full 47,981,683 / lite 28,861,258；单包 24/24 断言）；setup **33,516,243 B** `7e8b262e…c2fc6dfa`；portable **41,210,859 B / 38 文件** `a0d549aa…46ea894a` | `sha256sum` |
| 安装实测 | `/VERYSILENT /SUPPRESSMSGBOXES /NORESTART` **EXITCODE 0**（安装前有 10 个活着的 `shunbo.exe`，被 `CloseApplications` + `PrepareToInstall` taskkill 兜住）；`dist/windows/Shunbo-1.0.5` ↔ `D:/Programs/Shunbo` **38/38 逐字节一致**；`data/app.so` 8,553,352 B（9:36:40）；索引目录 7,601,062 B；iss UTF-8 BOM + CRLF / 119 行 | 安装日志 + 哈希比对 |
| AOT 串取证 | 检出 `_closePlayback`(1) / `_resetSearchOnSectionSwitch`(1) / `VodPosterBatch`(1)，`_refreshAction` **0**（已删）；UTF-16LE：「关闭」12 / 「重试失败」2 / 「分类」7 / 「正在获取播放地址」1 / 「全目录命中」1 | `app.so` 字节扫描 |
| GUI 启动 | PID 4756 / 93 线程 / 775.6 MB / 窗口「顺播 shunbo」，验完已结束（mpv 打印两行 `Can't find filter element` 属常规噪声） | 进程检查 |
| 未验证 | ①图 3 按「去掉整个刷新按钮」处理，若本意只是去「刷新」两字、保留图标，一句话可改回；②大卡片一屏 2–3 行的遥控器手感与真机 120 卡帧率；③「类型/分类」在生成目录（`vod-index.json`）下只到 `dart run` 层；④全屏 + 选集浮层叠加时点「关闭」未上真机 | README §67.7 |
| 纪律 | 未提交、未推送；`legacy/` 零改动；不改播放参数；版本仍 `1.0.5+6` | `git status` |

### 五十六、设置-点播源收敛为单输入框 + 索引按地址独立存放 + 24 小时增量更新（1.0.5 同版重打，2026-11-13 10:5x）

| 项 | 结论 | 证据 |
|---|---|---|
| 需求 | 一张「设置-点播源」截图 + 四条：①只留一个第三方片源接口地址输入框，输完自动获取索引，按现有默认索引的存储方式落盘；保留原判断逻辑（与默认地址一致则复用、不重复获取）；新接口索引**独立存放**，不得覆盖默认索引；②排查是否已有自动获取最新片源，无则加定时自动更新，周期按主流播放软件惯例明确设定，**追加合并、不全量重取、处理重复**；③新增手动获取片源入口，同样追加写入；④改动限本模块、兼容既有逻辑、界面简洁 | 用户第二十一次修红标 |
| **排查结论** | 改前**没有**任何与片源目录相关的定时器（全仓 `Timer.periodic` 只服务浮层/控制条）。近似的两个都是**一次性**：`VodAutoSource.ensureLoaded()` 只回答「首次进栏目填片库」（`_pending` 固化、失败不重试）；`VodBootController` 只在冷启动跑一遍。结论：需新增真正的运行期周期任务 | README §68.1；`grep -n "Timer.periodic" lib/` |
| **界面收敛** | 整文件重写 `vod_source_section.dart`：只剩 **1 个** `TextField`（标签「第三方片源接口地址」，默认不回填）＋一行状态（当前生效 / 实时校验 / 提交结果）＋1 个「立即获取最新片源」按钮＋一行说明。删掉三个 `SwitchListTile`、`kVodSourceCandidates` 七条候选列表、`_pickCandidate` / `_runImport`、「添加并使用 / 应用当前地址 / 恢复默认」三按钮 | §68.2；门禁 H30–H32 反向锁死（`RegExp(r'TextField\(')` 计数 == 1、`!contains('kVodSourceCandidates')`） |
| **自动获取** | `onSubmitted` + `FocusNode` 失焦 → `_submitAddress()`；`if (raw == _lastSubmitted) return;` 同址不重复提交，失败 `_lastSubmitted = ''` 允许重试；明文 http 走 `_confirmInsecure`（「放行并获取」）；`isKnownUnusableSource` 提前拦；`disclaimerAccepted` 检查保留。成功后**不回填输入框**，状态行如实显示「当前生效：<地址>」 | §68.3；H33/H34 |
| **判断逻辑零改动** | `decideVodIndexSubmit` 三判据原样：地址 == 默认地址 → `loadExisting`（零网络，随包只读）；已有该地址独立文件 → `loadExisting`；其余 → `rebuild`（取片源 → 写独立文件 → 重跑校验） | §68.3；H35–H37 |
| **独立存放** | `vodIndexFileForUrl(url)` → `vod-index-<FNV1a32(url) 8 位 hex>.json`；**默认地址永不派生文件名**（`fileFor()` 返 null、`saveFor()` 抛错、`appendFor()` 返 skipped）。`rebuild` 开头再加 `isIndependentSource(url)` 双保险；成功走 `saveFor(url, …)`，不再写固定 `vod-index.json`。旧 `vod-index.json` 降级为只读，仅当 `sourceUrl` 逐字匹配才读到 | §68.4；H38/H39/H42 |
| **追加合并去重** | `mergeVodIndexItems(existing, incoming)` 按 `VodItem.id` 去重：旧条目前、新条目后，返回 `added/duplicates/total`。`appendFor()` 用 `.tmp` + `rename` 原子写盘，受 `kMaxVodLibraryBytes`（72 MB）护栏 | §68.5；H40/H41 |
| **不全量重取** | `fetchLatestVodIndexItems()` 轮转 `pager.next()`，只覆盖各采集站**第 1 页**（CMS `?ac=detail&pg=1` 按 `vod_time` 倒序），批次上限 20 / 预算 90 s / 站点上限 100；**绝不翻第 2 页**，不碰 `VodLibrary` / `VodSession` | §68.5 |
| **24 小时定时** | `kVodIndexUpdateInterval = Duration(hours: 24)`；`VodIndexAutoUpdater` 首帧后 `start()` 补一次 + `Timer.periodic`；上次成功时间落 `config.json` 的 `vod-index-last-update`；`shouldUpdate(last, now)` 判过期 | §68.6；H36（周期常量）、H37（让位） |
| **让位与单飞** | `await vodBoot.settled` → `await vodIndexGate.settled`，未 settled 直接跳过（1 万条 vs 147 万永远追不完）；`_running` 单飞防重入；失败**不写**时间戳，下一轮重试；只写盘不调 `gate.check()`，新片源下次进入点播生效 | §68.6 |
| **手动入口** | 「立即获取最新片源」→ `runOnce(force: true)`，跳过周期判断但仍走让位、单飞、追加去重、独立文件；按钮在运行中禁用并显示进度 | §68.6；H32 |
| **点播页读取统一** | 新增 `_generatedIndexDoc()`（按 `vodIndexGate.lastUrl` 走 `loadFor`），替换 `vod_page.dart` **5 处**直读固定 `vod-index.json` 的写法。否则新地址永远读不到自己的目录（回源、检索、栏目、条件全空） | §68.4；H06 |
| 门禁 | `flutter analyze` **0 issue**；**44 步 / 4513 断言**（上轮 44/4460，+53）。`vod-index-gate` → **182**（H18 改 `saveFor`、H06 改 `_generatedIndexDoc`、新增 H30–H42 与 `testSourceModule()` 34 条：纯函数 + 临时目录 IO + 调度器回归）；`vod-source-address` **128**（G04–G06c 按新 UI 口径改写 + G15–G20 六条）；`third-party-vod` **152**（F10–F13d / G15 / G16 改口径 + 默认地址双保险）；`vod-playback` **195**（C15/C16 改「设置页不再暴露外部代码开关，但 `allowExternalCode: s.allowExternalCode` 仍透传」） | `verify_all.dart` 121.1 s |
| 产物（三件） | APK **52,444,330 B** `900cc76b…74150f6`（full 47,981,692 / lite 28,861,258；单包 24/24 断言，minSdk 16 / v1+v2 双签 / 清单 1046 台 2135 线路字节一致）；setup **33,514,352 B** `2b01d8eb…cd16b315`；portable **41,359,583 B / 38 文件** `ac80642e…a7ed3078`。上一版归档 `dist/_prev/fix20/` | `sha256sum`；`build/single_fix21.log` |
| 安装实测 | `/VERYSILENT /SUPPRESSMSGBOXES /NORESTART` **EXITCODE 0**（安装前 10 个 shunbo.exe 句柄，被 `CloseApplications` + `PrepareToInstall` taskkill 兜住，未卡 `d3dcompiler_47.dll`）；`dist/windows/Shunbo-1.0.5` ↔ `D:/Programs/Shunbo` **38/38 逐字节一致**；`data/app.so` 8,553,352 B（10:53）；索引资产 7 文件 / 7,601,062 B 未变（本轮未重打索引）；iss UTF-8 BOM + CRLF / 119 行 | 安装日志 + 哈希比对 |
| AOT 串取证 | 检出 `_generatedIndexDoc`(1) / `mergeVodIndexItems`(1) / `VodIndexAutoUpdater`(1) / `vodIndexFileForUrl`(1) / `appendFor`(1) / `isIndependentSource`(1) / `shouldUpdate`(5) / `vod-index-last-update`(1) / `_submitAddress`(1)；已删的 `_pickCandidate` / `kVodSourceCandidates` / `_refreshAction` **全 0**；UTF-16LE：「立即获取最新片源」1 /「第三方片源接口地址」1 /「正在获取最新片源」1 /「已追加」1 /「24 小时」2 /「当前生效」1 | `app.so` 字节扫描 |
| GUI 启动 | PID 17796 / 49 线程 / 窗口「顺播 shunbo」，验完已结束（mpv 两行 `Can't find filter element` 属常规噪声）。残留 9 个 0 线程 0 MB 的 shunbo 句柄是历史僵尸对象，非活实例 | 进程检查 |
| 未验证 | ①定时器跨进程重启后的「首帧补一次」仅在桌面与模拟器路径验证，真机长期挂机未测；②增量取数依赖各采集站 `pg=1` 按 `vod_time` 倒序，若站点忽略排序参数会取到旧片（去重后不增长，不会脏写）；③多地址并存时每个地址一份独立文件，磁盘占用随地址数线性增长，只受 `kMaxVodLibraryBytes` 单文件护栏约束，**未做总容量上限** | README §68.8 |
| 纪律 | 未提交、未推送；`legacy/` 零改动；不改播放参数；版本仍 `1.0.5+6` | `git status` |

### 五十七、点卡片直接播 + 播放页右栏详情 + 8 秒自动收缩（1.0.5 同版重打，2026-11-13 11:1x）

| 项 | 结论 | 证据 |
|---|---|---|
| 需求 | 一张详情页截图 + 三条：①选中片源后**跳过中间详情页**，直接进播放页开始播；②播放页**右栏**加载并展示影片详细介绍；③右栏无操作达到设定超时后**自动收缩**，交互时重新展开或刷新计时。并要求明确说明触发条件、内容来源与展示形式、超时时长与收缩后交互 | 用户第二十二次修红标 |
| **触发条件** | **只有一条**：用户点击 / 遥控器确认列表里的某张卡片（`_VodCard.onTap` → `_openAndPlay`）。换集（选集 / M 键 / 上一集下一集）只在播放页内部换源，不重新进页；`_busy \|\| _resolving` 为真直接 return，连点不起两次播 | README §69.1；`T11` |
| **视图收敛** | `_VodView` 三态 → **browse / playing** 两态；`_buildDetail()`、`_resolveNotice`、`_retryResolve`、详情页选集 `_EpisodeChip` 全部删除（最后一个按 analyze `unused_element` 删） | `T11`；analyze 0 issue |
| **两条起播路径** | 内置索引命中 → 立刻切播放视图 + 遮罩「正在载入…」，后台 `vodBuiltin.resolve()` → 取续播 → `_play()`；已有完整条目 → 取续播 → 直接 `_play()`。续播规则原样（有记录续、看完进下一集、无记录从头） | `H27`；`_openAndPlay` |
| **失败不退回** | 回源失败留在播放页，右栏给原因 + 「重试」（`_retryOpen`）；空剧集给「这个片源没有可播放的剧集」；`_play` 失败从 SnackBar 改到右栏（不重复说两遍） | `H28`/`H29`；`_playResolved` |
| **右栏内容与来源** | 全部来自内存里的 `VodItem`，**不新增任何网络请求**：海报 16:9（既有 `_Poster`，异步补图 / 失败色块）、标题、`item.subtitle`（「暴风资源 · 恐怖片」）、状态行（取地址中 / 失败+重试 / 上次看到第 N 集 mm:ss）、`item.description` 简介、`item.license` 授权说明 | README §69.2；`T12` |
| **展示形式** | 右侧浮层，宽度 = 视口 32% 夹在 **340–440 px**，黑底 84% + 左侧 1 px 分隔线，内容可滚动（底部留 120 px 给控制条）。**覆盖画面不缩 `PlayerStage`**（改渲染几何会触发解码器/渲染面重建，容易黑屏一帧）；z 序排在**控制层下面**，顶栏「关闭」与进度条压在它上面 | `T03`/`T13`；`AnimatedPositioned` 180 ms |
| **超时时长** | **8 秒**（`kVodDetailIdleTimeout`）。不是抄控制条的 4 秒：4 秒是「按完让出画面」，详情是**读**——标题+类型+两行简介；主流信息层（Netflix / Plex / 爱奇艺桌面端）都在 5–10 秒，取中间偏长 | README §69.3；`T01`/`T02` |
| **交互重置** | 进播放页即展开并起第一段计时；指针进面板 / 面板内滚动 / 点面板 → 保持展开并重置 8 秒；点画面切控制条、音量键、快进快退、换集 → 若右栏开着同样重置（`_pokeControls` 联动）；**I / D / 信息键** toggle（遥控器没鼠标，不给键位就再也拉不回来） | `T05`–`T10`/`T15` |
| **收缩后行为** | 右侧留 **44 px 窄条**（`info_outline` + 竖排「详情」），不是整个消失；点窄条 / 指针移上去 / 按 I·D 都重新展开。**唯一不改状态的输入**是点画面别处（只刷新计时，不把刚收起的又弹出来） | `T04`/`T14`；`VodDetailInput.pointerElsewhere` |
| **不收缩的时刻** | `_resolving`（正在取地址）与 `_resolveError != null`（取不到）时**不启动计时**并强制展开 —— 那是必须看见的状态，缩起来等于把「为什么没画面」藏了 | `T17`；`_restartDetailTimer` |
| **状态机纯函数** | `vodDetailExpandedAfter(expanded, input)` + `VodDetailInput` 七种输入 + `vodDetailWidth()`，`dart run` 可穷举 | `vod_playback_controls.dart` |
| 顺带修 | `_back()` 分层返回三层 → 两层（选集浮层 → 全屏 → 回列表）；`_leavePlaying()` 回 `browse`、`_item=null`、`_resolveSeq++` 作废在途回源（不作废会「退回列表后莫名开始放片」） | README §69.4 |
| 门禁 | `flutter analyze` **0 issue**；**44 步 / 4530 断言**（上轮 4513，+17）。`vod-playback` 195 → **212**（新增 `testDetailPanel()` 17 条：8 秒与 4 秒独立 / 宽度三档 + NaN 兜底 / 窄条 44 / 状态机穷举 / 内容五要素 / z 序 / 键位 / 计时器取消 / 取地址中不收缩；E10、I04 改口径）；`vod-index-gate` **182**（H27–H29 改口径：直连 `playing`、`_VodView.detail` 与 `_buildDetail()` 全文件不存在、`_retryOpen` 取代 `_retryResolve`）；`vod-posters-facets` **121**（D42 改「关闭回列表」）。第一轮全量曾 FAIL 1 步（D42 仍要求回详情），改口径后全绿 | `verify_all.dart` |
| 产物（三件） | APK **52,460,714 B** `61cfaee5…0ed95`（full 47,997,737 / lite 28,877,312；单包 24/24 断言）；setup **33,515,646 B** `90f6804e…dd46b`；portable **41,366,217 B / 38 文件** `c516c944…8650f`。上一版归档 `dist/_prev/fix21/` | `sha256sum` |
| 安装实测 | `/VERYSILENT /SUPPRESSMSGBOXES /NORESTART` **EXITCODE 0**（安装前有活着的 shunbo.exe，被 `CloseApplications` + `PrepareToInstall` taskkill 兜住）；`dist/windows/Shunbo-1.0.5` ↔ `D:/Programs/Shunbo` **38/38 逐字节一致**；`data/app.so` 8,553,352 B（11:26）；索引资产 7 文件 / 7,601,062 B 未变 | 安装日志 + 哈希比对 |
| AOT 串取证 | 检出 `_openAndPlay`(1) / `_playResolved`(1) / `_detailPanel`(1) / `_detailRail`(1) / `_detailBody`(1) / `_detailStatus`(1) / `_toggleDetail`(1) / `_pokeDetail`(1) / `vodDetailWidth`(1) / `VodDetailInput`(2)；已删的 `_openDetail` / `_buildDetail` / `_retryResolve` / `_EpisodeChip` **全 0**；UTF-16LE：「详情」2 /「收起详情」1 /「正在获取播放地址…」1 /「上次看到」1 /「播放失败：」1 /「这个片源没有可播放的剧集」1。单包两个 ABI 的 `libapp.so` 同样 `_openAndPlay`=1 / `_detailPanel`=1 / `_buildDetail`=0 | `app.so` 字节扫描 |
| GUI 启动 | PID 3536 / 48 线程 / 1033.7 MB / 窗口「顺播 shunbo」，验完已结束（mpv 两行 `Can't find filter element` 属常规噪声） | 进程检查 |
| 未验证 | 右栏滑入在 120 卡网格 + 4K 窗口的帧率未测；遥控器「信息键」`debugName` 各家盒子不同（`Info`/`Guide`/`KeyI` 都收，真机未逐台验证）；8 秒是否舒服只在桌面鼠标下试过；右栏覆盖区在 1:2.35 超宽片源下会不会压字幕未实测 | README §69.6 |
| 纪律 | 未提交、未推送；`legacy/` 零改动；不改播放参数；版本仍 `1.0.5+6` | `git status` |

### 五十八、设置页去说明行 + 默认接口也能追加获取 + 筛选去「分类」·类型照爱奇艺 + 右栏悬停伸缩（1.0.5 同版重打，2026-11-13 11:4x）

| 项 | 结论 | 证据 |
|---|---|---|
| 需求 | 三张截图、四条红标：①「设置-点播源」输入框下那行说明（默认留空…）**去除**；②点「立即获取最新片源」时**必须真的按追加方式去取一遍**，不能因为默认接口是只读就跳过；③点播筛选条件把「分类」整行**去除**，且「类型」不对 —— 照爱奇艺的「类型」行；④播放页右栏的交互（鼠标移入移出时怎么伸缩）与半透明程度**参考左栏**，并**去掉右上角的收缩按钮** | 用户第二十三次修红标 |
| **① 说明行** | `TextField.decoration.helperText` 整行删除（下一行状态行本来就写着「当前生效：…」）。输入框仍不预填地址（`_input.clear()` + G11–G13 不动） | README §70.1；`G14`/`H43` 反向锁死 |
| **② 根因** | `VodIndexAutoUpdater.runOnce()` 里有一句 `if (isDefaultSource(url)) return skipped('默认片源索引随包只读，无需更新')` —— 默认接口下**一次网络都不发**，把「没实现」说成了「不需要」 | §70.2 |
| **② 现在的分工** | 默认接口：随包索引一个字节不动，新片源写 `vod-index-<hash>.json`（`appendFor` → `supplementFileFor`），由 `loadSupplementFor()` 读；自填接口：同一文件名即它的整份目录（可重写可追加），由 `loadFor()` 读 | `I19`/`I19b`/`I19c` |
| **② 红线未破** | `fileFor(default)` 仍 null、`saveFor(default)` 仍抛错（不许整份重写）；`loadFor(default)` 仍 null ⇒ 闸门读不到增补文件，`decideVodIndexSubmit` 三判据一字未改 | `I12`/`I19`/`H32`/`H38` |
| **② 点播页合并五处** | 浏览首屏（`_indexPage == 0` 排在整批目录最前 + 按片名去重 + `adoptMany` 否则点不开）／关键词检索（`filterVodItems(extra, q)` 追加、总数相加）／目录级筛选（`applyVodFilter(extra, f)` 追加）／筛选条件（`mergeVodFacets` 类型计数相加、地区去重、时间重排）／「共 N 条」= 分片 records + 增补条数 | `H44`；`_supplementItems`/`_withSupplement` |
| **② 调度层简化** | `isDefaultSource` 注入点整个删除 —— 调度器不必知道谁是默认地址，地址分流下沉到存储层（`appendFor` 内部判断） | `I31` 改「默认接口也照走同一条链路」 |
| **③ 删分类** | `VodFacets.categories`、`VodFilter.category`、`_filter.category`、`filterSection(category:)`、`facetOptionsFrom*` 里的 `categoryCounts`、UI 的「分类」行 **全部删除** | `D37`/`D46`/`D47`/`F25`/`F28`/`G14` |
| **③ 类型词表** | 新增 `kVodGenreVocabulary`（33 词，顺序即界面顺序，照爱奇艺：喜剧 动画 动作 爱情 恐怖 战争 惊悚 枪战 科幻 犯罪 悬疑 奇幻 剧情 青春 冒险 家庭 少儿 警匪 历史 武侠 伦理 灾难 传记 运动 音乐 魔幻 歌舞 戏曲 玄幻 悲剧 史诗 西部 其他） | `D52`；`A02b` |
| **③ 归一是关键** | `vodGenreKeyOf()` 剥体裁后缀（`_kFormSuffixes`，长的先剥）再查词表，查不到返回 `''`：`剧情片`→`剧情`、`动作片`→`动作`，而 `4K电影`→`4K`、`Netflix电影`→`Netflix`、`邵氏电影`→`邵氏`、`欧美剧`→`欧美` 都不进类型行 | `A07b`/`A09c`；`D52` |
| **③ 顺序不按命中数** | `VodFacets` 内部改存 `typeCounts`（词→计数），`types` 是从词表筛「有片」的 getter；类型行不再因某个词片多而跳位 | `A01b`；`D46` |
| **③ 筛选口径同源** | `applyVodFilter` 走 `vodGenreKeysOfItem(it)`（`genre` 优先、缺失回落 `typeName`、再归一）；`filterSection` 走 `vodGenreKeysOf(label)` —— 两条路径同一判据，「点下去一定筛得到」 | `D51` |
| **③ 有意代价** | 电视剧类目名（国产剧/日剧/香港剧）归不进词表 ⇒ **类型行会是空的**，只剩地区/时间/排序。比列一排「XX剧」诚实，也与用户参考图一致 | `A09f`；§70.3 |
| **④ 悬停伸缩** | `onHover` → `onEnter` + `onExit`：进栏即展开并取消计时；离栏 1.2 s 收缩（`kVodDetailHoverExitDelay`，与左栏 `_scheduleSideHide` 同一档）。8 秒（`kVodDetailIdleTimeout`）降级为**兜底**（进页一次 + 遥控器/触屏） | `T18`/`T19`/`T20` |
| **④ 悬停时不排计时** | `MouseTracker` 会同时点亮外层 `onHover`（`_pokeControls`），那条路径改走 `_touchDetailPanel()`：`_detailHovering` 为真就不排计时，否则会出现「悬停中 8 秒到点缩回」 | `T20`；§70.4 |
| **④ 半透明对齐左栏** | 展开态与窄条底色都改 `AppTheme.panelScrim`（surface @0.78，左右两侧栏唯一出口），删掉自调的 `black 0.84` / `black 0.55` | `T21` |
| **④ 去收缩按钮** | 右上角 `IconButton(chevron_right_rounded, tooltip: '收起详情…')` 删除；收缩出口改为「移出 1.2 s / 8 s 兜底 / I·D·信息键」三条 | `T22` |
| 门禁 | `flutter analyze` **0 issue**；**44 步 / 4542 断言**（上轮 4530，+12）。`vod-index-gate` 182 → **186**（I19 改口径 + 新增 I19b/I19c + I31/I32/I33 计数 + H42 文案 + H43 + H44）；`vod-playback` 212 → **217**（新增 T18–T22，F03f/F25/F28/F29 改写）；`vod-posters-facets` 121 → **124**（A01/A01b/A02/A02b/A07/A07b/A07f/A09b/A09c/A09c3/A09f 改写 + D37/D46/D47/D50 改写 + 新增 D52/D53）；`third-party-vod` **152**（G14 反向改写）。第一轮全量曾 FAIL 1 步（G14 仍要求「默认留空」），改口径后全绿；增补并发的 `Future` 修复后又完整复跑一次，仍 **44 步 / 4542 断言全通过**（EXIT=0、无 FAIL、111.6 s） | `verify_all.dart` 110.4 s |
| 产物（三件，**重打**） | 首轮产物打完后自查发现增补目录读取的并发缺陷（`bool _supplementLoaded` 会让同帧第二次调用拿到空列表并永久缓存 ⇒ 条件行与「共 N 条」恒为 0），改成 `Future` 缓存后 **`flutter analyze` 0 issue + 全量门禁 44 步 / 4542 断言全绿**，三件产物与安装、取证全部重做。APK **52,460,714 B**（full 47,997,736 / lite 28,877,310，单包 24/24）`1b256810…e30de7a`；setup **33,518,640 B** `8550423d…24c1abc`；portable **41,214,158 B / 38 文件** `ef5cf62d…419a8213`。修复前那一版归档 `dist/_prev/fix23a/` | `dist/` |
| 安装实测 | 静默覆盖安装 **EXITCODE 0**（未卡 `d3dcompiler_47.dll`）；`dist` ↔ `D:/Programs/Shunbo` **38/38 逐字节一致**（安装目录多出的只有 `unins000.dat`/`unins000.exe`）；`data/app.so` **8,569,736 B**，sha 与 `dist` 一致（`8edb7c63…ac8e5`，与修复前 `981b279c…` 不同 ⇒ 确实是新代码）；GUI 启动 **PID 14104 / 55 线程 / 1165.1 MB / 窗口「顺播 shunbo」**，验完已结束 | `build/install_fix23c.log` |
| AOT 串取证 | app.so 8,569,736 B。**新符号命中**：`vodGenreKeyOf`=1、`vodGenreKeysOf`=2、`vodGenreKeysOfItem`=1、`mergeVodFacets`=1、`loadSupplementFor`=1、`supplementFileFor`=1、`vodIndexSupplementFileForUrl`=1、`_supplementItems`=1、`_readSupplementItems`=1、`_withSupplement`=1、`_resetIndexPool`=1、`_touchDetailPanel`=1、`_scheduleDetailCollapse`=1、`pointerLeftPanel`=1、`panelScrim`=1、中文「默认接口同样按追加方式」utf16=1。**已删符号清零**：`_supplementLoaded`=0、`_restartDetailTimer`=0、中文「收起详情」=0、「默认片源索引随包只读」=0。单包两 ABI（arm64 7,340,936 B / armv7a 8,176,200 B）同样命中 `_readSupplementItems`/`_withSupplement`/`vodGenreKeyOf`/`pointerLeftPanel` 各 1、`_restartDetailTimer` 0 | `python` 扫 app.so 与 APK 内 `libapp.so` |
| 未验证 | ①默认接口首次启动会在后台跑一次增量取数（`last == null` 即允许），100 站第 1 页 / 90 s 预算，没有「关掉冷启动取数」的开关；②「共 N 条」把增补条数直接相加，没跟随包分片按片名去重（列表本身已去重），同一部新片两边都有时会多算；③悬停伸缩在 4K 全屏 + 240 卡网格的帧率未测，触摸屏手感未验证；④词表缺「古装」等词表外题材（严格照参考图），这些片只能从「全部」进 | README §70.6 |
| 纪律 | 未提交、未推送；`legacy/` 零改动；不改播放参数；版本仍 `1.0.5+6` | `git status` |

### 五十九、设置-点播源：去版本号 + 免责版权说明 + 自动更新间隔七档可选（1.0.5 同版重打，2026-11-13 12:2x）

| 项 | 结论 | 证据 |
|---|---|---|
| 需求 | 两张截图、三条红标：①标题「点播源（1.0.5）」**版本号去除**；②输入框下面那行灰字位置**加一个简短的免责版权说明**；③「每 24 小时自动更新一次片源：…」那行**去除**，改成**可以手动设定更新时间**（一天 / 三天 / 一周 / 一月 / 一季度 / 半年 / 一年） | 用户第二十四次修红标 |
| **① 版本号** | `_Section(title: '点播源（1.0.5）')` → `'点播源'`。版本号仍在「关于与诊断」四行里（应用 / 渠道 / 版本号 / 应用标识），区块标题不再挂版本 | `G03` 反向锁死；AOT「点播源（1.0.5）」utf16 = **0** |
| **② 免责版权说明** | 输入框下方那行灰字（第二十三次修删掉 helperText 后一直空着）现在放：**「仅聚合第三方公开接口的索引信息，不提供、不存储、不传播任何影音内容；片源与版权归各来源站点所有，请自行确认来源合法。」** 字号 11 / `textTertiary` / 行高 1.4，两行内收住 | `G21`；AOT utf16 两句各 1 |
| **③ 七档间隔** | 新文件 `lib/data/onboarding/vod_update_cadence.dart`：`VodUpdateCadence` 七档（一天 1 / 三天 3 / 一周 7 / 一月 30 / 一季度 90 / 半年 180 / 一年 365），`days`+`label`+`duration`，`fromDays()`/`tryParse()` 只认这七档，其余回落一天。单独成文件是因为设置持久化、调度器、UI 三处都要读 | `D25`/`D26` |
| **③ 持久化** | `VodSourceAddressSettings.updateIntervalDays`（默认 1）落 `config.json` 的 `vodUpdateIntervalDays`；反序列化**最先**解析档位，后面「坏地址回默认」的早退用 `fallback()` 带上档位，不会把用户选的间隔丢掉 | `D21`–`D24` |
| **③ 调度器** | 周期从「构造参数 24 h」改为「`runOnce` 现读 `settings.interval`」；定时器改 `Timer.periodic(kVodIndexUpdateTick)`（**1 小时**一跳，只问「按当前档位到点了吗」）⇒ 改档位下一次 tick 就生效，不必重启定时器；跳过文案改「距上次更新不足三天」（读档位 label）；`shouldUpdate` 保留可选第三参数 | `I24`/`I27b`/`I27c`/`I29b`；`H35` |
| **③ 界面** | 「立即获取最新片源」按钮下方「自动更新间隔」+ 七个 chip（`Wrap` 换行、遥控器可聚焦）；自写 `_CadenceChip`（选中 = `accentDim` 底 + `accent` 描边），不用 `ChoiceChip`（Material 默认边框/勾选在深色页比正文还亮）。点档位**只落盘、不取数** | `G22`/`G23` |
| 删掉的长说明 | 「每 24 小时自动更新一次片源：只取各接口最新一页…」整段 `_Tip` 删除，`_Tip` 组件一并删掉。其中「按 id 去重 / 只追加不重取 / 默认接口可追加」三条口径仍由 `H41`/`I19`/`D53` 等功能断言保证，不是靠文案 | `H42` 反向改写 |
| 门禁 | `flutter analyze` **0 issue**；**44 步 / 4554 断言全通过**（上轮 4542，+12；EXIT=0、无 FAIL、140.2 s）。`vod-index-gate` 186 → **189**（I24 改七档表 + I27b/I27c 档位判断 + I29b 周期读设置；H35/H42 改写）；`vod-source-address` 128 → **137**（G03 反向 + G18 改写 + 新增 G21/G22/G23 + D21–D26） | `verify_all.dart` |
| 产物（三件，同版重打） | APK **52,526,250 B**（full 48,063,274 / lite 28,877,312，单包 24/24）`11b035a0…64537b02`；setup **33,518,372 B** `7cc90fb3…b956c6`；portable **41,217,443 B / 38 文件** `3af6a558…a9fb81`。上一版归档 `dist/_prev/fix23b/` | `dist/` |
| 安装实测 | **第一次静默安装 EXITCODE=2**：桌面上有一个正在运行的实例（PID 31384，用户截图时开着），`CloseApplications=force` + `PrepareToInstall taskkill` 没兜住就直接退了，**连安装日志都没生成**（`/LOG` 文件不存在，`app.so` 仍是 12:05 的旧文件）。关掉该实例后重跑 → **EXITCODE=0**，`dist` ↔ `D:/Programs/Shunbo` **38/38 逐字节一致**，`data/app.so` 8,569,736 B sha `8a3ee539…`（12:24）；GUI **PID 22384 / 49 线程 / 1156.8 MB / 窗口「顺播 shunbo」**，验完已结束 | `build/install_fix24*.log`、`build/inno_fix24.log` |
| AOT 串取证 | app.so 8,569,736 B。**新符号命中**：`VodUpdateCadence`=2、`_CadenceChip`=1、`_selectCadence`=1、`updateIntervalDays`=1、`fromDays`=1、`tryParse`=5、`shouldUpdate`=5；UTF-16LE「自动更新间隔」1 /「一季度」1 /「仅聚合第三方公开接口的索引信息」1 /「片源与版权归各来源站点所有」1 /「距上次更新不足」1。**已删文案清零**：「点播源（1.0.5）」**0**、「每 24 小时自动更新一次片源」**0**、`_Tip` **0**。（`kVodIndexUpdateTick`/`kVodIndexUpdateInterval` 是 const，内联后为 0，属预期。）单包两 ABI（arm64 7,406,472 B / armv7a 8,176,200 B）同样 `VodUpdateCadence`=2、`_CadenceChip`=1、免责句=1、「点播源（1.0.5）」=0 | `python` 扫 app.so 与 APK 内 `libapp.so` |
| 未验证 | ①「一季度 / 半年 / 一年」只做了纯函数与计数验证，**没跨月跨年实测**；②每小时 tick 在电视端长期后台的耗电未测（每跳只读一次设置文件）；③改小档位后「上次更新时间」不清零，把一年改成一天且上次就在昨天时会立刻到点，下次 tick 就取一次 —— 有意，但界面没解释；④设置页七 chip 在窄窗口（比如 800×600 电视形态）是否换行成两行未截图确认 | README §71.5 |
| 纪律 | 未提交、未推送；`legacy/` 零改动；不改播放参数；版本仍 `1.0.5+6` | `git status` |

### 六十、索引误报「已失效」+ 右栏完全隐藏（1.0.5 同版重打，2026-11-13 12:5x）

| 项 | 结论 | 证据 |
|---|---|---|
| 需求 | 两张截图：①点卡片弹「这条索引记录已失效，请重新检索」，**过一会又好了**，要排查；②右栏「要和左栏一样，当一定时间没有任何响应要自动隐藏，只有当鼠标移入区域才显示出来，**隐藏后不要再有详情条**，参考左栏完全隐藏」 | 用户第二十五次修红标 |
| **① 真凶** | **不是索引坏了**。`_openAndPlay` 用 `hitById(item.id)` 判「失效」，而 `_byId` 是**会话级缓存**：只在 `toItem()` 里写入、上限 `kHitIndexCap = 4000`、老实现到顶 `_byId.clear()` **整表清空**、不落盘。浏览 ~33 页（120/页）+ 几次筛选（每次 ≤400 命中）就会溢出 ⇒ 屏幕上还摆着的卡片全部查不到命中 ⇒ 误报。列表没坏，切走再切回来会重新载入一页并把命中表填回去 ⇒ 表现为「过一会就好了」 | README §72.1 |
| **① 修法一** | 不再把「缓存里没有」等于「记录失效」：新增顶层纯函数 `parseBuiltinHitId()`（拆 `builtin:<站点下标>:<vod_id>`）与 `BuiltinIndexService.hitByIdOrRebuild()`（查不到就按 id 重建命中）。回源 `fetchDetail` 只需要这两个字段 ⇒ id 结构完好且站点下标未越界就**一定可回源**；`typeId` 缺失只影响类型栏显示 | `J07`–`J15` |
| **① 修法二** | `_remember()` 到顶改成**淘汰最早的 1/4**（`final drop = kHitIndexCap ~/ 4;` + `keys.take(drop)`），不再一次铲掉工作集 | `J16` |
| **① 保留的准确提示** | 只有两种情形仍报失效：id 结构解析不出（非 `builtin:` / 缺分隔符 / 负下标 / 空 vod_id）、站点下标越界。`_openAndPlay` 在 await 后补 `if (!mounted \|\| seq != _resolveSeq) return;`；`_retryOpen` 用 `identical(_item, item)` 拦「回包晚到换了片」 | `J09` / `J14` / `J15` |
| **② 右栏完全隐藏** | `AnimatedPositioned` 的收起从「`width` 缩到 44 px 竖条」改成「`right` 滑到 `-width`」，与左栏 `left: -188` 同构；滑动时长 `kVodDetailSlideDuration = 240ms`（与左栏 `AnimatedPositioned` 同档）；`_detailRail()` 组件与 `kVodDetailRailWidth` 常量删除；不再用 `AnimatedSwitcher` 换一套 UI，只滑同一块 `_detailBody` | `T04` / `T23` / AOT `_detailRail`=0 |
| **② 怎么叫回来** | 新增 `_detailLayer(item)`：`[面板, if (!_detailExpanded) EdgeRevealHandle(side: EdgeSide.right)]` —— 与左栏同一个组件（贴边 400 ms 自动展开 / 点一下 / 从边缘往内拖）；遥控器仍是 I / D / info / guide 四键 | `T14` / `T06` |
| **② 改名** | `VodDetailInput.pointerOnRail` → `pointerOnEdge`（语义从「点在竖条上」变「指针进右边缘热区」） | `T06`，AOT `pointerOnRail`=0 |
| 门禁 | `flutter analyze` **0 issue**；**44 步 / 4566 断言全通过**（上轮 4554，+12；EXIT=0、无 FAIL、130.5 s，日志 `build/verify_all_fix24b.log`）。`vod-playback` 217 → **219**（T04/T06/T13/T14 改写 + T23/T24 新增）；`vod-builtin-service` 119 → **129**（J07–J16 新增） | `verify_all.dart` |
| 产物（三件，同版重打） | APK **52,460,714 B** `5cb5d973…3ea5896`（full 47,997,737 / lite 28,877,308，单包 24/24）；setup **33,516,695 B** `5a16ebc8…8fb220bd`；portable **41,217,304 B / 38 文件** `25ab3086…9b056ae`。上一版归档 `dist/_prev/fix24/` | `dist/` |
| 安装实测 | 安装前先 `CloseMainWindow()` 关掉用户当时开着的实例（PID 25064，第二十四次修踩过 `EXITCODE=2` 且**连日志都不生成**的坑）→ 静默覆盖 **EXITCODE 0**；`dist` ↔ `D:/Programs/Shunbo` **38/38 逐字节一致**（多出 `unins000.*` 两个卸载器）；`data/app.so` 8,569,736 B `1436ced3…`（12:52）；GUI **PID 29264 / 50 线程 / 1124.9 MB / 窗口「顺播 shunbo」**（验完保留运行，方便用户直接看效果） | `build/inno_fix24b.log` |
| AOT 串取证 | app.so 8,569,736 B。**新符号命中**：`hitByIdOrRebuild`=1、`parseBuiltinHitId`=1、`BuiltinHitRef`=2、`_detailLayer`=1、`_remember`=2、「这条索引记录已失效，请重新检索」utf16=1。**已删符号清零**：`kVodDetailRailWidth`=0、`_detailRail`=0、`vod-detail-rail`=0、`pointerOnRail`=0。（`kVodDetailSlideDuration` 是 const、内联后为 0，与上轮 `kVodIndexUpdateInterval` 同况。）单包两 ABI（arm64 7,340,936 / armv7a 8,176,200）同样 `parseBuiltinHitId`=1、`hitByIdOrRebuild`=1、`_detailLayer`=1、`_detailRail`=0、`pointerOnRail`=0 | `python` 扫 app.so 与 APK 内 `libapp.so` |
| 未验证 | ①「表满 → 淘汰」只用源码断言锁住，**没真跑 4000 条命中**再点卡片；②右边缘热区有上下各 80 px 边距不可热（与左栏同策略），鼠标停在最上/最下 80 px 会呼不出面板，键盘 I/D 仍可用；③触屏没有常驻手柄，唤出只靠 I/D/info/guide | README §72.4 |
| 纪律 | 未提交、未推送；`legacy/` 零改动；不改播放参数；版本仍 `1.0.5+6` | `git status` |

### 六十一、获取进度条 + 不许死循环 + 输入页「当前接口」（1.0.5 同版重打，2026-11-13 13:2x）

| 项 | 结论 | 证据 |
|---|---|---|
| 需求 | 两张截图：①「正常能获取时要有进度条，无法获取时会一直闪，当获取不到要有提醒，不能死循环」；②红框标在「安装包内置索引目录记录的接口：http://47.96.82.41:5188/config.json」，红字「改成当前接口，如果没有就是空，初次加载也是空，要有简短免责说明」 | 用户第二十六次修红标 |
| **① 进度条** | 新文件 `lib/features/vod/vod_build_progress.dart`：`VodBuildStage`（connecting/fetching/saving/done/failed）+ 站点数 + 条数，`fraction`/`note` 全是纯函数。`VodSession._runStart` 每批上报（`finishedSites`/`siteCount`/`_loaded`）→ 装配层转交 `gate.reportBuildProgress` → 设置页与点播页读 `gate.buildProgress` 渲染 `LinearProgressIndicator` | `J01`–`J14` |
| **① 进度口径** | 站点翻完**封顶 0.9**（写盘未完，先到 100% 再停住更像卡死）；0/45 给 **0.02**（空条形图看不出已启动）；站点总数未知返回 **null** 走不确定进度条；文案「已完成 12/45 个站，已取 1,240 条」不用百分数。设置页另有「已用 N 秒」（500 ms 本地计时器，只在获取期间跑） | `J02`–`J07` |
| **① 闪的真因 A** | **提交未通过 ⇒ 自动弹回输入页 ⇒ 再提交**。`_maybePromptAddress` 在 `needAddress` 自动弹窗，提交后仍不 ready 又弹 ⇒ 对话框反复闪。现在 `if (!verdict.ready)` ⇒ `_addressPromptDismissed = true` + toast，要重试必须自己点「重试 / 改地址」 | `H45` |
| **① 配套** | 装配层 `rebuild` 遇默认地址不再静默 `return null`（那是循环的燃料），改成回一句「随包默认索引目录不可用（缺失或未记录接口地址），请换一个接口地址」 | `H18`/`H32`/`G15`/`G16` |
| **① 闪的真因 B** | **生成没有硬截止**：`VodSession` 的 90 s 预算只在**批间**检查，单批卡住就无限等。闸门外加 `kVodIndexBuildDeadline = 3 分钟`，到点判 failed 并给可读理由。坑：`Future.timeout` 按**接收者运行时泛型**检查 `onTimeout`，实现只 `return null` 时是 `Future<Null>` ⇒ 先 `.then<String?>((v) => v)` 规范化，否则抛 `TypeError` | `J12`/`J13` |
| **① 闪的真因 C** | **提交期间输入框置灰 ⇒ 丢焦点 ⇒ 再触发失焦提交**。`enabled: !_busy` → `readOnly: _busy || _updating`：禁编辑但保住焦点 | `G24`（反向锁死 `enabled: !_busy`） |
| **① 一定收场** | `_submit` 的 `_buildProgress` 置位/清除包在 `try/finally`；设置页 `_busy`/`_updating` 都加 `catch` 兜底并给结论文本，失败用告警色（`_noteIsError`）；构建结束后**迟到的进度上报一律丢弃**（`reportBuildProgress` 在 `_buildProgress == null` 时直接 return），否则界面会从「失败」跳回「正在获取 87%」 | `J10`/`J11`/`G25` |
| **② 当前接口** | 输入页那行固定地址改成**用户设定的接口**（`selectedUrl`），没设过整块不渲染；输入框也只预填这条（初次为空）；删掉「填同一个地址可直接加载…」提示与「填入内置索引地址」按钮（保留「填入默认源地址」） | `H12`；AOT「填入内置索引地址」=0、`builtinSourceUrl`=0 |
| **② 免责说明** | 对话框底部固定：「仅聚合第三方公开接口的索引信息，不提供、不存储、不传播任何影音内容；片源与版权归各来源站点所有，请自行确认来源合法。」（10 px / tertiary） | `H12`；AOT utf16=1 |
| **② 空输入不报错** | 新增 `_attempted`：只有点过「确定」之后才显示校验红字，初次打开不再一进门就顶一行「请填写片源接口地址」 | `dialog.contains('_attempted')` |
| 门禁 | `flutter analyze` **0 issue**；**44 步 / 4583 断言全通过**（上轮 4566，+17；EXIT=0、无 FAIL、133.0 s，`build/verify_all_fix26.log`）。`vod-index-gate` 189 → **204**（J01–J14 新增、H12/H18/H32 改写、H45 新增）；`vod-source-address` 137 → **139**（G15 同步 + G24/G25）；`third-party-vod` 152 → 152（G16 改写，不放宽） | `verify_all.dart` |
| 产物（三件，同版重打） | APK **52,608,170 B** `46d737ef…6641e9b1`（full 48,145,146 / lite 28,893,635，单包 24/24）；setup **33,526,774 B** `b015f9c0…7f581679`；portable **41,225,314 B / 38 文件** `94608511…125ff6b`。上一版归档 `dist/_prev/fix25/` | `dist/` |
| 安装实测 | 装前先关掉用户开着的实例（PID 15836 / 60 线程）→ 静默覆盖 **EXIT=0**；`dist` ↔ `D:/Programs/Shunbo` **38/38 逐字节一致**（多出 `unins000.dat`/`unins000.exe` 两个卸载器）；`data/app.so` 8,586,120 B `7579b4e0…63cb4b7`；GUI **PID 23928 / 58 线程 / 564.8 MB / 窗口「顺播 shunbo」**（保留运行，方便直接看效果） | `build/inno_fix26.log` |
| AOT 串取证 | app.so 8,586,120 B。**新符号命中**：`VodBuildProgress`=2、`reportBuildProgress`=1、`_startTicker`=2、`_statusArea`=1、`_stopTicker`=1、`VodBuildStage`=2；utf16「正在获取片源：已完成」1 /「正在连接接口并读取配置」1 /「已用 」1 /「获取超时」1 /「随包默认索引目录不可用」1 /「当前接口：」1 /「仅聚合第三方公开接口的索引信息」1。**已删存在清零**：`builtinSourceUrl`=0、「填同一个地址可直接加载」=0、「填入内置索引地址」=0。单包两 ABI（arm64 7,472,008 / armv7a 8,192,584）同验 | `python` 扫 app.so 与 APK 内 `libapp.so` |
| 未验证 | ①真实爬升速度未测（替身分页器验的逻辑），弱网下可能长时间停在 0.02；②3 分钟超时没真跑到（要造一个卡死的站），只用源码断言；超时后底层那次 `saveFor` 若最终完成会写出一份当前未启用的目录文件，下次进点播才生效；③对话框反复弹只用源码断言锁住，没在 UI 上连点十次 | README §73.5 |
| 纪律 | 未提交、未推送；`legacy/` 零改动；不改播放参数；版本仍 `1.0.5+6` | `git status` |

### 六十二、状态句「默认」→「当前」（1.0.5 同版重打，2026-11-13 13:4x）

| 项 | 结论 | 证据 |
|---|---|---|
| 需求 | 设置-点播源截图，红框框住「与默认片源索引地址一致，已直接复用默认记录（未发起网络请求）」，箭头批注「把『默认』文字改成『当前』」 | 用户第二十七次修红标 |
| 改动 | 只改一条字符串字面量：`与当前片源索引地址一致，已直接复用当前记录（未发起网络请求）`。两处「默认」**一起换** —— 只换前半句会变成同一格里两种口径 | `vod_source_section.dart` `_submitAddress()` |
| 有意保留的两处「默认」 | ①状态行无地址时「当前生效：默认片源索引（随包）」——修饰随包资产本身，改「当前」会变成「当前生效：当前片源索引」；②`main.dart` 失败理由「随包默认索引目录不可用」——「随包默认」是名词，不是口径对照 | README §74.2 |
| 判断链未动 | `decideVodIndexSubmit()` 三判据、`builtin.matches(url)` → `loadExisting` 零网络分支、`fileFor(default) == null` 护栏全部未改 | `G15`/`G16` 仍通过 |
| 门禁 | `flutter analyze` **0 issue**；**44 步 / 4584 断言全通过**（上轮 4583，+1）。`vod-source-address` 139 → **140**：新增 `G26` 正向锁新句、反向锁旧句为 0 | `build/verify_all_105.log` |
| 产物（三件，同版 1.0.5） | APK 52,608,170 B `bb1f0b23…ae594b1`（full 48,145,149 / lite 28,893,643，单包 24/24）；setup 33,526,521 B `cbf3867e…55d075`；portable 41,225,312 B / 38 文件 `0412ab46…c2ca4df091`。**字节数与上一轮几乎一致**：同长度替换（「默认」→「当前」各 2 汉字 = 6 字节），只有 sha 变 | `dist/_prev/fix27/` |
| AOT 取证 | UTF-16LE 新句=1、旧句=0；`当前生效：`=1（状态行未受影响）；单包两 ABI 同验 | app.so / `libapp.so` |
| 未验证 | 纯字符串替换，无可测行为面。唯一副作用：用户手里的红标截图是旧版，对不上新文案 | README §74.5 |
| 纪律 | 未提交、未推送；`legacy/` 零改动；不改播放参数 | `git status` |

### 六十三、选集右栏 6 秒无响应自动隐藏 + 版本升 1.0.6（2026-11-13 14:1x）

| 项 | 结论 | 证据 |
|---|---|---|
| 需求 | 播放页选集抽屉截图，红字「播放页面，选集弹出的右边栏如图，当无响应 6 秒需要自动隐藏」；随后指令「将当前版本升为 1.0.6」 | 用户第二十八次修红标 + 升版指令 |
| 实现 | 新增 `lib/ui/vod/panel_idle_hider.dart` 的 `PanelIdleHider`（`idle` / `onIdle` / `child`）。计时器跟着 widget 生命周期走（`initState` 起、`dispose` 取消），所以「点条目 / 点 X / Esc / 换集 / 退播放」任何一条关闭路径都不会漏掉取消 | `T25`/`T28` |
| 常量 | `kVodEpisodeIdleHide = Duration(seconds: 6)`，与 `kVodControlsIdleTimeout`(4 s)、`kVodDetailHoverExitDelay`(1.2 s)、`kVodDetailIdleTimeout`(8 s) 同处：6 秒夹在「控制条 4 秒」与「读文字 8 秒」中间 | `T25` |
| 「有响应」口径 | **六类信号**任一都重置计时：`onHover` / `onPointerDown` / `onPointerMove` / `onPointerSignal`（滚轮，不触发 hover）/ `ScrollNotification`（拖滚动条）/ `Focus.onFocusChange` + `Focus.onKeyEvent`（遥控器）。只接 `onHover` 会把「正在翻集数」的用户误收 | `T27` |
| 收起动作 | `onIdle` 先复核 `if (!mounted || !_showEpisodes) return;`（到点可能已被别的路径关掉）→ `setState(() => _showEpisodes = false)` → `_pokeControls()` 让控制条亮回来 | `T26` |
| 接线 | `_episodePanel` 的 `Positioned` 内多一层 `PanelIdleHider(idle: kVodEpisodeIdleHide, …)`，`Material/SafeArea/Column/ListView` 原样不动（状态不重建） | `vod_page.dart` `_episodePanel` |
| 升版 | `1.0.5+6` → **`1.0.6+7`**：`pubspec.yaml`、`system_channel.dart`（name/code）、`tooling/windows_installer.iss`；**新建** `dist/windows/Shunbo-1.0.6.iss`（`VersionInfoVersion=1.0.6.7`、`ProductVersion=1.0.6`、`TextVersion=1.0.6+7`，BOM+CRLF 保持）与 `dist/windows/Shunbo-1.0.6/`（Release 覆盖 + 补 10 个 VC++ DLL）；单包合并显式传 `--version-name 1.0.6 --version-code 7` | 4 个门禁文件同步（R12×4 / I01 / N09 / G14·G36 / H01–H03） |
| 踩坑 | `dart format` 把 `widget.services.live.stop().timeout(…)` 拆成三行 ⇒ `I05` 的 `contains('widget.services.live.stop()')` 当场失败。断言改成 `RegExp(r'services\.live\s*\.\s*stop\(\)')`，**语义未放宽**（仍要求起播前先停直播），只是不再依赖格式化风格 | `I05` |
| 门禁 | `flutter analyze` **0 issue**；**44 步 / 4588 断言全通过**（上轮 4584，+4；EXIT=0、110.3 s，`build/verify_all_106.log`）。`vod-playback` 219 → **223**（T25–T28 新增、I05 改写） | `verify_all.dart` |
| 产物（三件，1.0.6） | APK **52,608,170 B** `253dbc6d…dc35d7`（full 48,145,142 / lite 28,893,638，单包 24/24）；setup **33,527,503 B** `ff8eb08a…eef503d`（`FileVersion=1.0.6.7`）；portable **41,229,215 B / 38 文件** `6c88f60d…050b24c`。1.0.5 三件归档 `dist/_prev/fix27/`，`dist/` 根只剩 1.0.6 + 1.0.4 基线 | `dist/` |
| 安装实测 | 先 `CloseMainWindow()` 关掉 1.0.5 实例 → 静默覆盖 **EXIT=0**、`/LOG` 生成；`dist/windows/Shunbo-1.0.6` ↔ `D:/Programs/Shunbo` **38/38 逐字节一致**（多 `unins000.dat`/`unins000.exe`）；`data/app.so` 8,586,120 B `5197e4ab…0cfe9d7a`；GUI **PID 28104 / 49 线程 / 1063 MB / 窗口「顺播 shunbo」**（保留运行） | `build/inno_106.log` |
| AOT 串取证 | `PanelIdleHider`=2、`_PanelIdleHiderState`=1、`_restart`=3、`1.0.6`=1；utf16「与当前片源索引地址一致，已直接复用当前记录（未发起网络请求）」=1、「与默认片源索引地址一致」=0、「选集（」=2。`kVodEpisodeIdleHide`=0 属正常（`const Duration` 编译期内联，无符号）。单包两 ABI（arm64 7,472,008 / armv7a 8,192,584）均 `PanelIdleHider`=2 | app.so / `libapp.so` |
| 未验证 | ①6 秒真实手感未量（`flutter test` 本工程不可用，只能源码断言 + 用户验收）：点开后静置是否准点收 / 翻列表是否被误收 / 收后控制条是否亮回；②遥控器走 `Focus.onKeyEvent` 无真机（S50 Air）实测；③抽屉是直接消失，没有 240 ms 滑出动画（本轮未要求） | README §75.7 |
| 纪律 | 未提交、未推送；`legacy/` 零改动；不改播放参数 | `git status` |
