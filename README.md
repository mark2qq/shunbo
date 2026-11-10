# 顺播 (shunbo) — 跨端视频播放软件（Flutter 工程）

> 设计方案：`/e/TV/跨端视频播放软件设计方案.docx`
> 评估与计划：`/e/TV/顺播_技术评估与研发执行计划.docx`
> 范围变更记录：`/e/TV/顺播_研发启动纪要_范围变更记录.docx`

## 范围（2026-11-05 决策）
- **iOS 暂不实现**。其余端（Android / 桌面 / TV）按研发执行计划推进。
- 修订基线：~165 人日（移除 iOS 交付 ~15 人日）。

## 技术栈
- Flutter 3.47.9 + Dart 3.13.7（SDK 安装至 `D:/flutter`，Dart 随 Flutter 捆绑）。
- 播放内核：libmpv（Android/桌面/TV 共用，必要时 ExoPlayer 回退）。
- 源适配：Android 端 jar 爬虫 / QuickJS；桌面端源覆盖较少（已明示落差并建模约束）。

## 工程结构
```
shunbo/                      # Flutter 工程根（包名 shunbo）
  pubspec.yaml
  lib/
    main.dart                # 入口（M0 自校验 + MVP UI：搜索→选集→选源→播放面板）
    core/
      source/
        source_profile.dart        # 源画像（集数偏移 + 广告模型）
        source_adapter.dart        # 源适配器契约 + 数据模型（E2，含平台约束）
        memory_source_adapter.dart # 内存示例适配器（MVP/测试用）
        source_registry.dart      # 源适配器注册表（按平台裁剪）
        source_parser.dart         # 【E2】解析器契约（解析内核：站点文本→结构化）
        dart_backend.dart          # 【E2】Dart 解析子集 + 真实取数（超时/状态码/体积/SSRF/请求头/路径模板/跨 origin 凭据隔离）
        site_rule.dart             # 【E2 扩充】站点规则纯数据模型 + 预设 + ReDoS 静态校验 + URL/实体工具
        rule_source_parser.dart    # 【E2 扩充】规则驱动解析器（regex/json 双形态、脏数据隔离、去重排序）
        jar_backend.dart           # 【E2】Android jar 后端（MethodChannel，仅 Android）
        source_fetcher.dart        # 【E2】取数契约 + 失效枚举/异常 + MockFetcher（注入响应，不联网）
        parsed_source_adapter.dart # 【E2】真实适配器：parser + fetcher 组合，含取址自愈
        source_parser_factory.dart # 【E2】桌面/TV 工厂（支持传入 SiteRule；jar 落差：Android 另走 jar_backend）
      scheduler/
        alignment.dart            # 换源对齐核心算法（M0 验证，Dart 移植）
        source_catalog.dart       # 源画像注册表（换源决策唯一权威 R1）
        playback_orchestrator.dart # 播放编排层：搜索（源级优先级稳定排序）→选源→解析→对齐→载入
        playback_failure.dart     # 【E7】可恢复失效模型 + FailoverPolicy
        source_failover.dart      # 【E7】自动换源韧性（唯一重试决策点 + 全失效兜底）
        progress_reporting.dart   # 【E6】播放中进度落盘（换算/节流/串行写/换源护栏）
      playback_queue.dart       # 【E6→播放列表】自动连播：下一集选源/迟到事件/最后一集
      player/
      player_controller.dart    # 播放器抽象（E3，libmpv 封装契约；load 接收 url+原始坐标+请求头）
      media_kit_player_controller.dart # 【E3 桌面】media_kit/libmpv 真实内核（Windows/Linux/macOS）
      mock_player_controller.dart # 可验证播放器模拟实现（E3 占位/MVP 演示）
      player_bootstrap.dart     # 按平台选内核（Android→平台通道 / 桌面→media_kit）+ 后端标签
        mpv/
          player_metrics.dart      # 运行时指标 + 门禁（首帧/内存/卡顿，三项相互牵制）
          mpv_native.dart          # 原生绑定抽象（FFI / 平台通道）
          libmpv_player_controller.dart # 播放控制器（load 后采样并即时跑门禁）
          fake_mpv_native.dart     # 纯 Dart 假实现，逻辑验证用
          metrics_sampler.dart     # 【真实】运行时指标采样器 + 三者牵制模型/参数寻优
          mpv_backend_resolver.dart# 【真实】后端决议（FFI 优先，缺失降级平台通道）
          mpv_ffi_bindings.dart    # 【真实】libmpv client.h C API 的 dart:ffi 绑定 + 动态库探测
          mpv_ffi_native.dart      # 【真实】基于 FFI 的 MpvNative 实现（命令/属性/指标桥接）
          mpv_platform_channel_native.dart # 【真实】Android ExoPlayer 回退（MethodChannel）
          mpv_native_factory.dart  # 【真实】后端工厂：探测→决议→构造 + 事件管线一行式入口
          mpv_event.dart           # 【E3 事件】libmpv JSON 事件模型 + 宽松解析
          mpv_event_loop.dart      # 【E3 事件】事件循环：脏数据隔离/背压/订阅者隔离/暂停
          mpv_property_observer.dart # 【E3 事件】property-change → 采样器 → 门禁
          mpv_event_pipeline.dart  # 【E3 事件】原生流→循环→观察器→门禁→埋点 一行接线
          mpv_event_channel.dart   # 【E3 事件】Android EventChannel 'shunbo/mpv/events' 契约
    diagnostics/
      diagnostic_sink.dart       # 【E7】结构化诊断事件 + Sink 抽象/内存实现/空实现
      file_diagnostic_sink.dart  # 【E7 真实】JSONL 落盘 + 体积轮转 + 串行写 + 缓冲上限
    cast/
      cast_fallback.dart         # 【E5】投屏状态机 + 传输抽象 + 失败/掉线/主动结束降级（进度守恒）
      dlna/dlna_transport.dart   # 【E5 真实】DLNA：SSDP 发现 + 设备描述 + SOAP AVTransport
    ui/player_surface.dart       # 原生视频表面 AndroidView（shunbo/player_view）
    ui/media_kit_surface.dart    # 【E3 桌面】media_kit 的 Video（libmpv → Flutter 纹理）
    data/config_store.dart       # 配置/持久化抽象（E6，含安全注记）
    data/file_config_store.dart  # 【E6 真实】配置/进度/引导状态 JSON 落盘：原子写 + 损坏降级
    data/resume_record.dart      # 续播记录模型（E6：只存去广告规范坐标 + JSON 序列化）
    data/resume_store.dart       # 续播持久化抽象（E6）
    data/memory_resume_store.dart # 内存版续播存储（MVP/测试用）
    data/file_resume_store.dart  # 【E6 真实】JSON 落盘：原子写 / 损坏降级 / 重启回读
    data/sync/
      sync_transport.dart        # 【E6 跨端】SyncEntry/Snapshot + 内存/共享目录传输
      resume_sync_engine.dart    # 【E6 跨端】Lamport 时钟合并 + 墓碑 + 离线队列 + 装饰器
    data/onboarding/
      source_config_validator.dart # 【E9】源配置安全白名单（多源容器/禁代码加载字段/scheme/allowedOrigins 严格校验）
      source_config_loader.dart  # 【E9→E2】配置消费方：逐条校验隔离 → 多源适配器/画像注册
      source_import_service.dart # 【E9→UI】导入编排：安全门禁/净化落盘/重复替换/重启恢复
      source_config_file.dart   # 【E9→UI】从文件导入：路径归一化/UTF-8 BOM/体积/类型/远程路径边界
      source_config_url.dart    # 【E9→UI】从链接导入：唯一网络 IO 边界（https/重定向/体积/编码/超时）
      sample_source_config.dart # 【E9→UI】一键示例（App/演示服务/回归共用同一份数据）
      onboarding_flow.dart       # 【E9】首次配置引导状态机（免责→导入→平台确认）
  test/
    alignment_test.dart          # 对齐算法 Dart 测试（6 项，镜像 Python 原型）
    source_adapter_test.dart     # 源适配/注册表测试（2 项）
  spike/                         # M0 纯逻辑原型（Python，零依赖）
    core/alignment.py
    tests/test_alignment.py
  tooling/
    install_flutter.sh           # Flutter SDK 安装脚本（下载+校验+解压）
    flutter_setup_verify.sh      # 首跑 init（pub get/analyze/test）
    verify_logic.dart            # 逻辑自验证（dart run，绕开 flutter test 限制）
    verify_all.dart              # 统一门禁入口：一次跑完 analyze + 二十六套回归 + Python 原型
    verify_live_http.dart        # 真实 HTTP 端到端回归（本地样本站点 + 真实 socket 取数）
    verify_source_config.dart    # 配置驱动多源真实回归（聚合/隔离/换源/坏配置）
    verify_onboarding_import.dart # 导入全流程真实回归（门禁/状态一致性/重启恢复/示例可播）
    verify_queue.dart            # 自动连播回归（排序去重/迟到事件/最后一集/换源/并发）
    fetch_windows_kits.sh        # Windows 构建前置：拉 libmpv/ANGLE 原生包（镜像 + 断点续传）
    windows_installer.iss        # Windows 安装包（Inno Setup，per-user 安装）
    installer_readme_zh.txt      # 安装包首屏说明（能力边界与数据位置）
    ChineseSimplified.isl        # Inno Setup 简体中文语言包
    verify_url_import.dart       # URL 导入真实回归（本地拦截/重定向/体积/编码/编排隔离）
    verify_dlna_cast.dart        # DLNA 投屏真实回归（真实 UDP SSDP + 每设备 HttpServer）
    verify_progress.dart         # 播放中进度落盘 + 片尾判定真实回归（换算/节流/串行写/换源护栏/已看完）
    verify_source_config_file.dart # 从文件导入真实回归（BOM/编码/体积/符号链接/远程路径/真实可播）
    verify_source_config_export.dart # 导出/备份真实回归（不覆盖/原子换名/往返一致/真实可播）
    verify_cross_origin.dart    # 三台站点：跨主机取址/重定向/凭据隔离/源级优先级
    verify_channel_contract.dart # Dart↔Kotlin 通道契约静态核对（通道名/方法/事件/指标键）
    fixture_site.dart            # 公共本地样本站点（三类结构 + 故障路径 + 跨主机 + 请求头校验）
    serve_fixture_site.dart      # 常驻样本站点服务（默认 56782，打印可粘贴配置）
  ../.github/workflows/verify.yml # CI 验证门禁（本地文件，未推送远端）
android/app/src/main/kotlin/com/shunbo/shunbo/
    MainActivity.kt              # 【E3】唯一注册点：MethodChannel + EventChannel + PlatformView
    MpvMethodHandler.kt          # 【E3】10 个方法分发；sampleMetrics 后台等首帧；请求头映射
    PlaybackEventBridge.kt       # 【E3】事件推送（主线程 post，一行一个 JSON）
    ExoPlayerEngine.kt           # 【E3】media3 后端：事件映射 / 首帧 / 内存 / 丢帧 / seek
    PlayerSurfaceFactory.kt      # 【E3】TextureView 渲染面（与内核生命周期解耦）
```

## 验证状态（截至 2026-11-05）
| 项 | 结果 |
|---|---|
| `flutter --version` | ✅ Flutter 3.47.9 / Dart 3.13.7 |
| `flutter pub get` | ✅ 依赖解析完成（24 包） |
| `flutter analyze` | ✅ No issues found（全工程 0 告警） |
| Python 原型测试 | ✅ 6/6 通过 |
| 核心逻辑 `dart run tooling/verify_logic.dart` | ✅ **169/169 断言通过**（脚本内自动计数，覆盖 M0/E2/E3/E5/E6/E7/E9 全部可验证逻辑） |
| 真实联网 `dart run tooling/verify_live_http.dart` | ✅ **43/43 断言通过**（三类站点结构真实 GET + 7 类网络边界；收集式断言，失败置退出码 1） |
| 通道契约 `dart run tooling/verify_channel_contract.dart` | ✅ **19/19 断言通过**（MethodChannel/EventChannel/PlatformView 名两侧一致、Dart 调用的方法原生侧都有分支、原生推送的事件名都在 Dart 解析表内、`sampleMetrics` 三个键对齐、渲染面注册链路完整、原生侧有兜底 catch） |
| 多源配置 `dart run tooling/verify_source_config.dart` | ✅ **47/47 断言通过**（配置驱动三源聚合 + 单源故障隔离 + 跨源自动换源 + 8 类坏配置隔离；会话播放地址与播放器载入一致且可取回；配置里的 Referer/UA 真的到达播放层） |
| 引导导入 `dart run tooling/verify_onboarding_import.dart` | ✅ **60/60 断言通过**（安全门禁 / 状态一致性 / 重复导入 / 写盘降级 / 重启恢复 / UI 一键示例真实可播） |
| URL 导入 `dart run tooling/verify_url_import.dart` | ✅ **37/37 断言通过**（真实本地服务：免责门禁零请求、file:// 与明文 http 拦截、URL 内联凭据拒绝、同主机重定向跟随/跨主机与自环拒绝、256KB 上限、二进制与非法 UTF-8 拒绝、慢响应超时；编排层：成功注册+落盘、失败不破坏已生效源、零可用源回退、重复导入注销旧源） |
| DLNA 投屏 `dart run tooling/verify_dlna_cast.dart` | ✅ **61/61 断言通过**（真实 UDP SSDP 应答 + 每台设备一个 HttpServer：多设备发现与去重、设备数上限、M-SEARCH 重发、公网/非 http/内联凭据/未知域名/跨 origin controlURL 全部拒绝、描述超限与非法 UTF-8、SOAP 序列与 XML 转义、SetAVTransportURI Fault、Seek 退化重试、`RelTime` 解析与 `NOT_IMPLEMENTED`、应答超限、设备不响应超时；端到端：投屏成功、掉线降级进度不倒退、全设备不可用降级） |
| 文件导入 `dart run tooling/verify_source_config_file.dart` | ✅ **84/84 断言通过**（真实临时文件：BOM/CRLF/编码/体积/目录/符号链接/远程路径；免责门禁零 IO、失败不破坏已有源、导入后真实 HTTP 可播、重启恢复到最后一次落盘版本） |
| 导出备份 `dart run tooling/verify_source_config_export.dart` | ✅ **46/46 断言通过**（默认不覆盖已有文件、覆盖原子换名无残留、父目录不自动创建、**导出→导入往返一致**且备份恢复后真实可播） |
| 跨主机 `dart run tooling/verify_cross_origin.dart` | ✅ **63/63 断言通过**（三台独立端口站点：跨主机取址/每跳重定向白名单/凭据头隔离/净化落盘与恢复/源级优先级稳定排序） |
| 播放进度 `dart run tooling/verify_progress.dart` | ✅ **102/102 断言通过**（内容坐标换算、节流三阈值、慢盘并发合并、换源 epoch 护栏、写失败重试与降级、真实 JSON 落盘、跨端同步联动、编排层三条路径、**片尾判定/已看完标记/换集重读时长**） |
| 自动连播 `dart run tooling/verify_queue.dart` | ✅ **28/28 断言通过**（剧集表排序去重、迟到事件丢弃、最后一集不重播、开关真能关、当前源缺集换源、平台裁剪、并发重复触发去重、detach 后不推进） |
| 投屏双模式 `dart run tooling/verify_cast_dual_mode.dart` | ✅ **117/117 断言通过**（模式判定与记忆、真实 socket 中继：无 Referer 返 403 的源站经中继可播放、播放列表全量改写后分片可达、直推→5s 未出图→改串流、唯一兜底） |
| 手机端 `dart run tooling/verify_mobile_layout.dart` | ✅ **82/82 断言通过**（方向策略：手机播放不锁横屏/仅全屏锁横屏/电视恒横屏；5 款真机尺寸下视频高度不超 16:9、不超半屏、列表恒 ≥132px；触摸常驻手柄/频道弹层/上下滑换台接线） |
| 直播投屏 `dart run tooling/verify_live_cast.dart` | ✅ **60/60 断言通过**（换台重下发状态机：连按后发先至、换源站必须重启中继、直推↔串流双向退回、非法地址一律不下发、结束投屏后不再下发） |
| **一条命令全量** `dart run tooling/verify_all.dart` | ✅ **27 个步骤全通过，断言 1942/1942**（analyze + 二十六套回归 + Python 原型，109.5s；任一步失败即退出码 1） |
| **Android APK 构建** `flutter build apk --release` | ✅ **成功**：compileSdk/targetSdk 36、minSdk 24；APK 内已确认五项权限与 `shunbo/mpv` 通道名 |
| **Windows 构建** `flutter build windows --release` | ✅ **成功**：产出 `build/windows/x64/runner/Release/`（含随包 `mpv-2.dll`、`d3dcompiler_47.dll`、`libEGL/libGLESv2`），安装包见「安装包」章节 |
| 门禁自检 `dart run tooling/verify_all.dart --selftest` | ✅ **6/6**（验证「静默跳过 / FAIL 却退出 0 / 非零退出码」都会被判失败，不会被误放行） |
| `flutter test` | ⚠️ 受限：本 Windows 镜像 `flutter_tester` 无法建立握手（WebSocketException），与代码无关 |

### 关于 `flutter test` 受限的说明
`flutter test` 运行器需启动 `flutter_tester` 子进程并与之做本地 WebSocket 通信，
而当前 Windows 沙箱镜像中 `flutter_tester` 进程握手失败（已排除沙箱 loopback 因素——
**禁用沙箱后仍同样失败**，故为镜像缺失运行时不完整所致）。

**应对**：纯逻辑层（`lib/core/`）的验证统一用 `dart run tooling/verify_logic.dart`，
该脚本复刻了 `test/*.dart` 的全部断言，单进程执行、不依赖 `flutter_tester`。
原生通道这类「只在运行时才对得上」的契约，则用 `verify_channel_contract.dart` 做文本级核对
（通道名/方法名/事件名/指标键逐条比对），把能静态发现的那类错提前到提交前。
涉及 UI 行为与真机指标的测试仍需具备设备的环境或 CI 运行。

## 门禁设计（为什么不是「跑一遍打印绿字」）

`tooling/verify_all.dart` 是本项目唯一的判定入口，CI 与本地都用它。三个刻意的设计：

1. **不 fail-fast**：一步失败也跑完其余步骤，一次看到全部缺口（与各回归脚本的收集式断言一致）。
   只看第一条报错往往会误判影响面。
2. **防静默假成功**：声明「应有断言」的步骤若**退出码 0 却没报告断言数**，判为失败 ——
   脚本被改坏、提前 `return`、断言被注释掉时不会悄悄变绿；输出里出现 `FAIL` 但退出码 0 同样判失败。
3. **清单只有一份**：CI 不再逐条列 `dart run`，直接调用本脚本。此前 CI 与本地命令各维护一套，
   新增回归脚本时极易只改一处，出现「CI 全绿、本地少跑几条」的偏差。

`--selftest` 用临时目录里的合成子进程反向验证上述判定（静默通过/FAIL 但退出 0/非零退出码/
正常脚本/另一种汇总格式），证明这个门禁脚本本身不是摆设。

## 常用命令
```bash
export PATH="$PATH:/d/flutter/bin"   # 当前 shell 临时加入 Flutter
cd /e/TV/shunbo
flutter pub get                      # 安装依赖（已缓存）
dart run tooling/verify_all.dart     # ★ 全部门禁一次跑完（analyze + 二十六套回归 + Python，1942 项）
dart run tooling/verify_all.dart -v  # 同上，实时流式打印子进程日志
dart run tooling/verify_all.dart --only=cross,export   # 只跑指定步骤（名字子串匹配）
dart run tooling/verify_all.dart --skip=analyze        # 跳过某步
flutter analyze                     # 单独静态分析（已含在 verify_all 第一步）
dart run tooling/verify_logic.dart   # 核心逻辑实跑验证（169 项断言，自动计数）
dart run tooling/verify_live_http.dart  # 真实 HTTP 端到端回归（43 项断言）
dart run tooling/verify_source_config.dart  # 配置驱动多源真实回归（47 项断言）
dart run tooling/verify_channel_contract.dart # Dart↔原生通道契约静态核对（19 项断言）
dart run tooling/verify_onboarding_import.dart # 导入全流程真实回归（60 项断言）
dart run tooling/verify_progress.dart # 播放中进度落盘 + 片尾判定回归（102 项断言）
dart run tooling/verify_queue.dart   # 自动连播回归（28 项断言）
dart run tooling/verify_source_config_file.dart # 从文件导入真实回归（84 项断言）
dart run tooling/verify_source_config_export.dart # 导出/备份往返真实回归（46 项断言）
dart run tooling/verify_cross_origin.dart # 跨主机取数 / 源级优先级真实回归（63 项断言）
dart run tooling/serve_fixture_site.dart legacy  # 常驻本地样本站点（默认端口 56782）
flutter test                        # 本机 flutter_tester 握手失败，须在 CI/完整环境运行

# ---- Android 构建（本机已可用）----
export ANDROID_HOME=/d/Android/android-sdk
export JAVA_HOME=/d/Android/openjdk/jdk-17.0.12
# 国内必需的两个镜像：官方 storage.googleapis.com 实测 68KB/s、plugins.gradle.org 4KB/s，
# 不开镜像时构建会卡在「下载依赖」十几分钟且毫无输出。
export FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn
export PUB_HOSTED_URL=https://pub.flutter-io.cn
flutter build apk --debug           # 产物 build/app/outputs/flutter-apk/app-debug.apk
flutter build apk --release         # 发布包（当前用 debug 签名，见 android/app/build.gradle.kts）
```

### 换机器时 Android 构建的四个坑（都实际踩过）
1. **SDK 版本**：Flutter 3.47.9 要求 Android SDK **36**，只有 34/35 会直接报
   `Flutter requires Android SDK 36`。补装：`sdkmanager "platforms;android-36"`。
2. **三处镜像缺一不可**，否则表现为「构建十几分钟无任何输出」（不是报错，是卡住）：
   | 卡点 | 官方源实测 | 改用 |
   |---|---|---|
   | Gradle 发行版 | services.gradle.org 46KB/s | 腾讯 `mirrors.cloud.tencent.com/gradle`（8.5MB/s，改 `gradle-wrapper.properties`） |
   | Maven 依赖/插件 | repo1 139KB/s、plugins.gradle.org 4KB/s | 阿里 `maven.aliyun.com/repository/{public,google,gradle-plugin}`（7.4MB/s，改 `settings.gradle.kts`/`build.gradle.kts`） |
   | Flutter 引擎 jar | storage.googleapis.com 68KB/s | `FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn`（8.7MB/s） |
3. **`flutter create` 会顺手改坏两处**：重写 `analysis_options.yaml` 去 include 未安装的
   `flutter_lints`（analyze 立刻红），以及生成引用 `MyApp` 的 `test/widget_test.dart`（本项目入口不叫这个）。
   两处都要恢复，否则「只是生成骨架」也会让门禁失败。
4. **`build-tools` 会被自动补装**：AGP 会自己下 `build-tools;36.0.0` 并写 `licenses/`，
   首次点击「运行」时若断网就会卡在这一步 —— 表现为无输出，不是编译错误。

## 安装包（Windows / Android）

两个产物都由仓库内脚本产出，不依赖手工操作：

```bash
# ---- Windows x64（Inno Setup，per-user 安装，不弹 UAC）----
bash tooling/fetch_windows_kits.sh          # ① 预取 libmpv + ANGLE（镜像 + 断点续传 + md5 校验）
flutter build windows --release             # ② 产出 build/windows/x64/runner/Release/
"/c/Program Files (x86)/Inno Setup 6/ISCC.exe" tooling/windows_installer.iss
# 产物：shunbo/dist/Shunbo-Setup-0.1.0-x64.exe（≈23.8 MiB）

# ---- Android ----
flutter build apk --release
# 产物：build/app/outputs/flutter-apk/app-release.apk（≈50.3 MiB，三 ABI，debug 签名，侧载用）
# 已另拷一份到 shunbo/dist/Shunbo-0.1.0-universal.apk，两个包同处交付
```

两个包都做过实装闭环：Windows 静默安装 → 启动（窗口标题 `顺播 shunbo`）→ 静默卸载；
APK 用 `aapt2 dump badging` 核验包名/minSdk/label/权限/ABI。详见 `CHECKLIST.md` 第 5.1 节。

> 别用 Git Bash 直接跑安装包：MSYS 会把 `/VERYSILENT` 改写成 `C:/Program Files/Git/VERYSILENT`，
> 安装器正常退出（exit 0）却没装任何东西。用 PowerShell `Start-Process` 传参，或设
> `MSYS2_ARG_CONV_EXCL='*'`。

### Windows 侧的三个前置条件（不是「点一下就好」）

1. **VS 2022 生成工具必须带 `VC.CMake.Project`**。Flutter 的检测逻辑是
   `vswhere -latest -requires VC.Tools.x86.x64 VC.CMake.Project`，两个组件**在同一个实例上**才放行。
   本机原来只有 MSVC、没有 CMake，表现为 `Unable to find suitable Visual Studio toolchain`。
   补装：`vs_installer.exe modify --installPath "<BuildTools 路径>" --add Microsoft.VisualStudio.Component.VC.CMake.Project --quiet`。
2. **libmpv / ANGLE 走仓库脚本预取**。`media_kit_libs_windows_video` 在 CMake configure 阶段用
   `file(DOWNLOAD github.com/...)`，国内网络下会拿到 0 字节文件并报
   `Integrity check failed`（它只在 md5 不匹配时重下，且不带重试）。
   `fetch_windows_kits.sh` 用可用镜像（默认 `ghproxy.imciel.com`，可 `SHUNBO_GH_MIRROR=` 覆盖）
   + 断点续传把包放到 CMake 期望的位置并校验 md5。
3. **不要开 Kotlin 增量编译**（`android/gradle.properties` 已关）：本机会在插件模块报
   `Could not close incremental caches ... class-fq-name-to-source.tab`，全量编译则稳定通过。
4. **`windows/runner/*.cpp` 保持纯 ASCII**：Flutter 的 runner 工程开了 `/WX`，而 MSVC 按本地代码页
   (936) 解析源码，文件里出现 UTF-8 中文会先报 `warning C4819`，随即变成
   `error C2220: 以下警告被视为错误`。中文窗口标题要写成宽字符转义
   （`window.Create(L"\u987A\u64AD shunbo", ...)`，即「顺播 shunbo」），注释也别写中文；
   否则需给文件加 BOM 或给工程加 `/utf-8`。

### 数据与卸载

- 桌面数据目录：`%LOCALAPPDATA%\Shunbo`（`resume.json` / `config.json` / `sync-snapshot.json` / `diagnostics.jsonl`）。
- Android 数据目录：应用私有缓存（卸载即清）。
- 卸载不删数据目录，「继续观看」重装后仍在；要彻底清空需手动删。

## 源配置导入（用户可用路径）

配置能力不再只存在于回归脚本里，App 内可直接完成：

1. 启动样本站点：`dart run tooling/serve_fixture_site.dart legacy`
   （默认 `127.0.0.1:56782`，被占用时自动随机端口；终端会打印一份可粘贴的 JSON 配置）。
2. 启动 App，在引导卡片「导入源配置」或右上角拼图图标打开导入框；
   点「填入本地示例」自动填入**同一份**配置（也可粘贴第 1 步打印的 JSON）。
3. 点「校验并导入」→ 展示结果、被拒条目明细、已生效源 id；搜索页常驻状态条显示当前外部源。
4. 也可以把配置存成本地 `.json` 文件，在导入框「配置文件路径」里填入路径后点「从文件导入」；
   成功后编辑框会回填**净化后**的配置，便于继续查看或微调。
5. 想直接分享一个配置链接：在「配置链接」里填入 **https** 地址后点「从链接导入」
   （本机 `http://127.0.0.1:端口/...` 也放行，便于自测；其余 http 一律拒绝）。
6. 想把当前配置备份/迁到另一台设备：在同一个路径框里填目标路径，点「导出到该路径」。
   默认**不覆盖**已有文件；确实要覆盖时先勾选「允许覆盖已有文件」。导出的是当前**已生效**
   的净化配置，不含编辑框草稿；把导出的文件拷到另一台设备，用第 4 步导入即可。
7. 重启 App：净化配置自动回读并重新注册，引导不会重复出现，源仍可搜可播。

安全与一致性约束（`source_import_service.dart`）：

- **未接受免责声明一律拒绝**，包括「跳过引导」的用户；导入框内提供补签入口，补签前导入按钮禁用。
- 逐条隔离：坏配置被拒绝并列出索引/原因，不影响同份配置里的好源；**零可用源即整体失败**，
  不注册、不落盘、不推进引导，也不会破坏上一次已生效的配置。
- 落盘的是**净化后配置**（只含通过校验的源），危险字段不会在重启时复活；
  与内置源同名的 id 一律拒绝，防止外部配置篡改 `SourceCatalog` 换源画像。
- 重复导入先注销旧源并关闭连接池；写盘降级为内存态时如实提示「重启后需重新导入」——
  此时重启恢复的是**最后一次成功落盘**的配置，内存态的新源不会被悄悄复活。
- `jar` / `quickjs` 后端不提供 UI 授权开关，Dart 侧永不构造代码执行面。
- 从文件导入与粘贴导入共用**同一条** `importFromText` 净化链路，唯一差别是前面多一层本地 IO；
  **免责声明门禁在读文件之前**，未接受声明时连一次文件读取都不会发生。
- 从链接导入同样共用该链路，且**免责声明门禁在网络请求之前**——未接受声明时一次请求都不发，
  不会替用户向内网/任意地址发起访问；下载失败不影响已生效的源。

### 导入 / 导出的文件边界（`source_config_file.dart`）

| 处理 | 原因 |
|---|---|
| 剥离成对引号 / 首尾空白、支持 `file://` 本地 URI | Windows「复制文件路径」与选择器返回 URI 的常见形态 |
| 剥离 UTF-8 BOM（含重复 BOM），容忍 CRLF | 记事本保存的配置文件否则会被 `jsonDecode` 直接判为坏 JSON |
| 先 `stat` 体积再读字节（上限 256 KB），读后二次校验 | 防超大文件把内存放大；TOCTOU 下文件被追加也能挡住 |
| 拒绝目录、符号链接（不跟随）、NUL 字节、非 UTF-8 | 只把可解析的纯文本交给解析器，失败给可读原因而非裸异常 |
| 拒绝 `file://host/...` 与 UNC 网络路径 | 「从文件导入」必须保持纯本地，不能让一次读文件变成 SMB 请求 |
| 只回显文件名，不回显完整本机路径 | 避免把用户目录结构带进界面/日志 |
| 导出**默认不覆盖**已有文件，覆盖时先备份再原子换名、失败回滚 | 备份文件一旦被半截写入就失去意义；也不该悄悄盖掉用户自己放的同名文件 |
| 导出**不创建父目录** | 路径填错应该报错，而不是在磁盘上默默长出一串目录 |
| 导入与导出共用同一套路径规则（同一份 `_checkPath`） | 两处各写一份迟早漂移，而这类漂移就是漏洞 |

> 当前为**路径输入框**（零第三方插件，桌面端可用）。系统文件选择对话框需要 `file_picker`
> 类插件或平台通道；TV 端遥控器输入路径体验较差，二者都留待完整工具链阶段处理。

> 本机限制：`flutter run -d windows` 需要完整 Windows 桌面工具链（含 VS 运行时），当前镜像不具备；
> **Android 侧已可真实构建**（`flutter build apk --debug` 成功），只是没有设备可跑。
> 桌面 UI 仍只到 `flutter analyze` 类型校验。导入框产出的示例、服务编排与真实 HTTP 链路
> 已由 `verify_onboarding_import.dart` 端到端覆盖，且演示服务四个端点已用 curl 实测。

### 导入 / 下载的链接边界（`source_config_url.dart`）

| 处理 | 原因 |
|---|---|
| 仅 https；`http` 只对 loopback 放开 | 配置决定「去哪里取内容」，明文传输可被任意替换；loopback 仅用于本地自测 |
| 拒绝 URL 内联凭据（`user:pw@host`） | 会被原样写进日志、剪贴板与分享链接，比不加密更危险 |
| 逐跳复检重定向，且必须同主机同端口；禁 https→http；上限 2 次 | 跨主机跳转等于把「用户指定的来源」偷偷换掉 |
| 256 KB 流式上限，超限立即中断 | 不先读进内存再判断，否则「上限」只是事后安慰 |
| 拒 NUL 字节、拒非法 UTF-8、拒空响应 | 配置文件是纯文本 JSON；混进二进制说明来源根本不是配置 |
| 单次总超时（连接+响应头+读体共用预算） | 慢速灌包不能挂住引导流程 |
| 结果只回显 `host:port`，绝不回显完整 URL | query 里常带私有 token，回显即泄漏 |
| 免责声明门禁在网络请求之前 | 未接受声明时一次请求都不发，不替用户向内网/任意地址发起访问 |
| 下载成功 ≠ 可信：文本仍走 `importFromText` 全量净化 | 「网络通」与「内容安全」是两件事，后者只由 E9 白名单负责 |

## 跨主机取数（allowedOrigins）与源级优先级

真实站点很少把所有页面放在同一个主机：搜索 API、详情页、播放页常分属不同域名。
此前 `DartHttpFetcher` 虽有 `allowedOrigins` 参数，但配置层从不传，运行期只认 `baseUrl` 自身；
E9 白名单里的 `qualityRank` 也一直没人消费。两者现均已闭合。

配置示例（在单源配置里追加两个字段）：

```json
{
  "id": "src-a",
  "baseUrl": "https://www.example.com",
  "allowedOrigins": ["https://api.example.com", "https://cdn.example.com"],
  "qualityRank": 80
}
```

**`allowedOrigins` 安全模型**：限制的不是配置作者（他本来就能填任意 `baseUrl`），而是
**运行期站点响应**——详情页返回的绝对取址页、302 的 `Location` 只能落在事先声明的 origin 内，
防止源站被劫持后把 App 导向任意主机（SSRF / 内网探测）。

- 默认拒绝：不声明就只放行 `baseUrl` 自身；最多 8 个额外 origin。
- 按**整个 origin** 授权：必须为 http/https 绝对地址，禁通配符、路径、查询串、片段、userinfo、空白。
- 每跳独立校验：手工跟随重定向，302 落到未声明 origin 立即拒绝，不给「自动跟随绕过白名单」的机会。
- 协议不降级：`https` 主站不得授权 `http` 附加源站。
- **跨 origin 凭据隔离**（本轮最关键的一条）：配置为 baseUrl 定制的 `Cookie` / `Authorization` /
  `X-Api-Key` / `Referer` 绝不会发给另一个主机；跨主机只放行 `User-Agent` / `Accept` /
  `Accept-Language` 三个与身份无关的头。否则允许跨主机本身就会变成凭据外泄通道。

**`qualityRank`**：源级优先级（0..100 整数，默认 0），越大在多源聚合结果里排越前，
`SearchHit.qualityRank` 会带到 UI。与 `PlayUrl.qualityRank`（同一源内多个播放地址的清晰度择优）
是两层不同语义。排序实现显式带原序号做**稳定排序**，未配置该字段时聚合顺序与原来完全一致。

`tooling/verify_cross_origin.dart` 用三个独立端口的样本站点（主站 / CDN / 未授权外部站）做真实
socket 验证：声明后跨主机取址→择优→播放器载入→真实 GET m3u8 全通；未声明被拒且**目标主机零请求**；
跨主机重定向每跳校验；主站确实收到凭据头而 CDN 完全没有；坏字段逐条隔离；净化配置落盘后重启
恢复仍保留白名单与优先级；63/63 断言通过。

## 直播选源：记忆、探测与失效（2026-11-06）

> 直接对应两个用户可见症状：「央视/卫视点不开」与「每次切回同一个台都要重新检索」。

### 1. 每频道的线路记忆（`preferred_stream.dart` + `preferred_stream_store.dart`）

落盘文件 `live-preferred.json`（原子写：`.tmp` → `.bak` → 换名），记录 `频道 id → 线路地址 + 时间`。
**写入点只有一个**：某条线路真的出了画面（`pos > 0.2` 或首帧到达）才算成功，且立刻强制落盘
——用户常常「看两秒就退出」，5 秒节流会把最有价值的那次记录丢掉。

命中后的行为是**直达**，不是「优先一点」：

* 该线路被移到尝试队列第一位；
* **完全跳过探测**（连 1.2 秒的短探测也不做），直接 `player.load`；
* 源站需要 `Referer` / `User-Agent` 时，用的仍是当前频道表里这条线路自己声明的请求头。

### 2. 记忆什么时候失效 / 更新

| 触发 | 处理 | 为什么 |
|---|---|---|
| 该频道任一条线路真的出画面 | **覆盖**为那条线路 | 永远保留最近一次成功的事实 |
| 记录的地址已不在该频道线路表里 | **作废**并落盘 | 源站换 token / 换路径 / 换镜像后，旧地址既不能播也不该一直占位 |
| 用记录里的地址起播失败 | **作废**并落盘 | 只 `markDead` 不够：失效表 10 分钟就过期，之后每次切回又会先试这条已证明播不了的线 |
| 本会话内该地址已被判失效 | **不前置**，走正常排序 | 记忆不该压过「刚刚试过打不开」这个更新的事实 |
| 超过 7 天 | 过期 | 公开源生命周期以周计；有上面三条自愈，长 TTL 不会把用户钉在死链上 |
| 频道 id 变化（改名 / 合并） | 自然失效 | 记忆以 id 为键，不做跨 id 猜测 |

7 天而不是 24 小时：记忆已经有三重自愈（不在表 → 作废、起播失败 → 作废、判死 → 不前置），
短 TTL 只会惩罚正常用户——隔一天回来看同一个台，又要重新检索一遍。

### 3. 探测的语义：**「探测没通过」不等于「播不了」**

`LiveCatalogService.probe` 只回答「2 秒内有没有回包」，它不能证明码流可解码。旧实现把
探测失败当作终态（`markDead` + `return false`），**`player.load` 根本不会被调用**。

实测（`tooling/diag_live_sources.dart`，119 条央视/卫视线路，每条「裸探两次 → 带头一次」）：

| 结论 | 条数 |
|---|---|
| 裸探一次即成功 | 30 |
| 首次失败、**重试成功**（瞬时抖动，与请求头无关） | 12 |
| 两次裸探都失败、带线路声明的头才成功 | **0** |
| 三次都失败（真死链 / 网络不可达） | 77 |

