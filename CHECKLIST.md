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