即约 10% 的线路是「慢但能播」（成功耗时 2.0~4.7 秒），而旧探测超时只有 1.2 秒——它们全被判死。
现在的规则：

* 探测超时提到 **3.5 秒**（第二轮提的，见 §6：能播的央视线路首字节实测 1.5~5.1 秒）；
* 探测失败**不再判死**，仍交给内核尝试，只把首帧耐心压到 **12 秒**（可疑主机 6 秒）；
* 真正的死活由内核终态错误（`Failed to open`，通常 1~3 秒）+ 首帧轮询裁决。

### 4. 主机连坐：单条失败不再拉黑整站

`DeadStreamRegistry` 原先「一条线路失败 → 整个主机 10 分钟不试」。结合上面 10% 的抖动率，
一次抖动就会把同一镜像上本来能播的台一起拖下水（用户看到的是「好几个台同时点不开」）。
现在需要**同一主机累计 3 条独立线路失败**才判死整站；整站真死时首屏一轮并发 6~8 条，
同一轮内就能累积到阈值，收敛速度几乎不变。

> 阈值从 2 提到 3 是第二轮的事故修复，原因见 §6：一个主机承载 13 个央视台时，
> 阈值 2 等于「用户随便撞两次就整组央视判死」。

两条配套规则（缺一条都会退回事故状态）：

* **成功可以解除连坐**（`noteSuccess`）：只记失败不记成功，一次抖动留下的封禁会在 10 分钟里
  继续压住同一主机上**已经恢复**的台。某条线路真的出画面时，同时撤掉它的地址失效记录和主机封禁。
* **连坐只影响排序，不影响候选资格**：`isDeadUrl`（这条地址刚真的打不开）才取消候选资格；
  `isDeadHost`（这个镜像好像不稳）只把线路挪到最后。混用会导致「13 个台同时没有候选」。

同时 `tune` 与看门狗换线都会**跳过已判定失效的地址**：它们 10 分钟内不会自己变好，
逐条重试只会让用户盯着黑屏一条一条等。整台全部判死时只试第一条（验证是否恢复）。

另加**整台起播总预算 30 秒**（`tuneBudget`）：央视补强后单台可达 10 条线路，
若逐条都等满 12 秒，最坏是两分钟黑屏——比直接说「本台线路都不通」更糟。

顺带修掉一个同源缺陷：探测请求原先只带 `shunbo/1.0`，而播放带线路声明的 `Referer`。
本轮实测里它还**没有**造成误判（0 例），但只要源站开始校验防盗链就会立刻变成「能搜到、一播 403」。
现在探测与播放共用 `applyStreamHeaders`：只放行 `User-Agent` / `Referer` / `Origin` / `Cookie` /
`Authorization`，含 CR/LF 的整条丢弃，`Host` / `Range` 这类传输层字段一律不转发
（远端 M3U 是不可信输入，改 `Host` 等于把请求打到别的虚拟主机）。

### 5. 央视频道整批不可播：根因与修复（2026-11-06 第二轮）

用户反馈「央视频道都不能播放」。用 `tooling/diag_cctv.dart` 把频道表拉下来逐条探测，
结论是**三个原因叠加**，其中两个是代码缺陷、一个是源生态：

**原因 A（代码）：探测器比源还急。** 能播的央视线路首字节实测落在
1.5 / 1.9 / 2.2 / 2.5 / 2.9 / 4.5 / 5.1 秒；而链路里有两把更短的尺子：
首屏批探 3 秒、起播前单探 2 秒。于是一批「慢但能播」的源被量成死链。

**原因 B（代码，最致命）：一个主机承载了 13 个央视台，两次抖动就整组判死。**
主索引 iptv-org `cn.m3u` 里 CCTV-1/2/3/7/8/10/11/12/14/16/17 的线路**全部**指向
`74.91.26.218:82`。`DeadStreamRegistry` 的主机连坐阈值是 2，而
`_firstCandidate` 用的是含连坐的 `isDead` —— 用户只要在任意两个央视台上各撞一次超时，
这个主机就被封禁 10 分钟，**其余 11 个央视台同时变成「一条候选都没有」**，
`hasLiveStream` 为 false，自动切台把整组央视跳过。界面表现就是「央视频道全都不能播」。

**原因 C（代码）：唯一一份每日测速的聚合表被 scope 裁掉了央视条目。**
适配器把 Guovin `result.m3u` 按 `cityOnly` 收窄（只收城市台），而这份表里
89 条央视线路中有 30 条从本机可达、覆盖 CCTV-2/4/5/5+/6/7/8/9/10/11/12/13/14/15/16/17。
也就是说：**能救场的备份线路一直被主动丢弃**。

**原因 D（源生态，改不了）：** 央视剩余线路分布在 `69.30.245.50`、
`198.204.240.250`、`192.151.150.154`、`38.75.136.137`、`204.12.221.218` 等境外中转 IP，
以及 `101.35.240.114:88`（要求 `AptvPlayer-UA`，且返回非标准状态码 660）。
它们**本身就是不稳的**，任何「永久可播」的承诺都站不住。

修复内容：

| 位置 | 改动 |
|---|---|
| `live_source_descriptor.dart` | 新增 `LiveSourceScope.nationalOnly`：只收央视（CCTV/CGTN/CETV）+ 卫视，忽略 `group-title`（只信台名，防展示分组骗人） |
| `live_catalog.dart` | `parseM3U` / `parseNameUrl` 支持 `nationalOnly`；`kDefaultDiscoverySources` 增加 Guovin `result.m3u` 两条镜像（`channelLimit: 400`） |
| `live_selection.dart` | 连坐阈值 2→3；新增 `noteSuccess`；`_firstCandidate` 改用 `isDeadUrl`（连坐不再取消候选资格） |
| `live_controller.dart` | 单探 2s→3.5s；首帧耐心 8s→12s（可疑主机 6s）；整台总预算 30s；成功时调 `noteSuccess`；`alive` 过滤改用 `isDeadUrl` |

效果（`tooling/diag_cctv.dart`，同一网络、同一时段）：

| 指标 | 修复前 | 修复后 |
|---|---|---|
| 央视类频道线路总数 | 112 | **224** |
| CCTV-5 线路数 | 2（均不可达） | 10 |
| CCTV-13 / 15 / 5+ 线路数 | 4 / 3 / 3 | 8 / 10 / 10 |
| CCTV-4 线路数 | 1（固定失败） | 6 |
| CCTV-1..17 中有至少一条可达线路 | 11 | **16** |

仍不可播：**CCTV-8K**（官方 8K 组不对外，公开源也没有可用流）、
`CCTV+ 1/2` 等付费点播台。这一段的结论已被下一节取代 —— 央视现在走官方线路。

上一轮的结论（「再加几个公开源并不能解决」）在这里被修正了一半：**加源确实没用**
（Guovin 的卫视/城市部分与 iptv-org 指向同一批 IP），但把它按 `nationalOnly` 收窄后
并入**是有用的**——它给的央视线路恰好是另一批主机。

### 6. 央视官方线路逆向：拿到了地址，但流是加密的（2026-11-06 第三轮）

上一节修完仍有一个悬着的问题：我这边能出画面的台，在用户电视网络上不一定行。
所以这一轮直接去拿**央视自己的流**，结论是**拿到了地址、但播不了**，
过程与判据都必须记下来，否则下一个人还会走一遍。

**入口**：`tv.cctv.com/live/cctv1/` 加载的 `js.player.cntv.cn/creator/liveplayer.js`（混淆过）。
做法是把「串表 `a0_0x224f` + 解码函数 `a0_0x4c09` + 首段自转 IIFE」切出来在 `node:vm` 里跑，
按下标 `arr[n-0x14a]` 取字符串。注意**必须先跑自转**，否则整张串表错位（拿到的是别人的字符串）。

拿到两类关键常量：

* 配置地址 `api.live.cntv.cn/livestatic/zs/livestatic_config/pcweb/1001/unity_pcweb.json`
* 该文件是 **AES-256-CBC**，key / iv 以 Base64 字面量写在脚本里：
  key `JMo0DT+7XkLZcT1KE1Nv8rOXwxDc7UmOB7eVzx11MvU=`、iv `I6JulGGNroT8GVjO56ss6A==`
  （iPad 分支另有一组 key + iv；`1002` 版本用这两组都 bad decrypt）
  **坑**：iv 用错时 CBC 只有**第一块**是乱码，后面全对 —— 很容易误以为「已经解开了」。

解密后 `live_policy[]` 是 23 组地址模板，形态为
`https://<组主机>/<组前缀>/cdrmld<频道标识>_1/index.m3u8?b=<码率区间>`，
其中**前缀按组不同**：`ldncctvwbcd`(1/13) / `ldcctvwbcd`(5/16/5+) /
`ldocctvwbcd`(2/3/4/6~12/14/15/17) / `l14cctvwbcd`(4K，文件名 `wl14`)，且必须带 `?b=200-3200`。

**为什么会「看起来全通」**：这个 CDN 对**任意**频道名都生成一条合法的 master 清单
（`cctv999` 也 200），变体清单也正常，分片首字节同样是 `0x47`，SPS 还能解析出
`67 64 01 28`（High / L4.0）。换句话说：HTTP 200、EXTINF、TS 同步字节这三层**全部通过**。

**真相要用解码器才看得见**。用 libmpv 播 4 秒、经 `mpv_request_log_messages` 抓日志：

```text
[ffmpeg/video] h264: error while decoding MB 24 0, bytestream 13923
[ffmpeg/video] h264: Reference 3 >= 3
```

`cdrm` 就是 CCTV DRM：切片载荷加密，TS 结构完好。三条变体（td/ud/hd）分别报 124/115/113 次，
4K 组（`hls_nd_4k`，名字里带 nd）同样 103 次 —— 整族都不可播。播放器会「有画面」，
但画面是满屏色块；首帧检测照样通过，用户看到的就是花屏。

所以这一版**没有采用**官方线路（写完又全部回退），保留的是判据工具：

```bash
dart run tooling/scan_live_decode.dart --url <地址>        # 单条：能不能真播
dart run tooling/scan_live_decode.dart --group 央视频道 --per 3
```

它的判定不是 200、不是 EXTINF，而是「解码链建成 + 解码器零报错」，并会打出
实际分辨率。加密流会被判 FAIL 并给出报错次数与首条报错原文。

**已验证能播的公开镜像**（同一台机器、同一时段，解码零错误）：
`192.151.150.154`（CCTV-2，1280×720）、`107.150.60.122`（CCTV-5，1920×1080）——
它们是「境外中转 IP」里少数真的能解的，与其按地域一刀切拉黑，不如按**解码结果**排序。
下一步如果要继续做央视，方向是在起播阶段接入这个判据（解 2~3 秒无错才认这条线路），
而不是再去找「更多地址」。

### 7. 内置实测清单：把「能播」变成默认（2026-11-07）

上一节只解决了**判据**，没解决**首屏**。首屏依赖的远方索引对 CCTV 给的多是境外中转 IP，
抽风时整批归零——用户看到的就是「央视一个台都放不出来」，而他手上没有任何可操作项。

所以这轮把「验证过的线路」直接**编译进包里**，变成内置清单：

| 环节 | 工具 | 数字 |
|---|---|---|
| 源表 | 昭昭TV `kds_common.txt`（7270 条 / 3083 台） | 2494 条明文线路 |
| ① HTTP 层并发探测 | `tooling/probe_all.py` | 624 条返回合法 m3u8 |
| ② libmpv 解码（8s×6 并发） | `tooling/scan_batch_decode.dart` | 487 条零解码错误 |
| ③ 失败项复检（14s×3 并发） | 同上，输入换成 `decode_fail.json` | 再捞回 30 条（多为 1080p） |
| ④ 生成常量 | `tooling/gen_verified_channels.dart` | **440 个台 / 515 条线路** |

清单落在 `lib/features/live/verified_channels.g.dart`，由 `main.dart` 作为
`LiveCatalogService.builtIn` 的第二部分装载（第一部分是那条公开 HLS 演示信号，语义不同：它只用来
区分「信号源坏了」和「播放内核坏了」）。

**为什么编译成 Dart 常量而不是塞 assets**：纯 dart 回归（`dart run tooling/verify_*.dart`）
没有 `AssetBundle`，读不到 assets，内置清单就进不了回归；生成常量后 `verify_live_catalog`
可以直接断言「央视几个台、每条线路都带实测画质分、id 不与演示信号相撞」。

**几条必须守住的语义**（都已进回归）：

* 线路的 `qualityRank` 来自**实测分辨率**（`scan_batch_decode` 报的 w/h），不是台名里吹的 HD；
* id 走线上同一套 `channelIdFor`，所以远端索引里同名台的线路会**并进**这份内置台
  （`mergeChannels` 保留内置台名与分组，线路按画质并入），不会出现两个 CCTV-1；
* 只收 http/https，`headers` 不得含 `Host` / `Range`（改了等于把请求打到别的虚拟主机）；
* 文件头写死验证时间 `kVerifiedLiveAt`。**这份清单有保质期**：公开直播地址以周为单位腐烂，
  超过一个月必须重跑上面 ②③④，而不是继续信它。

实测时的两个反直觉点，记下来免得下次再判错：

* **失败项要复检**。第一轮 8s/6 并发的 137 条失败里，30 条在 14s/3 并发下正常出画面（16 条 1080p）。
  高并发 + 短窗口会把「慢但能播」判成死链 —— 与 §5 原因 A 是同一个错，只是换了层级。
* **央视那 13 个台里 11 个全指着同一个转播域 `play.kankanlive.com`**。单点依赖，
  但它现在确实是唯一一批「能解码」的央视公开线路；这份清单的价值正是把这个事实固化下来，
  而不是假装央视有更多选择。

### 8. 官方源解码接入与两阶段验证（2026-11-07）

第 7 节解决的是「有没有线路」，这一节解决的是「线路该是什么级别」。官方源定义为
**广电 / 持牌平台自有 CDN 的直连流**（`miguvideo.com`、`mgtv.com`、`cztv.com`、
`bestv.cn`、`sztv.com.cn`、`hebtv.com`、`kan0512.com` …），不是境外中转或第三方转播。

#### 实现（四层）

| 层 | 文件 | 作用 |
|---|---|---|
| 判据 | `decode_gate.dart` | mpv 日志分类 → `scrambled` / `format` / `network`；`DecodeGateBoard` 按身份 URL 记忆花屏（TTL 10min） |
| 内核 | `media_kit_player_controller.dart` | 实现 `DecodeFaultSource`，把解码加扰转成带「实际 load 地址」的事件 |
| 解析 | `official_sources.dart` | 起播前跟 302 换当次有效令牌；官方域白名单、跳数上限、禁 IP 终点、跨 origin 凭据隔离 |
| 编排 | `live_controller.dart` + `live_selection.dart` | 解析 → 透传 UA/Referer → 花屏时拉黑身份 URL、废偏好线路、自动换线；`_loadedUrl` 隔离迟到日志 |

`LiveStream` 新增 `decodeVerified`（离线实测过）与 `resolverUrl`（需运行时换令牌）；
排序为**花屏记忆 → 实测优先 → 画质优先**。身份键 `url` 与实际播放地址分离，
带 `txSecret` / `txTime` 的地址不会被硬编码进包。

#### 两阶段实测

工具 `tooling/measure_stability.dart`：55 条线路 × 3 轮 × 每条 6s、轮间隔 30s，
判据与 App 起播同为 `scan_batch_decode.probeDecode`（libmpv 建解码链 + 解码器零报错）。

| 同台同轮指标（6 个有官方源的卫视） | 官方直连 | 现有线路 |
|---|---:|---:|
| 成功率 | 83.3% (15/18) | **94.4%** (17/18) |
| 平均首帧 | **710 ms** | 3289 ms |
| P95 首帧 | **932 ms** | 5990 ms |
| 真 2160p 次数 | **6** | 0 |

**结论：官方源不是「整体更稳」，而是「快 4.6 倍 + 唯一真 4K」**。所以策略是
官方源优先起播、实测线路排前、花屏自动换线、现有线路兜底，而不是二选一。
内置 `official_satellite.g.dart` 为 12 个台 / 13 条线路，全部 `decodeVerified`，
8 条带 `resolverUrl`，7 条实测 3840×2160 线路（去重后是 5 个官方 4K 源：
浙江广电、芒果 TV、深圳广电、河北广电、苏州广电）。

阶段二 16 个 4K/8K 频道：5 个真 4K 通过、2 个仅 1080p、9 个未通过。
失败按 8 类归因：403 防盗链 / token 过期、`Location: 1` 占位、空 Location、
二级 `brtn.php` 404、反盗链提示片、中转超时 + IPTV 组播内网、CCTV `cdrm` 切片加密、
名义 4K 实为 1080p。详见 `../顺播_官方源解码接入与两阶段验证报告.md`。

#### 判据的边界（本轮新发现，别再踩）

`live.264788.xyz/channel/sichuanweishi4k` 三轮都被判「1920x1080 解码无错」，
但不跟随重定向的探针显示它 302 到
`static.tv.darwinchow.com/status/error_account_pirated.mp4`（7 MB 的**反盗链提示片**）。
**解码零错误只能证伪花屏，证不了「画面是不是这个台」**。已把两个主机加入
`kPlaceholderMediaHosts`，解析器对 `Location: 1` / 空 / 含 `pirated`、`/status/`
的跳转直接判失败并退回原线路，同时把该台从内置清单剔除。
`verify_decode_gate.dart` 用 11 项新增断言钉住这套语义。

黑屏、静帧、循环垫片这类内容级错误现已由 §10 的**离线帧级抽样判据**覆盖；
但错台、黑屏上只有台标、OCR 才能辨认的提示文字仍需帧级 OCR / 人工抽检。

### 9. 运营商电视通道：按网络可达性筛候选（2026-11-07）

依据《顺播_运营商电视通道研发方案.txt》R2。本户实测为**档位 C**：光猫是移动
H2-3、中兴路由「电视专网」开关关闭、魔百和走普通 LAN 口即 OTT 单播，
`192.168.5.0/24` 全网段无 4022 / 7088 端口 —— 没有 电视专网，也没有组播转单播。
因此**组播默认关闭、不部署任何硬件、安装包内不含一条运营商地址表**。

落地的是「按网络可达性筛选候选」的**共用框架**，三条通道共用同一张候选表、
同一套健康度与换源体系，通道只是准入与排序因子：

| 通道 | 进候选的条件 | 默认 |
|---|---|---|
| `public` | 恒进 | 全部既有线路 |
| `carrier_net` | 识别出的出口运营商与线路归属一致、且非蜂窝 | 不启用（未订阅） |
| `multicast` | 开关开启 + 网关合法 + 300ms 主机连通 + 1.5s 首包 | 关闭 |

关键实现：
- `channel_settings.dart` / `_store.dart`：组播开关、网关、手动覆盖、订阅地址、
  地址表版本与上一版回滚，走 `FileConfigStore.saveState` 原子写；老库读出默认
  「纯公网」，无需迁移。
- `carrier_detector.dart`：**三网自动识别**（14.8）。蜂窝零网络请求；Wi-Fi/有线请求
  一次公网 IP 归属服务（复用 `IpCityLocator` 的 pconline / ipinfo 端点），字段互相
  矛盾、服务不可用、复核不一致一律 `unknown`；按网络键缓存 1 小时，开机 / 回前台 /
  设置页「重新检测」失效重判。特征复核地址只从用户订阅清单取，**不内置**。
- `network_channel.dart`：`NetworkChannelPolicy` 做准入、5 分钟冷却、一键检测与
  诊断；`UdpxyRewriter` 把 `udp://` / `rtp://` 改成 HTTP 单播并保留 `rawAddr`，
  换网关端口时每次选源重新生成，无需重新导入（验收 5）。主机只放行私网 /
  loopback / `*.local`，组播地址只放行 224/4。
- `carrier_playlist_importer.dart`：m3u 与两列文本导入，复用 `parseM3U` /
  `parseNameUrl` 的台名归一与分组推断，不另写一套；组播清单没有有效组播地址时
  **明确报错**，不静默变成「导入成功但只有公网线路」。
- `live_channel.dart`：`LiveStream` 加 `channelType` / `carrier` / `rawAddr` /
  `transport`，默认值保证所有老数据仍是 `public`；`LiveChannel.hasMulticast` /
  `hasCarrierNet` 由线路实时汇总，不落库。
- `live_selection.dart` / `live_controller.dart`：`rankStreams` 等增加可选
  `policy` 参数，**传 null 时行为与接入前逐字节一致**；异网线路不进候选、不发起
  探测、不产生失败记录（N5）；公网线路失败仍归 `DeadStreamRegistry`，
  通道策略不接管 —— 少了这条边界，会把「整台判死仍留一条验证恢复」整个筛掉
  （本轮确实踩到并修回）。
- 设置页新增「网络与通道」分组；频道列表只对非公网台显示通道标签；仅组播台
  无专网时置灰不隐藏、点击给「需要 电视专网网络」提示。

验收：`verify_carrier_channel.dart` **231/231**（注入假归属服务 / 假网络 / 假时钟，
零真实外网请求；R2.1 补完三项后累计 275/275，见 §10.4），全量门禁 **32 步 / 2619 断言**，`flutter analyze` 0 issue。

**真机边界**：档位 A 的组播起播 ≤1.5s、Wi-Fi 切 4G 续播、低端路由并发、
第 3 天地址更新提示，只能在有 电视专网的环境验收，本轮不声称已实测。
Android ConnectivityManager 精确网络回调与订阅清单来源签名校验已在 §10 补完，
但真机切网时序、VPN 能力集差异、定制 ROM 回调权限仍未实测。
方案 R1 的 `link` 表字段与顺播实际数据结构的逐项映射见方案 R2 §5.2。

### 10. R2.1 补完：精确网络回调 / 来源可信度 / 内容级帧抽样（2026-11-07）

三件事同属「上一轮明确列为未做」的收尾，互不耦合，但共用同一条原则：
**拿不准就当不可用，绝不静默放行**。

#### 10.1 Android 精确网络回调

- `android/.../NetworkWatch.kt`：`registerNetworkCallback`（API 21；本包
  minSdk 24 用不了 API 26 的 `registerDefaultNetworkCallback`）观察默认网络；
  状态一律从 `activeNetwork` 现读，避免把 VPN 子网络当成主网络；回主线程投递，
  并按「传输类型 + 接口名 + 计费属性」做语义去重。
- **不申请定位权限**：Android 8+ 读 SSID 需要 `ACCESS_FINE_LOCATION`，为一个缓存键
  要这个权限不划算。离线 / VPN / 未知传输 → `NetworkChannelPolicy.suspend()`：
  识别结论与组播结论立即失效、**零归属探测请求**，网络回来后再重新识别。
- Dart 侧 `features/live/network_event.dart` 是纯 Dart 净化层（键长度、控制字符、
  类型、运营商提示归一），`platform/network_watch.dart` 只做通道封装；桌面端与
  未注册通道的旧包确定性回落 `DefaultNetworkStateProvider`。
- `AppShell` 订阅变化流：首帧只在受限时立刻暂停，避免与启动识别重复发请求；
  回前台用 `currentSnapshot()` 判断「暂停」还是「重判」。Android debug 包已实测
  Kotlin 可编译。

#### 10.2 订阅来源可信度与签名校验（E9 最后一环）

`source_config_url.dart` 之前只保证「这段文本来自用户填的主机」，证不了「今天
下发的还是上次认可的那份」。新增 `data/onboarding/source_trust.dart`：

| 闸门 | 行为 |
|---|---|
| 首次使用信任 | 第一次从某 origin 下载必须用户显式确认，确认后固定规范化文本 SHA-256 摘要与路径 |
| 来源绑定 | 记录按 `scheme://host[:port]` + path 索引；换主机、换路径、https→http 降级不复用旧结论 |
| 变更重确认 | 内容一变就再次询问，并把新旧摘要片段给用户看 |
| 可选分离签名 | 发布者给 `X-Shunbo-Signature: sha256=<HMAC-SHA256>`，用户填共享密钥；验签通过的内容更新自动放行 |
| 防降级 | 曾签名的来源后来给无签名/验签失败响应，**即使人工点确认也拒绝** |

- 源配置 URL 导入与频道地址表订阅**共用同一份信任库**；`SourceImportService`
  新增可选 `trust` / `confirmTrust`，传 null 时行为与接入前逐字节一致（旧回归未改一行）。
- 传输层只回显两个签名头，值限可打印 ASCII、≤256 字节、只在最终 2xx 采集；
  `Set-Cookie` / 自定义鉴权头绝不进入导入链路。
- 信任库走 `FileConfigStore.saveState` 原子写；写盘失败不打断导入，但如实提示
  「重启后需重新确认」。
- **边界**：这是 webhook 式共享密钥，防镜像替换与中间人改包，**防不了持有密钥的人**，
  也不是公钥签名；密钥明文存于本机配置，App 不给任何发布者背书。

#### 10.3 内容级帧抽样判据（离线）

- `features/live/content_gate.dart`（纯 Dart）：帧级亮度均值 / 动态范围 /
  时域差 / 感知哈希 → 黑屏、静帧、纯色测试卡、循环垫片；**采样不足绝不判通过**。
- `tooling/scan_content_frames.dart`：libmpv `vo=image` 落真实帧 → 均匀抽样 →
  16×9 亮度网格 + 64 位 dHash → 交给判据。本机 media_kit 的 libmpv 构建对任何
  `vf` 都会弄丢解码链（`signalstats` / `fps` / `scale` 三种实测），所以不用
  `lavfi=[signalstats]`；低质量 JPEG + 即时清理临时帧目录是实测可行路径。
- 实跑证据（`../.apk_analysis/content_probe_real.json`）：浙江 4K 官方直连
  3840×2160 / 抓帧 94–109 帧 / 抽样 8 帧 → 内容正常；静帧图片只解出 1 帧 →
  采样不足（正确地不通过）；反盗链提示片 mp4 在 4s 窗口内未解出帧 → 采样不足。
- **判据边界**：能抓「根本没内容 / 内容在循环」，抓不到**错台**（A 台画面套
  B 台名字）、黑屏上只有一个台标、OCR 才能辨认的提示文字。内置清单的「通过」
  结论不包含这几项，别把「内容正常」读成「台名与画面一致」。

#### 10.4 验收

`verify_carrier_channel.dart` 追加 44 项（累计 **275/275**）、
`verify_source_trust.dart` **80/80**、`verify_content_gate.dart` **46/46**，
全部并入 `verify_all.dart`；全量门禁 **32 步 / 2619 断言（约 1.5 分钟）**，`flutter analyze` 0 issue，
门禁自检 6/6。方案文档同步升到 R2.1（§14），三份产物按 0.1.0 重打并核验哈希。

### 11. 手机横屏右侧黑底与频道入口（2026-11-08）

用户截图：手机横屏全屏播放时，画面只占左侧约 4/5，右侧一整条纯黑，换台入口也不在那一侧。

**根因不在"没铺满视频"，而在舞台被二次约束**：`PlayerStage` 的固定
`AspectRatio(16/9)` 外层是 `ColoredBox → GestureDetector`，这两层把约束原样透传
（**松散约束**）。于是 2.16:1 的屏幕上舞台按 `宽 = 高 × 16/9` 算出 889×500 并默认
**左对齐**，剩下的 191px 被外层黑底填满；控制条是舞台内的 `Positioned.fill`，
同样只画到 16:9 边界。此前"横屏双栏"的修复只作用于**非全屏**，而截图正是全屏态，
所以看起来完全没生效。

修法分四层，全部沿用现有深色主题与既有控件：

| 层 | 改动 |
|---|---|
| 舞台 | `PlayerStage` 加 `fill`：直播一律铺满父级有界区域（宽高无界时安全退回 16:9），点播保持原 16:9 语义；渲染面继续按 `fit` 三档适配，比例不再由舞台决定 |
| 全屏 | 新增 `_buildFullscreenStage`：`Positioned.fill` 铺满 + 右侧常驻 `ChannelRailTab`（带当前台号、点按 / 贴边内滑展开）；展开为**不透明**右侧抽屉，点遮罩 / 收起按钮退出，翻几百个台时不再 6 秒自动消失；`SafeArea` 避开挖孔与手势区 |
| 非全屏横屏 | 双栏右栏宽度改为 `MobileLayout.landscapeRailWidthFor(w,h)`＝「画面按高度算完 16:9 后剩余的宽度」（208~320），不再拍脑袋取 30%；1080×500 下画面 872 宽，两侧都不留黑边 |
| 控制条 | 触摸形态把「频道」做成**钉在最右**的实色按钮，其余按钮进 `SingleChildScrollView`；任意窄屏都不 overflow，换台入口也不会被横滚带出屏幕；按钮点击区由 38 放大到 44 |

统一入口：全屏横屏时控制条按钮与右侧标签都开同一个右侧抽屉，竖屏 / 非全屏仍走底部弹层
（`_showChannelPicker` 里按 `MobileLayout.useFullscreenChannelRail` 分流），不会出现两套列表。
窄侧栏（≤260）里频道号缩到 26px、隐去次要标注，保住台名；分类横滑、上下滑换台、
画面缩放、投屏、数字跳台等原有交互一律不变。

验收：`verify_mobile_layout.dart` 扩到 **145/145**（新增 E/F 两节：双栏宽度数学、
全屏铺满、右侧入口、窄屏无溢出、触控目标），`verify_edge_handles.dart` **79/79**；
全量门禁 **32 步 / 2619 断言**，`--selftest` 6/6，`flutter analyze` 0 issue。

**边界**：本机无 Android 真机/模拟器（硬件虚拟化被占用），这几处改动只做到
「静态分析 + 纯 Dart 布局回归 + release 编译 + Windows 静默装起卸」；
真机上挖孔偏移、刘海横屏的 `SafeArea` 内缩、以及 2.16:1 屏幕 `contain` 的对称边宽
仍需实机目视确认。代码里保留的 `fit` 三档可自行切「铺满」消掉正常边宽。

## M0 验证结论（换源对齐 #1 暗坑）
- Python 原型与 Dart 移植语义 1:1，覆盖：集数偏移、广告插入时间错位、跨源往返一致、用户校准反解。
- `contentToRaw` 采用广告锯齿精确逆映射（求解 `floor(raw/adInterval)==k`），已验证往返一致。

## 播放中进度落盘（`progress_reporting.dart`）

> 修的是一个「看起来能续播、其实没存进度」的假成功：此前续播记录只在 `load` 那一刻写一次，
> `PlayerController.currentRawSeconds()` **全工程没有任何调用方** —— 用户看了 40 分钟再换端，
> 另一台设备依然从「这一集的起点」开始。

`ProgressReporter` 把播放中的读数按策略落盘，四个必须做对的点：

| 点 | 做法 | 若做错的后果 |
|---|---|---|
| 坐标换算 | 采样值是该源的**物理秒数（含广告）**，落盘前用锚点画像 `rawToContent` 转成规范内容坐标 | 跨源/跨端带着广告偏移漂移，越是长视频越偏 |
| 不乱写 | 未前进（暂停/刚载入）、位移不足、间隔不足都不写 | 刚打开就落盘，把上次的 40 分钟覆盖成 0 |
| 写入串行 | 单写者 + 待写槽（队列恒定为 1），慢盘上并发写不会「旧位置后落地覆盖新位置」 | 机械盘/杀软扫描时进度莫名倒退 |
| 换源护栏 | `begin` 先排空旧会话写入再递增 epoch；切换后仍排队的旧帧丢弃 | 新源的记录被旧源坐标覆盖 |

调用时机：`开始播放 / 换源`切锚点（编排层入口先 flush 再写新记录，避免兜底 flush 把新记录盖回去）、
用户暂停、切后台（`AppLifecycleState` 监听）、退出（`dispose` 尽力落盘）。
落盘失败不打断播放：置 `degraded` 并上报 `progressWriteFailed`，且**不推进基线**以便下次重试。

## 已落地里程碑
- **M0 技术验证门禁**：换源对齐算法 Dart 化并实测通过（最高风险已攻克）。
- **M1 工程骨架**：pubspec + 分层 lib + 入口 + MVP 注册表示例。
- **E2 源适配接口**：`SourceAdapter` 契约 + 数据模型 + 示例适配器 + 按平台裁剪注册表。
- **E3 播放器（可验证占位）**：`PlayerController` 抽象 + `MockPlayerController` 模拟实现，
  无需原生 libmpv 即可验证「载入/播放/续播」链路（真实 libmpv 封装后续替换，UI/编排不改动）。
- **E3 libmpv 封装契约（骨架）**：`mpv/` 目录落地 —— `MpvNative` 抽象绑定（FFI / 平台通道两条路线）、
  `LibMpvPlayerController`（依赖 `MpvNative`，每次 load 后采样指标并即时跑门禁）、
  `PlayerMetrics` + `PlayerMetricGate`（首帧快/内存低/不卡顿三项门禁，直击设计稿"三者相互牵制"风险）、
  `FakeMpvNative`（纯 Dart 假实现，无需原生构建即可验证逻辑）。
- **播放器契约修正**：`PlayerController.load` 现接收真实播放地址(url) + 源原始坐标(episode, rawSeconds)，
  播放内核只做物理播放；去广告的内容坐标换算完全归属调度层（alignment.dart）。编排层已补齐"把解析地址传给播放器"。
- **MVP 垂直切片已打通**：`PlaybackOrchestrator` 串联 搜索→选源→解析→对齐→载入；
  `main.dart` 提供真实 UI（搜索→选集→选源→播放面板，面板直观显示「原始坐标 vs 内容坐标」，
  换源按钮演示无感对齐；选集页含"继续观看"续播入口）。UI 已通过 `flutter analyze` 整编检查。
- **E6 续播持久化（跨端续播数据底座）**：`data/` 落地 `ResumeRecord`（**只存去广告规范内容坐标**，
  不存源原始坐标）+ `ResumeStore` 抽象 + `MemoryResumeStore`（MVP/测试用）。编排层每次载入即落盘续播，
  并提供 `resumeFor` 查询；UI 在选集页展示"继续观看"并支持从记录恢复（优先沿用上次源，否则回退当前平台可用源）。
- **E2 真实适配器（多源解析链路）**：落地「解析内核 / 取数」解耦分层 —— `SourceParser` 契约 +
  `DartSourceParser`（桌面/TV Dart 子集，纯正则解析约定结构）+ `DartHttpFetcher`（dart:io 联网）+
  `JarSourceParser`/`JarFetcher`（Android jar，MethodChannel，**仅 Android**，显式建模"jar 不可跨端"落差）+
  `SourceFetcher`/`MockFetcher`（注入响应）+ `ParsedSourceAdapter`（组合式真实适配器）+ 平台工厂。
  `ParsedSourceAdapter.resolvePlayUrl` 含**取址自愈**（缓存未命中时补拉详情页），消除编排层/续播对
  `getEpisodes` 调用顺序的隐藏依赖。`main.dart` demo 已接入"Dart解析源"，UI 可演示真实解析链路。
- **E3 真实 libmpv 绑定（FFI + 平台通道 + 指标落地）**：`mpv/` 补齐 6 个文件 ——
  `metrics_sampler.dart`（可注入时钟的事件流采样器 + `KernelTradeoffModel` 首帧/内存/卡顿**牵制模型**与
  `findBalancedTuning` 参数寻优）、`mpv_backend_resolver.dart`（后端决议：FFI 优先、缺失降级）、
  `mpv_ffi_bindings.dart`（libmpv client.h C API 的 `dart:ffi` 绑定 + 按平台动态库探测）、
  `mpv_ffi_native.dart`（命令/属性/指标桥接的 `MpvNative` 实现）、
  `mpv_platform_channel_native.dart`（Android ExoPlayer 回退）、`mpv_native_factory.dart`（探测→决议→构造）。
  `pubspec.yaml` 新增 `ffi: ^2.1.0`（本机缓存 2.2.0，离线解析成功）。
  - **牵制模型已量化验证**：单压首帧+大缓存 → 内存超标；无缓存 → 卡顿率超标；
    存在三项同时达标的平衡解 **预解码 4 帧 / 缓存 24MB / 内存 76MB**（网格内最省内存）。
  - **Android 原生侧已补齐**（本轮）：两个通道 + 渲染表面（`TextureView`）+ OS 内存探针（`Debug.MemoryInfo`），
    实现是 ExoPlayer 回退后端而非 libmpv（本机无 NDK/.so），详见「Android 原生侧」章节。
    桌面端的 `mpv_render_context_create` 渲染面仍未接（缺 `libmpv.dll` 与 VS 运行时）。
- **E6 真实持久化（跨端续播落盘）**：`FileResumeStore` 用 `dart:io` + JSON 实现，零平台插件依赖，
  三端通用且可在裸 `dart run` 下验证。具备**原子写**（`.tmp` → 旧文件转 `.bak` → 转正 → 清理，失败可回滚）、
  **损坏容错**（缺失/坏 JSON/字段不兼容降级为空记录集）、**写入失败降级**（退化为内存态、播放不中断），
  并以 `degraded` 标志供诊断上报。`main.dart` 已改用它，重启应用后"继续观看"仍在。
- **E6 播放中进度落盘（补上"续播只存起点"的假成功）**：`scheduler/progress_reporting.dart` 的
  `ProgressReporter` —— 此前 `PlayerController.currentRawSeconds()` 全工程无调用方，续播记录永远是
  "这一集的起点"。现在按 `ProgressPolicy`（采样 5s / 落盘间隔 10s / 位移阈值 5s）把播放中的物理位置
  用当前源画像换算成**规范内容坐标**后落盘；单写者 + 待写槽保证慢盘上不会出现"旧位置后落盘覆盖新位置"；
  `begin` 先排空旧会话写入再递增 epoch，切换后仍排队的旧帧丢弃。编排层在 `startPlayback` /
  `switchSourceAligned` 入口先 flush（避免兜底 flush 把新记录盖回旧源），UI 在暂停、切后台
  （`AppLifecycleState`）与 `dispose` 时强制保存。写失败不打断播放，置 `degraded` 并上报
  `progressWriteFailed`，且**不推进基线**以便下次重试。
- **E6 片尾判定（补上"看完一集却被送回片尾字幕"的假成功）**：距内容结尾 ≤90s 且本集 ≥300s 时，
  落盘的是 `finished: true`（位置归一到内容时长末端）而不是"末尾第 N 秒"；同一集只写一次、只在
  **确认落盘后**才发诊断与 `onEpisodeFinished`，写失败则清位重试，回拖到中段会撤销标记。
  `tooling/verify_progress.dart` 102/102。
- **E7 自动换源韧性（源失效兜底）**：`playback_failure.dart` 把失效建模为一等事件
  （`PlaybackFailureException` 可恢复失效 vs `StateError` 程序员错误刻意区分）；
  `source_failover.dart` 是**唯一重试决策点**：按平台裁剪候选源、跳过坏源、逐个做对齐重试，
  每次都从失效瞬间的原始坐标出发（杜绝多次重试累积漂移），全失效时返回可执行兜底文案。
  UI 播放面板新增「模拟当前源失效 / 模拟全部源失效」两个演示入口。
  - **顺带修复静默假成功缺陷**：原 `switchSourceAligned` 在目标源解析不到地址时，
    仍返回"成功"会话并落盘续播（实际无东西可播）。现改为抛可恢复失效、不载入、不落盘。
  - **量化验证**：自动换源跳过坏源 fb 后落到 fc，内容坐标守恒（第1集650s），
    目标源广告错位精确对齐到 680s；策略上限、全源失效兜底均通过断言。
- **E3 事件循环 / Property 观察 / 指标管线（真机集成数据通路）**：新增 5 文件 + 工厂入口。
  `mpv_event.dart`（libmpv JSON 事件模型 + 宽松解析）、`mpv_event_loop.dart`（脏数据隔离 / 背压丢最旧 /
  订阅者异常隔离 / 可暂停 / 确定性 pump）、`mpv_property_observer.dart`（把 `drop-frame-count` /
  `estimated-frame-count` **累计值取差值**喂给采样器，维护 time-pos/pause/cache 运行态）、
  `mpv_event_pipeline.dart`（原生流→循环→观察器→门禁→埋点 一行接线）、
  `mpv_event_channel.dart`（Android `shunbo/mpv/events` EventChannel 契约）。
  `mpv_native_factory.dart` 增加 `createMpvEventPipeline()` 真机一行式入口。
  - **指标不再依赖手工调用**：`file-loaded` 重置窗口、`playback-restart` 标记首帧、累计 1000 帧自动采样；
    实测首帧 300ms / 丢帧率 0.005 / 内存 80MB 门禁通过，首帧未到达则门禁必失败。
  - **发现并固化集成陷阱**：真机必须走 `attach` 逐行即时分发；若批量入队后统一 `pump`，
    `file-loaded` 与 `playback-restart` 落在同一时钟刻，首帧被算成 0ms 致门禁失真（已写入事件循环注释）。
- **E7 结构化诊断埋点**：`diagnostics/diagnostic_sink.dart` 提供 `DiagnosticEvent` / `DiagnosticSink` /
  `MemoryDiagnosticSink` / `NoopDiagnosticSink`。`SourceFailover` 注入可选 sink（默认 Noop，零开销），
  上报 `playbackFailure → failoverAttempt×N → failoverRecovered / failoverExhausted`，
  属性含 reason / platform / candidates / 内容坐标；事件管线的门禁失败与坏行也自动埋点（坏行去重上报）。

- **E6 跨端续播同步（「跨端续播」卖点最后一环）**：`data/sync/` 落地双向同步引擎。
  `SyncAwareResumeStore` 装饰器拦截本地 `save`/`remove` 进入待同步队列，**编排层与 UI 零改动**；
  同步应用远端变更走 `applyRemote`，不产生回声写入。传输抽象支持「账号云」与
  `FileSyncTransport`（局域网共享目录 / WebDAV 挂载降级路径），均为纯 `dart:io`。
  - **暗坑 1 时钟偏移**：不用 `updatedAt` 取最新（TV 长期离线、手机改时间会让时钟超前的设备
    永久压制真实更新）。改用 **Lamport 逻辑时钟**：观察远端最大 stamp 后才给本地写入打戳，
    冲突只比 stamp，stamp 相同才按 deviceId 确定性裁决。已实测「2035 年旧写 vs 2020 年后写」后者胜出。
  - **暗坑 2 删除复活**：删除写**墓碑**而非抹除条目，旧设备同步时被墓碑清掉，无法把已删进度推回来。
  - 另有：离线保留队列并自动重传、重复同步幂等、对端脏数据逐条隔离 / 坏 JSON 降级、
    并发冲突计数与 `syncConflict`/`syncOffline`/`syncApplied` 结构化埋点。
- **E9 首次配置引导 + 源配置安全白名单（闭合评估报告「需求完整性」缺口）**：
  `source_config_validator.dart` 只放行纯数据字段，任意层级禁 `script/jar/class/quickjs/eval/exec`
  等动态代码加载键，限制 scheme（仅 http/https）、嵌套深度、条目数、字符串长度；
  外部配置**默认禁止 jar/QuickJS 后端**，需显式授权。`onboarding_flow.dart` 为
  「免责声明 → 配置导入 → 设备形态确认」状态机，可持久化回读，安全不变量是
  **未接受免责声明前禁止任何导入**；不安全配置拒绝且不推进流程。UI 首页有引导卡片。
- **E9 导入闭环（把配置能力交到用户手里）**：新增 `source_import_service.dart`（纯 Dart 编排）+
  `sample_source_config.dart`（App / 演示服务 / 回归共用的示例数据）。引导卡片的「导入源配置」
  与 AppBar 入口现在真的能粘贴 JSON → 校验 → 注册 → 落盘 → 推进引导，并在重启时自动恢复。
  闭合三处潜在假成功：零可用源却推进引导、坏条被落盘后重启复活、外部配置用同名 id 顶掉内置源画像；
  另有重复导入注销旧源 + 释放连接池、写盘降级如实提示、跳过引导用户可补签免责声明。
  `verify_onboarding_import.dart` 60/60（含 UI 一键示例配置真实可搜可播）。
- **E9 从文件导入（纯本地、不扩网络攻击面）**：新增 `source_config_file.dart` 作为唯一文件 IO
  边界，`SourceImportService.importFromFile` 经注入的读取器接入同一条净化链路；UI 导入框增加
  路径输入与「从文件导入」，成功后回填净化配置、结果展示来源文件名。
  `verify_source_config_file.dart` 84/84（真实临时文件 + 真实 HTTP 链路 + 重启恢复）。
- **E9 从链接导入（把"下载配置"这件事关进笼子）**：新增 `source_config_url.dart` 作为唯一网络 IO
  边界，`SourceImportService.importFromUrl` 复用同一条净化链路；UI 导入框增加链接输入与「从链接导入」。
  收紧九条：仅 https（loopback 例外）／禁 URL 内联凭据／逐跳同主机复检／禁 https→http 降级／
  重定向上限 2 次／256 KB 流式上限（超限即中断，不先读进内存）／拒 NUL 与非法 UTF-8／
  单次总超时／只回显 `host:port`（query 里常有私有 token，不能回显）。
  验证过程中抓到一个真实坑：夹具用 `HttpResponse.write` 写中文配置时按 latin1 编码抛异常，
  被 `catch (_)` 吞掉后表现为"客户端超时"——现在夹具错误一律打到 stderr，不再伪装成网络故障。
  `verify_url_import.dart` 37/37（真实 socket：3 类重定向 + 体积 + 编码 + 超时 + 编排隔离）。
- **E9 配置导出 / 备份（与导入对称）**：`writeSourceConfigFile` 与读取共用同一套路径规则
  （抽成 `_checkPath`，避免读写两处漂移）；默认不覆盖已有文件、覆盖时 `.shunbo-bak` 备份 +
  原子换名 + 失败回滚、不自动创建父目录、拒绝目录/符号链接/远程路径；`SourceImportService.exportToFile`
  只导出当前**已生效**的净化配置（不导出编辑框草稿）。UI 导入框加「允许覆盖已有文件」+「导出到该路径」。
  `verify_source_config_export.dart` 46/46（含导出→导入往返一致、备份恢复后真实可播）。
- **跨主机取数与源级优先级（闭合最后两处「白名单允许但无人消费」）**：`allowedOrigins` 新增为
  配置字段并按整个 origin 严格授权（默认拒绝 / 最多 8 个 / 禁通配与路径 / 每跳重定向复检 /
  禁 https→http 降级），`DartHttpFetcher` 在跨 origin 请求上剥离 `Cookie`/`Authorization`/
  `X-Api-Key`/`Referer`，只放行三个身份无关的安全头，避免「允许跨主机」变成凭据外泄通道。
  `qualityRank`（0..100）从配置贯通到 `SourceAdapter` → `SearchHit` → UI，聚合按 rank 降序且
  显式稳定排序（未配置时顺序不变）。`verify_cross_origin.dart` 63/63（三台独立端口站点真实取数）。
- **E7 诊断真实落盘**：`FileDiagnosticSink` 把失效轨迹 / 门禁退化 / 同步事件写成 JSONL，
  串行异步写（不阻塞播放链路）、超限自动轮转为 `.1`、缓冲有上限且写失败保留待重试。
  `main.dart` 已把 UI 的 `SourceFailover` 接到该 Sink；AppBar 提供「跨端续播同步」手动触发入口。
- **E2 桌面解析子集扩充（站点规则驱动，覆盖真实站点结构）**：新增 `site_rule.dart` +
  `rule_source_parser.dart`。把原先硬编码在 `DartSourceParser` 里的三条正则抽成**纯数据规则**
  （`SiteRule`：搜索/剧集/播放地址三段，支持 `regex` 与 `json` 两种形态、命名捕获组、JSON 点分路径、
  `?name` 可选组、`${x}` 模板、字面量），内置 `legacy` / `vod-html` / `json-api` 三种预设。
  实现同一 `SourceParser` 契约，可直接注入 `ParsedSourceAdapter`，**编排层 / UI / 调度层零改动**。
  - **健壮性**：坏正则/坏 JSON/缺字段/非法数字逐条隔离；输入超长截断（防 ReDoS 放大）；
    剧集按集数去重升序、地址按 url 去重按清晰度降序；HTML 实体解码 + `\/` 还原 +
    危险 scheme 过滤 + 相对地址按 `baseUrl` 补全。
  - **安全闭环（与 E9 呼应）**：外部配置可携带 `rules`，但 `validateSourceConfig` 会先跑
    `validateSiteRuleMap`（拒超长正则 / 嵌套量词 ReDoS / 缺必需字段 / 非法 baseUrl），
    并校验 `rules.baseUrl` 与配置 `baseUrl` 主机一致（防注入外部站点）；`_allowedRootKeys` 只放行纯数据字段。
  - **回归**：三类站点结构样本（不同 class/属性、JSON 接口、JSON 内转义 m3u8、乱序剧集、
    重复项、脏数据、危险 scheme）全部通过，且规则源真实驱动「搜索→剧集→取址→对齐→播放」全链路。
- **E5 投屏兜底 UX（闭合评估报告「投屏兜底不足」缺口）**：`cast/cast_fallback.dart` 落地投屏状态机 +
  `CastTransport` 抽象；**传输层已从 `FakeCastTransport` 换成真实 DLNA**
  （`cast/dlna/dlna_transport.dart`，SSDP 发现 + 设备描述解析 + SOAP AVTransport 控制），
  `FakeCastTransport` 仅保留给「无电视环境」的演示与纯逻辑回归。覆盖无设备 / 连接失败（自动换下一台）/
  起播失败 / 播放中掉线 / 设备发现异常 / 位置查询异常六条路径，**任何失败都返回可继续看的结果**。
  - **关键设计**：降级结果携带的是**源原始坐标（含广告）**，交由调度层用 `rawToContent` 换算成
    规范内容坐标后重新 `startPlayback`，绝不把投屏设备的物理位置直接当内容进度（否则广告错位会
    让进度凭空跳变）；进度只许前进不许倒退。实测：内容 650s → 投屏物理 800s → 降级换算回 770s，
    往返一致。UI 播放面板分两层：「搜索局域网设备」走**真实 DLNA**（发现后点设备即投屏），
    下面的「模拟投屏 / 模拟掉线 / 模拟无设备」是无需电视的兜底演示；两条路径共用 `_settleCast`
    降级收尾，并接 `castStarted` / `castFallback` 结构化埋点。
- **E5 真实 DLNA 投屏（把「第三方设备的字符串」当不可信输入）**：SSDP 应答里的 `LOCATION`、
  设备描述里的 `controlURL`、SOAP 应答都来自局域网里的陌生设备，逐个收紧：
  - **只认私网**：`LOCATION` 指向公网一律丢弃（默认拒绝，`allowPublicAddresses` 仅供调试），
    域名只放行 `localhost` / `*.local`（mDNS 保留域）；否则恶意应答能把本机变成为公网打点的跳板，
    也会把带签名的播放地址发给外部主机。
  - **只认 http**：DLNA 规范内就是明文 http，`file://` / `ftp://` 一律拒绝。
  - **controlURL 必须同 origin**：解析后比对 scheme/host/port，不一致即拒绝该设备——否则
    一张设备描述就能指使客户端把 SOAP 发给第三方。
  - **体积/条数/时间全有上界**：单条 SSDP 报文 4KB、设备描述 256KB、SOAP 应答 64KB、
    设备数 32、重发 2 次、发现 3s、单请求 5s；响应流式读取、超限即中断（不先读进内存）。
  - **M-SEARCH 会重发**：UDP 丢包是常态，单发一次会表现为「电视在列表里时有时无」。
  - **connect 是真探活**：发一次 `GetTransportInfo` 能拿到 `CurrentTransportState` 才算在线，
    不是「发现过就算连上」。
  - **起播顺序 SetAVTransportURI → Play → Seek**；Seek 失败退化成 `Pause → Seek → Play` 再试，
    两次都失败就返回失败让上层降级——「从 0 秒开始播」比投屏失败更糟（用户以为进度丢了）。
  - **不走系统代理**（`findProxy: DIRECT`）：Windows 系统代理会把局域网请求接管成 502。
  - 回归 `tooling/verify_dlna_cast.dart` **61/61**：本机起真实 UDP SSDP 应答 + 每台设备一个
    HttpServer，覆盖发现/去重/上限、五类恶意 LOCATION、跨 origin、超大/坏编码描述、SOAP 序列与
    XML 转义、Seek 退化、`RelTime` 解析、超时，以及接 `CastFallbackController` 的端到端降级。
  - 验证中修掉两个真 bug：① 收尾定时器可能**先于**已排队的 socket 读事件执行，导致首次发现少一台
    设备（真机表现就是「设备列表时有时无」）；② `complete()` 之后排队的事件仍在派发，
    `maxDevices` 形同虚设。
  - 顺带补上一个「假成功」根因：`PlaybackSession` 原先不携带物理播放地址，投屏只能用
    `https://cast/...` 这种编造地址——投屏「成功」了电视却播不出来。现在 session 带 `playUrl`
    （解析结果的最高画质那条），投屏与本机播的是同一个资源。
- **E6 引导状态真实持久化**：`FileConfigStore` 实现 `ConfigStore`（纯 `dart:io` + JSON，原子写、
  损坏降级、写入失败降级内存态），除源配置/进度外提供通用 `saveState/loadState`。
  `OnboardingFlow.persist` 已接到它，`main()` 启动时回读 —— **已完成引导的用户重启后不再被打断**
  （此前为内存态）。验证覆盖重启回读、并发条目不覆盖、坏 JSON 不抛异常。

- **【本轮补全】功能实现逐项核对**：对照设计稿功能矩阵、README 自述与「已声明但无调用方」
  的接口做了一次全量检查，补上 5 处「看着有、其实没接上」的地方，逐项结论见
  [`CHECKLIST.md`](CHECKLIST.md)：
  - **自动连播**（`scheduler/playback_queue.dart`）：`onEpisodeFinished` 此前只被回归调用，
    UI 从未接；现在看完一集自动进下一集，能处理迟到事件、跳集、当前源缺集换源、最后一集不重播，
    开关状态落盘。`verify_queue` 28/28。
  - **桌面端真实内核**（`player/media_kit_player_controller.dart` + `ui/media_kit_surface.dart`）：
    桌面不再是「Mock 不出画面」，改为 media_kit + 随包 libmpv；Android 仍走自研 media3 通道，
    避免 APK 体积翻倍。编排/调度/续播代码零改动。
  - **结束投屏**：`stopCasting()` 之前无调用方，投屏成功后本机已暂停且无法返回；
    现在有「结束投屏」入口，先取回设备真实位置再按画像换算续播，并新增
    `CastFailureReason.userStopped` 修正「主动结束」被说成「连接中断」的文案。
  - **`initialize()` 生命周期**：接口声明了但全工程无调用，Android 靠惰性 `ensureEngine()`
    掩住了，换 media_kit 后必现空指针。
  - **数据目录**（`data/app_paths.dart`）：从 `%TEMP%` 改为桌面 `%LOCALAPPDATA%\Shunbo`，
    否则系统清理临时目录会把「继续观看」一起清掉。

## E2 真实联网闭环（输入侧从 Mock 走向真实）

**为什么先做这一项**：此前 169 项断言全绿，但全部跑在 `MockFetcher` / `MemorySourceAdapter` /
`MockPlayerController` 上 —— 工程从未发过一次真实 HTTP、解析过一页真实 HTML、载入过一个可取回的
播放地址。这属于系统性「假成功」，且会让 E3 真机联调时输入侧与内核侧两个变量同时不确定。
因此先把输入侧固定为可信链路，再接播放内核。

**做法**：`tooling/verify_live_http.dart` 在本机起 4 个真实 `HttpServer`（legacy / vod-html /
json-api 三类站点 + 一个「越权外部源站」），由 `DartHttpFetcher` 通过 socket 发真实 GET，
串起 `搜索 → 剧集 → 取址 → 择优 → 换源对齐 → 播放器载入`，最后**把播放器拿到的地址再真实 GET 一次**
确认返回的是 m3u8 内容，而不是只长得像 URL 的字符串。

**首轮 red → 加固后 green**：43 项中首轮仅 36 项通过，7 项暴露真实缺陷：

| 首轮失败项 | 根因 | 加固 |
|---|---|---|
| 404 错误页被当成正常内容解析 | 无状态码检查，错误页里的合法 HTML 造成「假成功」，且把网络故障误判成 `emptyPlayUrl` | 非 2xx 一律抛 `httpStatus` |
| 慢响应拖死链路 | 无超时 | 连接 / 响应头 / 响应体三段超时 |
| 超大响应全量读入 | 无体积上限，放大内存与正则回溯 | `maxResponseBytes` 字节上限 |
| 非 UTF-8 直接抛 `FormatException` | `utf8.decoder` 严格模式 | 按 Content-Type 解码，`allowMalformed` / latin1 降级（GBK 会乱码，属已登记落差） |
| 站点返回的绝对取址页可指向任意主机 | `startsWith('http')` 直接采信，运行期无 origin 约束（SSRF） | `_u()` 统一判 scheme + origin 白名单；**手工跟随重定向**，每跳重跑校验（HttpClient 自动跟随会绕过） |
| 网络异常穿透 UI，自动换源形同虚设 | 裸 `SocketException` / `HttpException` 不是 `PlaybackFailureException` | 见下方三级归一链路 |
| 连接级失败未归一 | 同上 | 同上 |

**失效归一化链路（分层单向，不反向依赖 scheduler）**：
`DartHttpFetcher` → `SourceFetchException(reason)` → `ParsedSourceAdapter._guard` →
`SourceAdapterException(sourceId, reason)` → `PlaybackOrchestrator._fromAdapter` →
`PlaybackFailureException(networkError / decodeError)` → `SourceFailover` 自动换源。
UI 只捕获最后一类；`main.dart` 手动换源遇到真实失效时也改为直接自动换源并透传真实 reason。
另把多源搜索改为**逐源隔离**：单个源 404 不再让整次搜索归零。

**边界说明**：origin 白名单只约束「取页面请求」；解析出的播放地址交给播放器、不经过 fetcher，
因此不会误伤真实站点常见的跨 CDN 直链，需要跨站取页面时由调用方显式扩展 `allowedOrigins`。
`useSystemProxy`（默认 true）可关闭系统代理 —— 本轮实测发现该 Windows 环境会把
`127.0.0.1:1` 请求交给代理并返回 502，回归脚本固定 `false` 保证判定确定。
`close()` 必须调用以释放连接池，否则失败连接残留会挂住 Dart 进程。

## 配置驱动多源 + App 真实源开关

**闭合的缺口**：E9 白名单早定义了 `headers` / `searchPath` / `playPath` / `platforms` /
`episodeOffset` / `adInterval` / `adDuration` 等字段，但此前**只有校验、没有消费方** ——
导入配置后仍只能手工构造 `MockFetcher`。本轮新增 `data/onboarding/source_config_loader.dart`，
把「一份配置 = N 个真实源」打通。

配置支持两种根形态：多源容器 `{"sources": [单源配置, ...]}` 或单个源配置（向后兼容）。
单源示例（省略 `rules` 内部字段，内容为 `SiteRule.toJson()` 的纯数据）：

```json
{
  "id": "src-a", "name": "站点 A", "baseUrl": "https://example.com",
  "parser": "regex",
  "headers": {"User-Agent": "shunbo/1.0", "Referer": "https://example.com/"},
  "searchPath": "search?q={keyword}", "playPath": "detail/{mediaId}",
  "platforms": ["desktop", "tv"],
  "episodeOffset": 1, "adInterval": 600, "adDuration": 30,
  "enabled": true,
  "rules": {"...": "SiteRule 纯数据（搜索/剧集/播放地址三段）"}
}
```

链路：配置 → E9 白名单（容器逐条递归） → `validateSiteRule` → `SourceProfile` + 平台裁剪 +
请求头注入校验 + 路径模板 → `ParsedSourceAdapter` → `SourceRegistry` / `SourceCatalog`。
坏配置**逐条隔离**（`ConfigRejection` 带索引与可读原因），不会让整份导入作废；
`enabled:false` 跳过且不算拒绝。

安全补充：规则 `baseUrl` 被配置 `baseUrl` 强制覆盖，防规则内部指向别的站；禁止配置覆盖
`Host` / `Content-Length` / `Proxy-Authorization` 等头、拒绝头值换行注入；`jar` / `quickjs`
后端即使显式授权也不由 Dart 加载器构造（需 Android 原生实现）；单份配置最多 50 个源；
loopback 源自动直连，避免系统代理改写。`LoadedSourceConfig.close()` 负责释放连接池。

`DartHttpFetcher` 同步新增 `headers` / `searchPath` / `detailPath`，真实站点常见的
UA/Referer 校验与自定义端点路径被真正接上（回归里站点开启 403 头校验来验证确实发出）。

**让 App 本体连真实源**（此前只有验证脚本走真实网络）：

```bash
dart run tooling/serve_fixture_site.dart legacy     # 终端 1，打印站点地址
flutter run --dart-define=SHUNBO_LIVE_BASE_URL=http://127.0.0.1:<port> \
            --dart-define=SHUNBO_LIVE_RULE=legacy  # 终端 2
```

规则名可用 `legacy` / `vod-html` / `json-api`；未设置 `SHUNBO_LIVE_BASE_URL` 时行为与原 MVP
完全一致（MockFetcher），AppBar 会显示「真实源」标识。本机缺 Windows 桌面工具链，
`flutter run` 需在完整工具链或 CI 上执行；开关的类型正确性由 `flutter analyze` 覆盖，
同一条取数链路由 `verify_source_config.dart` 真实回归覆盖，样本站点各端点已实测可访问。

## Android 原生侧（E3：已实现、已编译、待真机实测）

`android/` 骨架已生成，两个通道 + 渲染表面全部落地，`flutter build apk --debug` 可产出可安装包。

| 文件 | 职责 |
|---|---|
| `MainActivity.kt` | 唯一注册点：挂 MethodChannel / EventChannel / PlatformView 工厂 |
| `MpvMethodHandler.kt` | 10 个方法的分发；`sampleMetrics` 在**后台线程**等首帧（主线程等 3 秒就是 ANR）；`http-header-fields` → 请求头 |
| `PlaybackEventBridge.kt` | EventChannel 推送，统一 `Handler(mainLooper).post` |
| `ExoPlayerEngine.kt` | media3 后端：事件映射、首帧/内存/丢帧采样、精确 seek |
| `PlayerSurfaceFactory.kt` | `TextureView` 作为渲染面，与内核解耦（谁先就绪都能工作） |

两条运行期约束写进了代码：

- **不向 Dart 抛异常**。Dart 侧对 `MpvNative` 的调用是按 libmpv 同步 C API 写的、没有 try/catch；
  抛 `PlatformException` 会把「读不到时长」升级成「播放失败」。所以原生侧一律 try/catch +
  返回安全默认值（`getTime` 0.0、`sampleMetrics` null）。
- **回调线程不得直调 EventSink**。播放器回调可能来自任意线程，统一 post 到主线程。

### 能力差距（必须在 UI 明示，不可静默降级）
当前 Android 端用 **ExoPlayer（media3）** 而不是 libmpv：

| 能力 | libmpv | 当前 ExoPlayer |
|---|---|---|
| 硬解/软解切换、倍速、精确 seek | 可配 | 默认策略，seek 受关键帧限制 |
| 缓存策略（`cache-secs`/`demuxer-max-bytes`） | 可配 | 由 media3 默认值决定，`setOption` 明确**忽略**而非假装成功 |
| 丢帧率口径 | `drop-frame-count` | media3 回调累加，与 libmpv 不完全同口径 |
| 封面/字幕轨/音轨切换 | 支持 | 未暴露 |

没接 libmpv 的原因不是没写，而是本机**没有 NDK、也没有 libmpv.so**：硬接会得到
「编译通过、装机启动即 `dlopen` 失败」的假集成。要切回 FFI，只需在
`player_bootstrap.dart` 里把 Android 分支换成 `MpvFfiNative` 并放入对应 ABI 的 `.so`。

### 通道契约（两侧同名，由 `verify_channel_contract.dart` 看守）

| 通道 | 方向 | 契约 |
|---|---|---|
| `shunbo/mpv` MethodChannel | Dart → 原生 | `create` / `setOption{key,value}` / `load{url}` / `play` / `pause` / `seek{seconds}` / `getTime` / `getDuration` / `sampleMetrics` / `dispose`；`sampleMetrics` 返回 `{firstFrameMs:int, memoryMb:double, droppedFrameRate:double}` |
| `shunbo/mpv/events` EventChannel | 原生 → Dart | 一行一个 JSON：`{"event":"file-loaded"}`、`{"event":"playback-restart"}`、`{"event":"property-change","name":"time-pos","data":12.3}`、`{"event":"end-file","reason":"eof"}`、`{"event":"shutdown"}` |

ExoPlayer 回调映射：首次 READY → `playback-restart`；`onIsPlayingChanged` → `pause` property；
`onPlayerError` → `end-file`；帧/丢帧计数 → `estimated-frame-count` / `drop-frame-count`（**累计值**）；
缓冲时长 → `demuxer-cache-duration`。降级时画质/能力可能与 libmpv 不等价，UI 须明示（见 `MpvBackendResolution.reason`）。

## 下一步（按优先级重排，2026-11-05）
> 排序依据：**当前最大风险已从「算法没做」变成「假设没被真实数据验证」**。本轮先把 E2 输入侧
> 做成真实链路（43/43），因此 E3 联调时只剩内核一个变量；但 E3 需换环境才能做，故与 E2 原生侧并行。

1. **E3 真机实测（已从「写不了」变为「只差设备」）**：Android 侧两个通道 + 渲染表面 + 内存探针
   已实现并通过**真实编译**（`flutter build apk --debug` 成功，APK 内已核验权限与通道名）。
   本机没有 Android 设备/模拟器，所以还差三件只有真机能给的结论：
   ① `PlayerMetricGate` 三项在真机上的实测值与机型校准（`KernelTradeoffModel` 系数）；
   ② TextureView 与 Flutter 合成的首帧时序（`onRenderedFirstFrame` 是否被 surface 就绪拖慢）；
   ③ Android 13+ 的 `NEARBY_WIFI_DEVICES` 运行时授权对 SSDP 发现的影响（已声明权限，未实测弹窗行为）。
   桌面端仍缺 `libmpv.dll` 与 VS 运行时，`flutter run -d windows` 暂不可用。
2. **E2 剩余**（不依赖 libmpv，可与上项并行）：已完成「配置驱动多源 + 请求头/路径模板 +
   App 真实源开关 + 引导 UI 导入闭环（粘贴 + 本地文件 + URL 链接 + 配置导出/备份）+ 跨主机
   `allowedOrigins` 白名单/凭据隔离/源级优先级」，剩余 ① Android 端 `MethodChannel` 侧 jar/QuickJS 原生实现
   （Dart 契约已就绪，外部配置须先过 E9 白名单且显式授权）；② 用真实站点结构校准 `SiteRule`
   预设与 `allowedOrigins` 的实际取值（当前用本地多主机样本站点回归，真实站点仍待实测）；
   ③ 系统文件选择对话框（需 `file_picker` 类插件 / 平台通道，当前为路径输入框）。

   > URL 导入（`source_config_url.dart`）已落地**传输层**全部收紧：仅 https（loopback 例外）、
   > 禁 URL 内联凭据、逐跳同主机复检、禁 https→http 降级、256KB 流式上限、拒二进制/非 UTF-8、
   > 单次总超时，且免责门禁先于任何请求。**仍未做的是「来源可信度」**：目前没有签名校验，
   > 也不对域名做发布者认证——下载成功仅代表网络通，内容安全仍完全依赖 E9 白名单。
   > 若后续要做「一键订阅官方源列表」，应先定签名/公钥分发方案，再放开域名白名单。
3. **把演示实现换成真实实现**：~~`FakeCastTransport` → DLNA~~（已完成，见 E5 章节）；
   剩余 `FileSyncTransport` → 云账号服务（需先定账号体系）、`FileDiagnosticSink` → 远端日志聚合
   （需先定上报端点与脱敏策略）。`MockPlayerController` 在 **Android 上已被真实内核替换**
（`player_bootstrap.dart` 按平台选择），桌面端仍用 Mock —— 缺 `libmpv.dll` 与 VS 运行时，
硬接会启动即崩。
   DLNA 侧仍待真机校准：SSDP 在部分路由器上被 AP 隔离/组播过滤，需要实测重发次数与超时窗口；
   厂商私有协议（小米/华为/三星）与 Chromecast 未覆盖。
4. **E6 剩余**（已补「播放中进度落盘」+「片尾判定」）：① 真机实测校准节流参数——`time-pos`
   有抖动与 seek 后回跳，10s 间隔 / 5s 位移需按实测调；② `EndingPolicy` 的 90s / 300s 两个阈值
   需按真实剧集时长分布校准（不同平台片尾字幕长度差异大）；③ 「看完自动连播下一集」目前只暴露
   `ProgressReporter.onEpisodeFinished` 回调 + `ResumeRecord.finished` 标记，真正换集编排
   （含最后一集、跨源换集对齐）留给播放列表能力层。
5. **CI 门禁接入**：`../.github/workflows/verify.yml` 已就位（本地文件，未推送、仓库未初始化），
   现已收敛为单步 `dart run tooling/verify_all.dart` + `--selftest`，本地与 CI 判定口径一致；
   待接入后在完整工具链上确认 `flutter test` 通过，再去掉该步骤的 `continue-on-error`。

---

## 安卓端形态与安装包（依据《顺播 · 安卓端形态与安装包要求》）

### 1. 一个包，两套形态

安卓端**只出两个渠道包**，不按「手机版 / 电视版」拆包。形态是**运行时判定**的：

| 判定顺序（R1） | 命中条件 | 结果 |
|---|---|---|
| a | 系统 `UiModeManager` 报告 `UI_MODE_TYPE_TELEVISION` | 电视形态 |
| b | 无触摸屏 **且** 存在方向键输入 | 电视形态 |
| c | 其余情况 | 手机形态 |

- **不用屏幕分辨率判定**：4K 手机、横放平板都会被误判，而误判成电视会藏掉全部触摸交互。
- 判定结果**不缓存结论只缓存偏好**：设备接驳变化（插拔遥控器接收器、外接键盘）后重新探测才对。
- 设置页「屏幕形态」提供 **自动 / 强制手机 / 强制电视**，用于纠正误判（R1）。
- 设置页「关于与诊断」展示：当前形态、判定依据（命中哪条规则）、渠道、版本号、应用标识、
  设备架构、冷启动实测耗时（R10）。

形态差异只体现在**布局、焦点规则、输入映射**三处：

| 形态 | 屏幕与系统栏（R4） | 导航可达性（R3） |
|---|---|---|
| 电视 | 锁横屏 + 沉浸式隐藏状态栏/导航栏 | 左侧导航常驻、频道栏常驻，全部可用方向键/确认/返回完成；焦点默认落在当前频道 |
| 手机 | **横竖屏均可**（播放不锁方向）；点「全屏」才锁横屏，退出即恢复可旋转 | 频道：**常驻边缘手柄** + 控制条「频道」弹层 + 上下滑换台 + 底部导航 |

源解析、调度、换源状态机、播放内核参数模板两种形态**完全共用**（R5/R6），
`tooling/verify_android_form.dart` 会扫描 `lib/core/source`、`lib/core/scheduler`、
`lib/core/player`，出现形态分支即判失败。

#### 手机形态的两处硬伤与修复（2026-11）

这两条都不是「观感问题」，而是让功能**不可用**的缺陷，所以单独记下来。

**① 频道切不了 —— 两个原因叠加**

* *布局*：窄屏分支写死 `Column[视频(16:9), 分隔线, Expanded(频道列表)]`。
  手机横屏可用高度只有 360~430，而 `AspectRatio(16/9)` 按 844 宽度算出来的视频高度是 474，
  视频先撑满并溢出，`Expanded` 拿到的剩余空间为 **0** —— 列表在树上有位置、在屏幕上有一个
  标题，但**一条也点不到**。
* *交互*：宽屏分支的频道栏 6 秒后自动收起，唯一的呼出方式是 `MouseRegion.onEnter`。
  触摸屏不产生 hover 事件，而手柄在不可见时还被 `IgnorePointer` 吃掉点击，
  于是**收起即永久消失**。

修法：

| 层 | 做法 |
|---|---|
| 布局 | `app/mobile_layout.dart` 把「宽屏 / 竖屏 / 窄屏横屏」显式分成三类；视频高度 = `min(16:9, 半屏, 高 - 132)`，硬保证列表至少 132px（分类条 + 一条半频道项） |
| 横屏 | 不再上下塞列表，改为**右缘抽屉**（宽度 `min(360, 52% 宽)`），点遮罩收起 |
| 手柄 | `EdgeRevealHandle(persistent: touchInput)`：触摸形态常驻半透明、整块 30px 热区可点、支持从边缘向内拖 |
| 入口 | 控制条最左加「频道」按钮 → 底部弹层（分类筛选 + 按号升序 + 当前台高亮），弹层自带 `ScrollController`（与侧栏共用会抛 "attached to multiple scroll views"） |
| 手势 | 画面区上滑 = 下一台、下滑 = 上一台（速度阈值 300px/s，避免误切） |

**② 界面被强制横屏**

`DisplayMode` 旧策略是「手机 + 正在播放 → 只允许 landscape」。一开播整个界面就被钉死在横屏，
竖屏被系统拒绝，而手机上的「全屏」按钮当时**根本没有效果**（窄屏分支没判断 `_fullscreen`，
AppBar 和底部导航都还在），用户没有任何绕回来的入口。

现在的方向策略收在 `app/screen_policy.dart` 一个纯函数里：

| 场景 | 策略 |
|---|---|
| 电视 | 仅横屏 + 沉浸（竖屏电视不存在，无例外） |
| 手机 · 浏览/播放 | **横竖屏均可**，跟随系统 |
| 手机 · 点「全屏」 | 仅横屏 + 沉浸（这是「按要求进入横屏」的显式入口） |
| 手机 · 退出全屏 | 立即恢复四方向可旋转（竖屏回退一步可达） |
| 桌面 | 不接管（也不调用 `SystemChrome`，浏览器等不支持方向控制的平台因此不会抛异常） |

`playing` 不再是方向的输入 —— `resolveScreenPolicy` 的签名里根本没有这个参数，
`tooling/verify_mobile_layout.dart` 用「签名不存在该参数」把这条钉死，防止回退。

**走查方法**：`SHUNBO_WINDOW=420x740 ./shunbo.exe` 可指定初始窗口尺寸并跳过最大化，
用于在桌面上复现竖屏 / 窄屏横屏分支（不设则沿用 1280×720 + 最大化）。
本机实测：420×740 竖屏与 740×400 窄屏横屏均无布局异常，频道列表高度正常。

**关于手机浏览器**：本项目当前**没有 web 构建目标**（`web/` 目录不存在，25 个文件依赖
`dart:io`，含平台通道、文件存储与 DLNA socket），因此不存在「在手机浏览器里打开顺播」这条路。
上面两条修复都在触摸与布局层，不依赖平台，将来补 web 目标时同样适用；但 web 端另需
替换 `dart:io` 依赖与 `SystemChrome`（浏览器只有 Screen Orientation API）。

### 2. 打包矩阵（R8/R9）

| 渠道 | 应用标识 | ABI | minSdk | 体积（实测） |
|---|---|---|---|---|
| 完整版 | `com.shunbo.tv` | arm64-v8a + armeabi-v7a | 24 | 36.6 MB |
| 精简版 | `com.shunbo.tv.lite` | armeabi-v7a | 24 | 19.2 MB |

两个包 applicationId 不同，因此**可同机并存**，各自的 `files` 目录独立、数据互不影响（R8）。
同一渠道内升级保留数据：数据目录已从 `cacheDir`（可能被系统清空）改为 `filesDir`。

打包命令（ABI 由 `--target-platform` 决定，写在 gradle 的 `abiFilters` 会被 Flutter 覆盖）：

```bash
bash tooling/build_android_apks.sh          # release，逐包校验 ≤60 MB
```

已知偏差（**必须如实记录**）：

- **minSdk 无法做到 21 / 19**。Flutter 3.47 的 Gradle 插件对 minSdk < 23 直接抛异常，
  且 `flutter_embedding` 的 AAR 自身声明 minSdk 24，清单合并取最大值，实测
  `aapt2 badging` 为 `minSdkVersion:'24'`。要回到 19/21 必须降级 Flutter 并自建播放内核，
  属独立任务。影响：Android 4.4/5.x 的乐视早期一体机**装不上精简版**，
  该场景当前只能走投屏兜底。
- **Google Cast / AirPlay 未实现**（R12a 未完成）。DLNA（SSDP + AVTransport）是唯一
  已落地的协议。这两条需要原生协议栈：Cast 要 CASTV2 的 protobuf 通道 + mDNS 发现
  （TLS 长连接、心跳、命名空间），AirPlay 要 RTSP + FairPlay 握手与 H.264 重封装。
  不是配置层面能补齐的，属独立任务。

### 3. 投屏（R12）

| 要求 | 状态 | 落点 |
|---|---|---|
| R12a DLNA / UPnP | **已实现** | `core/cast/dlna/dlna_transport.dart` |
| R12a Google Cast | 未实现 | 需 CASTV2 + mDNS |
| R12a AirPlay | 未实现 | 需 RTSP + FairPlay |
| R12b 直推优先、5 秒未出图自动改串流、记住该源 | **已实现** | `core/cast/cast_mode.dart`、`core/cast/relay/` |
| R12c 换源由手机决策、电视只执行 | **已实现** | `core/cast/cast_session.dart` + `app/live_cast.dart`；直播页控制条有投屏入口，换台/换线路自动重下发 |
| R12d 四项指标 | **已实现并可判定** | `core/cast/cast_metrics.dart`，投屏卡片上直接显示 |
| R12e 电视形态不显示入口 | **已实现** | `formFactor.castEntryVisible` |
| R12f 覆盖 Tizen/webOS | 依赖 R12a 三条协议 | — |

**为什么要中继**：带防盗链的源校验 `Referer` / `User-Agent` / `Cookie`。电视只按
DLNA 的 `SetAVTransportURI` 拉地址，没有补请求头的能力 → 源站返回 403 → 但 DLNA
的 `Play` 应答照样是 200，界面显示"投屏成功"而屏幕全黑。这是典型的**假成功**。

**双模式的判定顺序**（`CastModePolicy`）：

1. 有记忆 → 按记忆走（记住的是"验证过的事实"，不记推测）；
2. 无鉴权头探测返回 401/403/407 → 直接串流，不白等 5 秒；
3. 其余 → 先直推，交给"5 秒首帧未确认"这条兜底。

**首帧确认**分三档而不是 bool：`confirmed`（位置在前进，或状态由非播放跃迁为播放）、
`playingUnverified`（设备自称在播但读不到位置——直播流常态）、`failed`（回落到
停止/无媒体）。只有 `failed` 与"未验证"才触发改串流；串流仍未验证时**保持投屏并
如实说明**，不谎报失败 —— 把"读不到位置"当成"黑屏"会让本来正常的投屏被强行降级。

**中继的边界**（与 DLNA 传输层同一套纪律）：

* 只服务私网与回环来源（`isPrivateAddress`），否则本机在酒店/公司 Wi-Fi 上就成了开放代理；
* 随机 token 前缀，局域网其它设备不知道 token 就取不到流（返回 404，不暴露存在）；
* 上游仅 `http`/`https`，禁 userinfo，地址长度有上限；
* HLS 播放列表整体改写：分片、`EXT-X-KEY` 密钥、`EXT-X-MAP` 初始化段、音轨、
  I 帧列表全部指回中继（防盗链通常对分片一样校验，只改写主列表等于没改）；
* 播放列表读取上限 2 MiB，分片**边收边发**（不缓冲，一集几百 MB）；
* 支持 Range（点播拖动）与上游 302（以最终地址为基准解析相对分片）。

**直播投屏与换台重下发**（R12c）：

直播页控制条上的投屏按钮只出现在手机/桌面形态（电视形态 `cast == null`，R12e）。
投屏建立后，换台与换线路都会由 `LiveCastCoordinator.retarget` 把**新线路的上游地址**
重新推给同一台设备 —— 不再重新发现设备（那 5 秒不该在每次换台时重新付一遍）。

三条不能省的保护：

* **后发先至**：`CastSession.retarget` 串行执行且带 epoch。连按换台时前一次在下个
  检查点即作废，绝不让旧台的起播结果覆盖新台的状态（否则电视永远慢一步）；
* **换源必须重启中继**：中继启动时把鉴权头固定注入，换台若换了源站而继续用旧中继，
  就是把上一路的 `Referer` 发给新源站；
* **直播不把"未确认"当失败**：直播流没有时长，设备上报位置常恒为 0，首帧几乎必然
  `playingUnverified`。只有设备明确拒绝下发或传输状态回到停止，才切模式重试。

投屏期间**本机保持播放**：看门狗靠"画面有没有在动"判断线路是否还有效，本机一停播，
一条完全正常的线路会被判死并自动换台。代价是带宽翻倍，UI 文案已如实说明。

### 4. 电视侧载入口（R11a）

按机型逐一说明，四条路径任选其一：

1. **U 盘 + 电视自带安装器**：把 APK 放 U 盘根目录 → 插入电视 → 打开「我的应用 / 媒体中心 /
   电视卫士」→ 找到 U 盘 → 选中 APK → 安装。首次会提示「禁止安装未知来源应用」，需在弹窗里允许。
2. **电视卫士 / 应用助手**：创维、TCL、海信的「电视卫士」里有「安装包管理 / 本地安装」，
   可直接扫描 U 盘或局域网共享里的 APK。
3. **应用市场的本地安装**：当贝市场、沙发管家等有「本地安装 / U 盘安装」入口，
   适合没有文件管理器的机型。
4. **工厂菜单 ADB**：部分机型（小米、海信）在「设置 → 关于 → 版本号」连点开启开发者模式，
   再打开 ADB 调试，用 `adb install -r app-full-release.apk` 安装。工厂菜单（`*#*#6484#*#*`
   一类）因厂商而异，且可能影响保修，非必要不用。

装完只能在桌面看到一个「顺播」图标：`LAUNCHER` 与 `LEANBACK_LAUNCHER` 写在**同一个**
intent-filter 里（分成两个会出现两个图标），并配了 320×180 的 `android:banner`
（缺 banner 时华为智慧屏会按「手机应用」判定而拒绝安装）。

**后台保活**：酷开、小米等系统会主动结束后台进程。播放期间应用会启动前台服务
（`KeepAliveService`，`mediaPlayback` 类型）降低被杀概率；更彻底的做法是在系统的
「电池 / 应用管理」里把顺播加入白名单、关闭省电限制。

**遥控器键值**：不依赖菜单键与主页键（这两个常被系统占用）。数字键直接跳台，
方向键可达全部分类与频道，返回键按层级逐级退出（全屏时先退全屏，再退出应用）。

## 12. 1.0.0 电视端安装兼容版（2026-11-08，可回退）

针对乐视/乐融超级电视 S50 Air（eui 8.0）安装 0.1.0 报「解析程序包时出现问题」，
本轮按参考实现 `昭昭TV.apk` 的实测兼容基线做了**一处功能性改动**：在
`android/app/build.gradle.kts` 的 `signingConfigs.debug` 显式启用
`enableV1Signing = true`（保留 `enableV2Signing = true`）。AGP 9 在 minSdk≥24 时默认
只签 v2，老电视/定制 ROM 的包解析器在解析阶段读不到 `META-INF/MANIFEST.MF`，
直接抛 `INSTALL_PARSE_FAILED_NO_CERTIFICATES`。1.0.0 两包实测 v1=true、v2=true，
`apksigner verify --min-sdk-version 22 --verbose` 返回 `Verifies`（0.1.0 同命令报
`Missing META-INF/MANIFEST.MF`）。

**刻意不改**：证书（沿用同一 `debug.keystore`，证书 SHA-256 与 0.1.0 相同）、
`versionCode`（仍为 1）、minSdk/targetSdk、清单 TV 声明、`screenOrientation`、
业务代码与依赖版本。清单里的 `leanback`/`touchscreen` 非必需、双启动入口、
320×180 banner、明文 HTTP、双 ARM ABI 经核对已与参考实现一致，无需改动。
`minSdk 16/21` 因 Flutter 3.47 引擎 AAR 下限固定 24 而无法照搬，属待另立任务。

版本同步到 `pubspec.yaml`（`1.0.0+1`）、`lib/platform/system_channel.dart`
（`kAppVersionName`）、`tooling/windows_installer.iss`（`AppVersion`）。
`verify_android_form.dart` 新增 R12 节 14 条断言锁住「双签 + 回退契约 + 清单约定」，
全量门禁 32 步 / 2619 断言、`--selftest` 6/6、`flutter analyze` 0 issue。

**回退**：`dist/` 中 0.1.0 三份产物原样保留；因证书相同且 versionCode 均为 1，
`Shunbo-1.0.0-*.apk` 与 `Shunbo-0.1.0-*.apk` 可**双向直接覆盖安装**，无需先卸载。
完整实现、对照实验与判定条件见《顺播_1.0.0_电视端安装兼容适配说明》。

| 产物 | 字节 | SHA-256 |
|---|---|---|
| `dist/Shunbo-1.0.0-full.apk` | 39 359 764 | `b7b173bc…d944505` |
| `dist/Shunbo-1.0.0-lite.apk` | 20 698 082 | `edcc9038…4814b32` |
| `dist/Shunbo-Setup-1.0.0-x64.exe`（已签名 `CN=Shunbo`） | 25 294 120 | `61a920bc…48f67c4` |

## 13. 底部控制区自动隐藏 / 悬停唤出（2026-11-08）

桌面 / Web 播放界面：默认整条控制区滑出屏幕底部；鼠标移入页面底部 96px 触发带并
连续停留 260ms 才滑入；离开触发带 300ms、或连续 3200ms 无鼠标操作后再次滑出。

- **状态机**：`lib/ui/widgets/auto_hide_controls_policy.dart`（纯 Dart，不依赖
  flutter / dart:ui；时间由 `advance(ms)` 外部推进，因此时序可精确回归）。
- **渲染**：`lib/ui/live/player_overlay.dart` 用 `AnimatedPositioned`
  （`bottom: 0 → -82`）+ `AnimatedOpacity` + `IgnorePointer` +
  `Stack(clipBehavior: Clip.hardEdge)`，220ms `easeOutCubic`；隐藏时是真的移出
  画面，既不遮挡主要内容也不吞掉画面点击。
- **触发检测**：全幅 `MouseRegion.onHover` + `LayoutBuilder` 取播放区高度，
  不新增可见热区、不新增会拦截点击的透明层；高度无界时安全回退。
- **防误触发**：停留阈值 260ms；一轮等待窗口内累计位移 > 120px 视为「划过」
  并重算停留时间，快速划过不会因为恰好够 260ms 就弹出。
- **防重复触发**：自动隐藏后不重新武装，鼠标必须先离开触发带再回来才能开始
  下一轮；重复 enter / 重复 `pointerLeave` / 重复 `advance` 均幂等。
- **显示期间可操作**：控制条自身 `MouseRegion` 进入时暂停空闲计时；所有按钮点击、
  音量滑块拖动、频道入口点击都调 `interaction()` 重置空闲；从触发带移到控制条
  （同在底部带内）不会触发隐藏。
- **形态保护**：`autoHide` 默认 false，只有 `!tvMode && !touchInput` 的桌面形态
  启用。电视（遥控器）与手机（手指）不产生 hover，仍走原来的「精简条常驻 +
  点画面钉住」；暂停 / 无信号 / 钉住三种兜底强制显示，不会被自动隐藏吃掉。
- **开销与生命周期**：单个 `Timer.periodic(50ms)`，仅在 `needsTicking` 时喂时间、
  仅在 `visible` 变化时 `setState`；`dispose`、形态切换、全屏切换都有清理与
  坐标复位。

回归 `dart run tooling/verify_auto_hide_controls.dart` **147/147**（8 组时序 +
渲染 / 形态静态护栏），已注册进 `verify_all.dart`。本轮统一门禁
**33 步 / 2766 断言 / 96.5s** 全绿，`--selftest` 6/6，`flutter analyze` 0 issue。

交互预览（本机 `flutter run -d windows` 受 VS 桌面运行时阻塞，无法真机走查）：
`E:/TV/output/player-controls-autohide/index.html`，浏览器打开即可用鼠标验证；
右上角实时状态面板、内置自检 33/33，URL 加 `#show` 可直接看控制条展开态。
页面 JS 状态机与本节的 Dart 策略参数一致，仅用于手感验证，不参与构建。

## 14. 运行时版本兼容分支（2026-11-08，乐视 API 18 实测后）

自检页实测：Letv S50 Air / Android 4.3 / **API 18** / `armeabi-v7a, armeabi` /
不支持 v2 签名。`eUI 8.0` 只是厂商界面版本号，不是 Android 版本。顺播 1.0.0
基于 Flutter 3.47，引擎 AAR 下限 `minSdk 24`，所以这台设备无法加载默认流程；
补 v1 签名已经解决「解析失败」的第一道门槛，剩下的是系统版本下限。

**三个定义**（唯一事实来源：`lib/platform/version_compat.dart`，纯 Dart 可裸跑）：

| 项 | 定义 |
|---|---|
| 比较对象 | 设备 Android API 等级 `Build.VERSION.SDK_INT`（整数） |
| 排除 | 应用版本 1.0.0、`Build.VERSION.RELEASE`（「4.3」）、eUI 8.0 —— 都不是门槛，且字符串比较会误判 |
| 低版本阈值 | **24**，严格 `<`：`<24` 兼容分支，`>=24` 默认流程；边界 23→兼容 / 24→默认 / 25→默认 |
| 兼容分支范围 | 启动引导 + 能力探测 + 交付判定；**不碰**播放内核、换源调度、投屏、续播、UI、数据格式、清单/签名/版本号/产物 |
| 失败策略 | Android 探测失败 / 字段缺失 / 值非法 → 兼容分支 + `degraded`（保守侧）；非 Android → `notApplicable`，默认流程逐字不变 |
| 分支切换 | 启动期 `CompatBranchSelector` 锁存一次，运行期不翻转 |

落点：`SystemProbe.kt` 的 `buildInfo()` **增量**返回 `sdkInt`/`release`；
`SystemChannel` 只透传不比较；`main()` 决策一次并注入 `ShunboServices`；
兼容分支仅停掉 `shunbo/network` 精确回调（调用方原本就有
`DefaultNetworkStateProvider` 兜底），播放主链路不变；设置页「关于与诊断」
新增「运行分支 / 版本比较」两行。`ProbeActivity.java`（minSdk 16 自检入口）
是同一套判定的原生镜像，构建脚本会跨语言核对阈值、严格小于与保守策略。

**验证**：`verify_version_compat.dart` **227/227**；统一门禁 **34 步 /
2993 断言 / 98.2s** 全绿，`--selftest` 6/6，`flutter analyze` 0 issue；
`flutter build apk --release --flavor full` 真实编译通过（101.1s，
`minSdk 24 / versionName 1.0.0 / versionCode 1`，`apksigner @22` 仍
`Verifies` 且 v1+v2 均 true）。探针重建 min16 8,879 B / min24 16,865 B，
7 条跨语言一致性 + 7 个分支场景全绿。详见
《顺播_版本兼容分支改动范围与验证结果》md/html/pdf。

**不声称完成**：本轮没有实现低版本原生播放器，兼容分支在 API 18 上只保证
「判定 + 原生自检入口」可运行；Flutter 版顺播在这台电视上仍装不上跑不了。
真机运行态（无 adb）、兼容分支下运营商识别走兜底的实际表现均未走查。
版本仍 1.0.0+1，`dist/` 三份 1.0.0 产物哈希未变、未重打。
**后续用户已明确选择「路线 B」，原生播放器兼容分支见 §15。**

## 15. 原生兼容分支 / 路线 B（2026-11-08，独立 APK）

用户据 `331.jpg` 真机自检（`Letv S50 Air / Android 4.3 / API 18 /
armeabi-v7a,armeabi / legacyCompat`）选定路线 B：让顺播在这台电视上
装得上、起得来、能换台、能起播。

**这是另一个 APK，不是主程序的补丁**：`shunbo/legacy/` 下独立纯 Java 工程，
产物 `dist/Shunbo-Legacy-1.0.0-armv7a.apk`（3,427,674 B，SHA-256
`e3d3f310…`），包名 `com.shunbo.tv.legacy`，与主程序并存不覆盖。

| 项 | 值 |
|---|---|
| 系统门槛 | `minSdk 16 / targetSdk 22 / versionCode 1 / versionName 1.0.0`（未升版本） |
| 签名 | **仅 v1(JAR, SHA-1)**；`@16` 与 `@18` 档均 `Verifies` |
| ABI | 仅 `armeabi-v7a`；3 个 so stored + 4 字节对齐 |
| 内核 | ijkplayer 0.8.8 官方 aar（LGPL-2.1），FFmpeg 软解；关硬解 / 关 OpenSL ES |
| 清单 | `tooling/gen_legacy_catalog.dart` 从 `verified_channels.g.dart` 生成 **441 台 / 516 线路** |
| 判定 | `LegacyVersionCompat.java` 是 `version_compat.dart` 的原生语义镜像，启动期锁存一次 |

取舍要点：不用系统 `MediaPlayer`（API 18 的 HLS 残缺，而 516 条全是 `.m3u8`）、
不从加固过的参考包抠 so、不合并令牌按小时过期的官方卫星源；https 线路
（252 条）保留但排序靠后，连续 3 次失败后整体跳过。换源 12 秒首帧超时 +
`attempted` 防绕圈 + 全失败明确提示。

**验证**：`legacy/build_legacy.py` **78/78**（含 8 个分支场景、dex 高版本
API 扫描、交互 11 条、台账 7 条）；`verify_legacy_compat.dart` **127/127**
（注册为第 33 步）；统一门禁 **35 步 / 3120 断言 / 108.4s 全绿**；`--selftest` 6/6；
`flutter analyze` 0 issue；连续两次构建 SHA-256 一致（可复现）；证书
`50347d02…cd6ea` 与 1.0.0 主包相同。**主程序零改动**：gradle / pubspec / lib /
版本常量 / 0.1.0 与 1.0.0 全部产物哈希逐字未变。

### 15.0 交互打磨与可播台账（2026-11-08，真机「能播」之后）

真机确认能播后，补齐体验四条：遥控器逐键与换台换线、按实测可播性重排清单、
收藏 / 上次观看 / 频道名检索、布局对齐主流电视播放器。

| 项 | 做法 |
|---|---|
| 模式状态机 | `MODE_PLAY/CONTROL/PANEL/SEARCH/HELP` 五态，`setMode()` 单点管可见性与自动收起；面板收起后必须回落播放态（否则「遥控器像失灵」） |
| 控制条 | OK 唤出，8 动作（频道 / 上下台 / 暂停 / 换线 / 收藏 / 检索 / 信息），焦点左右环绕，5 秒无操作收起；展开时 ↓ 不换台 |
| 台号直达 | 最多 3 位、2 秒自动提交、越界给范围提示；换台横幅 1.5 秒 |
| 换台合并 | 连按只在 280ms 后提交一次，不再「按 5 下播 5 次」 |
| 频道抽屉 | 400dp、9 行窗口、动态分组（全部 / 收藏 / 实际出现的小组）、菜单键收藏、**数字键不吞** |
| 拼音检索 | 26 字母 4 行参差键盘 + 离线索引 `legacy/tools/pinyin_initials.json`（428 字），六档评分（首字母前缀 100 > 全拼 80 > 台名 70 > 包含 50/30/20），插入排序保稳定 |
| 收藏 / 续播 | `Prefs`（`SharedPreferences` 私有，`SCHEMA=1`）存 `favorites` / `last_channel_num` / `last_stream_index`；启动回台、`surfaceCreated` 续上次线路、首帧回调才落盘 |

**可播台账**（`tooling/probe_legacy_streams.dart` → `legacy/assets/probe_ledger.json`）：
判据为 m3u8 HTTP 200 + `#EXTM3U`、master 再拉变体、首个分片 `Range` 实收 ≥4 KB；
两轮 8 并发/8s → 2 并发/15s 复检。实测 **516 条线路 478 可达（92.6%）、38 死线（7.4%）**；
441 台中 **406 台至少一条可达（92.1%）**，35 台全失败。可达耗时中位 331 ms。
死线归因：`not m3u8` 14、`HTTP 403` 8、`HTTP 404` 5、`timeout` 8、连接关闭 2、
分片 404 1。**死线只沉底不删除**（PC 侧可达 ≠ 电视侧可达），排序改为
「`probeOk` 组号 > `probeMs` 升序 > `verified` > `rank` 降序 > http 优先 > 原序号」。

**产物归档（本轮踩过的坑）**：重建直接覆盖了真机验证过的上一版包（`00c1829f…`），而工程没有 git、也没有 `dist/_prev/`，那只包**已不可恢复**。现在 `build_legacy.py` 在签名写出前会把已存在的同名产物移到 `dist/_prev/<name>.<时间戳>.<sha8>.apk.bak`，回归 `G07` 断言这个顺序（归档必须在 `apksigner` 之前），以后重建不会再丢回退件。

局限写清：台账是网络可达性判据，**不等价于解码成功**，也不证明内容正确；
从 PC 网络发起，与电视所在网络可能不同；`kVerifiedLiveAt` 超一月须重跑（本轮
`2026-11-08T11:59:35Z`）。交互**尚未在真机逐键走查**（13 键映射、焦点框可见度、
抽屉行高、280ms 手感）。详见《顺播_兼容版遥控器交互与可播台账》md/html/pdf。

**真机终态（2026-11-08 二轮回填）**：`00c1829f…` 修复版在乐视 S50 Air 上
**覆盖安装成功、打开不闪退、正常起播**。安装、启动、起播三项已真机确证；
交互改动之后的逐键（↑↓/←→/数字键/OK/菜单/搜索）、可播台数与线路占比、
https 线路与软解性能仍未走查。https 在 API 18 上的 native TLS、软解在 Cortex-A9
上的 1080p 表现、清单保质期（2026-11-07）、投屏/续播/诊断等主程序功能均不在本分支范围。
dex 里唯一一条 API 19+ 引用是 ijkplayer 未使用路径上的 `MediaDataSource`（API 23），已登记。

### 15.1 首轮真机回填：安装成功、打开闪退（已修复）

用户回填首轮包**安装成功、打开报错闪退**。`aapt2 dump badging` 实测启动入口为
`com.shunbo.tv.legacy.LegacyPlayerActivity`，而 dex 中只有
`com.shunbo.legacy.LegacyPlayerActivity` —— 清单 `package="com.shunbo.tv.legacy"`
配上相对名 `.LegacyPlayerActivity` 被系统拼成了前者。PackageManager 安装时不校验
类存在，点击图标时 `loadClass` 失败 → 闪退。上一版 45 条断言只查「dex 里有这个类」，
没查「badging 解析出的全限定名与 dex 一致」，属断言缺口。

修复（主程序仍零改动、版本仍 1.0.0）：activity 改**全限定名**但保留独立包名与
versionCode → 可**直接覆盖安装**；构建断言 45→54，新增 3 条从 badging 提取两个
入口名转 dex 描述符反查；新增 `CrashReport.java` 把未捕获异常写入私有
`last_crash.txt` 并可在菜单信息页回看；`onCreate` 整段 `try/catch(Throwable)` +
纯 TextView 错误页；`loadNativeLibraries()` 改为返回真实异常而非笼统 `false`。
旧坏包备份在 `dist/_broken/`。详细根因、修复与真机复验矩阵见
《顺播_原生兼容分支_路线B_改动范围与验证结果》md/html/pdf **§零、§十**。

## 16. 单包（1.0.1）：一个 APK 通吃 API 16–36

用户要求「安装就一个版本」。这条在 Flutter 技术栈里不是配置问题，是硬限制：

| 事实 | 实测证据 |
|---|---|
| Flutter 3.47 的 Gradle 插件对 `minSdk < 23` **直接抛异常** | `D:/flutter/.../DependencyVersionChecker.kt:117 errorMinSdkVersion = 23` |
| 把 `minSdk` 写成 16，`flutter build` 会**改写回** `flutter.minSdkVersion` | 构建日志 `Upgrading build.gradle.kts`；改完文件里变回 `minSdk = flutter.minSdkVersion` |
| 产物 badging 仍是 24 | `aapt2 dump badging app-full-release.apk` → `minSdkVersion:'24'` |
| Flutter 引擎本身要 API 24 | 引擎 AAR 声明；`FlutterExtension.minSdkVersion = 24` |

所以「一个包同时装进 API 18 的乐视 S50 Air 和现代设备」只能**绕开 `flutter build`**：

- `flutter build` 照常产出 Dart/AOT 产物（dex、so、assets、arsc）；
- `tooling/merge_single_apk.py` 用**自己的 manifest**（minSdk 16 + 分流入口）
  单独 `aapt2 link`，只取那一个 `AndroidManifest.xml`，arsc 沿用 Flutter 的，
  资源 ID 用 `--stable-ids` 对齐（脚本会断言 `LaunchTheme`/`ic_launcher`/`tv_banner`
  ID 与 Flutter 产物逐字相同）；
- **dex 顺序是核心**：原生内核作 `classes.dex`，Flutter 的两个 dex 顺延
  `classes2/classes3`。API 18 没有 multidex，系统只加载 `classes.dex`，
  于是它只看得见原生类，永远不会去加载/校验 Flutter 的类；
- `zipalign -p 4` + `apksigner` **v1 + v2 双签**（v1 给老解析器，v2 给 24+）。

运行时由唯一入口 `com.shunbo.legacy.RouterActivity` 分流：`SDK_INT >= 24` 跳
`com.shunbo.shunbo.MainActivity`（Flutter 完整界面），否则跳原生播放界面。
RouterActivity 只用 API 1 接口，用 `Class.forName` 做探针，**编译期不 import
任何 Flutter / androidx 类**，起不来还回落原生。

**必须删掉 `androidx.startup.InitializationProvider`**：ContentProvider 在
`Application.onCreate` 之前由系统创建，API 18 上会去加载 `classes2.dex` 里的
androidx 类 → 直接崩在启动，代码层面拦不住。

代价说清楚：Flutter 产物里这个 provider 只注册了两个初始化器 ——
`androidx.lifecycle.ProcessLifecycleInitializer` 与
`androidx.profileinstaller.ProfileInstallerInitializer`。删掉的含义是
**ProcessLifecycleOwner 不会自动初始化**（一旦有人调用它会 `IllegalStateException`），
以及 **Baseline Profile 不会被安装**（首次启动略慢）。前者本仓库零引用
（回归 N03b 扫 `lib/` 与 `android/app/src/main/kotlin/` 锁死），后者只是性能优化。

**频道源统一**：主程序运行时那份表（内置实测 + 官方卫星 + 城市补充 + 全网发现 +
`streams.json` 备用线路）由 `tooling/dump_live_catalog.dart` 导出成
`legacy/assets/unified_channels.json`，`gen_legacy_catalog.dart` 优先吃它，
再把可播台账注入排序。这样「电视上看到的台 = 手机上看到的台」，代价是清单
变成一次性固化快照，需要按月重跑到期复核。

**清单必须手动打进单包**（踩过一次）：`flutter build` 的产物里只有
`assets/flutter_assets/**`，**没有 `assets/channels.json`** —— 而原生界面
`ChannelCatalog.ASSET` 只从 `assets/` 读它。第一版单包漏了这一步，装上就是
「频道清单加载失败」。现在 `merge_single_apk.py` 从 `legacy/assets/` 搬运并
断言：包内条目存在、与源文件**字节一致**、规模与源一致（≥900 台 / ≥1500 线路）；
回归 N12（Java 端 `ASSET` 名与打包脚本 `LEGACY_CATALOG` 逐字相同，改名一侧就红）
与 N13（报告里 `catalog.channels/streams` 必须等于当前 `channels.json`）。

**口径要说清**：「同一套」指的是**同一份表与同一条生成链**，不是两个界面在任意
时刻的台数完全相同。Flutter 侧运行时还会去拉远端聚合订阅与城市补充，
网络好的时候能到 2000+ 条线路；原生侧用固化快照（导出时 1046 台 / 1895 条
原始线路，另加同路径明文镜像，见 §18.1），是那个时刻的下界而不是上限。

**版本**：`1.0.2+3`（pubspec / `kAppVersionName` / 安装器 / 单包清单 / 独立包
五处同源，回归 R12 + I01 锁住）。`1.0.1` / `1.0.0` 可被直接覆盖升级；回退到更低
versionCode 需要先卸载（versionCode 降级不允许）。历史 `1.0.1` 产物仍留在 `dist/`。

**产物与实测数字**（2026-11-09 17:15 同版重打，含 §25 顶部条移除 / chip 横向滚动 / 省市面板再放大；更早几版见 §17 / §18 / §19 / §23 / §24）：

| 产物 | 大小 | SHA-256 | 内置断言 |
|---|---|---|---|
| `dist/Shunbo-1.0.2-full.apk`（单包，交付这只） | 43,842,035 B | `8b07b620800951fa64b180a2ea66841fdf5024f05a499a135187b2c74739176a` | 24/24 |
| `dist/Shunbo-Legacy-1.0.2-armv7a.apk`（仅原生，回退用） | 3,528,219 B | `484b7eacf848576116be4d1fc68e84c3768a7eb091a52cf99b0593bf3ca1b99e` | 80/80 |

单包内容自证：`minSdkVersion:'16'` / `targetSdkVersion:'36'` /
`versionCode='3'` / `versionName='1.0.2'`；两个 category 都指向
`com.shunbo.legacy.RouterActivity`；dex 顺序 `classes.dex`（原生）→
`classes2.dex` / `classes3.dex`（Flutter）；`assets/channels.json` 1,024,206 B
与 `legacy/assets/channels.json` 字节一致（1046 台 / 2135 线路，含 `is4K` /
`province` / `city` / `regions` / `mirror` / `quality` / `extra`）；
`apksigner verify --min-sdk-version 16/18` 均 `Verifies`，v1 + v2 同时存在；
`zipalign -c -p 4` 通过。
2135 = 台账逐条对齐的 2082 条（1895 原始 + 187 明文镜像，见 §18.1）
+ 53 条独立实测通过的扩展线路（见 §19.2）。

**频道与线路台账**（同一份表，2026-11-09T05:40Z 探测）：

| 指标 | 数值 |
|---|---|
| 频道 / 线路 | 1046 / 2135（http 1380、https 755） |
| 台账逐条实测线路 | 2082 条，其中可达 1046 条（50.2%）；至少一条可达的频道 605 / 1046 |
| 清单里 `probeOk=true` | 1103 条（含明文镜像与扩展线路），每台排在最前；扩展线路另起一层 |
| 解码实测标记 | 524 条（`verified`，来自 libmpv 逐条解码） |
| 高清标签 `quality>=720` | 930 条；CCTV-1 有 4 条（720P×1、1080P×3），其中 2 条台账可达 |
| 拼音覆盖 | 576 个台名用字全覆盖，缺 0 |
| 探测口径 | 第一轮 8 并发 / 8s 全量；第二轮 3 并发 / 12s 复检前 300 条失败项；跟随 302 后以最终 URL 解析分片（见 §19.2） |

**302 之后的分片基址**是本轮把可达率从 32.3% 抬到 50.2% 的根因：旧探针跟随
重定向后仍拿原始 URL 解析相对分片，123 条本来能播的线路被误判 `segment HTTP 404`。
修复后交叉核对结论不变：**低可达率主要来自聚合源灌水**（解码实测 27/31 可达、
旧判活 22/22 可达、聚合 17/341 可达）。死线**不删除只沉底**
（`probeOk` 分组 2），因为「PC 侧不可达 ≠ 电视侧不可达」。

构建：
```
flutter build apk --flavor full --release --target-platform android-arm,android-arm64
python tooling/merge_single_apk.py --skip-flutter-build   # 复用已编译的 Flutter 产物
python legacy/build_legacy.py                            # 可选：仅原生的回退包
```
若 `legacy/single/work` 被系统安全策略加了「禁止删除子项」的 ACL（无法 rmtree
也无法重命名），不必去动保护规则，换一个干净目录即可：
`SHUNBO_SINGLE_WORK=work_20261109 python tooling/merge_single_apk.py --skip-flutter-build`。

**不声称完成的部分**：单包在 API 18 真机上**尚未验证**（本机无设备/模拟器满
足不了硬件虚拟化，也用不了模拟器），只能静态确证 minSdk 16、入口可解析、
dex 顺序与签名档位；Flutter 侧在 24+ 的行为也未回归（多 dex 顺延、移除
startup provider 的影响需实测）。台账是**网络可达性**判据，不等于解码成功，
且从 PC 网络发起，与电视所在网络可能不同，超过一个月须重跑。

## 17. 电视端交互修订（1.0.1 同版重打，2026-11-09）

依据两张真机截图的红标与三项补充需求，在**同一个版本号**上重打产物：
版本常量仍是 `1.0.1+2`，`1.0.0` / `0.1.0` 回退基线不动。

### 17.1 截图红标

| 红标 | 现象 | 根因 | 修复 |
|---|---|---|---|
| 22.png ① | 台名后面挂着 `·2` / `·1`，被读成「频道号的 -2 / -1」 | `ChannelPanel.render()` 把「台账可达线路数」拼在台名后 | 列表行只保留「台号 + 台名」；可达信息仍在信息页摘要里 |
| 22.png ② | `CCTV-2` 显示台号 3 | 清单按主程序导出顺序编号，「中国教育1台」插在 CCTV-1/2 之间 | `gen_legacy_catalog.dart` 对央视组按主流顺序重排后再连续编号；`CCTV-1..17 = 1..17`，画质变体 / 海外版 / CGTN / 教育台依次靠后 |
| 12.png | 切台成功后左上角 `CCTV-1 央视频道 · 线路 1/10 · 首帧 705ms · API 18/legacyCompat` 常驻 | `topBar` 建好后从没隐藏过 | 首帧成功后 `hideOsdForPlayback()` 收掉顶部信息条与底部提示；换台 / 唤出控制条 / 频道栏时重新显示，回到播放态若已出画则再收起 |

### 17.2 4K 归集（与排序无关）

`channels.json` 每个台新增 `is4K`（判定规则由 `live_region.dart` 的
`ChannelQuality` 提供，手机与电视共用一条正则）。列表渲染前做一次**稳定分区**：
4K 整组挪到最前，4K 之间 / 非 4K 之间保持清单原顺序。**不改台号、不改线路
优先级、不改数字直达**。「全部 / 收藏 / 央视 / 卫视 / 地方 / 其它 / 地区」每个
列表都适用。实测 15 个 4K 台（含 CCTV-4K、10 个卫视 4K、苏州 4K×2 等）。

### 17.3 地方台默认本地 + 省 / 市切换

`channels.json` 新增 `province` / `city` / `regions`：归属用主程序
`CityDirectory.inferCity` 推断城市、行政区划代码反查省、台名前缀补省级台；
省 / 市选项与台数在数据层算好，老机器运行时零计算。

- 默认 **江苏·苏州·市模式**，只显示苏州 7 个地方台；央视 / 卫视 / 其它频道
  任何地区下都始终可见。
- 频道栏「地方」后面的「地区」分组按 OK 打开两列面板：左列选省 = 加载本省
  **全部**地方台（江苏 53 台），右列选市 = 只加载该市台（南京 4 台），
  ←→ 切列时右列跟着换省。
- 末项「其它城市」回捞推断不出归属的 599 台，避免切换地区让频道永久消失。
- 选择落 `SharedPreferences`，开机先恢复地区再定位「上次观看」；当前台不属于
  新地区时自动切到新列表第 1 台，不会下标越界或黑屏。
- 地区过滤做在 `ChannelCatalog` 的**统一可见视图**里，`size()/get()/
  indexOfNumber()` 全部只返回可见台，于是频道栏、检索、方向键换台、数字直达
  自动遵守同一条规则。

主程序同步：频道列表在按台号排序后做同样的 4K 稳定分区；地方频道默认从
「全部城市」改为本地（苏州），城市下拉新增「按省」项，优先级为
用户选择 > IP 定位 > 本地默认 > 全部城市。

### 17.4 缓冲卡死

**根因**：旧实现在主线程同步调用 `IjkMediaPlayer.stop/reset/release`。网络卡在
缓冲时 native 读线程不退，`release()` 会 join 等它 → 主线程被卡死 → 遥控器按不动、
换台没反应；同时 `onInfo` 等 native 回调直接改 TextView（非 UI 线程操作 View）。

四层修复（全部在 `PlaybackController.java`）：

1. `stop/reset/release` 丢给单线程后台队列，主线程只做 `setDisplay(null)`，
   换台 / 换线 / 数字直达随时可抢占；
2. 所有 native 回调用 `postToUi` 回主线程，界面更新不再跨线程；
3. 每次起播递增 `generation`，旧 player 迟到的回调一律丢弃，不会把「上一台的
   缓冲中」贴到新台上；
4. 12 秒首帧超时 + 首帧后 15 秒缓冲看门狗 + FFmpeg `timeout` 10 秒，卡住就
   换下一条线路；`onCompletion` 反复重连超过 3 次也改换线。

`packet-buffering=1` 保留：靠超时换线解决卡死，而不是关掉缓冲引入音画不同步。

### 17.5 验证口径与边界

`verify_legacy_compat.dart` 新增 O 组 20 条断言（合计 161/161），其中 O03 / O05–O07
直接对 `channels.json` 跑与 Java 端等价的 4K 分区与省 / 市过滤仿真，O18 用状态机
跑「缓冲 → 换台抢占 → 旧代回调作废 → 首帧 → 缓冲超时换线」转移序列。
全量门禁 35 步 / 3154 断言、`--selftest` 6/6、`flutter analyze` 0 issue。

**不声称完成**：以上三项都未经 API 18 真机走查（本机无设备/模拟器）。缓冲修复是
线程模型与超时策略的静态确证 + 纯逻辑仿真，实际网络下的恢复时间、软解卡顿、
遥控器手感仍需上机；4K 台能否真解出 4K 画面取决于线路与电视解码能力。


## 18. 苏州地方台修复与频道栏重设计（1.0.1 同版重打，2026-11-09 12:30）

依据三张真机截图的红标：**列表下方大片留白**、**列表背景要透明**、**「地区·苏州」看不出能切换**，
以及「苏州地方台全部频道无法播放」。仍不升版本（`1.0.1+2`），主程序 Dart 侧这轮没动。

### 18.1 苏州台全不可播：定位、范围与修复

**受影响范围**：台号 `369–373`（苏州新闻综合 / 社会经济 / 文化生活 / 电影娱乐信息 /
生活资讯）、`618 苏州4K`、`619 苏州4K频道`，共 **7 台**。异常表现是每台
「全部 1 条线路不可用」（4K 台为 1–2 条），按 ←→ 手动换线也救不回来。

**根因是三层叠加，实测数据如下**：

| 现象 | 实测 |
|---|---|
| 这 7 台的线路清一色是 https，且**一条明文兜底都没有** | 全清单 1046 台里有 408 台如此，苏州 7 台全在内 |
| `live-auth.51kandianshi.com` | TLS 1.3 + `TrustAsia DV TLS RSA CA 2024` 新链，ijkplayer 0.8.8 的旧 OpenSSL 很可能协商不了；**同路径 http 200 且分片可下** |
| `tylive.kan0512.com`（苏州 4K 官方） | PC 上 https 就握手失败（`curl code=000`），**同路径 http 200 且分片可下**；台账也把这两条判死 |
| `PlaybackController` 的 `httpsUnavailable` | 连续 3 条 https 失败后置位并**永久跳过**剩余 https 线路，于是只有 https 的台立刻进「全部不可用」，手动换线也进不了候选集 |

**修复（不猜白名单，逐条实测）**：新增
`tooling/probe_plaintext_mirrors.dart`，对 408 台的 576 条唯一 https 线路逐条测
「同路径 http 的 m3u8 2xx + 首分片 2xx」，只把通过的写进
`legacy/assets/plaintext_mirrors.json`（182/576 通过，2026-11-09T04:17Z）。
`gen_legacy_catalog.dart` 只给「原本没有任何明文线路的频道」追加镜像，
标注 `mirror=true / https=false / probeOk=true`，**频道、台号、原始线路一条没删**。
结果 187 条镜像覆盖 176 台，苏州 7 台全部有明文线路且排在前面。

播放内核同步把「永久跳过」改成**两遍扫描**：第一遍优先明文，第二遍仍把加密线路
试完；`switchTo()` 清掉 TLS 经验值，新增 `retryAll()` 一键从第一条重来。
异常提示不再只说「不可用」，而是给出「本机 HTTPS 连续失败（TLS / 证书链），
已优先尝试 N 条明文线路，共 M 条均未出画」+「按 OK 重试全部线路（含加密）·
←→ 手动换线 · 频道键换台」；`allStreamsFailed` 时 OK 直接重试，控制条也加了「重试」。

### 18.2 频道栏：透明、填满、状态明确

- `Ui.PANEL_SCRIM = 0xA60B1420`（65% 压暗）替代 `0xF2` 实色；非焦点行无底色，
  分组 chip 与状态卡也用半透明 `CARD_SCRIM`。左侧播放画面能透出来。
- 行数从写死 9 行改成**按屏幕高度算**（`CHROME_DP=190`、最少 9 最多 16 行），
  行高用 `weight=1` 均分剩余空间，下半屏不再留白。
- 底部新增状态卡：`▶ 371 苏州文化生活 · 线路 1/2 · 播放中`（异常时红色
  `⚠ … 全部线路不可用`）+ `地区 苏州 · 7 个地方台 ▾ 绿键 / OK 切换省·市`，
  由 `setPlaybackState()` 从 Activity 推送，首帧 / 缓冲 / 失败 / 换线都实时更新。

### 18.3 地方台切换：入口清晰、步骤少、不打断播放

| 入口 | 操作 |
|---|---|
| 绿键 / 导视键 | 播放态、频道栏、控制条任一界面一键打开；面板内再按一次取消 |
| 频道栏 chip | `地区·苏州 ▾切换`，点击即开 |
| 底部状态卡 | 列表按 ↓ 到底再按一下聚焦，OK 打开；鼠标可直接点 |
| 控制条 | 新增「地区」按钮 |

面板改三列：**最近使用 / 省 / 市**。默认聚焦「最近」并排除当前地区，
常看城市「绿键 → OK」两步到位；另有一键「▸ 江苏全省（全部地方台）」。
标题写明「当前地区 · 地方台数 · 正在播的台与播放状态」，左列选省加载本省
全部、右列选市只加载本市，**选中即应用并关闭**，没有二次确认。

切换只在 `ChannelCatalog` 重算可见列表，**不再调用 `startChannel(0)`**：
Activity 用 `playingChannel` 保存真正正在播的频道对象，当前台被新地区过滤掉时
画面照旧播、顶部信息与续播仍指向它，只是频道栏不画「正在播放」标记。
`Prefs.recentRegions()` 落盘最近 5 个地区。顺手修了「从频道栏打开地区面板时，
频道栏被隐藏会被误判成按了返回、模式抢回播放态」的交互坑。

### 18.4 验证

| 项目 | 结果 |
|---|---|
| 全量门禁 `verify_all.dart` | **35 步 / 3171 断言全绿**（新增 P 组 17 条） |
| `--selftest` / `flutter analyze` | 6/6 / 0 issue |
| legacy-compat / 独立包 / 单包 | 178/178、80/80、24/24 |
| 数据自证 | 明文镜像 182/576 实测通过；苏州 7 台全部有明文线路；台账 1895 条与非镜像线路逐条对齐 |

P07 直接仿真内核在 TLS 降级态的第一遍扫描，确认 7 个苏州台都能挑到可试线路。

**不声称完成**：以上仍是代码 / 数据 / 纯逻辑仿真层面的确认。本机无 API 18
设备与模拟器，明文镜像在电视网络下的实际起播、旧 OpenSSL 对
`51kandianshi.com` 的 TLS 行为、透明浮层在老屏上的对比度、绿键键码在
乐视遥控器上的映射、以及 4K 软解表现都**未经真机走查**。若电视侧网络屏蔽
明文 80 端口，两遍扫描会自动回落到 https 线路并给出明确失败原因。

## 19. 错误提示收起 / 浮层自动隐藏 / 线路扩容 / 设置中心（1.0.1 同版重打，2026-11-09 14:08）

对应两张真机截图红标与三条追加要求：① 切到一个播不了的台，黑底错误框
「全部 1 条线路不可用」一直停在画面中央；② 无操作时右侧频道栏不消失；
③ 播放源太少、CCTV-1 要有高清、要有设置（开机自启 / 启动直接播放）。
版本仍为 `1.0.1+2`，主程序 Dart 侧零改动，只动 `legacy/` 与 `tooling/`。

### 19.1 错误 OSD 生命周期与失败自动回退

- `LegacyPlayerActivity` 新增 `failHintTask` / `scheduleFailureDismiss()` /
  `cancelFailureTasks()`。全部线路失败后，错误框只停留 **2 / 3 / 5 秒**（默认 3 秒，
  设置项可改），到点自动 `showStatus("")` 清屏；不再常驻。
- `lastGoodChannel` / `lastGoodStreamIndex` **只在 `onFirstFrame()` 真正出画后**
  记录，绝不把「连接中 / 缓冲中」当成可回退目标。失败提示结束后若开启
  「切台失败自动回退」（默认开），自动回到上一个出画的台与原线路。
- `onKeyDown()` 开头统一 `resetOverlayHide(); cancelFailureTasks();`：
  用户一按任何键，就撤销待执行的回退与提示清除，不跟人抢遥控器。
- `retryAllStreams()` / `startChannel()` 同样先取消失败任务，避免旧定时器
  把新台的提示清掉。

### 19.2 频道/控制/地区/检索浮层统一空闲隐藏

`setMode()` 对 `MODE_CONTROL / MODE_PANEL / MODE_SEARCH / MODE_REGION`
统一调 `scheduleControlHide()`；`scheduleControlHide()` 用一个共享计时器，
默认 **5 秒**收起回播放态，设置项可选 3 / 5 / 8 / 10 秒或「不隐藏」。
任意按键经 `resetOverlayHide()` 重置计时。**设置页本身不自动收起**——
正在逐项改值时把人踢回播放态是主流播放器不会做的事。

### 19.3 播放源扩容：先修探测，再补线路

**(1) 302 最终 URL 基址**（`tooling/probe_legacy_streams.dart`）：旧探针跟随
302 后仍用原始 URL 解析播放列表里的相对分片，123 条本来能播的线路被误判
`segment HTTP 404`。改为 `_Response.url = redirects.last.location`，主播放列表
与 variant 都按最终 URL 解析。重跑台账（8 并发/8s + 3 并发/12s 复检）：

| 指标 | 修复前 | 修复后 |
|---|---|---|
| 可达线路 | 612 / 1895（32.3%） | **1046 / 2082（50.2%）** |
| 至少一条活线的台 | 503 | **605** |
| CCTV-1 可达线路 | 2 | **7**（含 720P） |

这不是「加了新源」，而是**把清单里本来就有、却被误判死的线路救回来**。

**(2) 扩展线路池**（新增 `tooling/collect_extra_streams.dart`）：固化 9 份公开
聚合快照到 `tooling/source_snapshots/`（Guovin / APTV / YueChan / iptv-org
全球与中国 / fanmingming 央视高清与 IPv6 / vbskycn），按台名归一化匹配
央视 + 卫视 + 苏州台；**只排除「本台」已有 URL，不做全局去重**（聚合源把
大量线路挂错台，全局去重会让 CCTV 一台候选都拿不到）；多源轮转取样；
逐条实测 m3u8 2xx + 首分片 2xx/206 ≥ 4 KB，10 并发/7s 首轮 + 3 并发/12s 复检。
结果：**197 条候选 → 53 条通过，覆盖 24 台，其中 8 条带高清标签**。
输出 `legacy/assets/extra_streams.json` 带来源、台号、耗时、分片字节，可回溯。

**(3) CCTV-1 高清**：清单原本就有 4 条高清线路，只是被旧台账判死。
重跑后台账中 `CCTV-1 (720p)` 实测可达（1547 ms），`3m1080p` 索引线路也可达；
另 2 条 1080P 本机握手失败，保留作兜底不删。生成器给每条线路写
`quality`（2160/1080/720/576/0），`ChannelCatalog.applyQualityPriority()`
按设置重排尝试顺序——**自动档先试可达的高清**，也可强制 1080P / 720P /
标清优先。扩展线路单独一层：排在原有可达线路之后、死线之前，不抢首播。

最终 `legacy/assets/channels.json`：1046 台 / **2135 线路**
（= 台账对齐 2082 + 扩展 53），单包内 `assets/channels.json` 与之字节一致。

### 19.4 设置中心（13 项 + 3 个动作，全部真实接线）

> §25 起为 **12 项 + 4 个动作**：「顶部信息条」开关随顶部信息条整体下线（§25.1）。

新增 `SettingsPanel.java`，↑↓ 选择、OK/←→ 修改、返回关闭，一屏内按权重
均分行高（老电视无滚动列表焦点问题），每项带说明与真机限制。控制条新增
「设置」按钮，蓝键 / `KEYCODE_SETTINGS` 也能直达。

| 分组 | 设置项 | 接线位置 |
|---|---|---|
| 启动 | 开机自启（默认关）、启动直接进入播放（默认开）、启动频道（上次观看 / 第 1 台 / 收藏首台） | `BootReceiver` + `RouterActivity` extras 透传 + `preferredChannelIndex()` |
| 浮层 | 自动隐藏（不隐藏/3/5/8/10 秒）、顶部信息条（首帧后隐藏 / 常显） | `scheduleControlHide()` / `hideOsdForPlayback()` |
| 失败 | 切台失败自动回退、失败提示停留（2/3/5 秒） | `scheduleFailureDismiss()` |
| 播放 | 优先清晰度、首帧超时（8/12/18 秒）、画面比例（铺满/16:9/4:3）、解码方式（软解/硬解） | `applyQualityPriority()` / `PlaybackController.setFirstFrameTimeoutMs()` / `setHardDecode()` / `applyAspect()` |
| 手感 | 台号输入确认（1/2/3 秒）、换台连按合并（不合并/280/500 ms） | 动态 `numberCommitMs` / `zapCommitMs` |
| 动作 | 清空收藏、恢复默认设置、关于与诊断 | `SettingsPanel.Listener` |

`BootReceiver` 监听 `BOOT_COMPLETED` / `QUICKBOOT_POWERON`，读取开关后用
`getLaunchIntentForPackage()` 拉起系统 LAUNCHER（单包与独立包都适配），
并写入 `EXTRA_AUTOSTART`；`RouterActivity` 重建 Intent 时把它透传下去。
`Prefs.SCHEMA=2` 但**旧键名（收藏、上次观看、地区）一个没改**，覆盖升级不丢数据。

**系统限制（设置页与帮助页都写明，不糊弄）**：Android 3.1+ 的 stopped 状态、
电视 ROM 的自启白名单、以及部分系统的后台启动 Activity 限制，应用本身无法绕过，
需要在系统设置里手动放行。

### 19.5 验证

| 项目 | 结果 |
|---|---|
| 全量门禁 `verify_all.dart` | **35 步 / 3196 断言全绿**（新增 Q 组 25 条） |
| `--selftest` / `flutter analyze` | 6/6 / 0 issue |
| legacy-compat / 独立包 / 单包 | **203/203**、80/80、24/24 |
| 数据自证 | 台账 2082 条与非扩展线路逐条对齐；扩展 53 条与 `extraStreamCount` 一致且全带 `probeOk`；CCTV-1 高清 4 条其中 2 条可达 |

产物：`dist/Shunbo-1.0.1-full.apk` 43,842,035 B（SHA-256
`5bc007f10cc3a33bda2bbcd5fa008d1f947a5b6518ddbf8f244e68663b45b132`）、
`dist/Shunbo-Legacy-1.0.1-armv7a.apk` 3,528,222 B（SHA-256
`5ba52973a6a1bed4ac67aa3e8ec59c8a69173d2050d0107ca1d5b338f3191e90`）。

**不声称完成**：本机仍无 API 18 真机 / 模拟器。开机自启在电视 ROM 白名单下
是否放行、蓝键键码映射、设置页在老屏上的对比度与焦点框、扩展线路的**画面
内容是否与台名一致**（PC 侧只验可达 + 分片可下载，不验解码与内容）、
4K 软解表现，均未经真机走查。超过一个月请重跑台账与扩展线路实测。

## 20. 地区切换入口改设置 + 浮层自动隐藏默认 30 秒可调（1.0.1 同版重打，2026-11-09 15:17）

对应一张真机截图与两条追加要求：① 在频道列表页**选具体播放频道**时，当前
会弹出「省 / 市台选择」界面，交互要改——改为「用户主动选地区」才弹，且把
地区切换入口收进底部控制栏的设置里，默认仍是当前市的所有电台；② 频道列表
页自动隐藏停留太短，改为**无操作超过 30 秒（默认）**才隐藏，并把该时长放进
控制栏设置菜单，支持手动调节。版本仍为 `1.0.1+2`，主程序 Dart 侧零改动，
只动 `legacy/` 与 `tooling/`。

### 20.1 地区切换：从「频道栏误触发」改为「设置 / 绿键 / 控制条直达」

根因定位（先看旧行为）：频道栏底部有一张「切换地区」状态卡，旧逻辑里**把
频道栏焦点用 ↓ 推到列表末行时会误聚焦这张卡**，此时按 OK 就打开省 / 市选择
面板——于是「在列表里选频道」和「弹省市面板」被绑在了一起，正是截图里
用户抱怨的现象。

改动（`ChannelPanel.java`）：

- 删除误触发路径：移除 `cardFocused` 字段及其全部引用（含 `show()` / `onClick`
  / `DPAD_UP` 前导块 / `DPAD_LEFT`·`DPAD_RIGHT` / chip `onClick` / `render()` /
  `renderInfo()` 背景 / `Ui.styleRow` 调用）。列表内 ↑↓ 只做行焦点移动，
  **DPAD_DOWN 末行不再环回聚焦地区卡**。
- 列表内 OK 语义固定为「切台」：`DPAD_CENTER` / `ENTER` 直接 `activate()`
  播放当前焦点台，不再有任何「弹省市面板」的分支。
- 底部状态卡背景改回统一 `Ui.CARD_SCRIM`，去掉选中高亮；底部提示改为
  `←→ 分组   绿键/设置 切换地区   返回 关闭`；地区行文案改为
  `…▾ 绿键 / 设置 / 点此卡 切换省·市`。

入口收敛到「明确要切地区」的操作（`SettingsPanel.java` + `LegacyPlayerActivity.java`）：

- 设置页新增 **「地区切换」** 条目（`ACTION_REGION = 4`，`Listener.onRegionFromSettings()`），
  位于顶部信息条之后；其 `activate()` 调 `listener.onRegionFromSettings()`，
  Activity 端 `onRegionFromSettings()` 直接 `setMode(MODE_REGION)` 打开省 / 市面板，
  不回退到播放态。
- 保留并明示其余三处入口：**绿键 / 导视键**、**控制条「地区」按钮**、以及
  底部状态卡的**触摸点击**（`regionLine`）。
- 默认仍是「当前市的所有电台」：`Prefs` 存的 `region` 不变（默认江苏·苏州），
  `ChannelCatalog.visible` 依旧按地区过滤，`playingChannel` 保证切地区不重启播放器。
  即「选地区才弹省市面板」成立，且默认即本地台。

### 20.2 浮层自动隐藏：默认 30 秒，可选 5/10/15/20/30/60 秒或不隐藏

`Prefs.java` 与 `LegacyPlayerActivity.java`：

- `K_PANEL_IDLE_MS` 默认值由 `5000` 改为 **`30000`**（适配遥控器选台节奏，
  不会因短暂思考就被收起）；`LegacyPlayerActivity.idleHideMs` 同步为 `30000L`。
- 设置页「浮层自动隐藏」选项由 `不隐藏/3/5/8/10 秒` 改为
  **`不隐藏 / 5 秒 / 10 秒 / 15 秒 / 20 秒 / 30 秒 / 60 秒`**
  （值数组 `{0,5000,10000,15000,20000,30000,60000}`，仍为 `ACTION_NONE` 直接写 `Prefs`）。
- `setMode()` 对 `MODE_CONTROL / MODE_PANEL / MODE_SEARCH / MODE_REGION` 仍统一
  `scheduleControlHide()`，**设置页 `MODE_SETTINGS` 依旧刻意不自动收起**（正在逐项
  改值时把人踢回播放态是主流播放器不会做的事）。任意按键经 `resetOverlayHide()` 重置。

### 20.3 验证

| 项目 | 结果 |
|---|---|
| 全量门禁 `verify_all.dart` | **35 步 / 3196 断言全绿**（C03b / Q06 / L06 / P14 同步更新；判据改为验证 `if (focus < filtered.size() - 1) focus++` 与 `onRegionFromSettings`） |
| `--selftest` / `flutter analyze` | 6/6 / 0 issue |
| legacy-compat / 独立包 / 单包 | **203/203**、80/80、24/24（`build_legacy.py`「panel focus wraps」断言同步去掉过时的 `cardFocused` 要求） |
| 数据自证 | 清单规模不变：1046 台 / 2135 线路（本轮未动源数据） |

产物：`dist/Shunbo-1.0.1-full.apk` 43,842,035 B（SHA-256
`e93af05211b54b91910c4f6f1f55b216d28c45f058837f81dcf35f23fb156122`）、
`dist/Shunbo-Legacy-1.0.1-armv7a.apk` 3,528,222 B（SHA-256
`dddc21c23eb10b9f3a5ddca6631b052ee9c2005679e8c82e8d18cb0792836558`）。

**不声称完成**：API 18 真机仍缺。本机未走查项与 §19 一致（自启白名单、蓝键键码、
设置页焦点框与老屏对比度、扩展线路内容是否与台名一致、4K 软解）；本次两处改动
均为静态确证 + 仿真 + 回归断言覆盖，未上机实测遥控器手感。超过一个月请重跑
台账与扩展线路实测。

## 21. 换台时不再弹出顶部调试信息条（1.0.1 同版重打，2026-11-09 15:36）

对应一张真机截图红标：顶部信息条「卫视频道 · 线路 2/2 · API 18/legacyCompat」
在**换台时**被弹出，用户要求「换台时，这边的信息隐藏不要显示」——即换台过程中
不显示这条顶部调试信息条。版本仍为 `1.0.1+2`，主程序 Dart 侧零改动，只动
`legacy/` 与 `tooling/`。

### 21.1 改动（`LegacyPlayerActivity.java`）

- 旧行为：`startChannel()` 与 `zap()`（连按合并）在换台一开始就无条件 `showOsd()`，
  把顶部信息条（含 `API 18/legacyCompat` 这类调试 / 诊断信息）弹出来；首帧后才由
  `hideOsdForPlayback()` 收掉——于是每次换台这条信息都会闪一下。
- 新行为：换台时**只有「顶部信息条 = 常显」才弹出**该条；默认（「首帧后隐藏」）
  换台全程保持隐藏，换台反馈改由画面中央的「台号 + 台名」横幅（`showChannelBanner()`，
  1.5 秒自动消失）承担，画面更干净。
- 两处调用均改为 `if (prefs != null && prefs.showTopBar()) showOsd();`：
  - `startChannel()`：直接切台 / 数字直达 / 频道键上下台 / 失败自动回退 / 列表选台后落定；
  - `zap()`：遥控器 ↑↓ / CH± 连按合并。
- 不影响既有设计：① 首帧成功后仍隐藏顶部条（`hideOsdForPlayback()` 不变）；
  ② 唤出交互（控制条 / 频道栏 / 地区 / 检索 / 设置 / 信息）仍 `showOsd()` 显示它作上下文；
  ③ 失败路径（`onStreamFailed` / `onAllStreamsFailed`）仍弹顶部条暴露错误；
  ④「顶部信息条 = 常显」用户仍能看到它。

### 21.2 验证

| 项目 | 结果 |
|---|---|
| 全量门禁 `verify_all.dart` | **35 步 / 3197 断言全绿**（新增 O17 锁「换台不再无条件弹顶部条」） |
| `--selftest` / `flutter analyze` | 6/6 / 0 issue |
| legacy-compat / 独立包 / 单包 | **204/204**、80/80、24/24 |
| 数据自证 | 清单规模不变：1046 台 / 2135 线路 |

产物：`dist/Shunbo-1.0.1-full.apk` 43,842,035 B（SHA-256
`4be6f059b29ec949957bcd63ea0b1e56063c0085dcca0e9bf8958068f0c1582a`）、
`dist/Shunbo-Legacy-1.0.1-armv7a.apk` 3,528,220 B（SHA-256
`65020857a8c34871a6b3080c572880dfc41d0ab90cb54e8cddf73968829d3d8f`）。

**不声称完成**：API 18 真机仍缺。本机未走查项与 §19 一致（自启白名单、蓝键键码、
设置页焦点框与老屏对比度、扩展线路内容是否与台名一致、4K 软解）；本次改动为静态
确证 + 仿真 + 回归断言覆盖，未上机实测遥控器手感。超过一个月请重跑台账与扩展线路实测。

---

## §22 频道号改中性白（截图红标）

**需求**：截图红框圈住顶部信息条的频道号「71」（当时为亮蓝 `Ui.ACCENT`），
红字批注「蓝色的频道号比较难看，换一种目前主流的呈现方式」——即频道号不要用刺眼
亮蓝，改成电视 / IPTV 主流的中性白色大号数字。

**改动**（`legacy/src/com/shunbo/legacy/LegacyPlayerActivity.java`，仅 `legacy/`
与 `tooling/`，Dart 零改动）：
- 顶部信息条 `topNumber`：`setTextColor(Ui.ACCENT)` → `setTextColor(Ui.TEXT)`（白色），
  字号 30、加粗不变；与白字台名靠字号 / 字重区分，不靠颜色。
- 换台中央横幅 `numberDigits`：`setTextColor(Ui.ACCENT)` → `setTextColor(Ui.TEXT)`
  （白色），字号 42、加粗不变；横幅深色圆角底不变，数字转白即与主流 IPTV（白字台号）
  一致。数字直达输入时复用的也是这同一个 `numberDigits`，因此一并转白，表现统一。
- 回归断言新增 **O18**：锁 `topNumber` / `numberDigits` 均为 `Ui.TEXT` 且不再含
  `Ui.ACCENT`。`Ui.ACCENT` 仍用于当前播放行、进度等其它强调位，未全局改动。

**验证与产物**
- 全量门禁 **35 步 / 3198 断言全绿**（O18 +1）；`--selftest` 6/6；`flutter analyze`
  0；legacy-compat **205/205**、android-form 91/91、python-m0 6/6；独立包 80/80、
  单包 24/24。
- 清单规模不变：1046 台 / 2135 线路。
- `dist/Shunbo-1.0.1-full.apk` 43,842,035 B（SHA-256
  `2b9c51241116ea9b7256e59b7fb3306650003a97dd32e493fc5d28cb323b3a46`）、
  `dist/Shunbo-Legacy-1.0.1-armv7a.apk` 3,528,224 B（SHA-256
  `d04fbc923a251765198bd187d7c95511f10963bd737feba57a1a6e249595ed44`）。

**不声称完成**：频道号为白字后，在浅色台标 / 浅色画面（如雪景、白底台标）上的可读性
未经真机走查；其余未走查项同 §19（自启白名单、蓝键键码、设置页对比度、扩展线路内容
一致性、4K 软解）。超过一个月请重跑台账与扩展线路实测。

---

## §23 频道导航栏新增内容分类（地方频道之后，2026-11-09 15:57）

**需求**：在频道导航列表（侧边栏菜单）中，于「地方频道」这一项**之后**，依次新增以下
频道栏目：**新闻、体育、影视、少儿、纪实、生活**。新增栏目须与现有频道项保持一致的
样式、排序规则与交互逻辑。

**改动**（仅 `legacy/` 与 `tooling/`，主程序 Dart 零改动；沿用 §16 同版重打）：

1. `legacy/src/com/shunbo/legacy/ChannelCatalog.java`（数据模型）
   - `Channel` 新增 `cats`（`List<String>`）字段：`主分类 group` + `叠加的内容分类`，
     构造期由 `computeCats(group, name)` 计算并冻结（`Collections.unmodifiableList`）。
   - 新增 `thematicOf(name)`：关键词判定内容分类，顺序与 Flutter 侧
     `channel_taxonomy.dart#thematicOf` 一致（少儿 → 体育 → 影视 → 纪实 → 生活 → 新闻）。
   - 新增 `inCategory(category)`：判定某频道是否属于该分类（叠加匹配）；镜像 Flutter
     侧 `LiveChannel.inCategory`。

2. `legacy/src/com/shunbo/legacy/ChannelPanel.java`（右侧频道抽屉）
   - `buildGroups()`：定位「地方频道」chip 下标后，依次插入 6 个内容分类 chip
     `新闻/体育/影视/少儿/纪实/生活`，随后再追加「地区·<当前市> ▾切换」镜像 chip。
     六个 chip 复用既有 `Ui.styleChip` + `rebuildChips`，故**样式、焦点、←→ 组切换、
     触摸点击与现有一致**。
   - `rebuild()` 过滤由精确 `group` 匹配改为 `c.inCategory(filterGroup)` **叠加过滤**：
     如「苏州新闻综合」既在「地方频道」也在「新闻」。分类内顺序保持 `channels.json`
     原序，既有的「4K 优先」稳定分区不变。

3. `tooling/verify_legacy_compat.dart`：新增回归断言 **O19**，锁住六分类顺序、
   `c.inCategory(filterGroup)` 过滤、`thematicOf` / `inCategory` / `cats` 三处实现。

**设计要点**
- 采用**叠加（overlay）**模型：内容分类不新建独立主组，而是挂在每个频道上的附加标签，
  与 Flutter 侧 `LiveRegion.groups` / `LiveChannel.inCategory` 完全对齐。
- **不重构 `channels.json`**：`unified_channels.json` 仅含 `id/name/group/badge/streams`
  字段，无 `categories`；本改动在 Java 解析期按台名关键词计算叠加分类，保留 1046 台 /
  2135 线路不变量，且只需重编 Java —— 单包用 `--skip-flutter-build` 复用既有 Flutter
  产物，零 Dart 改动。

**已知轻微偏差**
- `unified_channels.json` 的 `name` 已归一化（如 `CCTV-1` 不带「综合」后缀），部分
  「后缀含类型」的台（如原 `CCTV-13 新闻`）归一化后丢失类型线索，会少命中「新闻」。
  这与手机端（带后缀）有轻微发散，属可接受范围。

**验证与产物**
- 全量门禁 **35 步 / 3199 断言全绿**（O19 +1）；`--selftest` 6/6；`flutter analyze` 0；
  legacy-compat **206/206**、android-form 91/91、python-m0 6/6；独立包 80/80、单包 24/24。
- 清单规模不变：1046 台 / 2135 线路。
- `dist/Shunbo-1.0.1-full.apk` 43,842,035 B（SHA-256
  `cf871c9509e45106a60895c04c67a7a58b25129f50b47ff67a03c4e8ede501a7`）、
  `dist/Shunbo-Legacy-1.0.1-armv7a.apk` 3,528,223 B（SHA-256
  `24f0e6fb1b13c9e30d4ad454c6a3c6e5d063b8bd0141407007375c2e3c5a4aa7`）。

**不声称完成**：仍无 API 18 真机 / 模拟器。分类命中依赖台名关键词，召回率与排序手感
仅静态确证 + 仿真 + 回归断言覆盖，未上机实测遥控器逐键与分类面板实际展开效果；自启
白名单、蓝键键码、设置页对比度、扩展线路内容一致性、4K 软解仍需上机走查。超过一个月
须重跑台账与扩展线路实测。

---

## §24 换台误弹省市面板修复 + 省市面板排版优化 + 升版 1.0.2（2026-11-09 16:20）

**四项需求**：① 频道栏去掉「地区·苏州 ▾切换」chip（截图红标「地区切换去除」）；
② 修复「在频道列表中换台，第二次切换会再弹省市选择界面、导致换不了台」；
③ 省市选择面板「省、市 字体太小，上下间隔太大」，按主流播放软件重排；
④ 版本升到 **1.0.2** 并打包。

### 24.1 根因：频道栏里的可聚焦状态卡把 OK「吃掉」当点击

`ChannelPanel` 底部状态卡 `infoCard` 旧代码是 `setFocusable(true)` + `setClickable(true)`
+ `setOnClickListener → listener.onRegionRequested()`。整个频道栏里，列表行与分组 chip
都**不可聚焦**（只在 `Activity.onKeyDown` 里手写导航），于是 `infoCard` 成了**全窗口唯一
可聚焦控件**。频道栏显示后，遥控器 OK 会被系统当成「对聚焦控件的点击」直接派发，
`onRegionRequested()` 打开省 / 市面板——本该切台的 OK 变成了「弹地区选择」。
这正是「第一次正常、第二次又弹」的表象来源（焦点落点随面板重开而漂移）。
§20 之前只堵了「↓ 推到末行聚焦状态卡」这一条路径，**没堵住状态卡本身可聚焦**。

### 24.2 修复（`legacy/src/com/shunbo/legacy/ChannelPanel.java`）

- **状态卡改纯展示**：`infoCard.setFocusable(false)` + `setClickable(false)`，删除
  `setOnClickListener → onRegionRequested()`；底部状态卡只显示「当前台 / 线路 / 播放状态 /
  地区」，不再承接任何点击（OK 永远落回 `Activity.onKeyDown` → 切台）。
- **移除地区 chip**：删除 `GROUP_REGION` 常量及其在 `buildGroups()` 里的
  「地区·<市> ▾切换」镜像分组、`rebuildChips()` 的 chip 点击分支、`rebuild()` 的
  `filterGroup` 特判、`render()` 的 region 标题 / 空态分支。列表过滤统一
  `c.inCategory(key)`（叠加匹配不变）。
- **地区切换入口收敛为三处**：绿键 / 导视键（面板内与播放态）、控制条「地区」按钮、
  设置页「地区切换」。频道栏内不再有任何地区入口，在列表里按 OK 只会切台。

### 24.3 省市面板排版（`legacy/src/com/shunbo/legacy/RegionPanel.java`）

- 省 / 市 / 最近三列的行字号 **15sp → 19sp**，表头 **15sp → 17sp**，标题 **19sp → 20sp**。
- 行高由「`weight=1` 均分整列高度（9 行拉满全屏 ⇒ 行距巨大）」改为**固定 38dp、顶部紧凑
  排列**，行与行只保留必要呼吸感；`start()` 滚动逻辑不变。

### 24.4 版本 1.0.2（versionCode 3）

五处同源全部改到 `1.0.2` / `3`：`pubspec.yaml`（`1.0.2+3`）、`lib/platform/system_channel.dart`
（`kAppVersionName=kAppVersionCode`）、`legacy/AndroidManifest.xml`、`legacy/build_legacy.py`
（`OUT_NAME` / `aapt2 --version-code/--version-name` / 内置断言 / 报告）、
`tooling/merge_single_apk.py`（默认 `--version-name/--version-code`）、
`tooling/windows_installer.iss`、`LegacyPlayerActivity` 帮助文案「顺播兼容版 1.0.2」。
门禁断言同步：`verify_android_form` R12、`verify_version_compat` G14/G36、
`verify_legacy_compat` A04/G03/I01/N09/J03/J06 与 P14（地区入口收敛）/O19（`c.inCategory(key)`）。

**验证与产物**
- 全量门禁 **35 步 / 3199 断言全绿**；`--selftest` 6/6；`flutter analyze` 0；
  legacy-compat **206/206**、android-form 91/91、python-m0 6/6；独立包 80/80、单包 24/24。
- 清单规模不变：1046 台 / 2135 线路。
- `dist/Shunbo-1.0.2-full.apk` 43,842,035 B（SHA-256
  `6b133f1e9a32cb354b5b205368cdd875e17e9ae14060756a5a4c2e8a98a6af14`）、
  `dist/Shunbo-Legacy-1.0.2-armv7a.apk` 3,528,220 B（SHA-256
  `724134229615b4749934928f601d5675be43018a4bff3bbac14d12f31dd0210a`）。
- 构建工作目录 `SHUNBO_LEGACY_WORK` / `SHUNBO_SINGLE_WORK = work_20261109f`；单包
  `--skip-flutter-build`（Dart 侧仅版本常量随源码更新，TV 端展示的是 Java / manifest 版本）。

**不声称完成**：仍无 API 18 真机 / 模拟器。换台不再误弹、省市面板字号与行距为静态确证 +
仿真 + 回归断言覆盖，遥控器逐键手感、状态卡焦点彻底消失后的视觉一致性、分类面板实际
展开效果需上机走查；自启白名单、蓝键键码、设置页对比度、扩展线路内容一致性、4K 软解
仍需上机。超过一个月须重跑台账与扩展线路实测。

## §25 三处界面修正：顶部条彻底移除 / 分组 chip 横向滚动 / 省市面板再放大（2026-11-09 17:09）

三张截图红标，逐条对应：

### 25.1 顶部信息条「不管什么时候都不要显示」→ 整体删除

截图框住的是 `地方频道 · 线路 1/2 · 首帧 720ms · API 18/legacyCompat` 这条常驻诊断条。
上一版（§19 / §22）只做到「首帧后隐藏 + 换台不再无条件弹出 + 频道号转白」，用户仍能
看到它，本轮按批注**把这条信息条整个删掉**，不留任何显示路径：

- `LegacyPlayerActivity`：删除 `topBar` / `topNumber` / `topName` / `topMeta` 四个字段、
  整段构建代码、`refreshTop()` 方法与全部 15 处调用、`showOsd()` 与全部调用；
  `hideOsdForPlayback()` 只保留「收起底部提示 + toast」职责。
- 换台反馈全部交给画面中央的「台号 + 台名」横幅（`showChannelBanner`）；`zap()` 连按
  合并期间也**立即**刷新横幅（横幅优先取 `zapTarget`，与旧 `refreshTop` 的「先显示目标台」
  手感一致），280ms 后才真正起播。
- 设置项「顶部信息条」一并下线（`SettingsPanel` 12 项设置 + 4 个动作），`Prefs.showTopBar()`
  删除，`set_show_top_bar` 残留键在「恢复默认设置」时清掉。留着开关只会是个无效选项。
- 诊断信息没有丢：菜单键 →「关于与诊断」仍显示分支 / API / 清单摘要 / 上次崩溃。

### 25.2 分组 chip 一行放不下 → 横向滚动

截图批注：「当超出这个栏目数量时，后面可以滑动显示频道栏目，比如目前是其他频道，但是
下面菜单栏没有出现其它频道」。分组从 6 个涨到 12 个（全部 / 收藏 / 央视 / 卫视 / 地方 /
新闻 / 体育 / 影视 / 少儿 / 纪实 / 生活 / 其它），右侧面板宽度放不下，末尾几个被直接截断。

- `chips` 容器外面包一层 `HorizontalScrollView`（`chipScroll`），`chips` 宽度改
  `WRAP_CONTENT`，滚动条隐藏、`fillViewport=true`。
- 新增 `scrollChipIntoView(index)`：每次重建 chip 后把当前分组滚进可视区（左右各留 10dp
  余量，`smoothScrollTo`）。←→ 切到「其它」时 chip 自动露出，用户不会再「在其它频道里
  却看不到其它」。
- **防火墙**：`chipScroll.setFocusable(false)` + `FOCUS_BLOCK_DESCENDANTS` + `chip.setFocusable(false)`。
  频道栏所有按键都由 `Activity.onKeyDown` 手写，任何可聚焦子控件都会把 OK 抢走——正是
  §24 修掉的「第二次换台误弹省市面板」的成因，这里提前堵死。

### 25.3 省市面板：字号再放大 + 铺满列高 + 不溢出

截图批注：「要铺满，不留空白」；需求原文：「字体进一步放大，使文字更醒目、层级更清晰，
并保证放大后整体布局仍然整齐、不出现溢出或错位」。

演进链：15sp + `weight=1` 拉满（行距巨大，§24 前）→ 19sp + 固定 38dp 顶部对齐（底部一大片
空白，§24）→ 本轮 **22sp + 行数按屏高算 + `weight=1` 均分**：

- 行字号 **19sp → 22sp**，列头 17 → **18sp**，标题 20 → **21sp**。
- 行数不再写死 9 行：`computeRows()` 按 `heightDp` 算（每行约 40dp，7~14 行收敛），
  1280×720 上约 14 行 —— 铺满列高靠「多显示几行真实数据」，而不是把 9 行拉开。
- 每行 `LayoutParams(MATCH_PARENT, 0, 1f)`：列内剩余高度均分，列表一路铺到页脚，
  底部不再留白。
- 层级：名称用主字色（`TEXT`），台数用 `RelativeSizeSpan(0.82)` + 次字色（`TEXT_DIM`）；
  当前地区加「●」前缀并染 `ACCENT`；焦点行亮蓝底白字加粗。四处都在 `applyRowStyle()`。
- 防溢出：标题 / 提示 / 页脚 / 每行统一 `setEllipsize(END)`（`Ui.text` 本身单行），
  提示文案砍掉半句（原「…并关闭 | 左列选省=全省地方台…」在屏幕上被截成半句），
  页脚压成一句「切换只改列表，不打断正在播的画面 · 返回 取消」。

**验证与产物**
- 全量门禁 **35 步 / 3201 断言全绿**（legacy-compat 206 → **208**：O10/O17/O18 改为
  「顶部条不存在」的负向断言，新增 **O20** chip 横向滚动、**O21** 省市面板字号/铺满/省略）；
  `--selftest` 6/6；`flutter analyze` 0；android-form 91/91、python-m0 6/6；
  独立包 80/80、单包 24/24；清单规模 1046 台 / 2135 线路不变。
- `dist/Shunbo-1.0.2-full.apk` 43,842,035 B（SHA-256
  `8b07b620800951fa64b180a2ea66841fdf5024f05a499a135187b2c74739176a`）、
  `dist/Shunbo-Legacy-1.0.2-armv7a.apk` 3,528,219 B（SHA-256
  `484b7eacf848576116be4d1fc68e84c3768a7eb091a52cf99b0593bf3ca1b99e`）。
- 构建工作目录 `SHUNBO_LEGACY_WORK` / `SHUNBO_SINGLE_WORK = work_20261109h`；单包
  `--skip-flutter-build`（本轮零 Dart 改动）。版本仍 `1.0.2+3`，未升版、未 push。

**不声称完成**：仍无 API 18 真机 / 模拟器。顶部条删除后的「换台是否还有足够反馈」、chip
横向滚动的遥控器手感与滚动边界、22sp 字号在 720p 实屏上的观感、14 行列表的翻页节奏，
都只是静态确证 + 仿真 + 回归断言覆盖，需上机走查；自启白名单、蓝键键码、设置页对比度、
扩展线路内容一致性、4K 软解仍需上机。超过一个月须重跑台账与扩展线路实测。

## §26 音画不同步：三项同步参数 + 时钟探针（2026-11-09 19:00）

**症状**：连续播放一段时间后声音超前、画面滞后，偏差随时间累积；换台/切线路后暂时恢复。

**取证**：legacy 链路用 ijkplayer **k0.8.8（FFmpeg n3.1，aar 2018-02-12）**，`configure()` 原 12 个
参数里与时钟相关的 **0 个**；`onInfo` 只处理首帧/缓冲两态，无丢帧与时钟观测；`BUFFERING_END`
不重置时钟；`framedrop=1` 把「解码跟不上」翻译成「延迟」而不是「卡顿」。内核字符串核实
`sync-av-start`、`max-fps`、`video-pictq-size`、`mediacodec-sync` 均存在但从未设置。
换线/后台会重建 player（时钟重置），因此偏差只在「不换线的连续播放」中累积。

**三环节**：① 起播相位未对齐（固定偏差）；② 视频按 `frame_timer` 相对推进，Android 唤醒偏晚
逐帧累加（25fps 每帧晚 1ms ≈ 每分钟 1.5 秒，主因）；③ 缓冲恢复不重置时钟（阶跃叠加）。

**改动**（3 处，版本仍 `1.0.2+3`）：
- `PlaybackController.configure()`：`sync-av-start=1`、`max-fps=30`、`video-pictq-size=3`。
  三者独立可回退：起播变慢改回 `sync-av-start=0`，高帧源不连贯删 `max-fps`，解码抖动删
  `video-pictq-size`。
- `PlaybackController`：新增 `clockRate()` / `clockSampleCount()` / `resetClockProbe()`。
  口径为 **Δ播放位置/Δ墙钟**（10 秒窗口，暂停不刷新，pts 回退窗口丢弃），换线路清基准。
- `LegacyPlayerActivity.buildHelp()`：诊断页新增「时钟」与「同步策略」两行；`>1.01` 判「音频
  偏快、疑采样率错配」，`<0.99` 判「位置被缓冲拖住」，`≈1.000` 则偏差在视频侧。

**产物**：`dist/Shunbo-1.0.2-full.apk` 43,842,035 B（SHA-256
`d8a1ce45c1c14a6f013c5e70d5991bb017538c9191651985eb87895e2ceceb24`）；
`dist/Shunbo-Legacy-1.0.2-armv7a.apk` 3,528,221 B（SHA-256
`76327c6587a1ca3dc3ff63a1b908eef88fb11b4e19c010693712981b18902083`）。
门禁 35 步 / **3201 断言**全绿（legacy-compat 208/208、独立包 80/80、单包 24/24）；
工作目录 `work_20261109i`；`dist/` 已清理到 46 MB（只留最新版，`_prev` 已删）。

**不声称完成**：无 API 18 真机。三项参数的实际效果、「时钟」读数在真机上的分档是否可分辨、
`sync-av-start` 对起播耗时的影响、`max-fps=30` 对 50 场源流畅度的影响，均需上机走查；
P1 缓冲后 `seekTo(getCurrentPosition())` 自愈与 P2 硬解对照实验尚未实施。

## §27 央视换台慢 / 播放中频繁缓冲（2026-11-09 19:35）

**根因（台账量化）**：自动档按画质降序排线路，把探测 1.5–2.2 秒的跨境 1080P 源排第一，
100–650ms 的官方源被挤到第 2/3 位。央视 59 台里 **41 台**首条线路探测 ≥1.2 秒；
CCTV-1 首条 1080P/2212ms，官方 576P/116ms 常年排第 3。播放中频繁缓冲同源——这些跨境 IP
带宽窄、抖动大，而原来只能等 15 秒看门狗。

**改动（5 处，版本仍 `1.0.2+3`）**：
- `ChannelCatalog.applyQualityPriority`：自动档插入 `speedKey(probeMs)` 分档
  （≤1.2s / ≤2.2s / 慢或未知），顺序变为「可达 → 速度 → 画质 → 原顺序」；手动档语义不变。
  实测：央视首条 ≤1.2 秒的台数 18 → **26**，首条中位数 1556 → 1462ms；CCTV-1 2212 → **116ms**。
- `PlaybackController.configure`：`analyzeduration` 2s → 1s、`probesize` 1MB → 512KB
  （原来等于让内核先吞两个直播分片才 prepared）。
- `Prefs` + `PlaybackController`：首帧超时默认 12s → **8s**（设置页档位仍 8/12/18）。
- 新增 `scheduleQuickFail`：5 秒无首帧且**还有未试候选**时先换下一条；最后一条留给总超时兜底。
- 新增 `noteBufferHit`：60 秒窗口内 3 次 `BUFFERING_START` → 自动换线（首帧后才计数，
  换线清空；reason 「卡顿频繁（60 秒 3 次）」）。
- 诊断页新增「画面：最近 60 秒缓冲 N 次」与「起播策略」行。

**代价**：自动档优先稳源，CCTV-1 默认从 1080P 变 576P。想高清在设置 → 优先清晰度选
「1080P 优先」；回退只需删掉 `applyQualityPriority` 里的速度分档。

**产物**：单包 43,842,035 B（SHA-256 `079f841e2b53b4abb933953b08cbc76ee8317b2a9f025763884540a0ad7ed953`）；
独立包 3,528,224 B（SHA-256 `f52649bbe05f14fafb89e7f4fc1ef574fc33a169e7b689bdef743e4eef93ac6a`）。
门禁 35 步 / **3205 断言**全绿；legacy 自检 **212/212**（新增 O22–O25，其中 O25 直接读
`channels.json` 的 `probeMs` 重排并要求央视首条 ≤1.2 秒 ≥24 台）；单包 24/24；
工作目录 `work_20261109j`；dist 46 MB。

**不声称完成**：无 API 18 真机，起播秒数与缓冲次数未实测；`analyzeduration=1s` 对少数源
可能不足以识别编码（会自动换线，不会卡死）；5 秒快速失败会提前放弃 6–8 秒才出画的慢源；
扩展线路内容与台名一致性仍未逐条核验。

## §28 换台慢 / 换不了台：快速失败判据修正 + 死台跳过 + 音画对齐（2026-11-09 19:57）

**症状**：换台后长时间黑屏；部分台直接播不出来；偶发「按了换台又回到原台」；
画面出来后声音先到、画面后到。

**根因（第 1、2 条是上一版自己引入的）**：

1. **快速失败判据算错**。上一版 `hasMoreCandidates()` 判的是
   `attempted.size() < streams.size()`，而**当前这条线路此刻还没记进 attempted**，
   于是「只有一条线路的台」也满足条件。清单里 597 台只有单线路，其中 347 台的
   唯一线路台账不可达 → 5 秒即被判「全部线路不可用」→ 自动回退到上一个好台。
   用户看到的就是「换台没反应 / 又跳回原台」。
2. **起播探测窗口压得太狠**。上一版把 `analyzeduration` 压到 1s、`probesize` 压到
   512 KB。FFmpeg 的 analyzeduration 是**上限**而不是等待时长，换台耗时主要在建立
   连接与拉首个分片；压小之后部分高码率 / HEVC 源识别不出编码，`prepared` 失败，
   表现就是一直黑屏。已回到 1.5 s / 1 MB。
3. **清单结构本身**：1046 台只有 2135 条线路，每台线路数中位数 **1**；**434 台
   （41.5%）一条可达线路都没有**。对这些台按 8 秒去等，就是「换台没反应」。
4. **换台瞬间上一台的失败回调仍在队列里**。`failCurrent` 延迟执行的 `openNext()`
   没有代际校验，会去释放「新台刚起播的 player」、按旧下标重开一条线路，
   表现为换台后反复黑屏、一直连不上。

**改动（6 处，版本仍 `1.0.2+3`）**：

- `PlaybackController.hasMoreCandidates(int currentIdx)`：排除当前线路、排除
  resolver 线路；**最后一条一律交给总超时**，不再提前判死。
- 快速失败窗口 5 s → **6 s**（老盒子软解 + 跨境源首帧常落在 5～6 s）。
- 新增 `Channel.hasReachableStream()`：台账全灭的台首帧只等 **4 s**
  （`DEAD_CHANNEL_TIMEOUT_MS`），失败原因写明「该台台账无可用线路」；
  连续换台（↑↓ / 频道键 / 控制条上下台）**自动跳过**这类台并提示
  「已跳过 N 个无可用线路的频道」。频道栏点选与数字直达**不跳**——那是用户
  明确点名，仍照常进入并逐条试线。
- 起播探测窗口 `analyzeduration` 1 s → **1.5 s**、`probesize` 512 KB → **1 MB**。
- `failCurrent` 的延迟重建加**代际 + 频道双校验**；HTTPS 失败 streak 只统计内核
  真错误（`what >= 0`），超时 / 快速失败 / 卡顿换线不再误报「本机 HTTPS 连续失败」，
  也不会因此改掉线路排序。
- **音画一致**：起播静音到首帧（1.2 s 兜底解静音，避免「有画无声」）；长缓冲
  （≥1.5 s）结束后按当前位置 `seekTo` 一次，把内核 `frame_timer` 重锚到音频时钟。
  护栏：同一线路最多 3 次、两次间隔 ≥8 s、seek 自己引发的 buffering 不计入卡顿计数。
- 诊断页新增「换台：上次出画 X ms · 本次线路切换 N 次（本台台账无可用线路时标注）」
  与「同步：…再对齐 N 次」，起播策略文案同步。

**产物**：单包 `dist/Shunbo-1.0.2-full.apk` 43,842,035 B（SHA-256
`d08b16bfd4d1971a77d1ce75acba632530de9c9bd0b9b717523c5ac62a638e3e`）；
独立包 `dist/Shunbo-Legacy-1.0.2-armv7a.apk` 3,528,220 B（SHA-256
`636692cc5722d5fed82881f752acb14948ba8bb65b9636d2cf2218f673edb4f9`）。
门禁 35 步 / **3209 断言**全绿；legacy 自检 **216/216**（新增 O26–O29：候选判定、
死台跳过、代际校验、静音与再对齐）；单包 24/24；工作目录 `work_20261109k`；dist 46 MB。

**不声称完成**：无 API 18 真机。6 秒快速失败阈值、4 秒死台等待、静音解锁时点、
缓冲后再对齐的实际观感均未实测；「跳过」是否合理完全取决于台账（`probeAt`
2026-11-09），台账过期时可能跳掉其实能播的台——此时用频道栏点选或数字直达仍可进入；
再对齐在个别直播源上可能触发一次重新缓冲（已有 3 次上限与 8 秒冷却）。

## §29 官方源可行性分级（2026-11-09 20:13，仅分析不改码）

**结论：越「官方」越难，越「地方」越易。** 把六类来源按实现难度分成 L1–L6，
评级必须拆成**获取难度**与**可用难度**两轴，综合取较差者——央视官方源就是
「获取 ★、可用 ★★★★★」的典型，最容易被误判成容易。

| 级别 | 来源 | 获取 | 可用 | 综合 | 优先级 |
|---|---|---|---|---|---|
| L1 | 地方广电公网 CDN（市/县级） | ★ | ★ | ★ | P0 主力 |
| L2 | 省级卫视持牌平台 CDN（含真 4K） | ★★ | ★★ | ★★ | P0 主力 |
| L3 | 公开聚合清单 / 开源索引 | ★ | ★★★ | ★★★ | P1 兜底 |
| L4 | 央视官方 CDN（cntv/kankanlive） | ★ | ★★★★★ | ★★★★ | P1 有限补充 |
| L5 | 运营商 IPTV 单播/组播 | ★★★ | ★★★★ | ★★★★ | P3 用户自带 |
| L6 | 官方 App 私有协议 / DRM 绕过 | ★★★★★ | ★★★★★ | ★★★★★ | 不做 |

**台账实测支撑**（`channels.json`，probeAt 2026-11-09T05:40Z，1046 台 / 2135 线 / 501 主机）：

- 官方直连 **328 条 / 81.4% 可达 / 中位 306ms**；302 解析 **7 条 / 71.4% / 121ms**；
- 商业 CDN 778 条 42.3%；境外 VPS 299 条 65.2% 但中位 **1698ms**；
- 运营商 IP 310 条仅 **21.3%** 可达（异网），中位 191ms 最快；
- 第三方平台 173 条 **0.6%** 可达（基本不可直连）；
- 官方覆盖：央视 **12/59**、卫视 **8/59**、地方 **197/896**；全台全灭 434 台；
- 真 4K 可播 **6/15**（浙江/深圳/湖南/东方/河北/苏州），CCTV-4K 两线均不可达。

**结构性事实**：可达率最高的不是最官方的，而是最有动力开放的——地方广电要覆盖本地、
卫视要导流、央视要控版权（cdrm）。所以选源只能按实测结果排序，不能按「官方程度」排序。
L4 的地址 20 分钟可逆（liveplayer.js 串表 + AES 常量 + 23 组模板），但切片 cdrm 加密，
HTTP 200 / EXTINF / TS 同步字节三层全过、解码报错 124/115/113 次 → 满屏色块。
**再去「找更多央视地址」是已验证的死路。**

**分期建议**：P1 把带 `resolver` 的线路 7 → 30+、4K 6 → 10 台；P2 把 L3 改成
「先筛真后入库」（当前候选通过率仅 8.6% / 26.9%）；P3 只做 L5 导入器、不内置地址表；
L6 明确不做（付费台与 8K 在目标机型上也解不动）。

**产物**：`../顺播_官方电视源获取可行性分析.{md,html,pdf}`（PDF 8 页）。未改任何源码与产物。

## §30 4K 输出门槛：按系统版本与解码能力封顶（2026-11-09 20:35）

**动机**：目标机型乐视 S50 Air（API 18 / 1080p / 1 GB / 软解）上，清单里 15 个 4K 台、
40 条 2160 线路只有三种结局——解不动（黑屏/花屏）、解得动但掉帧（音画越来越不同步）、
解得动却被缩到 1080p 输出（白烧算力）。三种都不该让用户碰上，所以在**候选层**拿掉，
而不是让播放器去试错（进候选就要为它等 6 秒首帧、失败还污染「线路切换」诊断）。

**判据（保守与，任一不过即封顶 1080）**——新增 `DeviceCapability.java`：

| 判据 | 实现 | 理由 |
|---|---|---|
| 系统版本 ≥ 24 | `Build.VERSION.SDK_INT` | API 21 才有 `MediaCodecList`；叠加 HLS 4K 渲染与 HDMI 实际能力定在 24 |
| 输出宽 ≥ 3840 | `Display.getRealSize()` | 1080p 面板上放 2160 只会被缩放，清晰度不涨、算力翻四倍 |
| 2160 硬解 | `areSizeAndRateSupported(3840,2160,24.0)`，排除 `OMX.google.` / `c2.android.` 软解 | 软解 2160 跑不到 25fps，本身就是卡顿源 |
| 内存 ≥ 2048 MB | `ActivityManager.MemoryInfo` | 4K 帧缓冲是 1080p 的四倍 |

另加一条运行时开关：**软解也算不达标**（`hardDecode == false` 同样封顶），因为软解 2160
必然掉帧；改解码方式需重启（载入期算的），设置页与诊断页都写明，**不偷偷重载清单**。

**落地位置 = 载入期**：`ChannelCatalog.load(context, maxQuality)`。封顶时①剥离
`quality ≥ 2160`；②4K 专用台（`is4K`）连带「未知清晰度」线路一起剥，剥完为空则整台隐藏；
③普通台剥完为空时**保留一条最划算的 2160 线兜底**（玉林/乐山两台的 quality 标 2160、
标签却写 1080P，属生成器误标，不藏台）。上层排序、跳台、诊断计数因此看到的都是真能放的线路。

**实测影响（按台账实算）**：可见 1046 → **1031 台**（隐藏 15 个 4K 台：央视 1 / 卫视 9 /
地方 5）、线路 2135 → **2097 条**（剥离 40 条，2 条作兜底）、苏州 7 → 5 台。
被隐藏的 15 台里本机原本只有 6 台能出真 2160p，而这 6 台在 1080p 面板 + 软解上本来就放不动
——门槛没拿走任何「能看的清晰度」。

**诊断页**新增两行：`4K：已关闭 · 系统 Android 4.3（API 18）< 门槛 API 24` 与
`API 18 · 屏幕 1920×1080 · 2160 硬解 无 · 内存 1024 MB`；封顶时再补
`已剥离 40 条 2160 线路、隐藏 15 个 4K 台，另保留 2 条标错清晰度的兜底线路`。

**顺手修的构建坑**：`build_legacy.py` 的 `JAVA_SOURCES` 是硬编码表，新建
`DeviceCapability.java` 未登记 → 编译报「找不到符号」。已改为「登记表 + 自动补全
SRC 下未登记的 `.java`」，注释写明踩坑史（历史上还有一次漏进 dex 的静默缺失）。

**产物**：单包 `dist/Shunbo-1.0.2-full.apk` 43,842,035 B（SHA-256
`39cb15b35629bfc3a798a2f3c7afc8749d0129f08f9aa68956111d297d9ce6b5`）；独立包
`dist/Shunbo-Legacy-1.0.2-armv7a.apk` 3,528,222 B（SHA-256
`0ce39b728540546801efda25b133362bd489dc56e9def6b9a56cf60ebc17a9c9`）。版本仍 `1.0.2+3`。
门禁 35 步 / **3213 断言**全绿；legacy **220/220**（新增 O30–O33）；独立包 80/80；单包 24/24；
工作目录 `work_20261109m` / `work_20261109m2`；dist 46 MB。

**未验证**：无 API 18 真机；`MediaCodecList` 在 API 24+ 的真实读数未实测（个别 ROM 抛异常时
退回只判尺寸，可能把 15fps 芯片误判为支持）；「软解 4K 一定卡」来自机理与内核参数，未量化；
Flutter 主程序侧（API ≥ 24）未加等价门槛，需 `flutter build`，列为 P3。

---

## §31 研发计划 PQ-1 / M0：只读质量探针 + 观感两项 + 升版 1.0.3（2026-11-09 21:15）

**本轮定位**：研发计划（`E:/TV/顺播_1.0.3_清晰度流畅同步优化_研发计划.md`）的 M0 里程碑。
M0 的硬约束是**不改变任何播放行为**——只补读数、只修观感，因此可以随时发出去收数据，
做 A/B 时也有干净的对照基线。

### 1. 为什么先补读数

1.0.2 的机制全部工作在结果层：`BUFFERING_START` 事件、首帧超时、用户说「卡了」。
而 `IjkMediaPlayer` 0.8.8 其实已经暴露 5 个运行时读数（`getDropFrameRate()`、
`getBitRate()`、`getVideoCachedDuration()`、`getAudioCachedDuration()`、
`getTrafficStatisticByteCount()`，加上 `getVideoWidth/Height()`），此前一个都没读。

新增 `legacy/src/com/shunbo/legacy/QualityProbe.java`：1 秒采样、环形 60 条（最近 60 秒）、
**每个读数单独 try/catch**（内核不认某属性时该列记 -1，不影响其它列，也不抛到播放线程）。
采样跑在主线程 Handler 上——单次调用是 native 属性读取，&lt;1 ms，避免再开线程与
player 生命周期竞态。

派生指标（都带「样本不够」的返回约定，不拿 0 冒充正常）：

| 指标 | 口径 | 用途 |
|---|---|---|
| `videoCachedMs()` / 30 秒最低 / 均值 | 直播下即「还能播多少」 | B1 水位预警（M2） |
| `cachedGapMs()` = 视频 − 音频 | 缓存差 | D1 第二条同步判据（M2） |
| `dropDeltaMilli()` | 近 20 秒丢帧率增量（累计量必须求差） | B2 让路判定（M2） |
| `bitrateBps()` | 优先 `getBitRate()`，无效时用流量 ÷ 时长折算 | A1 假高清（M2） |
| `isFakeHd()` | 声称 1080P 但宽 &lt;1280 或码率 &lt;1.5 Mbps，起播满 8 秒才下结论 | A1 |
| `width()/height()` | 实际解码分辨率 | 标签真伪校验 |

**只读是验收项**：门禁 O35 断言 `QualityProbe` 里不出现 `failCurrent(` 与 `seekTo(`——
一旦有人在探针里塞决策，门禁立刻红。

### 2. 诊断页

`buildHelp()` 新增 4 行（码率 / 缓存 / 丢帧 / 画面），并且**打开诊断页时每 2 秒自动刷新**、
离开即停：水位是趋势量，静态快照看不出「在降还是在回升」。刷新时跳过崩溃记录读取（读文件）。

### 3. E1「缓冲中」提示去抖

旧实现只要内核报 `BUFFERING_START` 就弹「缓冲中…」，而直播分片轮询与 TCP 抖动会制造
200～500 ms 的瞬时欠载——画面其实没停。用户感受到的「老在缓冲」，有一半来自这条提示本身。

现在分三种情况：①首帧之前照旧立刻提示（此时屏本来就是黑的，压延迟反而像没反应）；
②再对齐 seek 引发的缓冲**完全不提示**；③播放中的普通缓冲延迟 **600 ms** 再决定，
600 ms 内恢复就当没发生。提示一旦出现至少停留 **400 ms**，避免「闪一下」——那比不显示更像故障。

### 4. E2 换台清屏

`SurfaceView` 的最后一帧会留在 surface 上直到新流首帧画上去，而新台音频往往先到：
「上一台的画面 + 新台的声音」看起来正是「画面滞后、声音超前」，是典型的**假不同步**。

在 surfaceView 之上、其余浮层之下加一层纯黑 `blackoutView`：换台 / 换线时盖上，首帧撤。
两条硬约束：①`setFocusable(false)` + `setFocusableInTouchMode(false)`——它一旦可聚焦就会
像旧版状态卡那样吞掉 OK 键；②**2.5 秒兜底**——有的流不报 `VIDEO_RENDERING_START`，
只靠首帧撤幕会永远黑屏，那比留一帧旧画面更糟。

### 5. 版本

`1.0.2+3` → **`1.0.3+4`**（用户 2026-11-09 21:03 明确指令升版）。同步改动：
`pubspec.yaml`、`lib/platform/system_channel.dart`（`kAppVersionName` / `kAppVersionCode`）、
`legacy/AndroidManifest.xml`、`legacy/build_legacy.py`、`tooling/merge_single_apk.py`、
`tooling/windows_installer.iss`，以及三份门禁里锁版本的断言（A04 / G03 / I01 / N09 / J03 /
R12 / G14 / G36）。

### 6. 产物与门禁

| 项 | 值 |
|---|---|
| 单包 | `dist/Shunbo-1.0.3-full.apk` 43,842,035 B · SHA-256 `a4d01da94d8314166812335b27e000ed3a67b62bc36b00c1437fe227abbb0008` |
| 独立包 | `dist/Shunbo-Legacy-1.0.3-armv7a.apk` 3,528,222 B · SHA-256 `fc05bc0f06ea6a78decc47801f7b36d65b8275dc9d293873b948f93db895bcf2` |
| badging | 两包均 `versionCode=4` / `versionName=1.0.3`；单包 minSdk 16 / target 36，独立包 minSdk 16 / target 22 |
| 门禁 | **35 步 / 3217 断言全绿**；legacy **224/224**（新增 O34–O37）；独立包 80/80；单包 24/24；version-compat 227/227；android-form 91/91 |
| dex | 独立包 `classes.dex` 190,776 → 200,284 B（含 `QualityProbe` / `blackout`）；单包 `classes.dex` 200,340 B |

回退基线 `1.0.2` 两个包移到 `dist/_prev/`，未删除。

### 7. 两条必须记住的边界

1. **单包里的 Flutter 产物仍是 11-09 11:15 那次构建的**（`--skip-flutter-build` 复用）。
   安装器看到的是 1.0.3（manifest 由 aapt2 写），Dart 侧的 `kAppVersionName` 已改成 1.0.3
   但**没有重编 dex**，因此 About 页的兜底常量仍是旧值；真实版本走 native 通道，显示不受影响。
   要彻底一致必须 `flutter build`，那是计划里明确划到 P3、不在 M0 范围内的动作。
2. **本轮没有真机**。探针的 5 个读数是否返回有效值、`blackout` 在 SurfaceView 上的层级是否
   如预期、2.5 秒兜底会不会在慢源上露旧帧——全部只有静态确证。这正是 M1 要裁决的三件事之一
   （`getBitRate` 有效性 / `cachedDuration` 语义 / `skip_loop_filter` 透传）。

---

## §32 M1 真机裁决 + M2 三闭环（2026-11-10 09:05）

**本轮定位**：研发计划 PQ-1 的 **M1 标定裁决**与 **M2 闭环**。M1 拿到了两张
乐视 S50 Air（API 18 / 1920×1080 / 1512 MB）的诊断页照片，**否掉了原计划里的两条判据**，
M2 因此按照实测重建，而不是照原稿硬写。

### 1. M1 裁决表（真机读数 → 结论）

| 裁决项 | 计划假设 | 真机实测 | 结论 |
|---|---|---|---|
| `getBitRate()` | 可能返回有效码率 | 两张图都显示「（流量折算）」 | **无效**（内核返回 ≤0）。A1 只能用流量折算，且窗口要拉到 30 秒 |
| `cachedDuration` 语义 | 视频−音频差可作同步判据 | 1080P 台：视频 21000 ms / 音频 6848 ms / 差 **+14152 ms**，而时钟读数 **1.000**；另一台：6560 / 6421 / 差 +139 | **口径不可比**（视频含解码帧队列，音频只是包队列）→ **D1 放弃** |
| 缓存「水位」能否预测卡顿 | 视频缓存 <1.5 秒即预警 | 读数长期 17～21 秒，30 秒最低 17.4 秒 | **不是「还能播多久」而是预取深度** → B1 改为「相对自身基线的吞吐塌陷」 |
| `skip_loop_filter` 是否必要 | 丢帧 >5% 时给解码让路 | 1080P 软解丢帧 **0.5%**，近 20 秒增量 **+0.0** | **问题不存在 → B2 取消**，不引入 CODEC 选项 |
| 起播 / 同步参数副作用 | 未知 | 时钟 1.000（3 个窗口）、首帧 1537 / 690 ms、换线 0 次、缓冲 0 次 | 参数组无副作用，**保留** |
| 4K 门槛 | 载入期剥离 | 剥 40 条 2160、隐 15 个 4K 台、留 2 条兜底；江苏全省 191 台 / 804 线路 | **符合预期** |

同时发现一处**会误导排障的文案**：诊断页把 `+14152 ms` 标成「偏大，视频侧积压」，
而同一时刻音画完全同步。已改为「两路统计口径不同，此差值与音画同步无关，勿据此调参」。

### 2. M2 三闭环（`Tuning.java` 集中阈值）

新建 `legacy/src/com/shunbo/legacy/Tuning.java`：阈值集中一处，每个常量都注明
「实测 / 经验」依据——半年后才有人知道某个 `0.40` 是哪来的。

| 闭环 | 判据（实测修正后） | 动作 | 为什么不更激进 |
|---|---|---|---|
| **A1** 假高清 | 实测宽度 < 标称宽度 × 0.75（`FAKE_HD_WIDTH_RATIO`） | **只降权、不动播放**：下次选线时把该 URL 排后（`findNext` 两遍扫描，第二遍仍会试） | 换线有代价，标注问题不值得打断正在看的画面 |
| **B1** 带宽塌陷 | 30 秒基线 ≥0.4 Mbps 且 8 秒窗口 <基线的 40%，连续 3 采样；**且近 60 秒已卡过一次** | 换下一条（冷却 60 秒） | 纯预防性换线会把好线路换掉；「已卡一次」是必要前提 |
| **D2** 时钟偏快 | 播放位置增速 >1.02，连续 2 个 10 秒窗口 | 换下一条（冷却 45 秒） | 只处理「音频真的快播」；<0.98 那一侧几乎总是网络，证据不足，交给看门狗 |

开关：设置页新增「自动换线」，**默认开**（用户 2026-11-10 决定）。关掉 = 1.0.2 行为
（只保留 6 秒快失败 / 15 秒看门狗 / 60 秒 3 次卡顿），诊断页会显示「关（等同 1.0.2）」。

**不做**：D1 缓存差（口径不可比）、B2 丢帧让路（实测丢帧 0.5%，问题不存在）、
降档切 720P（备选仅 16/296 台）。三者都写进代码注释与门禁，避免以后被「想起来」再加回来。

### 3. 诊断页

新增两行：
- `闭环：自动换线 开 · 假高清降权 N 条 · 塌陷换线 N 次 · 时钟换线 N 次`
- `判据：实测宽度 / 相对自身基线的吞吐 / 播放位置增速；缓存差与丢帧率经真机实测否定，不作换线依据`

另修一处措辞：`标清晰度 1191 条` → `标清线路 1191 条`。

### 4. 产物与门禁

| 项 | 值 |
|---|---|
| 单包 | `dist/Shunbo-1.0.3-full.apk` 43,842,035 B · SHA-256 `33a2cb593d0608f220bba3b188583bc7edc40d5d57f288e5f25ec759b8814c19` |
| 独立包 | `dist/Shunbo-Legacy-1.0.3-armv7a.apk` 3,544,606 B · SHA-256 `2b9bffdb16bfd30fe8875837293674dd41d126bd9224ec0945bd8db0c76066a6` |
| badging | 两包均 `versionCode=4` / `versionName=1.0.3`；minSdk 16 |
| 门禁 | **35 步 / 3223 断言全绿**；legacy **230/230**（新增 O38–O43）；独立包 80/80；单包 24/24 |
| dex | 独立包 `classes.dex` 200,284 → 205,724 B（含 `Tuning` / `evaluateQuality`） |

### 5. 仍然未验证

- B1 的 40% / 3 采样只在真机上跑过一次「不触发」的场景，**没有真实塌陷样本**；
  M3 之前建议再抓一次「卡着的台」的读数，确认它确实会在该触发的时候触发。
- D2 的 1.02 阈值同样只有 1.000 的静好读数，缺一次真实偏快的样本。
- A1 的 0.75 只有一条 800×600 冒充标清的正样本，缺「720 冒充 1080」的真样本。
- 单包内 Flutter 产物依旧是 11-09 11:15 那次构建（`--skip-flutter-build`）。

---

## §33 M3：线路稳定度记忆（2026-11-10 10:04）

**本轮定位**：研发计划 PQ-1 的 **M3**。计划里 M3 是四项（C1 预热 / A2 记忆 /
C2 相邻台预取 / C3 关键帧对齐），本轮**只做一项**，另外三项各有明确的不做理由——
这比把四项都做一半更有价值。

### 1. C1「次优线路静默预热」：在 ijkplayer 上不成立

预热的前提是「连接可以被下一个 player 复用」。ijk 的 http 由 ffmpeg 自己实现，
**每个 player 实例私有**：另起一个 player 拉一遍 m3u8，拿到的 DNS 结果、TCP 连接、
TLS 会话都无法交给真正起播的那个 player。能省下的只有「选哪条」这一步决策，
而代价是多一个解码上下文同时抢带宽和 CPU——S50 Air 只有 1512 MB 内存，
双 player 同时 prepare 会让当前台的首帧更慢。

### 2. A2「记忆排序」：替代 C1，收益相同、成本是几十字节

新增 `legacy/src/com/shunbo/legacy/StreamMemory.java`：

| 设计点 | 取值 | 依据 |
|---|---|---|
| 存储 | 独立偏好文件 `shunbo_legacy_streams` | 主偏好里全是小键，塞几百条线路会拖慢每次 `getInt` |
| 键 | `hash + "-" + url.length()` | URL 太长不宜当键；加长度消掉 hashCode 碰撞 |
| 上限 | 500 条，超出按时间淘汰一半 | 江苏全省 804 条线路，一次全量浏览也不会超 |
| 首帧耗时 | 取**两次的较小值** | 偶发一次慢（冷缓存 / 握手重传）不该把好线路的记忆拉长 |
| 降权条件 | 连续 **2 次**硬失败（内核报错 / 首帧超时） | 慢（快速失败 -5）和抖（卡顿 -6）不算——所有线路都慢时，慢但能播的就是最优解 |
| 降权有效期 | **14 天** | 源站会换 CDN / token，两周前的失败对今天没有判断价值；过期自动恢复 |
| 跳转门槛 | 至少快 **250 ms** 才跳 | 避免为了几十毫秒在两条差不多的线路间来回跳 |

**接线**：`open(channel)` 改成用「记忆首选下标」起播（`open(channel, startIndex)`
这条显式路径不受影响，续播仍然用上次的线路号）；`findNext` 两遍扫描时把
「A1 假高清」与「A2 连续硬失败」放在同一个降权集合里，第一遍跳过、第二遍收回。

**两条边界**（写进门禁 O46）：
1. 只在「自动换线开 + 优先清晰度＝自动」时生效。用户选了 1080P 优先，
   就不许记忆把他拽到一条更快的 576P 上——那是拿清晰度换速度，得用户自己选；
2. 画质地板取台账首条的标称清晰度，记忆只能跳到**同级或更高**的线路。

诊断页新增一行：`记忆：N 条线路 · 本台首选第 X 条（上次 690 ms）· 降权 M 条`。
关闭记忆排序时会额外注明「记忆排序已关闭（优先清晰度非「自动」）」。

### 3. C2「相邻台预取」：不做

频道与线路表本来就在内存（`catalog`），预取索引没有收益；唯一有效形式是预连
下一台的 m3u8，那会在换台瞬间和当前台抢带宽——直播本来就带宽紧张，等于用
当前的卡顿换下一台快 300 ms。何况「跳过不可达台」已经实现在翻台逻辑里。

### 4. C3「关键帧对齐起播」：不做（需真机 A/B）

直播源本来就从最近可用位置起播；要强制对齐关键帧得改 demuxer 的 `fflags`，
那会同时削弱抗抖动缓冲。没有对照数据就动它，等于用已知的稳定换未知的收益。

### 5. 产物与门禁

| 项 | 值 |
|---|---|
| 单包 | `dist/Shunbo-1.0.3-full.apk` 43,858,419 B · SHA-256 `e19ba325a3176416790dedfa9fa1e8c417bd7139192388bec71de1f62ed9f2a7` |
| 独立包 | `dist/Shunbo-Legacy-1.0.3-armv7a.apk` 3,544,604 B · SHA-256 `35752acf1995c3836f2c07f50e1199c2ff59baa3a80b3406d95792900507fc11` |
| 门禁 | **35 步 / 3227 断言全绿**；legacy **234/234**（新增 O44–O47）；独立包 80/80；单包 24/24 |
| dex | 独立包 `classes.dex` 205,724 → 211,208 B（含 `StreamMemory`） |

### 6. 未验证

- 记忆的**收益没有实测**：「上次最快的那条下次仍然最快」这个假设，在跨境源上
  不一定成立（同一 URL 早上 300 ms、晚上 2000 ms）。要验证得连开同一台 5 次，
  看第 2 次起首帧是否稳定低于第 1 次。
- 降权的 2 次阈值同样没有真实样本——它只影响「先试哪条」，即使错了也只是多花
  一次 6 秒，且有第二遍扫描兜底。
- 记忆文件是**新键空间**，升级安装不会与旧偏好冲突（独立文件名）。

---

## §34 诊断页分页（真机反馈修复，2026-11-10 10:22）

**问题**：10:18 的两张真机照片都停在「同步」那一行，底下的
**闭环 / 判据 / 记忆 / 内核 / 签名 / 本界面** 六行全部看不见。

不是这一版才有的：`helpView` 一直是 `WRAP_CONTENT` + 居中，内容超过屏高就直接被裁。
旧版内容刚好也超出一点点，所以一直没被发现；这一版又加了闭环/判据/记忆三行，
缺口从 4 行变成 7 行，恰好把我最需要看的三行裁掉了。

**修法**：按屏高分页，不删内容。

- 每页行数按屏高算：`(屏高dp − 110) / 26`，下限 12、上限 40（1080p/1.5x ⇒ 23 行/页）；
- **语义分页**：在「高清线路 / 扩展线路 / 标清线路」之后插一个 `\f`，
  第 1 页是「这台是什么」（分支/清单/4K/地区/台账/收藏/设置），
  第 2 页是「现在播得怎么样」（时钟/缓冲/码率/缓存/丢帧/画面/换台/起播/同步/闭环/判据/记忆/内核/签名）。
  纯按行切会把「码率」和「缓存」拆到两页，读的人得在两屏之间来回对。
- 遥控器 `←→` 翻页，其余键关闭；进入诊断页时回到第 1 页。
- **不做 ScrollView**：电视遥控器拖滚动条比翻页难受，且 ScrollView 一旦可聚焦
  就会吞掉 OK 键——与旧版状态卡是同一类坑。

底部提示条同步改成「←→ 翻页   OK/返回 关闭   · 读数每 2 秒刷新」。

**产物**：单包 43,858,419 B `28429449…db8dbb8`；独立包 3,544,608 B `28e4ef76…a17eeae`。
门禁 **35 步 / 3228 断言**（新增 O48）。版本仍 1.0.3+4。

### 这两张截图顺带给出的读数（M2/M3 的第一次野外样本）

| 台 | 码率 | 缓存 | 丢帧 | 分辨率 | 出画 | 缓冲 | 时钟 |
|---|---|---|---|---|---|---|---|
| 800×600（标称 576P） | 0.55 Mbps | 4240 ms（30 s 最低 3240） | 0.0% | 800×600 实测相符 | **305 ms** | 0 次 | 1.000（3 窗口） |
| 1920×1080（标称 1080P） | 1.72 Mbps | 6400 ms（30 s 最低 5320） | 0.5% | 1920×1080 实测相符 | **634 ms** | 0 次 | 1.000（5 窗口） |

- **出画 305 / 634 ms**，明显好于 M0 版同机的 1537 / 690 ms。这是记忆排序的**弱正信号**
  （也可能只是这两天源更快），要证实得同一台连开 5 次看第 2 次起是否稳定下降。
- 1080P 只有 1.72 Mbps 仍判「实测相符」——正是 M1 改成「只按分辨率判」的直接结果；
  若还按码率 2.5 Mbps 判，这条真高清会被误判成假的。
- 两份读数里 `闭环` 都是 0 次、`缓冲` 0 次——**没有触发样本**，B1/D2 仍然未验证。

---

## §35 分页验证 + 停滞盲区修复（2026-11-10 10:38）

### 1. 分页已验证

两张照片：第 1 页末尾是「—— 第 1/2 页 · ←→ 翻页 · 其余键关闭 ——」，第 2 页从
「时钟」开始，一路到「本界面在 API<24 启动」，**闭环 / 判据 / 记忆 / 内核 / 签名全部可见**。
分页这条修复成立。

### 2. 但第 2 页的读数说明「有一条线路正卡着，而四条保护一条都没动」

| 读数 | 值 | 含义 |
|---|---|---|
| 时钟 | **0.169**（3 窗口） | 10 秒里只推进 1.7 秒，画面基本不动 |
| 缓存 | 视频 **280 ms**（均 5008）· 音频 **0 ms** | 缓冲排空 |
| 码率 | **读不到** | 近 8 秒没有流量增长 |
| 缓冲 | 最近 60 秒 **1 次** | 不是持续缓冲，所以 15 秒看门狗不触发 |
| 闭环 | 塌陷 0 · 时钟 0 · 停滞（当时还没有） | **全部零动作** |

三个根因，逐个修：

**① B1 的基线选错了**。原来用「30 秒平均码率」当基线——画面卡住时吞吐趋零，
30 秒均值也跟着塌到接近 0，「现在 < 基线的 40%」就永远不成立。**最该触发的场景
反而永远不触发**。改用窗口内峰值（`peakTrafficBps(60)`，即最近 60 秒里最忙的
8 秒窗口），「从 2 Mbps 掉到 0」才看得见。

**② 零吞吐被当成「算不出来」**。`trafficBps()` 在流量没涨时返回 -1，而 B1 的条件是
`fast > 0`——于是「一个字节都没进来」这个最强的塌陷信号被直接放过。新增
`bytesStalled()` 把「算得出来，答案就是 0」与「样本不足」分开，前者单独算塌陷。

**③ 没有「停滞」这个动作**。原来只处理时钟 >1.02（音频快播），<0.98 那一侧写的是
「交给看门狗」——但看门狗要求**持续**缓冲事件，而这次 60 秒只有 1 次。等于
「音画能对上，但画面几乎不动」这个状态没有任何保护。新增 **D3**：

- 判据：播放位置增速 < **0.50** 连续 **2** 个 10 秒窗口（约 20 秒）；
- 有候选线路 → 换线（`-9`）；
- **只有一条线路** → 重连同一条（卡住的 HTTP 读经常重连一次就好）；
- 重连**只一次**（`stallGaveUp`）：否则废掉的源会每 30 秒重连一次、无限循环，
  用户看到画面反复重连比停在那一帧更糟；第二次直接提示「按 ←→ 换线路或 ↑↓ 换台」。

**顺带修一个会误伤的坑**：暂停时必须停巡检。暂停后吞吐为 0、位置不动，
B1 会判「塌陷」、D3 会判「停滞」，两个都会把一条正在正常播放的线路换掉。

诊断页同步改：时钟行在 <0.50 时显示「画面停滞（低于 0.50，连续 2 个窗口会自动换线 / 重连）」；
码率行在零吞吐时显示「近 8 秒没有任何流量增长——画面可能已卡住」，不再一律说「样本不足」；
闭环行新增「停滞处置 N 次」。

### 3. 产物与门禁

| 项 | 值 |
|---|---|
| 单包 | `dist/Shunbo-1.0.3-full.apk` 43,858,419 B · SHA-256 `7fdeaafef466686eac8e841aab3481de95e3560a3b80ec1ad3f603f5c2d9b588` |
| 独立包 | `dist/Shunbo-Legacy-1.0.3-armv7a.apk` 3,544,605 B · SHA-256 `7b9f8eb2e253e23f1933c90406f5befb8329c320b503edde5eea6cefeb30ce84` |
| 门禁 | **35 步 / 3231 断言全绿**；legacy **238/238**（新增 O49–O51，O40 改成峰值基线）；独立包 80/80；单包 24/24 |

### 4. 未验证

- D3 的 0.50 阈值只见过一次 0.169 的样本，没见过「0.6～0.9 的轻微卡顿」是什么读数——
  若真机出现 0.6 的读数长期不动却没触发，说明阈值该上调。
- 「重连一次就好」尚未被验证：这次卡住的线路是否重连即恢复，下一次读数才能看到。

---

## §36 1.0.4：D3 双判据修正 + M4 硬解（2026-11-10 11:06）

### 1. 审查结论：先修再发

按「先审查再执行」的要求，先把 10:58 两张真机照片与代码逐条对照，发现 **D3 的判据
会在好线路上误杀**，必须先修，否则版本号升了也是带着缺陷升。

| 读数（10:58） | 值 | 说明 |
|---|---|---|
| 时钟 | **0.004** | 10 秒只推进 0.04 秒 |
| 视频缓存 | **13040 ms** | 还攒着 13 秒 |
| 码率 | 3.18 Mbps | 持续在收 |
| 丢帧 | 0.5% | 正常 |
| 缓冲 | 60 秒 1 次 | 不是持续缓冲 |
| 闭环 | 停滞处置 **0 次** | 没有动作 |

**一个真冻住的流不可能还攒着 13 秒缓存并持续收 3.18 Mbps。** 0.004 是直播源
`getCurrentPosition()` 在分片边界重置造成的读数假象。对照 10:31 那次真实停滞：
0.169 + 缓存 **280 ms** + 音频 0 ms + 零流量——两次的区别就在缓存上。

**风险与影响范围**（若照旧发版）：
- D3 会在静音片段、场景切换、分片边界等「位置重置」时刻把**正在正常播放**的线路
  换掉，表现是「看着好好的突然黑一下换台」；
- 同一批失败会写进 `attempted`，把候选线路提前烧光，极端情况下直接报「全部线路不可用」；
- D2（音频快播 >1.02）同样会被位置正向跳变骗到，误换线。

**修复**：给 D3 加第二个必要条件「视频缓存 < 1000 ms」；D2 也加 `!cacheBottom` 门控
（缓存见底时的位置暴涨不可信，该交给 D3）。诊断页在「位置低但缓存充足」时明确写
「疑似分片边界重置，不处置」——让下一次读数能自己解释清楚。

**顺带修的第三条**：`setHardDecode` 原来只改字段，而解码器是在 `configure()` 里选定的，
要等到下次换台才生效，等于设置项「看起来没反应」。现在重建当前线路，改完立即生效。

### 2. M4：硬解可配置 + 自动回退

| 点 | 实现 |
|---|---|
| 可配置 | 复用已有 `Prefs.K_HARD_DECODE`（键名不变，`set_hard_decode`），默认 `0` 软解 |
| 即时生效 | `setHardDecode()` 检测到变化后 `retryCurrentStream()` 重建解码器，画面闪一下、不用换台 |
| 持久化 | 仍由 `Prefs.setSetting` 落盘；回退时由界面写回 `0` |
| 自动回退 | `fallbackToSoftDecode()` 挂三处：**解码错误**、**6 秒无首帧**、**首帧超时** |
| 回退策略 | 用软解**重开同一条线路**，不换线路——硬解失败大概率是解码器而非源的问题，换线路会把好线路白白换掉 |
| 一次性 | `hardDecodeFailed` 置位后本次运行不再试硬解，避免每条线路都先撞一次 |
| 落盘 | `Listener.onDecodeFallback` → 界面 `prefs.setSetting(K_HARD_DECODE, 0)` + 提示「可在设置改回」 |
| 诊断 | 新增「解码：实际 硬解 MediaCodec / 软解 FFmpeg · 设置 … · 硬解不可用已自动回退」 |

⚠️ 明确不做的：**不调整 MediaCodec 参数做「优化」**。API 18 的 MediaCodec 行为不稳是
已知事实，M4 的定位是「给用户一个可开关的选项 + 失败自动兜底」，不是承诺硬解更好。

### 3. 版本 1.0.4+5

`1.0.3+4` → `1.0.4+5`。原因：三次不同内容的构建都叫 `1.0.3+4`（M2 版、分页版、
停滞修复版），**出问题没法靠版本号区分装了哪个**，回退也指不准。
同步：`pubspec.yaml`、`kAppVersionName/Code`、legacy manifest、`build_legacy.py`、
`merge_single_apk.py`、`windows_installer.iss`、三份门禁断言（A04/G03/I01/N09/R12/G14/G36）。
1.0.3 两个包移入 `dist/_prev/`，未删除。

### 4. 产物与门禁

| 项 | 值 |
|---|---|
| 单包 | `dist/Shunbo-1.0.4-full.apk` 43,858,419 B · SHA-256 `60bc5f55a9eff2fc99fe9cb0c32a40169ea038baf9d3ca7c56981221b53aa1de` |
| 独立包 | `dist/Shunbo-Legacy-1.0.4-armv7a.apk` 3,544,605 B · SHA-256 `0569e2daf10de8f236a93aa0b2747fb9f2c9c17320562882c7ef4b427f692341` |
| badging | 两包均 `versionCode=5` / `versionName=1.0.4`；minSdk 16 |
| 门禁 | **35 步 / 3235 断言全绿**；legacy **242/242**（新增 O52–O55）；独立包 80/80；单包 24/24 |
| dex | 独立包 `classes.dex` 213,780 → 215,732 B（含 `fallbackToSoftDecode` / `usingHardDecode`） |

### 5. 未验证（M4 的核心结论仍然空缺）

- **硬解在 S50 Air 上到底能不能播**，只有上机才知道。本轮的代码保证的是
  「切得过去、坏了能退回」，不是「硬解可用」。
- 回退的三条触发路径（解码错误 / 6 秒无首帧 / 首帧超时）在真机上哪条先踩到，未验证。
- 0.004 的假象是否还有别的成因（例如 `getCurrentPosition` 在暂停后恢复），未逐一排除；
  当前处理是「缓存充足一律不处置」，属于保守而非精确。

---

## §37 硬解改「按线路」粒度（真机反馈，2026-11-10 11:38）

**用户反馈**：测试下来「有的台可以硬解，有的台只能软解」。

这句话直接证否了 1.0.4 第一版的实现——它把回退做成了**整机一次性**：

```
hardDecodeFailed = true;   // 全局
hardDecode = false;        // 连用户设置一起改
prefs.setSetting(K_HARD_DECODE, 0);   // 还写盘
```

于是**一个台硬解失败 → 后面所有能硬解的台也被降级 → 重启后仍是软解**。
用户看到的「有的台能硬解」其实只能维持到第一次失败为止。

### 1. 改法：粒度落到线路

| 点 | 改前 | 改后 |
|---|---|---|
| 判定 | 全局 `hardDecodeFailed` | `currentUseHard = hardDecode && !memory.hardDecodeUnfit(url)` |
| 回退 | 全局关闭硬解 | 只把**这一条 URL** 记进 `StreamMemory`（`hardFail` 标记） |
| 设置 | 被改成软解并写盘 | **不写**。设置是用户意图，回退是运行时兜底 |
| 换台 | 一直是软解 | 换到别的台仍按设置用硬解；不适配的线路**下次直接走软解**，不再先失败 6 秒 |
| 过期 | 永久 | 7 天（解码器被占用、源站换参数都可能是一次性的） |
| 重试 | 只能重装 / 手动改设置 | 在设置里重新选「硬解」即清空全部不适配记录 |

`StreamMemory` 的记录格式从 3 段扩到 4 段（`ok|fail|ts|hardFail`），
**旧 3 段记录按 hardFail=0 解析**，升级安装不会把已有记忆作废。

诊断页把三件事分开写：

```
解码：实际 硬解 MediaCodec · 设置：硬解 · 已记 2 条线路硬解不适配（7 天后自动重试）
解码：实际 软解 FFmpeg · 本线路硬解不适配，已自动用软解（其他台不受影响）
```

### 2. 过程中我自己捅的坑（必须记下来）

为了改 `onDecodeFallback`，我用「从 A 方法头切到 B 方法头」的方式替换代码，
而这两个位置之间还夹着 **6 个 Listener 回调**：`onSettingChanged`、`onChannelPicked`、
`onFavoriteToggled`、`onRegionRequested`、`onRegionPicked`、`onSearchPick`，
外加 `onControlAction` / `onControlFocus`。一次替换把它们全删了。

发现方式是编译报「未实现 Listener 的抽象方法」，**一次只报一个**——
这正说明「按 Java 接口实现」的编译期约束是有价值的：删了接口实现，编译立刻红。

恢复方式不是猜：把 `dist/_prev/Shunbo-Legacy-1.0.3-armv7a.apk` 里的 `classes.dex`
用 `dexdump -d` 反汇编，按 **原字节码 1:1** 还原这 6 个方法的调用顺序与常量
（例如 `onRegionPicked` 里是 `catalog.setRegion(...)` → `prefs.saveRegion(...)` →
`indexOfNumber(currentNum)` → 夹紧下标 → `setPlayingChannel` → toast → `updatePanelState()`
→ `setMode(MODE_PANEL)`）。`onControlFocus` 原实现只有一句 `scheduleControlHide()`，
我先前擅自改成「按焦点改提示文案」，也一并改回去了——那不是重构，那是改需求。

### 3. 产物与门禁

| 项 | 值 |
|---|---|
| 单包 | `dist/Shunbo-1.0.4-full.apk` 43,858,419 B · SHA-256 `55c36e4de9ac6c202f66a72e4d5b8ee15e3bfc6bf1523638311575f89a6e1845` |
| 独立包 | `dist/Shunbo-Legacy-1.0.4-armv7a.apk` 3,544,606 B · SHA-256 `c5bd84017ce1a8c159237690a28cc3ff4dd537d916558802fdea8d1326cf7d56` |
| 门禁 | **35 步 / 3236 断言全绿**；legacy **243/243**（O54 改按线路语义、新增 O56）；独立包 80/80；单包 24/24 |
| dex 校验 | `noteHardDecodeFail` / `hardDecodeUnfit` / `onRegionPicked` / `onControlAction` / `onSettingChanged` 均在 |

### 4. 验证方式（上机）

1. 设置 → 解码方式 → 硬解；
2. 依次切到「能硬解」和「只能软解」的两类台各一次；
3. 期望：能硬解的台诊断页显示「实际 硬解 MediaCodec」；不能的那台第一次弹
   「本线路不支持硬解…已改为软解播放 · 其他频道仍用硬解」，**设置仍是硬解**；
   再切回能硬解的台，应恢复硬解；
4. 再回到那台不能硬解的，应**直接**用软解起播（不再先黑 6 秒）。

### 5. 未验证

- 触发路径以哪条为主（解码错误 / 6 秒无首帧 / 首帧超时）仍未知；三条都接了同一个回退。
- 7 天过期是否合适：如果同一台每天都在看且硬解始终不行，每周会白失败一次。
- 不适配判定的键是 URL：同一路流的镜像 URL 会被当成新线路重新试一次。

---

## §38 苏州台1套「音画延迟」：为什么不做自动修复（2026-11-10 12:23）

### 1. 真机读数与它证否的东西

苏州台1套（12:19）：

| 项 | 值 | 说明 |
|---|---|---|
| 时钟 | **1.000**（6 窗口） | 音频按真实时间推进，没有快播 |
| 缓冲 / 丢帧 | 0 次 / 0.5% | 网络与解码都正常 |
| 缓存 | 视频 **9480 ms**（均 9001）· 音频 **7040 ms** · 差 **+2440** | 视频侧多积压 2.4 秒 |
| 出画 | 772 ms | 起播正常 |

本来打算用「视频缓存 − 音频缓存 > 800 ms」自动 seek 重锚。**这个方案被数据否掉了**：

- 11:06 的样本：差 **+14152 ms**，用户**没有**说不同步；
- 12:19 的样本：差 **+2440 ms**，用户明确说「画面延迟」。

同一个量，大的那次没事、小的那次有问题 —— 说明它不可解释（视频侧统计的是解码帧队列，音频侧只是包队列，口径不同）。
**拿一个不可解释的量去自动 seek，等于在好画面上做实验。** 这与本项目已确立的纪律一致：
只有被实测支持的量才允许驱动动作（参见 §32 里 D1 的放弃、§35 里 D3 的双判据）。

### 2. 实际给的两件东西（都不改默认行为）

**① 手动「音画立即对齐」**（设置页动作项）
按当前位置 `seekTo` 一次，把内核的 `frame_timer` 重锚到音频时钟——与 1.0.2「长缓冲后再对齐」
用的是同一招，只是触发权交给用户。执行后：

- 这次 seek 引发的 buffering 不计入「频繁卡顿」（`suppressBufferHitUntil = now + 3000`）；
- 冷却 3 秒，防连按；
- 诊断页「同步」一行记录「手动对齐 N 次」。

**② 「同步兼容模式」开关**（默认关）
关掉 1.0.2 为老机型加的两个参数 `max-fps=30` 与 `video-pictq-size=3`，把同步交回内核自己调度。
默认关 = 行为与之前完全一致；打开会重建当前线路，即时生效。

之所以怀疑它俩：苏州台是 1080P、1.9 Mbps、不卡、不丢帧，唯独视频侧多积压 2.4 秒——
「帧队列上限 3」在解码抖动时没有余量，而「帧率上限 30」对 50 场的源会强制丢帧。
**但这只是候选解释，不是结论**：只有用户切一次做对比才能定。

### 3. 怎么用（上机顺序）

1. 先什么都不改，在苏州台1套按一次 **设置 → 音画立即对齐**：
   - 如果对齐后正常，说明是起播相位差 → 下一步可以做成「检测到首次偏差就自动对齐一次」；
   - 如果对齐后又慢慢跑偏，说明是持续漂移 → 与相位无关，走第 2 步。
2. 打开 **设置 → 同步兼容模式**，回到该台看是否还延迟：
   - 好了 ⇒ 病因是那两个参数，考虑把「兼容模式」在检测到 1080P + 高积压时自动打开；
   - 没好 ⇒ 与这两个参数无关，需要抓更多样本（最好在出现延迟时按菜单看第 2 页）。

### 4. 产物与门禁

| 项 | 值 |
|---|---|
| 单包 | `dist/Shunbo-1.0.4-full.apk` 43,858,419 B · SHA-256 `4eff2f642ad2cb00617ea707d7755dd337d95af6ad4de4a5799d9e04c3cc2d57` |
| 独立包 | `dist/Shunbo-Legacy-1.0.4-armv7a.apk` 3,544,604 B · SHA-256 `8c6df5fce22bbaaf53c75c92256015ae5091776697586613bd30fb30f110fca4` |
| 门禁 | **35 步 / 3238 断言全绿**；legacy **245/245**（新增 O57「不做自动 seek」/ O58 兼容模式） |

### 5. 未验证

- 手动对齐对苏州台1套是否真的有效（这是下一步所有决策的前提）。
- 兼容模式是否是病因。
- 「声音比画面快」的另一种可能是**源端本身不同步**（地方台转播链路常见），
  这种情况下任何客户端手段都只能缓解，换线到同台的另一个源可能反而更好——
  诊断页「记忆」一行能看出该台是否有其它线路可换。

## §39 音画延迟第二轮：三条路径实测否证 + 补上帧率读数（2026-11-10 13:30）

用户按 §38 的步骤做完了：**手动对齐按了 3 次**、**同步兼容模式已打开**，回传 12:5x 的诊断页。
结论是**两条路都没解决**，但这一轮把「病因在哪」的范围压到了最小，并且找到了此前真正的取证缺口。

### 1. 新读数与它逐条否证的东西

| 项 | 12:19（§38） | 12:5x（本轮） | 判读 |
|---|---|---|---|
| 手动对齐 | 0 次 | **3 次** | 按了 3 次仍在 → **`seekTo(当前位置)` 重锚不是病因** |
| 兼容模式 | 关 | **开** | 已生效 |
| 缓存差 | +2440 ms | **+624 ms** | 大幅收敛，用户仍感知延迟 → **再次证否「缓存差」可作判据** |
| 时钟 | 1.000 | **0.999** | 音频没有快播、位置没被缓冲拖住 |
| 近 60 秒缓冲 | 0 次 | **0 次** | 不是缓冲造成的阶跃 |
| 丢帧 | 0.5% | **0.5%** | 解码有余量 |
| 码率 | 1.95 Mbps | **3.18 Mbps** | 1080P 正常码率，不是降码率导致的糊+迟 |

三条被否证的假设：

1. **「起播相位差，seek 一次就好」** —— 按 3 次无效。重锚只重置 `frame_timer`，而
   `frame_timer` 只影响「视频帧该在什么时刻显示」，不影响「音频已经走到哪」。
   两者如果本来就差一个恒定值，重锚之后还是差那个值。
2. **「帧队列上限 3 / 帧率上限 30 导致视频积压」** —— 兼容模式已把两项都关掉、
   缓冲 0 次、时钟 0.999，缓存差还从 +2440 掉到 +624，**问题依旧**。
   这两个参数是本台延迟的病因这一假设，**排除**。
3. **「缓存差可以当判据」** —— 第二次证否。第一次是 §38 的「大差无感、小差有感」，
   这次是「差收敛了 4 倍、感知没变」。这个量（视频侧解码帧队列 vs 音频侧包队列）
   与音画同步无关，**永久退出判据池**。

### 2. 修正 §26 里我自己的一个错误说法

§26 与上一轮口头结论说「内核没有任何音画补偿手段」，**不准确**。核实结果：

| 手段 | 状态 | 能否消除恒定偏移 |
|---|---|---|
| `framedrop` | **=1，`configure()` 里早已设置** | 不能。只在视频**迟到**时丢帧追赶，追的是累积型落后 |
| `sync-av-start` | **=1，`configure()` 里早已设置** | 不能。只对齐起播相位，之后的漂移它不管 |
| SoundTouch | 已编入（`ijk_soundtouch_*`、`setTempoChange`/`setRateChange`/`setPitch` 全在） | 不能。Java 层只暴露 `setSpeed(float)`，**同时**改音视频速度，相对偏移不变 |
| `adelay` / `atempo` / `asetpts` / `setpts` / `apad` | **均不存在**于 `libijkffmpeg.so` | — |

configure 串里 `--disable-filters` 与 `--enable-avfilter` 同时存在 ⇒ avfilter 框架在、
**滤镜一个都没编进去**。所以「用一个滤镜把音频推迟 200 ms」这条路在本内核上不存在，
除非重编 FFmpeg（成本远超收益，且 ijk 0.8.8 的 aar 是官方制品，重编会失去可复现性）。

准确表述应该是：**本内核能追「累积型」落后（framedrop），不能消「恒定型」偏移。**

### 3. 找到的真正缺口：探针没读帧率

这是本轮唯一的技术增量。`IjkMediaPlayer` 提供 `getVideoDecodeFramesPerSecond()` 与
`getVideoOutputFramesPerSecond()`，这两个数正好能把两类病因分开：

- **解码帧率 > 输出帧率**（差 >2 fps）⇒ 视频正在被丢帧追赶音频 ⇒ **累积型**，
  framedrop 在起作用但追不上，可以调 `framedrop` 阈值或降低解码负担来缓解；
- **两者相当而画面仍落后** ⇒ 视频链路本身没积压 ⇒ 延迟在**显示端**
  （电视的 MEMC / 图像处理延迟、或 HDMI 音频直通 vs 画面处理不同步），
  **播放器侧无解**，只能在电视设置里关「运动补偿/画质增强」或改音频输出模式。

`QualityProbe` 新增 `decFpsCenti` / `outFpsCenti` 两个环形数组（`WINDOW=60`，1 s 一采样），
`summary()` 新增第 5 行：

```
帧率：解码 25.00 · 输出 24.60（两者相当，解码链路没有积压）
帧率：解码 19.80 · 输出 7.81（输出比解码少 11.99，上屏前被丢；与上行丢帧率口径不同）
```

判读阈值 ±2 fps（`diffCenti > 200`）。两项各自 try/catch，读不到置 −1 显示「—」并标
`readFailed`，不影响其余读数。**仍然只读**：O62 断言探针内无 `failCurrent` / `seekTo`。

### 4. 苏州台的特殊性：换线路对本台无效

`legacy/assets/channels.json` 里「苏州新闻综合」只有 2 条线路：

```
https://live-auth.51kandianshi.com/szgd/csztv1.m3u8
http://live-auth.51kandianshi.com/szgd/csztv1.m3u8    ← 同源明文镜像
```

**同一个源，只有 http/https 之别。** 所以「换线路」对音画延迟没有任何意义——
之前 §38 里「换到另一个源可能更好」的建议对本台**不成立**，这一条要划掉。
全台唯一有第三方直连的是「苏州4K」（`http://tylive.kan0512.com/norecord/csztv4k_4k.m3u8`），
但那是另一个频道、且是 4K（S50 Air 走不了硬解）。

### 5. 顺手修掉的三处文案缺陷（都是「页面上自相矛盾」级别）

| 位置 | 原来 | 改成 | 断言 |
|---|---|---|---|
| `LegacyPlayerActivity.java:1644` | 写死「帧队列 3 · 帧率上限 30」，与下一行「兼容模式 开」矛盾 | 按 `compatSyncEnabled()` 动态输出「帧队列 / 帧率不限（兼容模式）」 | O59 |
| `QualityProbe.java:444` | 判据用 `FAKE_HD_MIN_BPS`(1.5 Mbps)，提示却写「需 ≥2.5 Mbps」 | 提示与常量同源，且只说「偏低、留意」，不据此降权 | O60 |
| `SettingsPanel.java:127` | 硬解描述说「把这一项改回软解」，与「按线路回退、不改设置」实现相反 | 「只让这条线路改用软解，本项设置保持不变」 | O61 |

三处都是「拿到截图排障的人会被误导」的类型——和 §34 那次 `WRAP_CONTENT` 裁掉 7 行一样，
属于真机照片才能暴露的缺陷。

### 6. 一次测量方法的自我纠错（不写进结论，写进教训）

我试过直接解析 TS 的 PES PTS 来量源端偏移：`首个音频 PES PTS − 首个视频 PES PTS`。
苏州台测出 −195 / −187 / −179 ms（三个连续分片单调变化），差点据此断定「源端音频领先 190 ms」。
**这个结论是错的**，用 CCTV-1 做对照也测出 −110 ms 才发现：首个音频 PES 必然跨分片切点，
偏差量约等于**半个音频 PES 间隔**：

| 台 | 音频 PES 间隔 | 半间隔 | 实测偏移 | 差 |
|---|---|---|---|---|
| 苏州新闻综合 | 352 ms | 176 ms | −187 ms | 11 ms |
| CCTV-1 | 170.7 ms | 85.3 ms | −110 ms | 24.7 ms |

两个不同源的台都测出负数 ⇒ 是方法偏差，不是源端偏移。改用首尾双点法再验：
苏州 `head=−195 / tail=−267 / drift=−72 ms`，CCTV-1 `head=−119.7 / tail=−245 / drift=−125.3 ms`，
**tail 同样跨 PES 切点**，仍然不可用。

结论：**这个测量方法不足以证明源端有偏移，不能作为证据。** 记在这里是为了防止下次
再拿它下判断——只有真机能感知的量才算证据，自己造的量必须先用两个不同源做对照。

### 7. 产物与门禁

| 项 | 值 |
|---|---|
| 单包 | `dist/Shunbo-1.0.4-full.apk` 43,858,419 B · SHA-256 `3bdea6d94467048a6ea059bb4e00a456cb4b894a53d82edda7bc6a0bde0cc461` |
| 独立包 | `dist/Shunbo-Legacy-1.0.4-armv7a.apk` 3,544,607 B · SHA-256 `8ddb0d6afbb47c3c270c7839f80222797220939e1f7cda4677d255afcae7fe0e` |
| 门禁 | **35 步 / 3243 断言全绿**；legacy **250/250**（新增 O59–O63） |
| 上一版 | `dist/_prev/` 保留 12:21 的 1.0.4 两包，可直接回退 |

### 8. 下一步只有一条路值得走

请再上机看一眼**新增的「帧率」那一行**（在「画面」行下面）。三种可能：

1. ~~**解码明显高于输出** ⇒ 累积型落后，可以调大 `framedrop` 缓解~~
   —— **此条已于 13:52 撤回，见 §40。** 源码核实：`framedrop=N` 只是「最多连续
   early drop N 帧」，调大只会丢更多帧；而显示阶段 late drop 的开关是 `framedrop>0`，
   1 和 10 完全等价。方向是反的，不要照做。
2. **两者相当而仍延迟** ⇒ 显示端延迟，播放器无解。这时该做的是在电视上关掉
   「运动补偿 / MEMC / 画质增强」再对比，而不是继续改 App；
3. **两项都读不到（显示「—」）** ⇒ ijk 的帧率统计在本内核上没输出，那就换用
   `getDropFrameRate()` 的长期趋势做替代判据，需要再一轮取证。

在此之前，**不承诺「对齐按钮能修好」**，设置页文案也不这么写。

## §40 帧率读数首次真机出数：口径核实、病因定位、撤回错误建议（2026-11-10 13:52）

用户装了 13:28 的包，回传诊断页第 2/2 页。**「帧率」这一行第一次有数，而且和两个旧读数当场打架**——
这一轮的工作就是把这个架打明白，并**撤回我在 §39 里给错的一条处置建议**。

### 1. 真机读数（第 2/2 页，逐字转录）

```
时钟：1.000 · 正常，偏差应在视频侧（渲染 / 解码） · 窗口 4 个
画面：最近 60 秒缓冲 0 次
码率：1.93 Mbps（流量折算）
缓存：视频 6320 ms（30 秒最低 5280 / 均 7194） · 音频 5920 ms · 差 +400 ms
丢帧：0.5% · 近 20 秒 +0.0 个百分点
画面：1920×1080 · 标称 1080P · 实测相符
帧率：解码 19.80 · 输出 7.81（解码比输出多 11.99，正在丢帧追赶音频）
换台：上次出画 647 ms · 本次线路切换 0 次
起播策略：探测 1.5 秒 · 6 秒无首帧且仍有候选才换线 · 帧队列 3 · 帧率上限 30
同步：起播静音至首帧 · 长缓冲后按时钟再对齐（本条线路 0 次） · 手动对齐 0 次 · 兼容模式 关
闭环：自动换线 开 · 假高清降权 0 条 · 塌陷换线 0 次 · 时钟换线 0 次 · 停滞处置 0 次
判据：实测宽度 / 相对自身基线的吞吐 / 播放位置增速；缓存差与丢帧率经真机实测否定，不作换线依据
记忆：111 条线路 · 本台首选第 2 条（上次 422 ms）
内核：ijkplayer 0.8.8（默认 FFmpeg 软解，仅 armeabi-v7a）
```

**注意**：这页「兼容模式 关 / 手动对齐 0 次」，与 §39 那张「开 / 3 次」不同，且码率
1.93 Mbps 也对不上那张的 3.18 Mbps ⇒ **两次不是同一条件下的样本，不能横向相减**。
最可能的原因是换了包（独立包与单包设置不共享）或用户主动关了开关。这一点不确认就不能做 A/B 结论。

### 2. 表面矛盾：解码 19.80 / 输出 7.81，为什么丢帧率只有 0.5%？

如果每秒解出 ~20 帧、只上屏 ~8 帧，中间 12 帧必然被丢掉，丢帧率却显示 0.5% ——
**三个数不可能同时按「同一个丢帧口径」成立**。查 ijkplayer k0.8.8 源码（`ff_ffplay.c` /
`ijksdl_timer.c` / `ijksdl_timer.h`）后确认：**它们本来就不是同一个口径**。

| 读数 | 采样点（源码） | 窗口 | 覆盖什么 |
|---|---|---|---|
| `vdps`（解码帧率） | `decoder_decode_frame()` 里 `avcodec_receive_frame()` 成功后 `SDL_SpeedSamplerAdd(&vdps_sampler, ..., "vdps[avcodec]")` | `samples[10]`，≈最近 9 次调用 | 解码器吐出多少帧 |
| `vfps`（输出帧率） | `video_image_display2()` 里 `SDL_VoutDisplayYUVOverlay()` **之后** `SDL_SpeedSamplerAdd(&vfps_sampler, ..., "vfps[ffplay]")` | 同上 | 真正上屏多少帧 |
| `drop_frame_rate` | `get_video_frame()` 的 early-drop 分支：`drop_frame_count / decode_frame_count`（**累计**） | 不是时间窗口 | **只统计解码后、入队前**的提前丢帧 |

关键在 `video_refresh()` 的迟到帧分支：

```c
if (frame_queue_nb_remaining(&is->pictq) > 1) {
    Frame *nextvp = frame_queue_peek_next(&is->pictq);
    duration = vp_duration(is, vp, nextvp);
    if (!is->step && (ffp->framedrop > 0 || ...) && time > is->frame_timer + duration) {
        frame_queue_next(&is->pictq);
        goto retry;                 // ← 丢帧，但没有 frame_drops_late++
    }                               // ← 也没有 drop_frame_count++
}                                   // ← 更不会走到 display: 的 SDL_VoutDisplayYUVOverlay
```

`goto retry` 直接跳过了 `display:` 标签，被丢的帧**既不进 `drop_frame_rate`，也不进 `vfps`**，
只留在 `vdps` 里。于是：

> **「丢帧 0.5%」= 解码后入队前几乎没丢；「解码 19.80 / 输出 7.81」= 帧都入队了，
> 是在上屏前被 `video_refresh` 抽掉的。两者是同一现象的上下游，不是互相矛盾。**

诊断页原来把这两行并排放、都不标口径，是**页面自相矛盾**，和第 34 节那次裁行属于同一类缺陷。

### 3. 病因定位：软解 1080P 跟不上，不是恒定偏移、也不是电视 MEMC

把 §38/§39 三条否证和这页放一起，链条闭合了：

1. 音频侧完全正常（时钟 1.000、缓冲 0 次）；
2. 解码只吐出 **19.80 帧/秒**（S50 Air 是 armv7a 软解 1080P，这类源常见 25 fps，此处按常识推断、未经源端确证）；
3. 解码慢 ⇒ `frame_timer` 持续落后于音频时钟 ⇒ `framedrop=1` 让 `video_refresh()` 不停判定
   `time > frame_timer + duration` 并丢帧 ⇒ **每秒只有 7.81 帧真正上屏**（约 128 ms 一帧）；
4. 因为帧在上屏阶段就被丢了，队列没积压，所以缓存差只有 **+400 ms**——这解释了为什么
   「缓存差」这个量一直和音画偏差对不上：**落后的是 `frame_timer` 的位置，不是队列深度**。

所以之前两条候选解释都不对：既不是「起播相位差」（对齐 3 次无效），也不是「显示端延迟」
（电视机 MEMC 不会让 `vfps` 掉到 7.81）。**播放器自己就在抽稀画面。**

> 待用户确认的一点：每秒 8 帧在真机上应该有明显的「一顿一顿 / 跳帧」观感。
> 如果用户看到的是「整体慢半拍但画面连贯」，那这页读数还需要再解释一轮。

### 4. 撤回「把 framedrop 提到 5–10」——方向是反的

§39 第 8 节第 1 条与给用户的回复里，我写过「解码明显高于输出 ⇒ 可把 `framedrop` 从 1
提到 5–10」。**源码核实后确认这是错的，已划掉**：

```c
// get_video_frame() 的 early drop
is->continuous_frame_drops_early++;
if (is->continuous_frame_drops_early > ffp->framedrop) {
    is->continuous_frame_drops_early = 0;      // 超过 N：这一帧放行
} else {
    ffp->stat.drop_frame_count++;               // ≤N：丢帧
    got_picture = 0;
}
```

`framedrop=N` 的语义是「**最多连续提前丢 N 帧，第 N+1 帧必须放行**」。调大到 5–10
只会让 early drop 更激进、上屏帧数更少。而 late drop 的开关条件是 `framedrop > 0`，
**1 和 10 对 `video_refresh()` 完全等价**。也就是说调这个值：治不了 late drop，还会额外
增加 early drop。已由 O66 锁死「固定为 1，代码与文档都不许再出现该建议」。

顺带核实：`libijkplayer.so` 的 player 选项表里 `skip-loop-filter` / `skip-frame` **都不存在**
（`framedrop` / `max-fps` / `video-pictq-size` / `sync-av-start` 都在）。codec 类别透传
FFmpeg `AVCodecContext.skip_loop_filter` 这条路本轮**未验证**，按纪律不擅自启用（O67）。

### 5. 苏州台1套的死结

台账里「苏州新闻综合」两条线路的 `quality` **都是 1080**，且 URL 同源
（`csztv1.m3u8`，仅 http/https 之别）：

```json
{"label":"苏州新闻综合 1080P","quality":1080,"url":"https://.../csztv1.m3u8"},
{"label":"明文·苏州新闻综合 1080P","quality":1080,"url":"http://.../csztv1.m3u8"}
```

⇒ 既不能换源（同源），也没有低分辨率线路可降（两条都 1080P）。而同市的
「苏州文化生活 / 电影娱乐信息 / 生活资讯」是 **720P**，可以拿来当对照组，
判断「分辨率降下来，帧率是否恢复正常」。

### 6. 本轮改动（只修诊断、不动播放逻辑）

| 位置 | 改动 | 断言 |
|---|---|---|
| `QualityProbe.summary()` 丢帧行 | 加「（不含上屏前丢帧）」，标明只覆盖 early drop | O64 |
| `QualityProbe.summary()` 帧率行 | 「正在丢帧追赶音频」→「输出比解码少 X，上屏前被丢；与上行丢帧率口径不同」；注释里写全源码口径与「不许建议调 framedrop」 | O64 |
| `LegacyPlayerActivity.java` 内核行 | 原来写死「默认 FFmpeg 软解」，改成显示**本线路实际**解码方式 + **设置值**，并在按线路回退时标「本线路已回退」 | O65 |
| `README.md` §39 第 8 节 | 划掉错误建议并指向本节 | O66 |
| 播放参数 | **一个都没动**（`framedrop` 仍为 1） | O66 / O67 |

内核行改动是给下一步 A/B 用的：M4 是「按线路」回退，设置值与当前线路实际值可能不同，
以前那行静态描述根本看不出硬解有没有真正落到这条线路上。

### 7. 下一步只有一个动作：硬解 A/B

在该台进 **设置 → 解码方式 → 硬解**（会立刻重建当前线路，画面闪一下），回诊断页看两点：

- **「内核」行**是否变成「本线路 硬解 · 设置 硬解」——若显示「本线路已回退」，说明这条线路
  硬解跑不起来，按线路记忆已自动退回软解，别再试；
- **「帧率」行**：若解码升到 25 左右、输出与解码接近，病因坐实为软解算力不足，
  接下来该做的是「1080P 台自动优先硬解、失败按线路回退」；若两个数仍差很多，
  说明瓶颈不在解码器，需要再取一轮样本（最好同时拍 720P 对照台的同一页）。

在此之前**不改任何播放参数**。另外请顺带确认一下：画面是「一顿一顿」还是「整体慢半拍」，
以及这页是不是在延迟出现时拍的——这两个信息决定要不要再开一轮取证。

### 8. 产物与门禁

| 项 | 值 |
|---|---|
| 单包 | `dist/Shunbo-1.0.4-full.apk` 43,858,419 B · SHA-256 `891e5ab94a56c6762e26674165b4de2b60dcd16288a8c70de8f48e513cec74cf` |
| 独立包 | `dist/Shunbo-Legacy-1.0.4-armv7a.apk` 3,544,603 B · SHA-256 `e6d5714e2e8171ee31ef89bb1b04b5d58b6855d422365aa15aacf34c79ac99d8` |
| 门禁 | 35 步 / **3247** 断言全绿；legacy **254/254**（新增 O64–O67）；独立包 80/80；单包 24/24 |
| 回退 | 13:28 与 12:21 的两包在 `dist/_prev/` |

## §41 「起播正常、切台回来后音画不同步」：四张真机对照与排查（2026-11-10 14:42）

用户给出**成对的**诊断页：起播时正常（1.jpg / 11.jpg），播放一段时间、从其它频道切回来后
不同步（2.jpg / 22.jpg）。同一台（第 369 台「苏州新闻综合」）、同样硬解、同样关兼容模式。
这比之前任何一张单点截图都更有判别力——**它把病因从「源」锁到了「客户端运行期状态」**。

### 1. 逐项对照

| 项 | 起播正常 | 切回后异常 | 判读 |
|---|---|---|---|
| **帧率 解码 / 输出** | **25.00 / 25.00** | **26.66 / 8.54** | 解码没变慢（还略升），**只有上屏被抽稀** |
| 丢帧（early drop） | 0.0% | 0.5% | 都近乎为 0，不是变量 |
| 时钟 / 缓冲 | 1.000（窗口 10）/ 0 次 | 1.000（窗口 9）/ 0 次 | 音频正常推进，没有缓冲阶跃 |
| 视频缓存 | 7120 ms（30 秒最低 7120 / 均 7850） | **16760 ms**（最低 10080 / 均 12238） | **逐步爬升**，不是瞬间跳变 |
| 音频缓存 | 7840 ms | 11264 ms | 也在涨，但幅度小 |
| 缓存差 | −720 ms | +5496 ms | 该量已两次证否、不作判据，此处只当旁证 |
| 码率 | 2.62 Mbps | 3.26 Mbps | 网络反而更快，不是带宽问题 |
| 分辨率 | 1920×1080 · 实测相符 | 同 | 与假高清无关 |
| 出画 / 线路切换 | 738 ms / 1 次 | 653 ms / 0 次 | 起播都正常 |
| 手动对齐 / 兼容模式 | 0 次 / 关 | 0 次 / 关 | 条件一致 |
| 记忆 | 111 条 · 本台无更快记录，按台账顺序 | 118 条 · 本台首选第 2 条（422 ms） | 中间切过约 7 个台 |
| 第 1 页「硬解不适配」 | **1 条** | **10 条** | 中间有 9 次硬解回退 |
| 内核 | 本线路 硬解 · 设置 硬解 | 同 | 解码方式一致 |

### 2. 这组对照一次性排除了什么

- **不是源**：同一个台、同一条线路（记忆首选第 2 条），起播时完全正常。
- **不是恒定相位偏移**：起播时零延迟 —— §38/§39 那套「源端 / 显示端恒定偏移」的解释到这里就不适用了。
- **不是解码算力**：异常时解码 26.66 帧/秒，比正常时的 25.00 还高（硬解已开，§40 建议的 A/B 用户已经做了）。
- **不是音频快播、不是缓冲、不是网络、不是 early drop、不是设置差异**：时钟 1.000、缓冲 0 次、
  码率反而更高、丢帧 0.0→0.5%、硬解/兼容模式/手动对齐全都一致。

**唯一显著变化：上屏帧率 25.00 → 8.54，同时 videoq 从 7 秒爬到 17 秒。**
按 §40 已核实的口径，这就是 `video_refresh()` 持续 late drop（上屏前丢帧），
而不是解码器掉速。

### 3. 病因链条（沿用 §40 口径）

`getVideoCachedDuration()` 量的是**解复用后尚未送解码器的 videoq 包队列时长**
（`q->duration` 只在 `packet_queue_get()` 取包时扣减），不是「还能播多久」、也不是 pictq 帧队列。
所以 7 → 17 秒的爬升说明**消费端变慢**，链条是：

```
上屏持续 late drop / 渲染变慢 → pictq（video-pictq-size=3）被填满
→ 解码线程阻塞在 frame_queue_peek_writable → videoq.duration 只增不减
→ 缓存读数从 7 s 爬到 17 s
```

解码帧率仍显示 26.66 并不矛盾：`SDL_SpeedSampler` 只在有新事件时更新返回值，
无新事件时**不衰减**，显示的是阻塞前的最后一次计算值。

### 4. 代码走查：可指认的位置（区分「确证」与「嫌疑」）

| 位置 | 事实 | 状态 |
|---|---|---|
| `LegacyPlayerActivity:754`、`:889` | 换台只调 `playback.open()`，**不重建 Surface / Controller**；所有 player 共用同一个 `SurfaceHolder` | 嫌疑 A 的前提 |
| `PlaybackController:1510`、`:686` | `releaseCurrentPlayer()` 把 `stop/reset/release` 丢进**后台单线程异步**执行，不等待；`startStream()` 紧接着 `new IjkMediaPlayer()` 并 `setDisplay(同一个 holder)` | **嫌疑 A**：API 18 的 MediaCodec + ANativeWindow 对这种重叠敏感；「硬解不适配 1→10 条」是旁证 |
| `PlaybackController:863`、`:865` | `max-fps=30` + `video-pictq-size=3`（兼容模式关时生效） | **候选 B**：硬解 output buffer 异步回传，3 帧队列偏小，容易顶住解码线程 |
| `PlaybackController:860` | `sync-av-start=1` | **排除**：源码核实是 `FFPlayer` 实例字段，`decoder_init()` 按实例重置，不跨 player 残留 |
| `QualityProbe:95` | `start()` 会 `count=0 / head=0` 重置环形数组 | **排除**：读数不串台，两页可直接对比 |

**明确不做**：不凭这些嫌疑去改播放参数或释放时序。项目纪律是「只有真机实测支持的量才能驱动动作」，
而现在还缺一个能把 A（换台路径状态残留）与 B（播放中累积）分开的读数。

### 5. 更正 §39 一处结论的适用范围

§39 写「手动对齐按 3 次仍延迟 ⇒ seek 重锚不是病因」。这条**只在当时那组条件**
（恒定偏移 + 兼容模式开）成立。这四张图的「手动对齐」**都是 0 次**，也就是
**在当前这个「切台回来后累积型落后」的场景里，seek 重锚从没被测过**。
而现在病因恰恰变成 `frame_timer` 落后 —— 正是 seek 重锚理论上能修的形态。
所以不能把 §39 的结论外推过来，这次必须实测一次。

### 6. 本轮改动：只加读数，播放逻辑一行没动

| 位置 | 改动 | 断言 |
|---|---|---|
| `QualityProbe` | 新增 `outputFpsCentiAgo(20)`：从同一环形窗口取 20 秒前的输出帧率，样本不足返回 −1；顺手把 §40 之前那套过时口径的字段注释改正 | O69 |
| `PlaybackController` | 新增 `sessionStarts`（**跨台累计**，`open()` 不清零）与 `streamElapsedSeconds()` | O70 |
| 诊断页 | 新增「会话：起播 N 次 · 本线路已播 X 秒 · 输出帧率 20 秒前 Y → Z（下滑/回升/持平）」 | O68 |
| 播放参数 | `framedrop` / `pictq` / `max-fps` / `sync-av-start` 全部原样 | O70 |

**这三个读数怎么定案**：

- 起播次数大、已播时长短、20 秒前就已经是 8.54 ⇒ **切回来那一刻就坏**，指向嫌疑 A（换台路径状态残留）；
- 已播时长长、20 秒前 25 → 现在 8.54「下滑」 ⇒ **播放中累积**，指向候选 B / `frame_timer` 漂移；
- 两者都不大却复现 ⇒ 与累积无关，回到源端 PTS 不连续，需要另一轮取证。

### 7. 下一步两个动作（都不用改设置）

1. **在异常出现的那一刻，按一次「音画立即对齐」**，然后立刻看帧率行。
   从 8.54 回到 ~25 ⇒ `frame_timer` 落后，可修；纹丝不动 ⇒ 持续 PTS 错位或资源问题。
   这是目前成本最低、判别力最强的一个实验。
2. 装新包复现一次，把「会话」行和「帧率」行一起拍下来。

在此之前不改任何播放参数。

### 8. 产物与门禁

| 项 | 值 |
|---|---|
| 单包 | `dist/Shunbo-1.0.4-full.apk` 43,858,419 B · SHA-256 `46f4a4c33ace2bec81239731c10097d2ebd0aa87af4c594cc720e6ea20ebe935` |
| 独立包 | `dist/Shunbo-Legacy-1.0.4-armv7a.apk` 3,544,606 B · SHA-256 `195b6c8fc81d863fe98822815b007069fbfde1de25fef268b7b6ccfa1cd04a31` |
| 门禁 | 35 步 / **3250** 断言全绿；legacy **257/257**（新增 O68–O70） |
| 回退 | 13:52 / 13:28 / 12:21 的包在 `dist/_prev/` |

## §42 起播 1 秒暂态页：口径纠错、补齐「对齐 A/B」取证（2026-11-10 15:50）

用户装了 14:42 的包、按了 3 次「音画立即对齐」后回传第 2/2 页。**这一页不能用来判病因**，
但它暴露了两个此前没发现的问题：一个是诊断页的口径错误，一个是我上一轮取证设计的漏洞。

### 1. 真机读数（第 2/2 页，逐字转录关键行）

```
时钟：采样中（每 10 秒一个窗口）
画面：最近 60 秒缓冲 0 次
码率：读不到（内核未返回，且流量样本不足）
缓存：视频 8081 ms（30 秒最低 8081 / 均 8081） · 音频 8384 ms · 差 -303 ms
丢帧：0.0%（不含上屏前丢帧）
画面：1920×1080 · 标称 1080P · 判定中（满 8 秒给结论）
帧率：解码 17.04 · 输出 9.61（输出比解码少 7.43，上屏前被丢；与上行丢帧率口径不同）
换台：上次出画 726 ms · 本次线路切换 2 次
会话：起播 81 次 · 本线路已播 1 秒
同步：起播静音至首帧 · 长缓冲后按时钟再对齐（本条线路 0 次） · 手动对齐 3 次 · 兼容模式 关
闭环：自动换线 开 · 假高清降权 2 条 · 塌陷换线 0 次 · 时钟换线 0 次 · 停滞处置 0 次
记忆：118 条线路 · 本台首选第 2 条（上次 422 ms）
内核：ijkplayer 0.8.8（本线路 硬解 · 设置 硬解，仅 armeabi-v7a）
```

### 2. 这是「起播 1 秒的暂态页」，17.04 / 9.61 不是稳态证据

五个独立信号同时指向同一件事：

| 信号 | 值 | 说明 |
|---|---|---|
| 本线路已播 | **1 秒** | `openedAtMs` 起算，刚起播 |
| 时钟 | **采样中** | 10 秒一个窗口，还没出第一个窗口 |
| 码率 | **读不到（流量样本不足）** | 差分样本不够 |
| 分辨率 | **判定中（满 8 秒给结论）** | `FAKE_HD_SETTLE_MS` 未到 |
| 缓存 | 最低 = 均 = **8081** | 环形窗口里**只有一个样本** |
| 会话行 | 没有「输出帧率 20 秒前 → 现在」 | `outputFpsCentiAgo(20)` 因样本不足返回 −1 |

`SDL_SpeedSampler` 的 `samples[10]` 在 1 秒内只有 1~2 个事件，此时 17.04 / 9.61 是
**起播追帧暂态**，既不能证明「切回来那一刻就坏」（§41 嫌疑 A），也不能证明「播放中累积」
（候选 B）。**按项目纪律，这一页退出证据池。** 之前几轮反复吃过「自己造的量没有对照就下结论」
的亏（§39 的 PES PTS 半间隔偏差），这次不能再犯。

### 3. 但这一页给了三条有效信息

1. **起播 81 次**（跨台累计）——用户为了复现做了高频换台。与「切台回来才坏」的
   叙述一致，也让 §41 的**嫌疑 A**（旧 player 异步释放 + 共用 `SurfaceHolder` 的状态残留）
   仍然在桌面上：若是播放中累积（候选 B），不需要 81 次起播。但**这只是旁证，不是定案**。
2. **手动对齐 3 次**——用户确实执行了 §41 要求的 A/B 动作（装新包后计数归零，故为本次按的）。
3. **本次线路切换 2 次 + 本线路已播 1 秒**——拍照时刚经历一次重新起播，`reanchorNow()`
   本身只 `seekTo(pos)`、**不重建线路**，所以这 2 次切换来自 `open()` 的候选尝试，
   不是对齐按钮造成的。

### 4. 口径纠错：同一行两个「次数」根本不是一回事

逐行核 `PlaybackController` 后确认：

| 字段 | 清零时机 | 诊断页文案 | 实际含义 |
|---|---|---|---|
| `alignSeekCount` | `startStream()` 清零 | 「长缓冲后按时钟再对齐（本条线路 0 次）」 | 本线路 |
| `reanchorCount` | **只增不减**，进程重启才归零 | 「手动对齐 3 次」 | **跨起播累计** |
| `lastReanchorAt` | 不清零 | （不显示） | 3 秒冷却 `REANCHOR_COOLDOWN_MS` |
| `openedAtMs` | `startStream()` 重置 | 「本线路已播 1 秒」 | 本线路 |

也就是说「手动对齐 3 次」是**装新包以来累计按了 3 次**，不是本线路按了 3 次——
而这一页本线路才播 1 秒。旧文案把两个口径并排写、只给其中一个标「本条线路」，
读的人几乎必然误判。这是和 §39 那三处「页面自相矛盾」同一类型的缺陷。

### 5. 真正的问题：我上一轮的取证设计有漏洞

§41 第 7 节让用户「**在异常出现的那一刻按一次对齐，然后立刻看帧率行，
从 8.54 回到 ~25 说明是 frame_timer 落后**」。这个实验要求用户掐准时机、自己心算前后差值，
**但页面只记了「按了几次」，没有记下按下瞬间的帧率，也没有把前后两个值并排显示**。
结果就是：用户按了 3 次，回传的页面上仍然只有一个瞬时帧率，我依然无法回答
「对齐到底有没有用」。**责任在取证设计，不在用户操作。**

### 6. 本轮改动：只补读数与标注，播放逻辑一行没动

| 位置 | 改动 | 断言 |
|---|---|---|
| `PlaybackController` | 新增 `reanchorBeforeFpsCenti`（按下时探针最近一次采样的输出帧率）、`lastReanchorAtThisStream`、`reanchorThisStream`；`startStream()` 三项清零；新增 3 个 getter | O71 / O72 / O74 |
| 诊断页 | 新增「**对齐：按前 X → 现在 Y（回升 / 持平 / 下滑）· 本线路第 N 次 · 距上次 N 秒**」；未按过时给操作提示；距上次 <3 秒标「对齐后未稳」 | O71 |
| 诊断页「同步」行 | 两个次数分别标「（本线路）」「（累计）」，压缩「长缓冲再对齐」措辞为新增标注腾出宽度 | O72 |
| 诊断页「会话」行 | 本线路已播 <8 秒时追加「**起播未稳，勿据此页判读**」，防止再拿 1 秒样本定病因 | O73 |
| 播放参数 | `framedrop` / `video-pictq-size` / `max-fps` / `sync-av-start` 全部原样；`reanchorNow()` 仍只 `seekTo(pos)` 一次 | O74 |

「按前」的准确口径是**按下前 0~1 秒**的探针读数（采样间隔 1 秒），不是严格瞬时值，
代码注释和页面文案都不把它说成瞬时值。

### 7. 下一步：一次按键就能定案

装新包复现到异常态（**等本线路已播 >8 秒、诊断页不再出现「起播未稳」**），然后：

1. 记下「对齐」行的「按前 X」与「帧率」行的输出值；
2. 按**一次**「音画立即对齐」，等 5 秒；
3. 看「对齐」行：`按前 8.54 → 现在 24.80（回升 16.26）` ⇒ `frame_timer` 落后确实可被
   seek 重锚修好，下一步做「检测到持续 late drop 时自动重锚」（但必须先解决 §39 的
   「不能拿缓存差自动触发」）；若 `（持平）` ⇒ 重锚无效，排除 frame_timer，
   回到 §41 的嫌疑 A（换台路径状态残留）继续取证。

同时请把那一页的「**会话**」行一起拍下来：起播次数 / 本线路已播秒数 /
输出帧率 20 秒前 → 现在，能把 A 与 B 分开。在此之前不改任何播放参数。

### 8. 产物与门禁

| 项 | 值 |
|---|---|
| 单包 | `dist/Shunbo-1.0.4-full.apk` 43,858,419 B · SHA-256 `6b883c7ac36fc1e224746e3aa6730ca7a2a65397bca42009e851f85d96a5af03` |
| 独立包 | `dist/Shunbo-Legacy-1.0.4-armv7a.apk` 3,544,603 B · SHA-256 `220670c2905d9933ffd7f553c9322d25ae2a041e4441d05d2595c01604160e89` |
| 门禁 | 35 步 / **3254** 断言全绿；legacy **261/261**（新增 O71–O74） |
| 回退 | 14:42 / 13:52 / 13:28 / 12:21 的包在 `dist/_prev/` |

## §43 稳态页趋势定案：「起播即带病」，嫌疑落到换台释放交接窗口（2026-11-10 16:18）

用户装 15:50 的包后回传第 2/2 页。**这是项目里第一张「稳态 + 有历史趋势」的有效证据页**，
它把 §41 悬着的 A / B 两条路线分开了：候选 B（播放中累积）被排除，嫌疑 A 成为主嫌。

### 1. 真机读数（第 2/2 页，逐字转录）

```
时钟：1.000 · 正常，偏差应在视频侧（渲染 / 解码） · 窗口 2 个
画面：最近 60 秒缓冲 0 次
码率：1.97 Mbps（流量折算）
缓存：视频 7440 ms（30 秒最低 6760 / 均 8026） · 音频 6304 ms · 差 +1136 ms
丢帧：0.5%（不含上屏前丢帧） · 近 20 秒 +0.4 个百分点（正在恶化）
画面：1920×1080 · 标称 1080P · 实测相符
帧率：解码 29.41 · 输出 9.85（输出比解码少 19.56，上屏前被丢；与上行丢帧率口径不同）
对齐：本线路未按过（异常态按一次，等 5 秒再看）
换台：上次出画 718 ms · 本次线路切换 2 次
会话：起播 34 次 · 本线路已播 21 秒 · 输出帧率 20 秒前 11.19 → 9.85（持平）
起播策略：探测 1.5 秒 · 6 秒无首帧且仍有候选才换线 · 帧队列 3 · 帧率上限 30
同步：起播静音至首帧 · 长缓冲再对齐 0 次（本线路） · 手动对齐 1 次（累计） · 兼容模式 关
闭环：自动换线 开 · 假高清降权 1 条 · 塌陷换线 1 次 · 时钟换线 0 次 · 停滞处置 0 次
判据：实测宽度 / 相对自身基线的吞吐 / 播放位置增速；缓存差与丢帧率经真机实测否定，不作换线依据
记忆：123 条线路 · 本台首选第 2 条（上次 422 ms）
内核：ijkplayer 0.8.8（本线路 硬解 · 设置 硬解，仅 armeabi-v7a）
```

**新包生效的四个旁证**：出现「对齐」行、两个次数分别标「（本线路）/（累计）」、
本线路 21 秒 > 8 秒所以**没有**「起播未稳」标注、仍是「第 2/2 页」且底部
「本界面在 API < 24 启动」没被挤走（§42 担心的分页风险未发生）。

顺带验证 §42 的口径纠错是对的：「手动对齐 **1 次（累计）**」但「**本线路未按过**」——
用户在别的线路按过 1 次，旧文案会让人误读成本线路按了 1 次。

### 2. 定案：不是「播放中累积」，是「这一次起播就带病」

「会话」行第一次给出有效趋势：

| 时间点 | 输出帧率 | 说明 |
|---|---|---|
| 20 秒前（≈起播后 1 秒） | **11.19** | 已经病态 |
| 现在（本线路已播 21 秒） | **9.85** | 差 1.34 fps，判「持平」 |

**没有观察到「从 25 掉到 8.54」的过程。** §41 我给的两条定案规则里，
「已播时长长 + 20 秒前 25 → 现在 8.54（下滑）⇒ 播放中累积 / `frame_timer` 漂移」
这一支被证否。剩下的是「起播次数大、已播时长短、20 秒前就已经是低值 ⇒ 切回来那一刻就坏」：

- 起播 **34 次**（装新包后累计）后复现，与用户「切走再切回来才不同步」的叙述一致；
- §41 的成对样本里，「干净起播」是 **25.00 / 25.00**，「切回后」是 **26.66 / 8.54**；
- 本页 21 秒后仍是 9.85、没有回到 25 ⇒ **不是起播追帧暂态**（§42 那张 1 秒页才是暂态，
  干净起播几秒内就该收敛到 25）。

**结论：病是换台路径在「起播那一刻」带进来的，不是播放过程中长出来的。**
§41 的**嫌疑 A**（换台不重建 Surface / Controller + 旧 player 后台异步释放不等待）
成为主嫌；**候选 B**（`video-pictq-size=3` 在播放中累积顶住解码线程）被排除。

### 3. 「解码 29.41 正常、上屏只有 9.85」把嫌疑收窄到渲染交接

同页排除项：时钟 1.000（音频正常）、缓冲 0 次、码率 1.97 Mbps 正常、
硬解未回退、1920×1080 实测相符、丢帧 0.5% 只是轻微恶化（近 20 秒 +0.4 个百分点）。
视频缓存 7440 ms 也没像 §41 异常页那样爬到 16760 —— 说明这 21 秒里还没堵到队列级。

于是组合变成：**解码器吐得出 29.41 帧/秒，帧却只有 9.85 帧能上屏，且从起播就如此、
不随时间变化。** 按 §40 的口径，帧是在 `video_refresh()` 的 late drop 分支被抽掉的；
一个「解码正常、上屏恒低、起播即坏、不累积」的形态，最像的是**渲染输出通道
（Surface / ANativeWindow / MediaCodec buffer 队列）在换台时没干净交接**，
而不是解码算力、时钟漂移或队列深度。

代码位置（§41 已核实）：`releaseCurrentPlayer()` 主线程只做 `p.setDisplay(null)`，
把 `stop/reset/release` 丢进单线程后台不等待；`startStream()` 紧接着在
`PlaybackController.java:835` 把新 player `setDisplay(同一个 holder)`。
本页「本次线路切换 2 次 + 塌陷换线 1 次」还意味着这一轮连续创建了多个 player，
后台释放队列更可能堆积。

**但这仍是嫌疑，不是确证**：MediaCodec 实例上限、Surface buffer 队列状态、
API 18 的 ANativeWindow 行为都能产生同样的读数。所以本轮**只加读数，不改释放策略**。

### 4. 本轮改动：新增「释放」行（纯读数，释放策略一行没动）

| 位置 | 改动 | 断言 |
|---|---|---|
| `PlaybackController` | `AtomicInteger releasePendingCount`（提交 +1 / `finally` 里 −1，跨线程安全）、`releaseOverlapCount`（**跨台不清零**）、`lastOverlapDepth`、`lastReleaseCostMs` | O76 |
| `startStream()` | 在 `p.setDisplay(holder)` 前读一次待释放数，>0 就记一次「重叠」+ 当时队列深度 | O76 |
| `releaseCurrentPlayer()` | 记提交时刻、在 `finally` 回填耗时并减计数；**仍然不 join、不等待** | O77 |
| 诊断页 | 新增「**释放：待释放 N 个 · 重叠 M 次 / 起播 K 次（最近队列 D 个） · 上次释放 X ms**」 | O75 |
| 播放参数与释放时序 | 全部原样（`framedrop` / `pictq` / `max-fps` / `sync-av-start`；仍后台异步释放） | O77 |

「重叠 M / 起播 K」怎么定案：

- **M 随 K 增长、待释放数 >0 且长期不降** ⇒ 释放队列堆积 = 运行期状态残留，
  嫌疑 A 从「代码走查」升级为「真机确证」，下一步才谈改释放时序；
- **M 一直是 0 却复现** ⇒ 与释放重叠无关，回退到 MediaCodec 实例 / Surface 状态，另开一轮取证；
- **M 是常态（≈K）但只在高 K 时复现** ⇒ 不是单次重叠，是每次重叠遗留了东西，
  需要看队列深度趋势。

### 5. 下一步两个动作

1. **不用等新包、判别力最强**：在异常态**退出 App 再重开**（进程重启），第一次直接进
   苏州台1套，看帧率是不是回到 25 / 25。若是 ⇒ 「进程内运行期状态残留」被钉死，
   与源、设置、电视、解码器全都无关；装新包也会重启进程，§41 那张「起播正常」
   很可能就是这种干净态。
2. 装新包复现到稳态异常页，拍「**释放**」行 +「**会话**」行；顺手按**一次**
   「音画立即对齐」，等 5 秒看「对齐」行是回升还是持平（§42 的 A/B 读数这轮还没被用过）。
   回升 ⇒ 起播即错位仍可由 seek 重锚修好，是一条独立的缓解路径。

在此之前不改任何播放参数，也不改释放时序 —— 后者会拖慢换台，必须在确证后才动。

### 6. 产物与门禁

| 项 | 值 |
|---|---|
| 单包 | `dist/Shunbo-1.0.4-full.apk` 43,858,419 B · SHA-256 `d6d0712a10b05b6ce01804cc74eb615ad5eada508a416afa32ff0a5ae28bfc8b` |
| 独立包 | `dist/Shunbo-Legacy-1.0.4-armv7a.apk` 3,544,601 B · SHA-256 `971c88b3ba9d413e8e25b120debc763cc03b46020bd75a678b71d2c2fb472fe7` |
| 门禁 | 35 步 / **3257** 断言全绿；legacy **264/264**（新增 O75–O77） |
| 回退 | 15:50 / 14:42 / 13:52 / 13:28 / 12:21 的包在 `dist/_prev/` |

## §44 「释放」行首次数：证否队列堆积，做一次有上限、可证伪的交接干预（2026-11-10 16:48）

用户装 16:18 的包后回传第 2/2 页。**「释放」行第一次有真机数，而且把 §43 给的三条定案规则
判掉了两条**。更重要的是：这组数把「改释放时序会拖慢换台」这个顾虑证否了，
所以本轮从「只加读数」前进到**一次可证伪的干预**。

### 1. 真机读数（第 2/2 页，逐字转录关键行）

```
时钟：1.000 · 正常，偏差应在视频侧（渲染 / 解码） · 窗口 2 个
画面：最近 60 秒缓冲 0 次
码率：1.90 Mbps（流量折算）
缓存：视频 6000 ms（30 秒最低 6000 / 均 7321） · 音频 5632 ms · 差 +368 ms
丢帧：0.4%（不含上屏前丢帧） · 近 20 秒 +0.0 个百分点（正在恶化）
画面：1920×1080 · 标称 1080P · 实测相符
帧率：解码 24.39 · 输出 10.00（输出比解码少 14.39，上屏前被丢；与上行丢帧率口径不同）
对齐：本线路未按过（异常态按一次，等 5 秒再看）
换台：上次出画 720 ms · 本次线路切换 2 次
会话：起播 86 次 · 本线路已播 28 秒 · 输出帧率 20 秒前 9.61 → 10.00（持平）
释放：待释放 0 个 · 重叠 83 次 / 起播 86 次（最近队列 3 个） · 上次释放 62 ms
同步：起播静音至首帧 · 长缓冲再对齐 0 次（本线路） · 手动对齐 1 次（累计） · 兼容模式 关
闭环：自动换线 开 · 假高清降权 1 条 · 塌陷换线 0 次 · 时钟换线 0 次 · 停滞处置 0 次
记忆：136 条线路 · 本台首选第 2 条（上次 422 ms）
内核：ijkplayer 0.8.8（本线路 硬解 · 设置 硬解，仅 armeabi-v7a）
```

### 2. §43 的三条定案规则，逐条判

| 规则 | 实际读数 | 判定 |
|---|---|---|
| M 随 K 增长 **且待释放 >0 长期不降** ⇒ 释放队列堆积 | 重叠 83 / 起播 86，但**现存待释放 0 个**、**上次释放仅 62 ms** | **证否**。队列能清空，没有资源耗尽 |
| M 恒 0 却复现 ⇒ 与释放重叠无关 | M=83 | 不适用 |
| M≈K，只在高 K 时复现 ⇒ 每次重叠遗留了状态 | 96.5% 起播都重叠、最深队列 3 个 | **命中** |

关键在「**待释放 0**」是拍照时（本线路 28 秒后）的瞬时值，而「**最近队列 3 个**」是
`startStream()` 绑定 holder 那一刻的深度。两者不矛盾：换台密集时瞬时排到 3 个，
但单线程串行 3×62≈186 ms 就清空了。所以嫌疑 A 的措辞要修正：
**不是「后台释放队列堆积」，而是「几乎每次换台，新 player 都恰好在旧 player 还没释放完时
绑到同一个 SurfaceHolder」**——一个 96.5% 命中的交接窗口。

### 3. 两张稳态页独立复现同一形态，且指向「进程第一次起播」

| 项 | §43（331.jpg, 16:18） | 本页（31.jpg, 16:48） |
|---|---|---|
| 起播次数 | 34 | **86** |
| 本线路已播 | 21 秒 | **28 秒** |
| 帧率 解码 / 输出 | 29.41 / 9.85 | **24.39 / 10.00** |
| 20 秒前 → 现在 | 11.19 → 9.85（持平） | **9.61 → 10.00（持平）** |
| 视频缓存 | 7440（最低 6760） | 6000（最低 6000） |
| 丢帧 / 码率 | 0.5% / 1.97 Mbps | 0.4% / 1.90 Mbps |
| 记忆 | 123 条 | 136 条 |

两张都是稳态（>8 秒）、都是「起播即病态、20 秒不回落」，解码正常而上屏恒 ~10。
§43 的定案因此**复现成立**：不是播放中累积，不是起播追帧暂态。

再叠上本页的 96.5% 重叠率：既然除「进程第一次起播」外几乎每次换台都重叠，
那 §41 那张「起播正常 25.00 / 25.00」最可能就是**没有旧 player 可释放的干净态**。
这与用户原话「开始播放时没有任何延迟；从其它频道切回来后不同步」完全吻合。

### 4. 数据改变了决策：为什么这轮敢动释放时序

§43 我写过「改释放时序会拖慢换台，确证之前不动」。本页把代价钉死了：
**单次释放 62 ms、队列不堆积、真机出画 720 ms**。也就是说等待的代价是几十毫秒，
不是当初担心的「换台被上一台的缓冲拖住」。于是做一次**可证伪的干预**：

> 在 `startStream()` 把新 player 绑到 holder 之前，有上限地等后台释放队列排空，
> 让后续每次换台都尽量接近「进程第一次起播」的干净态。

这不是凭嫌疑盲改，四个边界都锁死了：

| 边界 | 实现 |
|---|---|
| 硬上限 | `Tuning.RELEASE_DRAIN_TIMEOUT_MS = 200L`（3×62≈186 ms 够排空最深队列 3 个），超时**照常继续** |
| 不改异步模型 | 仍 `RELEASE_EXECUTOR.execute()`，不 join、不 `awaitTermination`、不 `Future.get` |
| 主线程不被卡死 | 2 ms 短轮询 + deadline，最多多等 200 ms（真机出画 720 ms） |
| 可回退 | 旧包在 `dist/_prev/`；播放参数 `framedrop` / pictq / max-fps / sync-av-start **一个没动** |

**如果消掉重叠后仍发病，嫌疑 A 当场排除**，比再加一轮读数的判别力更强。
「退出 App 重开」那个实验依然有效，但本包已经把每次换台都往干净态拉，优先级降低。

### 5. 本轮改动清单

| 位置 | 改动 | 断言 |
|---|---|---|
| `Tuning.java` | 新增 `RELEASE_DRAIN_TIMEOUT_MS = 200L`，注释写全真机依据与「超时不阻塞」 | O78 |
| `PlaybackController` | 新增 `awaitReleaseDrain()`，在 `releaseCurrentPlayer()` 之后、`setDisplay(holder)` 之前调用；新增 `drainCount` / `drainTimeoutCount` / `lastDrainCostMs` / `maxOverlapDepth` 四个跨台不清零读数 | O78 / O79 |
| `PlaybackController` | 绑定 holder 时仍记 `releaseOverlapCount`，并同步历史最深队列；正常情况该计数**不再增长** | O76 / O79 |
| 诊断页 | 「释放」行拆成两行：`释放：等待 M 次 / 起播 K 次（最近 X ms · 超时 T 次） · 本次无重叠 / 本次重叠 D 个`、`交接：历史重叠 O 次（最深 P 个） · 现存 N 个 · 上次释放 Y ms`。**「本次无重叠」是干净态的自证读数** | O75 / O79 |
| `QualityProbe` | 丢帧行阈值 30 → 100（与 `%.1f` 显示精度对齐），新增「在好转」；修掉真机照上的「**+0.0 个百分点（正在恶化）**」自相矛盾 | O80 |
| 门禁 | O75 / O77 改写，新增 O78–O81；O81 锁住四个播放参数与 `reanchorNow()` 仍只 `seekTo(pos)` | O78–O81 |

「+0.0 个百分点（正在恶化）」是 §39 那三处「页面自相矛盾」之后的第 4 处：
`delta` 用 `%.1f` 显示成 0.0，但恶化阈值只要 30（0.03 个百分点）。
真机照片才能暴露这类缺陷——数字自己不会投诉。

**没有新增设置项**：代价在 62 ms 量级、旧包可一键回退，加第 20 项只会挤压设置页行高
（§34 已有「WRAP_CONTENT 裁掉 7 行」的教训）。诊断页多一行，按 1080p 每页 23 行估算
仍在第 2 页内。

### 6. 装上新包后怎么判读（不需要做任何额外操作）

正常换台复现一次，看「释放 / 交接 / 帧率」三行：

- **「释放：等待 M 次…本次无重叠」+「交接：历史重叠 0 次」+ 帧率回到 ~25 / 25**
  ⇒ 交接窗口就是病因，修复有效。下一步把 200 ms 上限按「最深队列 × 单次释放耗时」
  再收一遍即可。
- **「本次无重叠」但输出帧率仍是 ~10** ⇒ 交接窗口被排除，回到 MediaCodec 实例上限 /
  Surface buffer 队列 / API 18 ANativeWindow，另开一轮取证。这次排除是硬的，
  因为新旧 player 已不再重叠。
- **「超时 T 次」持续增长** ⇒ 200 ms 不够排空，读数会给出「最深 P 个 + 上次释放 Y ms」，
  按实测调常量，不猜。

顺带留意底部是否仍是「第 2/2 页」；诊断页新增了一行。

### 7. 产物与门禁

| 项 | 值 |
|---|---|
| 单包 | `dist/Shunbo-1.0.4-full.apk` 43,858,419 B · SHA-256 `393a5f6de670965473d019461cc1da14e18cc22d00438d951aa421478433bce4` |
| 独立包 | `dist/Shunbo-Legacy-1.0.4-armv7a.apk` 3,544,604 B · SHA-256 `f94f70a825fe7e18e93788f9cf40e0b1802338df5f2d1512edf885109561dee4` |
| 门禁 | 35 步 / **3261** 断言全绿；legacy **268/268**（O75/O77 改写 + 新增 O78–O81） |
| 回退 | 16:18 / 15:50 / 14:42 / 13:52 / 13:28 / 12:21 的包在 `dist/_prev/` |
