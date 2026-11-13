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

---

## §45 Windows 桌面版 1.0.4 出包与 GitHub 发布（2026-11-11 08:40）

### 1. 产物

| 文件 | 说明 | 大小 (B) | SHA-256 |
|---|---|---:|---|
| `Shunbo-1.0.4-windows-x64-setup.exe` | 安装版：Inno Setup 6 / lzma2 / per-user（`PrivilegesRequired=lowest`，不弹 UAC） | 25,751,560 | `df4f0607123580759b6311db5b02b2fedb81b20856250c1b3a54265e2a0b71d1` |
| `Shunbo-1.0.4-windows-x64-portable.zip` | 便携版：解压即用，不写注册表 | 33,517,734 | `dabd8735721dc6981181487d0fc6b4637c0a8171a73d742fb4f513428ca91930` |

版本与 `pubspec.yaml` 的 `1.0.4+5` 对齐（`VersionInfoVersion=1.0.4.5`）。
`dist/` 仍被 `.gitignore` 排除，**二进制不入库，发布走 Release 资产**——与两个 APK 同一约定。

### 2. 构建链（仓库内可复现）

本次实测脚本落在 `tooling/windows_release.iss`（`dist/windows/Shunbo-1.0.4.iss` 是出包时的绝对路径副本，不入库）。顺序：

1. `bash tooling/fetch_windows_kits.sh` → `flutter build windows --release`（本次 112.9 s）。
2. 把 `build\windows\x64\runner\Release\.` 整体复制到 `dist\windows\Shunbo-1.0.4\`，**并补齐 VC++ 运行库 DLL**（`msvcp140.dll` / `vcruntime140.dll` / `vcruntime140_1.dll`）。缺任意一个，装到没装过运行库的机器上会启动即崩；Flutter 不会替你做这一步。
3. `ISCC.exe tooling\windows_release.iss` 出安装版；同目录压成便携 zip。

四个已验证的坑：`ArchitecturesAllowed` 必须写 `x64compatible`（Inno 6 里 `x64` 已弃用）；脚本须 UTF-8 BOM + CRLF，否则中文按 ANSI 解析乱码；Git Bash 直传 `/VERYSILENT` 会被 MSYS 改写成 `C:/Program Files/Git/VERYSILENT`（用 `MSYS2_ARG_CONV_EXCL='*'` 或 PowerShell）；调用脚本宿主用 PowerShell 工具而非 Bash。

与 `tooling/windows_installer.iss` 并存是有意的：旧脚本直接从 `build\...\Release` 打包、输出 `Shunbo-Setup-<版本>-x64.exe`，带 `installer_readme_zh.txt` 首屏与中文语言包，是早期通用脚本；新脚本是本次实测出包路径，两者不互相替换。

### 3. 内核与数据（静态核查）

桌面分支走 `MediaKitPlayerController`（libmpv），不是 Android 的 ExoPlayer / ijkplayer。频道台账编译进 `verified_channels.g.dart` / `official_satellite.g.dart`，**不是运行时读 assets**——安装包里没有 `channels.json`，也不需要随包分发内容源。

### 4. 验证范围

静默安装与静默卸载退出码均为 0，落地 33 个文件，`shunbo.exe` / `flutter_windows.dll` / AOT 库 / `icudtl.dat` / mpv 相关 DLL 齐全。**未做 GUI 启动与真机播放走查**（无桌面播放实测），这一项仍是空白，不能写进「已验证」。

### 5. 发布

Release `v1.0.4`（id `441082615`）在原有 2 个 APK 之外补上这 2 个 Windows 资产，共 4 个；服务端 `digest` 与本地 `sha256sum` 逐一比对一致。源码侧只新增 `tooling/windows_release.iss` 与本节记录，版本号、播放逻辑、门禁断言一个没动。

## §46 1.0.5：点播源开放接口（G2+G3 默认 / G1 用户自决）（2026-11-11 16:10）

### 1. 本版范围

版本升到 **`1.0.5+6`**（`pubspec.yaml`、`lib/platform/system_channel.dart`、`tooling/windows_installer.iss` 三处同源，对应门禁断言同步）。改动只落在 Flutter 侧点播能力：G1 地址配置、G3 片库检索、版本与门禁记录。**直播链路、播放内核、legacy 独立包、频道台账、1.0.4 产物一个没动**。

### 2. 默认组合 G2+G3

默认仍是内置合规片库 `VodCatalog`（Blender CC-BY 与公开测试素材），经 `MemorySourceAdapter` 复用 1.0.4 已有的续播、进度落盘、自动连播、换源对齐；E9 纯数据规则源导入链保持原样。G3 新增片库本地检索 `lib/features/vod/vod_search.dart`：**空查询原样返回传入列表引用**，计数文案与 1.0.4 逐字相同，因此浏览顺序、卡片数量、点击行为都不变。

### 3. G1 开放接口（用户自决）

- 设置页新增「点播源（1.0.5）」区块 `lib/ui/settings/vod_source_section.dart`：开关**默认关闭**；开启后可点选候选地址列表，也可手动输入地址并保存（上限 12 条，可移除、可恢复默认）。设置落在 `FileConfigStore.saveState('vod-source-address')`，坏数据一律回落「关闭」默认。
- 候选清单取自《播放接口.txt》的 6 个点播条目（官方入口 + 5 份 TVBox 配置），只是**可选项数据**：不随包请求、不随包注册、不代表已获授权；每项标注当前策略状态。
- 是否使用、用哪个地址完全由用户决定；选中后需主动点「应用当前地址」，走的仍是 1.0.4 已有的 `SourceImportService.importFromUrl` → E9 白名单 → 来源信任链，没有新增第二条导入路径。
- **安全基线不放宽**：仅 https（loopback 可明文 http）、拒绝内嵌账密 / 非 http(s) 协议 / 超长 / 控制字符；只接受 `dart` / `regex` / `json` 纯数据后端，**不执行外部 jar / QuickJS**（`shunbo/source_jar` 原生通道仍未注册，生产调用方 `allowUnsafeBackends` 仍为 false）。因此 5 个明文 http 候选会被策略明确拒绝并显示原因；官方入口虽是 https，但返回 HTML 页面而非源配置 JSON，导入会在 JSON 解析阶段被拒。要放开这些限制需另轮明确授权，本版不做。
- 结论边界：本版交付的是「可配置、可校验、可拒绝」的开放接口能力，不是「第三方影视仓可播」。

### 4. 1.0.4 行为隔离

| 保证 | 依据 |
|---|---|
| 启动不拉取任何外部地址 | G1 默认关闭；`main.dart` 只装配 store，不引用候选清单 |
| 点播浏览结果不变 | 空查询返回原列表引用；计数文案一致；内置片库未删改 |
| 默认片源不变 | `VodPage` 仍以 `VodCatalog.sourceId` 起播；片库未混入第三方地址 |
| 播放内核与直播链路不变 | 未改 `player_*`、`LiveController`、`legacy/`、台账与播放参数 |
| 1.0.4 可回退 | `legacy/build_legacy.py`、`tooling/windows_release.iss` 的 1.0.4 出包脚本原样保留，由门禁 H05/H06 锁住 |

### 5. 版本与出包说明

`legacy/build_legacy.py`、`tooling/merge_single_apk.py`、`tooling/windows_release.iss` 保留 1.0.4 字面值，作为**回退基线**未改。1.0.5 单包用 `merge_single_apk.py --skip-flutter-build --version-name 1.0.5 --version-code 6` 组装（**24/24** 断言）；Windows 出包用 `dist/windows/Shunbo-1.0.5.iss`——1.0.4 实测脚本的**绝对路径副本**（未入库，`tooling/windows_release.iss` 未改），保留 UTF-8 BOM + CRLF、`x64compatible`、`PrivilegesRequired=lowest`。legacy 独立包本版未升版、未重打。**已出 3 个 1.0.5 包，未提交源码、未推送、未建 tag / Release**；远端写操作需当轮明确授权。

### 7. 出包记录（2026-11-11 16:37）

| 产物 | 大小 (B) | SHA-256 |
|---|---:|---|
| `dist/Shunbo-1.0.5-full.apk` | 43,956,723 | `83ee2d0c39c4bcd0ab762564f75dac3d15c975cbfdf4aad6cdcbe7b6545f3dde` |
| `dist/Shunbo-1.0.5-windows-x64-setup.exe` | 25,759,732 | `4e8c457084a72a558250c44074b2bf4122d9c657521047e89a6b3d228b0579d9` |
| `dist/Shunbo-1.0.5-windows-x64-portable.zip` | 33,527,585 | `4f494fe2f91b569f1144442c8511e488cc6001b5ced7f3a9fa3bdf817d372e3c` |

构建链：`ANDROID_HOME=D:\Android\android-sdk` + JDK17 → `flutter build apk --flavor full --release --target-platform android-arm,android-arm64`（81.7 s）→ 单包组装；`fetch_windows_kits.sh`（缓存命中）→ `flutter build windows --release`（41.6 s）→ 补 10 个 VC++ CRT DLL → `ISCC.exe dist\windows\Shunbo-1.0.5.iss`（20.7 s）→ 便携 zip。

产物校验：单包 `versionCode=6 / versionName=1.0.5`、`minSdk=16 / targetSdk=36`、v1+v2 签名、24/24 断言；`libapp.so`（arm64 + armv7a）与 Windows `data/app.so` 均检出 `vod-source-address` / `VodSourceAddress` / `vod_search` ⇒ 1.0.5 新代码确实进包；安装版 `FileVersion=1.0.5.6` / `ProductVersion=1.0.5+6`，静默安装与卸载退出码均 0、落地 33 文件、关键 DLL 与 AOT 齐全、卸载后无残留注册表项。1.0.4 的 4 个产物哈希复核**未变**，可继续回退。

> ⚠️ 本节三个包（16:34–16:37）**不含**第三方点播接入代码，已被 §47.6 的重打产物取代，哈希作废，不要再分发。

仍未做：GUI 启动、桌面/电视真机播放、G1 真实 https 地址导入实测；这些不写进「已验证」。

### 6. 验证

`flutter analyze` **0 问题**；全量门禁 **37 步 / 3474 断言全绿**（1.0.4 基线 3261 断言全部保留 + 地址校验 93 + 第三方接入 120），legacy **268/268**。新增 `tooling/verify_vod_source_address.dart` 覆盖默认关闭、候选清单、地址校验、落盘往返、空查询等价、装配与安全基线、版本与回退基线；其中 D17 曾暴露「反序列化未校验自定义地址格式」的真实缺陷，已修实现后再复跑全绿。（§48 又加 21 条断言后为 **3495**。）

未做：GUI 里点开设置页与点播页的人工走查；G1 地址的真实导入实测（需用户自行配置合规 https 地址）；三端真机播放验证。这些不写进「已验证」。

## §47 1.0.5 复查：第三方点播数据「真接入 + 能播放」（2026-11-11 17:05）

### 1. 触发问题（真机截图）

设置页截图：输入框是 `http://124.223.214.31:16/8888`，下方却显示绿色「格式符合传输策略」，以及「链接导入失败：配置超过 256 KB 上限」。核查后确认**两条提示都不是针对输入框那条地址**：

- 绿字来自 `validateVodSourceAddress(_settings.effectiveUrl)`，验的是**当前选中地址**，与输入框文字无关（`vod_source_section.dart`）；
- 256 KB 来自 `source_config_url.dart` 的流式上限；实测唯一超限候选是影视仓官方入口 `https://api.starlink.fan/index.php`（**277,018 B** HTML），而 `:16/8888` 只有 12,437 B ⇒ 失败那次导入的是旧选中项。

更关键的是：这 5 份 TVBox 配置里，`:16/8888` 的 **27 个站点全部 `type:3`**（26 个 `csp_*`、1 个外链 `drpy2.min.js`、2 个带 jar），顶层 `spider` 指向远程 jar —— **配置只是插件注册表，本身没有影片数据**，必须执行外部 JS / jar 才能出片。所以放宽 http、去掉 256 KB、修文案都只能让它「导入成功」，一部片子也出不来。

### 2. 技术路径：纯数据协议，零代码执行

核查发现 `47.96.82.41:5188/config.json` 的 **20 个 `type:1` 站点是标准苹果 CMS V10 采集 API**，实测 11 个可直连返回影片 JSON：

- `?ac=list` → `{code,list:[{vod_id,vod_name,type_name,vod_year,vod_area,vod_remarks}]}`
- `?ac=detail&ids=…` → `vod_play_url` = `第1集$https://…/1.m3u8#第2集$…`（`$$$` 分隔多播放源）
- 一次详情请求 12 部会撑爆 256 KB ⇒ 按 **4 部一批**取

于是新增两条**不需要执行任何外部代码**的接入形态：

| 形态 | 契约 | 来源 |
|---|---|---|
| 点播数据契约 JSON | 顶层 `items`，每条含 `id/title/section/episodes[{number,title,url}]`，可选 `headers`（仅 Referer / UA / Origin 放行） | 自备 / 已授权接口 |
| TVBox 配置中的 `type:1` 采集站 | 扫描 `sites`，只取 `api` 为 http(s) 的 CMS 站 | 用户填写的地址 |

`type:3` / `csp_*` / `spider jar` 站点**一律跳过**并给出可读原因「本客户端不执行外部代码」，不再报误导性的「超限 / 格式错误」。1.0.4 确立的「外部配置默认禁止 jar / QuickJS 后端」安全基线**没有放宽**：`allowUnsafeBackends` 生产仍为 false，`shunbo/source_jar` 原生通道仍未注册，项目未引入任何 JS 引擎依赖。

### 3. 落地改动

**新增**：`lib/features/vod/third_party_vod.dart`（纯 Dart 解析：契约、CMS 列表/详情、`vod_play_url`、媒体 URL 与请求头安全校验）、`lib/features/vod/vod_library.dart`（运行期可变片库 + 注册适配器，**自带极简监听协议，不依赖 `flutter/foundation`**，门禁可裸 `dart run`）、`lib/data/onboarding/third_party_vod_service.dart`（下载编排）、`tooling/verify_third_party_vod.dart`（**120 断言**）。

**改动**：`VodItem` 增加 `sourceId` / `headers`（默认值保证 1.0.4 构造点不变）；`MemorySourceAdapter` 支持 `playbackHeaders`；`VodPage` 从 `VodLibrary.inSection()` 取数、按 `item.sourceId` 起播、监听片库刷新；`source_config_url.dart` 加 `allowInsecureHttp`（默认 false）；`vod_source_address.dart` 加同名显式开关（默认 false）；`services.dart` / `main.dart` 装配 `VodLibrary` 与 `ThirdPartyVodService`。

**修掉 3 个 UI 缺陷**：① 输入框实时校验，绿字不再冒充输入结果；② 「应用当前地址」**优先消费输入框内容**，界面显式显示「当前选中」；③ 被策略拒绝的候选不可选中，`fromJson` 也不会在重启后留下一个永远点不动的选中项。

**明文 http**：新增默认关闭的开关，打开后才在 G1 这条链路放行非 loopback http；1.0.4 的 E9 链接导入策略逐字不变。取数层实测「Dart 走系统代理访问采集站会挂住」，因此改为**直连优先、失败用短超时回退代理**。

### 4. 真网实测（2026-11-11 17:20，只读 GET）

| 输入 | 结果 |
|---|---|
| `http://47.96.82.41:5188/config.json` + 明文放行 | **ok = true，24 部 / 3 个可用采集站 / 5 站失败跳过 / 1 个插件站跳过**，耗时 32.6 s |
| 同上播放地址抽查 | `206 / application/vnd.apple.mpegurl / #EXTM3U`，407 ms 与 263 ms ⇒ **地址可直接交给播放器** |
| `http://124.223.214.31:16/8888` + 明文放行 | 明确失败：「共 27 个站点，全部是需要执行外部 JS / jar 的插件型站点…本客户端不执行外部代码」 |
| 同一地址不开明文放行 | 明确失败：「拒绝明文 http 下载源配置…或在「点播源」里显式打开允许明文 http」 |

期间修掉两个真实质量缺陷：一次取 12 部详情触发 256 KB 上限 ⇒ 改分批；部分采集站的 `vod_play_url` 是 `/share/<hash>` HTML 跳转页（Range 返回 `text/html`）⇒ 新增 `looksLikeDirectMedia()`，**只收能直接播的站点**，避免「栏目有片子、点开全黑屏」。

**内容合规边界**：本版只实现通用协议适配，**不内置任何第三方站点地址**；地址由用户填写，第三方内容的版权与授权由接口方及使用者自行确认。

### 5. 验证与未做

`flutter analyze` 0 问题；`tooling/verify_third_party_vod.dart` **120/120**，含离线端到端（注入 fetcher → `import()` → `VodLibrary.install()` → `SourceRegistry.resolvePlayUrl()` 拿到可播地址）、安全护栏与 1.0.4 行为不变（内置片库 6 条、默认 sourceId、空查询顺序）。旧门禁 G06 随导入服务变更如实更新为「走 `thirdPartyVod.import` + `vodLibrary.install`」，并补 G06b/G06c 锁住 UI 修复。

**仍未做**：GUI 里点开设置页 / 点播页的人工走查、真机（Letv S50 Air / API18）起播、Windows / Android 三端播放验证、全部 24 部逐条播放验证、晚高峰与跨日稳定性。这些不写进「已验证」。legacy 独立包（纯 Java 直播）没有点播栏目，本版改动不覆盖老电视端。

### 6. 重打出包（2026-11-11 18:45）：最终产物

§46.7 那三个包（16:34–16:37）是**第三方接入代码合入之前**的产物，`libapp.so` 里没有 `ThirdPartyVodService`。§47 的改动全部发生在出包之后，所以三包必须重打，旧包哈希作废。

**全量门禁（重打前）**：`flutter analyze` 0 问题；`verify_all.dart` **37 步 / 3474 断言全绿**（1.0.4 基线 3261 全保留 + `verify_vod_source_address` 93 + `verify_third_party_vod` 120），legacy **268/268**。重打后又单独复跑 legacy-compat 268、android-form 91、third-party-vod 120、vod-source-address 93，均绿。（本节的三个包随后被 §48 再次取代。）

**最终三包**

| 产物 | 字节 | SHA-256 |
|---|---|---|
| `Shunbo-1.0.5-full.apk` | 44,005,875 | `16bfa551154bff5286f76d493d92ee874ad9d1b8788b38c29f951c8202861f1f` |
| `Shunbo-1.0.5-windows-x64-setup.exe` | 25,775,802 | `da88470f95d7e6dec28714d63f342cb649babee2f6c43d33d546d6a5ffee7ebe` |
| `Shunbo-1.0.5-windows-x64-portable.zip` | 33,401,239 | `9ae37d718cd433dae1350930269101e26925b3e32ed028d7bbf05ffc5ac34d85` |

单包 `aapt2 dump badging`：`versionCode='6' versionName='1.0.5'`、`minSdkVersion:'16'`、`targetSdkVersion:'36'`，组装脚本 24/24 断言（dex 顺序、双 ABI、v1+v2、清单字节一致）。AOT 快照（`lib/arm64-v8a/libapp.so` 与 Windows `data/app.so`）均检出 `ThirdPartyVodService` / `parseCmsDetails` / `vod_play_url` / `allowInsecureHttp` ⇒ 第三方点播代码确实进包，不是只改了 Dart 源码。便携包 31 条，包内 `data/app.so` 与分发目录 sha256 一致、`testzip()` 无坏块。

**一次真实事故（已修复，记下来避免重犯）**：`tooling/merge_single_apk.py` 的 `--version-name` / `--version-code` 默认值仍是 `1.0.4` / `5`，重打时**漏传参数**，脚本按默认值把 1.0.5 代码打成了 `dist/Shunbo-1.0.4-full.apk`，并「归档上一版」把已发布的 1.0.4 基线覆盖掉。处置：

1. 从 `dist/_prev/Shunbo-1.0.4-full.20261111-181650.393a5f6d.apk.bak` 取回，`sha256 = 393a5f6d…478433bce4`（与 §46.7 发布记录逐字一致）⇒ 恢复 `dist/Shunbo-1.0.4-full.apk`；
2. 误标包改名隔离为 `dist/_prev/Shunbo-1.0.4-full.MISLABELED-1.0.5code.*.apk.bak`，**不允许**它被当回退基线；
3. 用 `--version-name 1.0.5 --version-code 6` 重打，`aapt2 dump badging` 复核通过。

教训：这个脚本的版本号是**命令行参数**而非读 `pubspec.yaml`，默认值会「成功」产出一个名字错误的包 —— 断言只验 minSdk/dex/签名，不验 versionName 是否与 pubspec 同名，所以不会报错。今后打单包必须显式传两个参数，并用 `aapt2 dump badging` 复核。

## §48 1.0.5 第二次修：候选地址的「闭合失败回路」（2026-11-11 19:05）

### 1. 截图暴露的真问题

真机设置页：`当前选中` 是 `https://api.starlink.fan/index.php`，下方绿字「格式符合传输策略」，点「应用当前地址」后底部报「链接导入失败：配置超过 256 KB 上限」。而候选里唯一实测能出片的 `47.96.82.41/config.json` 被画成灰色、「当前策略拒绝（可显式放行）」，**点不动**。

这不是文案问题，是**闭合的失败回路**：

| 候选 | 格式 | 实测 | 上一版能否点 |
|---|---|---|---|
| 影视仓官方入口 | https ✅ | 277 KB HTML，**永远导不进** | ✅ 能点（唯一能点的） |
| 5 条采集站 | 明文 http ❌ | 其中 1 条实测 24 部可播 | ❌ 灰的，点不动 |

⇒ 点得动的必然失败，能成的一个都点不动。用户没有第三条路，只能反复点那个必然失败的按钮，看到「超过 256 KB」。

「超过 256 KB」本身也是误诊：那是字节上限，真实原因是这条地址返回**网页**而不是接口 JSON。用户会以为「换个更大的地址就行」。

### 2. 三层修复

**① 候选分「实测可用性」，与「格式是否合规」解耦**

`VodSourceCandidate.availability`：

| 值 | 含义 | 清单里是哪些 |
|---|---|---|
| `usable` | 实测能出片 / 随包内置 | 内置片库、`47.96.82.41/config.json`、3 条未实测采集站 |
| `pluginOnly` | 全是 `type:3` 插件站点，放行也出不来 | `:16/8888`（实测 27 站点全插件） |
| `htmlPage` | 返回网页，不可能导入成功 | 影视仓官方入口（实测 277 KB HTML） |

`isKnownUnusableSource(url)` 供 UI 与反序列化共用。

**② 点候选 = 选中 + 立刻导入（明文先一次显式确认）**

`_pickCandidate()`：
- `!canProduceItems` ⇒ 不改变选中，只给「为什么不可用 + 换哪类地址」；
- 明文 http ⇒ 弹确认框（这一下点击**就是**显式放行，只作用于这条点播源），取消则什么都不做；
- 其余 ⇒ 选中并直接 `_runImport()`。

内置片库项走「摘掉外部源、回 1.0.4 行为」，不当成导入。

`_addCustom()` 也从「只保存」改为「保存 + 立即导入」——按钮写着「添加并使用」，只存不导会让人以为已生效。

**③ 网页不该拖到字节上限才报错**

`fetchSourceConfigUrl` 新增 `bool rejectHtml = false`（**默认 false，1.0.4 的 E9 链路零变化**）。G1 链路传 true：
- 响应头 `text/html` / `application/xhtml` ⇒ 立刻失败；
- 兜底看正文首字符 `<`（有些站点把网页写成 `text/plain`）。

新增失败原因 `SourceConfigUrlFailure.htmlPage`，文案：「服务器返回的是网页（HTML），不是点播接口数据；这条地址更像接口分发站 / 说明页，请改用返回 JSON 的采集接口地址」。

判定抽成纯函数 `isHtmlLikePayload({contentType, bodyPrefix})`，门禁可直接回归，不需要起 HTTP 服务。

**另外两处**：重启后 `selectedUrl` 落在已知不可用候选上会回落内置片库（否则每次进设置都停在一个点不动的地址上）；「当前选中」不再对必失败地址显示绿色「格式符合传输策略」。

### 3. 真网复测（19:00）

| 检查 | 结果 |
|---|---|
| `47.96.82.41/config.json` 导入 | ok，**12 部**可播条目 / 1 个站点成功 / 13 站取数失败跳过 / 1 插件站跳过，耗时 38 s |
| 抽到的播放地址 | `206 + application/vnd.apple.mpegurl + #EXTM3U + EXTINF 分片` ⇒ 可直接起播 |
| 影视仓官方入口 | 明确失败：「服务器返回的是网页（HTML），不是点播接口数据」——不再是「超过 256 KB」 |

导入耗时 38 s 是因为 21 个站点要逐个试探、多数已挂。设置页在此期间显示「正在拉取并解析接口：采集站要逐个试探，通常 20–60 秒」，避免被当成卡死。`maxSites` 由 8 提到 14、`itemsPerSite` 由 8 提到 12（8 站时只捞到 8 部）。

### 4. 验证与产物

`flutter analyze` 0 问题；全量门禁 **37 步 / 3495 断言全绿**（新增 B12–B16、C15–C22、D18–D20、F13b–F13f）。两条旧断言随行为变更**如实改写**（不是为过而改）：

- `G06c` 原锁「被拒候选不可选中」（`onTap: _busy || disabled ? null`）⇒ 现在改为「实时校验 + 走 `_confirmInsecure` 确认放行 + 不再整条禁用」；
- `F13` 原锁同一个字符串 ⇒ 拆成三条：点击只给原因不改选中 / 确认放行可取消 / 点候选即导入。

| 产物（19:12） | 字节 | SHA-256 |
|---|---|---|
| `Shunbo-1.0.5-full.apk` | 44,005,875 | `52504ca36916d67ebc5f8a17c1dce246cd20ef79dc2d7ef53beda8ce7334ee65` |
| `Shunbo-1.0.5-windows-x64-setup.exe` | 25,778,585 | `5b8879e4bf94670f8169bf756f8ec4b945dd41d437fca9d45037fe4a93b7d4d7` |
| `Shunbo-1.0.5-windows-x64-portable.zip` | 33,405,139 | `5213dadbdd2b88f8351bc07021364c8a26b66ba3aeec679548482564b17e4663` |

单包 `badging` = `1.0.5` / code 6 / minSdk 16 / targetSdk 36，24/24 断言；两平台 AOT 均检出 `isKnownUnusableSource` / `_confirmInsecure` / `_pickCandidate` / `isHtmlLikePayload`。

### 5. 正确操作路径（3 步）

1. 设置 → 点播源 → 打开「启用自定义点播源地址」；
2. 候选里点 **`TVBox 配置 · 47.96.82.41/config.json`**（唯一实测可出片的一条）→ 弹窗点「放行并导入」；
3. 等约 40 秒，看到「已接入…N 部可播放条目」后，回首页进「点播」。

**仍未做**：GUI 人工走查（本轮只做了真网取数与 AOT 进包校验）、三端真机播放、24 部逐条播放验证。影视仓官方入口、`:16/8888` 已标为不可用，但仍留在候选里作「反面样本」—— 点它们会说明原因，不再假装能用。

## §49 五条点播地址逐个实测 + 默认加载源（2026-11-11 19:40）

### 1. 实测结论（五个地址全部可达，差别全在「里面有没有能播的片」）

| # | 地址 | HTTP | 返回形态 | 站点构成 | 采集站实测 | 站内片量 | 应用内导入 |
|---|---|---|---|---|---|---|---|
| 1 | `124.223.214.31:16/8888` | 200 | JSON（`application/octet-stream`） | 27 站，**全部 type:3** | 0 个采集站 | 0 | **失败**：27 站全插件型，明确拒绝 |
| 2 | `124.223.214.31:55316/9981` | 200 | JSON | 117 站，**全部 type:3** | 0 | 0 | **失败**：同上 |
| 3 | `47.96.82.41:5188/config.json` | 200 | `application/json` | 21 站（20 采集 + 1 插件） | 11 个列表可达 / **9 个有直链** | **1,197,091** | **成功 12 部 / 1 站** |
| 4 | `124.223.214.31:924/924` | 200 | JSON | 105 站（2 采集 + 103 插件） | 2 个可达 / **0 个可播** | 248,507 | **失败**：一个返回网页、一个只给 `/share/` 分享页 |
| 5 | `124.223.214.31:20271/pps.bmp` | 200 | `image/x-ms-bmp`（**内容是 JSON**） | 151 站（14 采集 + 136 插件 + 1 其他） | 7 个可达 / 6 个有直链 | 824,191 | 成功 12 部 / 1 站 |

口径说明：

* **可达**：`?ac=list` 返回 200 且正文是采集 JSON（Python 侧 12 秒超时、10 并发）。
* **片量**：可达站点的 `total` 字段求和 —— 那是站内影片总数，不等于「本站能导入的条数」。
* **应用内导入**：走顺播自己的 `ThirdPartyVodService.import`（Dart 直连 8 秒超时 + 只收直链媒体）。
  只有 12 部是因为站点许多已挂/超时，且 `itemsPerSite=12`；两个可用地址都只活下来 1 个站点。
  用 Python 的 12 秒口径探测时 c3 有 9 个站可用 —— 口径更宽，不代表客户端能拿到。

### 2. 选谁做默认源

**`http://47.96.82.41:5188/config.json`**：可用站点数（9）与片量（119.7 万）都是第一，
次优的 `pps.bmp` 只有 6 站 / 82.4 万；另外两条根本没有影片数据，`:924` 有采集站却导不出可播条目。

`const String kVodDefaultSourceUrl`（`vod_source_address.dart`），候选清单里排在内置片库之后，
标签直接写「默认源 · 47.96.82.41/config.json」。

### 3. 「默认加载」怎么落地（不破坏 1.0.4）

两条路径，都只在**用户打开开关之后**才发生 —— 开关默认仍是关闭，第三方内容与明文 http 的
风险确认权在用户手里，这一点没有为了「默认」而松动：

1. **打开开关 = 预选默认源并立即导入**。`_enableWithDefaultSource()`：没选过地址就走
   `_pickCandidate(默认源)`，明文 http 弹一次确认框（那一下点击就是显式放行），成功后写入
   `selectedUrl`。已选过别的地址则只打开开关，不擅自替换。
2. **进入点播栏目按需自动加载一次**。`VodAutoSource`（`lib/features/vod/vod_auto_source.dart`，
   纯 Dart）三条纪律：**单飞**（电影/电视剧/纪录片三页共用一个实例，只发一次请求）、
   **不重试**（进程内只试一次，失败不静默重来 —— 一次要 40 秒，重试像卡死）、
   **只认默认源**（用户自己填的地址不自动请求）。

条件不满足就完全不发请求：开关关着 / 选中的不是默认源 / 片库已有外部条目。
加载中在栏目页标题下显示「正在加载默认点播源…20–60 秒」；失败显示原因，不弹窗、不挡内置片库。

### 4. 输入框默认不显示已填地址

用户明确要求：接口地址输入框不要预填当前地址。

* `_input` 构造时不带初始值（`TextEditingController()`），`_load()` 里再显式 `_input.clear()`，
  并在注释里写明「不预填已保存的地址」，防止以后有人为省一次输入把 `selectedUrl` 灌进来；
* 标签改为「手动输入接口地址（默认留空，不回填当前地址）」，helper 写「留空即使用默认源」；
* 门禁 `G11–G14` 锁死：不存在 `TextEditingController(text:`、不存在 `_input.text = …` 回填。

### 5. 门禁与产物

`flutter analyze` **0 问题**；全量门禁 **37 步 / 3521 断言全绿**（3495 → 3521：地址 116 + 第三方 144，
新增 B17–B23、G01–G19）。

顺带修了门禁自身的一个抽取缺陷：`verify_vod_source_address.dart` 用 `https?://[^\s]+` 从
《播放接口.txt》抽地址，而原文有两行在地址后直接跟了中文注释（「（119.7 万片量）」），
于是把「（119.7」也当成 URL 的一部分，B08 误报「地址不在候选中」。
已改为 URL 合法字符集 `[A-Za-z0-9\-._~:/?#\[\]@!$&'()*+,;=%]+` —— 修的是抽取规则，断言没有放松。

### 6. 产物（19:45）

| 产物 | 字节 | SHA-256 |
|---|---|---|
| `Shunbo-1.0.5-full.apk` | 44,005,875 | `ba4bba03933aaeda7a6e1a60096cdd0e2ed0800c86dc1dc17f3a069164aad452` |
| `Shunbo-1.0.5-windows-x64-setup.exe` | 25,781,954 | `16722de3dcff69d56cda176edfc7e9409a3c6b03b72713766e35203fcca65648` |
| `Shunbo-1.0.5-windows-x64-portable.zip` | 33,410,357 | `8ba0277940b60d197c7dcf2b283dbc042c8848ed7d28fcacd04422d8ea281f37` |

单包 `badging` = 1.0.5 / code 6 / minSdk 16 / targetSdk 36，24/24 断言；Windows `app.so` 与便携包内
`Shunbo-1.0.5/data/app.so` 逐字节一致（8,094,600 B）。两平台 AOT 均检出 `VodAutoSource` /
`noPlayable` / `_enableWithDefaultSource` / 默认地址串。1.0.4 回退包 `393a5f6d…478433bce4` **未变**。

## §50 1.0.5 第三次修：「只加载了 1 个站点」的两个真因（2026-11-11 19:42）

### 1. 用户看到的现象

设置页显示「1 个站点 / 12 部可播放条目（13 个站点取数失败已跳过）」，
而上一轮实测明明有 9~11 个采集站可达 —— 片源没被全部加载。

### 2. 真因一：网页判定把 JSON 当成网页（我上一轮自己埋的）

复测 20 个采集站，**列表可达只有 1 个**。但同一个地址用 `curl` 取回来是
`{"code":1,"msg":"数据列表","page":1,"pagecount":3692,...}` —— 合法 JSON。

差别在响应头：这些苹果 CMS 站点大量返回
`Content-Type: text/html;charset=utf-8`（老 PHP 站点的默认头），正文却是 JSON。
§48 加的网页判定**先看 Content-Type，命中 `text/html` 就直接判「这是网页」**，
于是 12 个能用的站被一起枪毙。

修法（`isHtmlLikePayload`）：**正文优先，Content-Type 只作兜底**。

| 正文开头 | 判定 |
|---|---|
| `<`（跳过 BOM / 空白） | 网页 ⇒ 拒绝 |
| `{` / `[` | JSON ⇒ 放行，**不管头写什么** |
| 其它 / 空 | 才看 Content-Type |

同时把判定从「读完整个 body 再判」改成「**首块到达就判**」（新增纯函数
`firstSignificantByte`）：277 KB 的说明页不会先撞 256 KB 字节上限，
报的仍然是「这是网页」而不是「超过上限」。

复测：列表可达 **1/20 → 11/20**，与 Python 侧口径一致。

### 3. 真因二：站点上限 14 < 配置里的 20，且串行等待拖到 40 秒

`maxSites` 原为 14，而这份配置有 **20 个 type:1 站点** —— 排在第 15 名之后的
4 个可用站（樱花、无尽、虎牙、量子）从来没被请求过。改成 32（防滥用上限，
实际取配置内站点数）。`kMaxThirdPartyItems` 由 60 提到 **240**，
`itemsPerSite` 由 12 提到 **20**。

串行改**分批并发**（批内 8 个并行、批间串行）：9 个失败站每个都要等满
8 秒直连 + 5 秒代理回退，串行整轮 100 秒以上；并发后 42 秒。

### 4. 顺带救回 3 个「只给播放页」的站

7 个站的 `vod_play_url` 不是媒体地址而是播放页。实测分两类：

| 形态 | 站点 | `<页>/index.m3u8` |
|---|---|---|
| `/play/<id>` | xluuss、jisuzyv、huyall | **200 + `#EXTM3U`** ✅ |
| `/share/<hash>` | ukubf3、dytt-tvs、lzcdn27 | 404 或另一张网页 ❌ |

新增纯函数 `deriveDirectMediaUrl`：只对 `/play/<末段无扩展名>` 派生
`index.m3u8`（保留 query），`/share/` 一律不动。

**派生只是猜地址，所以必须先验一条**：`_deriveForSite` 取该站第一个可派生的
地址真发一次请求，只有返回 `#EXTM3U` 才整站改写；不通过就把整站跳过，
保持「宁可少几部，也不要点开全黑」的原则。

### 5. 结果（19:42 真网，同一地址 `47.96.82.41:5188/config.json`）

| | 修前 | 修后 |
|---|---|---|
| 成功站点 | 1 | **9** |
| 可播放条目 | 12 部 | **180 部** |
| 剧集总数 | 78 | **5726**（全部 m3u8） |
| 耗时 | 38 s | 42 s |

抽样验证（`-r 0-400`）：`vv.jisuzyv.com/play/epYzjKpa/index.m3u8`（派生）、
`play.xluuss.com/play/egJxDXYd/index.m3u8`（派生）、`v.fengbao8.com/.../index.m3u8`、
`tyyszywvod.com/.../index.m3u8` 全部 `200/206 + application/vnd.apple.mpegurl + #EXTM3U`。

剩 11 个站失败且**都是真实失败**：DNS 不存在 3 个（茅台 / 豆瓣 / 索尼拒绝连接）、
TLS 握手失败 2 个（如意 / iKun）、超时 3 个（旺旺 / 暴风 / C K 部分批次）、
反诈页面重定向 1 个（非凡 → `www.js96110.com.cn`，正确拒绝）、真网页 1 个（卧龙）、
`/share/` 播放页 3 个（解析需要执行页面里的播放器逻辑，不做）。

### 6. 门禁

`flutter analyze` 0 问题；全量 **37 步 / 3531 断言全绿**（3521 → 3531）。

新增断言：`C23–C27`（text/html 头 + JSON 正文不误判、BOM、真网页仍拦、
首字节判定）、`D12–D16`（`/play/` 可派生、`/share/` 不派生、已直链不派生、
query 拼在路径后、带扩展名不当作播放页）。`C11` 的常量值 60 → 240（如实跟随）。

### 7. 产物（20:20）

| 产物 | 字节 | SHA-256 |
|---|---|---|
| `Shunbo-1.0.5-full.apk` | 44,022,259 | `0f5a078d8b266648571523bfb64194c65400d91b0b1277c5991c4a78d85c8c1b` |
| `Shunbo-1.0.5-windows-x64-setup.exe` | 25,782,843 | `977476af11d5ad5b5948ed6c1b5eb75aaa1b3fac583059859b9b1e841951f0f6` |
| `Shunbo-1.0.5-windows-x64-portable.zip` | 33,411,209 | `fde66651a544fbfef52d365a3c3bfc2b7f448a075d568158889f4f7a88cf9c83` |

单包 `badging` = 1.0.5 / code 6 / minSdk 16 / targetSdk 36，组装断言 24/24；
两平台 AOT 均检出 `firstSignificantByte` / `deriveDirectMediaUrl` / `_deriveForSite`；
便携包 31 条、`data/app.so` 与分发目录逐字节一致、无坏块。
重打后复跑 legacy-compat 268/268、android-form 91/91。
1.0.4 回退包 `393a5f6d…478433bce4` **未变**。

## §51 1.0.5 第四次修：海报图、外链上限 100、播放页控制、点播缓冲档（2026-11-11 21:10）

### 1. 用户提的五件事

1. 点播卡片**图片全都加载不出来**（截图里全是色块 + 首字）；
2. `maxSites` 要 **100**，并**允许执行外部代码**；
3. 播放界面要能**返回**，还要有**选集 / 暂停 / 快进 / 后退 / 下一集**；
4. 截图红标：**「栏目切换，页面加载很慢」**；
5. 点播**卡顿**，要更流畅。

### 2. 图片：不是「加载失败」，是**从来没发起过请求**

`_PosterBlock` 是纯色块 + 首字，注释还写着「刻意不引网络海报」——1.0.4 时代
内置片库只有 6 部公开测试素材、没有官方海报，这个选择是合理的；但 1.0.5 接入
采集站后，`vod_pic` 一直没被解析，用户看到的就是「图片全都加载不出来」。

修法三层：

| 层 | 改动 |
|---|---|
| 数据 | `VodItem.posterUrl`（默认空串，1.0.4 构造点零改动）；`CmsEntry.pic` / `CmsDetail.poster` |
| 解析 | 列表取 `vod_pic` → 空则 `vod_pic_slide`；详情同样取，列表没给时兜底；契约 JSON 认 `poster`/`pic`/`cover` |
| 地址 | 新增 `resolvePosterUrl`：`//cdn/x.jpg` 补协议、`/upload/x.jpg` 按站点 host 拼绝对地址、中文/空格逐字符百分号编码、非 http(s) 与超长直接丢弃 |
| 渲染 | `Image.network` + `cacheWidth`（按卡片宽度解码，不按原图）+ 淡入 + 失败回落色块并记入 `_dead` 名单（不反复重试） |

**实测（21:00，默认源）**：180 部条目 **180 部带海报**（100%）。9 个海报主机里
**5 个可下载**（`www.imgzy360.com` / `img.jisuimage.com` / `xl.xltupian.com` /
`www.mdzypic.com` / `image.huyajs.com` 返回 `200 + image/webp|jpeg`），
4 个（`p.bfvp26.com` / `tyyswimg2.com` / `ok.zuidapic.com` / `pic.youkupic.com`）
**握手阶段被掐断**：`openssl s_client` 显示 `write:errno=113 (EHOSTUNREACH)`、
`read 0 bytes`，http 也一样 —— 是这些图床在本网络不可达，不是 TLS 参数问题。
所以这 4 家的片子仍然是色块（有首字和集数角标，不是空白），能下载的 5 家正常出图。

### 3. 站点上限 100 + 「允许执行外部代码」

* `kMaxThirdPartySites = 100`（原 32），`import` 的默认值直接引用常量；
* `kMaxThirdPartyItems` 240 → **360**，`itemsPerSite` 保持 **20**（12 会让同一配置
  少掉三成条目，实测 108 vs 180）；
* 每批并发 10（原 8），整轮加 **100 秒预算**：超预算收工，已拿到的条目照常入库。

「允许执行外部代码」的**精确语义**（设置页原话）：

> 打开后：type:3 / csp_ 站点里 api 是 http(s) 地址的，会用同一条纯数据协议去取列表与详情
> （默认打开，站点上限 100）。说明：本机不运行 jar / 脚本 —— 客户端没有 JVM 也没有
> JS 引擎；api 写成 csp_xxx 的站点仍会跳过并计数。

也就是说：**放行的是「被标成插件型、但自带 HTTP 采集地址」的站点**（这类占插件站的
绝大多数，也是「片源没全部加载」的缺口），而不是真的在本机跑外部代码。
`scanVodConfigText(allowExternalCode:)` → `VodConfigScan.externalCodeSites` 单独计数，
`isKnownUnusableSource` 也不再一票否决插件型候选（原来点都点不动）。

默认源 `47.96.82.41:5188/config.json` 里是 **20 个 type:1 + 1 个 csp_**、**0 个
type:3+url**，所以这个开关对它的结果没有影响（实测开 / 关都是 9 站 180 部）；
对 `:20271/pps.bmp`（14 采集 + 136 插件）、`:55316/9981`（117 个 type:3）才可能显效。

### 4. 播放页：返回 + 常用控制

原来播放态只有一个「暂停」和一个「返回详情」的图标，进度条不可拖，没有选集、
没有快进快退、没有上下集，而且**系统返回键会直接退到桌面**（页内切换没有路由可弹）。

现在（`lib/ui/vod/vod_page.dart` + `lib/features/vod/vod_playback_controls.dart`）：

| 能力 | 实现 |
|---|---|
| 返回 | `PopScope(canPop: _view == browse)` → 播放 → 详情 → 栏目**逐级**退；顶栏左上角同功能按钮 |
| 选集 | 右侧抽屉，列全部剧集，当前集高亮 + 自动聚焦，点一下即播；顶栏与底栏各有入口 |
| 暂停/播放 | 中间大按钮 + 空格 / OK |
| 快进/快退 | ±10 秒，`vodSeekTarget` 夹在 `[0, 时长]`（负值会让内核回到片头，越过片尾会误触发连播） |
| 上下集 | 按**有序集号表**取相邻项（采集站跳号 1,2,3,5,8 也能接上）；到头置灰并提示 |
| 进度条 | 可拖动，拖动中钉住控制条，`onChangeEnd` 才真 seek |
| 自动隐藏 | 4 秒无操作收起，点画面切换显隐 —— 原来是常驻挡住画面 |
| 按键 | ←→ 快退快进、↑↓ 音量、Esc/返回 退出、媒体键上下曲；**确认键优先让给焦点控件**（`node.hasPrimaryFocus`），否则「焦点在『下一集』上按 OK」会变成暂停 |

### 5. 「栏目切换很慢」：三条真因

1. **每秒 `setState` 整页重建**：进度读数是 `Timer.periodic` + `setState`，
   播放中每秒把栏目页（含网格）重建一次 → 改成 `ValueNotifier`，只重绘进度条；
2. **每次 build 都重算分栏**：`inSection` 原先是 `[...内置, ...外部].where()`，
   360 部时每秒几十次 O(n) 分配 → `VodLibrary` 加**分栏缓存 + revision**，
   同一栏连续取返回**同一实例**；
3. **主 isolate 被 JSON 解析占住**：一次导入要解析上百个 `ac=list`/`ac=detail`，
   单个详情响应常有 100–400 KB，全部在主线程 `jsonDecode` → 新增
   `parseCmsListAsync` / `parseCmsDetailsAsync`，**>48 KB 的响应走 `Isolate.run`**；
   同时改为**分批入库**（每批 10 站跑完就 install 一次），用户边加载边看到新卡片。

### 6. 卡顿：点播专用 mpv 缓冲档

1.0.4 只调了一套**直播**参数（`cache-secs=6` / `demuxer-readahead-secs=4`）并让点播
共用。直播要「尽快出画面」，缓存越小越好；点播要「播得稳」，缓存越大越抗抖动 ——
两者诉求相反，共用一套就是「弱源上能播但一直卡」。

新增接口 `PlaybackTuner`（`applyVodProfile` / `applyLiveProfile`），
`MediaKitPlayerController` 实现两档：

| 参数 | 直播档（原值，未改） | 点播档（新增） |
|---|---|---|
| `cache-secs` | 6 | **30** |
| `demuxer-readahead-secs` | 4 | **15** |
| `cache-pause` | no | **yes**（起播先攒 2 秒，避免「出画面→立刻卡住」） |
| `demuxer-lavf-o` | 清空 | **reconnect=1, reconnect_streamed=1, reconnect_delay_max=5**（源站掐长连接不再当成 EOF） |

调用时序：`_play()` 在 `startPlayback` **之前**切点播档（`cache-secs` 只对当前
打开的流生效），返回详情 / 切走栏目时切回直播档（否则切台会多等 4–5 秒）。

边界要说清：**Android 走 ExoPlayer 平台通道，没有这条 mpv 参数链路**
（原生只认 `http-header-fields`），所以这一项只对 Windows 桌面版生效；
Android 侧维持 media3 的默认 LoadControl，不改原生代码、不冒新增崩溃的风险。

### 7. 门禁与实测

`flutter analyze` **0 问题**；全量 **38 步 / 3621 断言全绿**（新增第 38 步
`vod-playback`，89 条）。

新增断言（`tooling/verify_vod_playback.dart`）：
`A01–A26` 播放控制纯逻辑（夹取 / 相邻集 / 时钟 / 按键映射）、
`B01–B17` 海报（相对路径 / 编码 / 非法拒绝 / 列表与详情都带 / 页面真的 Image.network）、
`C01–C17` 站点上限 100 与外部代码开关（含「csp_ 仍跳过」「type:1 不受影响」「旧配置缺键默认开」）、
`D01–D07` **40 个站点**的配置里第 35 个也被请求（证明不再按 32 截断）、分批进度回调、
预算生效、
`E01–E22` 播放页护栏（PopScope / 返回 / 选集 / 暂停 / ±10 秒 / 上下集 / 可拖进度条 /
自动隐藏 / 按键）、内核两档参数、分栏缓存同一实例。

真网复测（21:00，`47.96.82.41:5188/config.json`）：
**9 站 / 180 部 / 180 部带海报 / 46 秒**（上一版 9 站 180 部、无海报）。

### 8. 产物（21:12）

| 产物 | 字节 | SHA-256 |
|---|---|---|
| `Shunbo-1.0.5-full.apk` | 44,284,403 | `7c79ffb51c29edb4891df82d74e2d0cb442e2cd545b90e3332934b76752299e8` |
| `Shunbo-1.0.5-windows-x64-setup.exe` | 25,820,536 | `1820c50079d4aafb190e1f80e6b97e302ab387bda862d527fe3dd5759bb01daa` |
| `Shunbo-1.0.5-windows-x64-portable.zip` | 33,616,075 | `20877c5d5f080672f03f7397fcc676e90c714101c4622d3982d0254d120a9b21` |

单包 `badging` = 1.0.5 / code 6 / minSdk 16 / targetSdk 36，组装断言 **24/24**；
`lib/arm64-v8a/libapp.so` 与 `data/app.so` 均检出本轮新增字符串
（`允许执行外部代码` / `选集（` / `本剧共` / `已经是最后一集了`），证明二进制确实含本轮代码；
便携包 39 条目、`testzip` 无坏块。上一版三包已备份到 `dist/_prev/*20261111-2050*`。
1.0.4 回退包 `393a5f6d…478433bce4` **未变**。

**未做**：GUI 逐屏走查、真机起播、180 部逐条播放验证；源码未提交、未推送、未建 tag。

## §52 1.0.5 第五次修：直播串台、百万片量只取到 180、点播页加载慢（2026-11-11 22:10）

### 1. 用户报的三件事

1. 从**直播切到电视剧**，直播画面被带进点播页继续放；
2. 默认源 `47.96.82.41:5188/config.json` 号称 **1,197,091 部**，实际只拿到 **180 部**；
3. 打开顺播切到点播页，**要等很久**才显示内容。

### 2. 直播串台：不是「没暂停」，是**渲染面没被摘掉**

先排除误判：`LivePage.didUpdateWidget` 在失活时确实调了 `controller.stop()`，
`VodPage` 失活时也调了 `_pauseForLeave()`。声音是停的。

真正的原因在渲染层。三个点播页 + 直播页全在一个 `IndexedStack` 里保活（这是刻意的：
直播页一旦重建就会重新调台）。但视频面不是普通 Flutter 组件：

| 平台 | 渲染面 | 「不绘制」够不够 |
|---|---|---|
| Android | `PlatformView` + `TextureView` | **不够**。原生视图在混合合成下不跟随 Flutter 的可见性，停播后仍留最后一帧 |
| Windows | media_kit 纹理 | 纹理不会被绘制，但内核停播后仍保留末帧，一旦哪一页停在 `playing` 就会画出来 |

再加上一处状态漏洞：点播页失活时只调 `_pauseForLeave()`，`_view` 仍然停在 `playing`，
`PlayerStage` 还在树上。于是「切到电视剧」时，电视剧页若能命中播放态，画的就是
**同一个内核实例里最后那一路直播**。

三处修：

1. `PlayerStage` 新增 `attachSurface`（默认 `true`）。为 `false` 时**不构建渲染面**，
   挂一块纯黑（不是「演示内核」提示，避免误报）。这是唯一对两个平台都成立的隔离手段。
2. `LivePage` 传 `attachSurface: widget.active`，`VodPage` 同样。
3. `VodPage` 失活时走 `_leavePlaying()`：停播 + **退回详情**（`_view` 不再停在 `playing`）。
   注意 `didUpdateWidget` 里**不能** `setState`（build 期间 `markNeedsBuild` 会抛断言），
   所以改成 `_leavePlaying(rebuild: false)`：只改字段，让紧随其后的那次重建生效。
4. 起播前补一手 `await services.live.stop()`：直播若还在 tune / 看门狗里，
   会在点播 `load` 之后把上游地址打回来，表现为「点了电影，放出来是电视台」。

### 3. 180 部 vs 119.7 万：**从来没请求过第 2 页**

实测接口响应（2026-11-11 21:40，默认源 20 个 type:1 采集站）：

| 站点 | `?ac=list&pg=1` 自报 |
|---|---|
| 电影天堂 dyttzy | `"pagecount":4255,"total":85082` |
| 暴风资源 bfzy | `"pagecount":8573,"total":171459` |
| 如意 tyyszy | `"pagecount":3692,"total":73836` |

旧实现只发一次 `?ac=list`（等价 `pg=1`），每站取 20 部、取 9 个可达站 → **180 部**，
并且把 `pagecount` / `total` 这两个字段整体丢掉（`parseCmsList` 只读 `list`）。
所以缺的不是「取数失败」，而是**分页从来没走过**。

修法四层：

1. **分页元信息**：新增 `CmsListing` / `parseCmsListing`，读 `page` / `pagecount` /
   `total` / `limit`（兼容数字与字符串两种写法）。
2. **分页游标**：新增 `VodSourcePager`。每个站一个游标，轮转取「下一个未翻完的站的一页」，
   所以连点「加载更多」会把各站的第 1、2、3… 页均匀铺开，而不是先把一家翻到底。
   * 翻页无效（站不认 `pg`、每页都回同一批）→ 用首条 `vod_id` 识别，立即判到底；
   * 连接超时 / DNS 失败**一次即判死**（这类站占一半，每次都要白等一个超时窗口）；
     HTTP 5xx / 脏数据给两次机会；
   * 跨站去重（`标题|年份`）：这几个站互为镜像，首屏 9 个站有 6 成是同一批新片，
     不去重就是同一张海报刷满整面墙。
3. **合并接口**：分页优先走 `?ac=detail&pg=N` —— 苹果 CMS 这个接口一次返回 20 部
   **含 `vod_play_url`** 的完整数据。实测同样 20 部：`list + 分批 detail` 要 **6 个请求、
   3–8 秒**，`detail&pg` 只要 **1 个请求、1.3–3.6 秒**。站点不支持时自动回退老路径。
4. **多播放源取值**：`vod_play_url` 里的 `$$$` 是**多个播放源**，原来只取第一个。
   实测电影天堂第一个源全是 `/share/<hash>` 网页，第二个源才是干净 m3u8 ——
   这就是它整站被判「播放地址均为 HTML 跳转页」的原因。现在**逐源打分取直链最多的那个**。

界面同时给出「已加载 M 部 / 接口统计 N 部」和「加载更多」按钮，滚到底也会自动翻页。
百万级条目不可能、也不需要一次性装进电视内存：`kMaxThirdPartyItems = 20000`
是**进程内安全天花板**，不是业务上限。

**实测（22:00，默认源）**：16 批 / 75 秒拿到 **601 部去重后的可播条目**，
接口统计从 85,082 一路读到 **1,322,947 部**；每批 1.7–6 秒、新增 30–60 部。

### 4. 点播页加载慢：每次冷启动都在**重跑一遍网络**

旧实现没有任何缓存：每次启动 → 拉配置 → 探测 20 个站 → 每站列表 + 详情，
最短 30 秒、长的 100 秒。用户看到的就是「打开顺播、切到点播页，等很久」。

四条修：

1. **本地缓存**（`VodLibraryStore` → `vod-library.json`）：外部条目 + `sourceId` +
   `sourceName` + **`headers`**（不带 Referer，恢复出来的条目一播就 403）。
   每批入库后节流落盘（4 秒一次），最多 2500 条。冷启动读回：
   **实测 136 条 297 KB → 读盘 38 ms、恢复 4 ms**，内容立刻可见。
2. **缓存新鲜就不发请求**：`VodLibrary.cacheFresh()` 默认 12 小时。
   新鲜 ⇒ 栏目秒开、后台不动；过期 ⇒ 先用缓存铺满，再后台刷新（不闪空）。
3. **超时收敛**：直连 8s → 6s；**超时不再回退代理**（真死的站等两轮纯属浪费），
   每个死站从 13 秒压到 6 秒。
4. **检索缓存**：`filterVodItems` 按 `(revision, query, 源列表实例)` 缓存 ——
   几千条时每次 build 全量过滤，是切栏目卡的隐形来源。

### 5. 门禁

`flutter analyze` 0 问题；全量 **38 步 / 3653 断言全绿**（本轮新增 P01–P15 分页、
C01–C08 缓存、I01–I06 隔离、S01–S03 会话，共 32 条；断言随夹具调整如实改写，未放宽）。

关键新增：
`P04` 读得出 `pagecount/total`、`P10` 第二批真的带 `pg=2`、`P13` 跨站同名去重、
`P14` 不认 pg 的站不空转、`P15` 超时一次判死、`C01–C03` 缓存往返保留 Referer 与海报、
`C05/C06` 12 小时新鲜度、`I01–I06` 渲染面摘除 / 退播放态 / 起播前停直播。

### 6. 产物（2026-11-11 22:20 重打）

| 产物 | 大小 | SHA-256 |
|---|---|---|
| `dist/Shunbo-1.0.5-full.apk`（单包） | 44,382,707 B | `5cf8a0bb…231196f0` |
| `dist/Shunbo-1.0.5-windows-x64-setup.exe` | 25,832,330 B | `db55fc4f…78efe266` |
| `dist/Shunbo-1.0.5-windows-x64-portable.zip` | 33,477,085 B | `9fe6745a…a3e0bb30` |
| `dist/Shunbo-Legacy-1.0.4-armv7a.apk`（独立包，**未变**） | 3,544,604 B | `f94f70a8…9561dee4` |

单包 `versionCode=6` / `versionName=1.0.5` / `minSdk=16` / `targetSdk=36`，
组装 **24/24** 断言通过、v1+v2 双签、`assets/channels.json` 与源文件字节一致
（1046 台 / 2135 线路）。

**legacy 独立包重跑后 sha256 与 1.0.4 逐字节相同** —— 这不是巧合，而是本轮改动
100% 落在 Flutter 侧（`git status` 里 `legacy/` 一个文件都没动）的直接证据；
单包内嵌的是同一份 legacy 类，所以「老电视走独立包」与「新设备走单包」不会走岔。
独立包的 `versionName` 因此仍写 1.0.4 / code 5，**刻意不跟着改**：二进制没变，
改版本号只会让「同一份文件两个名字」多出一层混淆。

Windows 侧：`Shunbo-1.0.5/` 目录 31 个文件与 1.0.4 清单**逐条一致**
（12 个 Flutter 产物 + 10 个 VC++ 运行库 DLL + `data/` 下 9 个）；
安装包 28.8 秒编译完成，便携 zip 内部根目录为 `Shunbo-1.0.5/`。

上一版三包已归档：`dist/_prev/*20261111-2110|2112*`。

### 7. 仍未做（不许写成已验证）

- **GUI 逐屏走查 / 真机起播**：本轮三个修复里，串台与分页只有静态确证 + 门禁断言，
  没在 Letv S50 Air 上看过「直播→点播」的实际画面切换；
- 601 部条目**没有逐条播放验证**，只验了「拿到 + 去重 + 有直链」；
- Windows 安装包只做了编译，**没跑安装/启动**（1.0.4 那次跑过静默安装卸载，1.0.5 未跑）。

## §53 1.0.5 第六次修：左栏底色改成与右栏一致的透明（2026-11-11 22:30）

### 1. 用户报的现象

截图（406×1670，DPR 2）里左栏是一整块实心深色板，右栏直接是画面本身，
两侧底色不一致；要求**左栏也透明**，且**布局与内容不变**。

### 2. 先取证，不猜

没有 PIL 也没有 ImageMagick，手写了一个 PNG 解码探针（zlib + 逐行反滤波）
直接采样像素，结论是干净的：

| 采样位置 | 色值 | 含义 |
|---|---|---|
| 左栏内部 x = 3…370（逻辑 0…185） | `#121821` 全区一致 | **正好等于 `AppTheme.surface`**，是绘制出来的实心底色，不是画面 |
| 分界处 x = 372 → 376 | `#121821` → `#5b3b32` | 一刀切，**中间没有渐变、没有半透明遮罩** |
| 右栏 x = 376…404 | `#5b3b32` / `#553129` / `#aeb4c3` | 画面像素本身，说明右栏压根没画底色 |

也就是说：问题不是「遮罩太厚」，而是左栏真的刷了一层 `surface`。

### 3. 命中的是哪一个侧栏

代码里有两套左栏，都是 `color: AppTheme.surface`：

| | 宽度 | 特征 | 是否命中截图 |
|---|---|---|---|
| `_buildTvRail()`（电视常驻轨） | 140 | 只有「顺播」两字，无副标、无收起箭头 | ✗ |
| `_SideBar`（宽屏浮层侧栏） | 184 | 「顺播」+ 小字 `shunbo` + 收起箭头 `<` | ✓ |

截图里 `shunbo` 副标与 `<` 都在 ⇒ 是 `_SideBar`。

### 4. 修法：一个共用常量，两处引

```dart
/// 左侧导航栏的底色：**不绘制**，与右侧内容区保持一致。
const Color _railBackground = Colors.transparent;
```

`_buildTvRail()` 与 `_SideBar` 的 `Container` 都改成 `color: _railBackground`。
**宽度（140 / 184）、内边距、导航项顺序、品牌区、设置入口一个字没动** ——
用户要求「保留现有布局与内容」是硬约束，这次只换了一层底色。

之所以抽常量而不是两处各写 `Colors.transparent`：这两处历史上就是「各写一份
`color:`」，日后只要有人改回其中一处，两侧就又开始不一致。

### 5. 取舍（明说，不藏着）

透明之后导航文字直接压在画面上，**亮场景（雪景、白底海报）的对比度会下降**。
当前项仍保留 `surfaceHigh` 高亮块 + 蓝色左条，所以「我现在在哪一栏」依然可辨。

如果实际看着发飘，一条常量就能切换成同色系半透明遮罩（例如 `Colors.black45`），
但那就不再是用户要的「透明」——所以先按字面做，等真机观感反馈再决定。

### 6. 门禁

`flutter analyze` 0 问题；全量 **38 步 / 3660 断言全绿**。
新增 E 段 7 条（`verify_mobile_layout.dart`）：常量存在且为透明、两个 rail 都用它、
两处都不再出现实心底色、宽度未变、导航项仍来自 `AppSection` 且顺序未变、
品牌区与设置入口仍在。**同时锁「变透明」和「布局没动」** ——
只锁透明，宽度被改也照样绿；只锁宽度，底色又会悄悄退回去。

### 7. 产物（同版重打，22:30）

| 产物 | 大小 | SHA-256 |
|---|---|---|
| `dist/Shunbo-1.0.5-full.apk` | 44,382,707 B | `4b686211…10990eb5` |
| `dist/Shunbo-1.0.5-windows-x64-setup.exe` | 25,832,377 B | `1d84cee3…5642839e` |
| `dist/Shunbo-1.0.5-windows-x64-portable.zip` | 33,477,083 B | `e130e832…080b2879` |

单包 `1.0.5 / code 6`、组装 24/24；`libapp.so` 与上一版**同尺寸（7,144,328 B）
但哈希不同**（`73ac65c0…` → `c90a1be2…`），正是「只改了一个颜色常量」的典型指纹。
legacy 独立包未重打：本轮只动 Flutter 侧，`legacy/` 零改动。
上一版三包归档在 `dist/_prev/*2210|2223*`。**§52.6 的哈希已被本节取代。**

## §54 1.0.5 第七次修：左栏改成「和右栏同一档」的 78% 半透明（2026-11-11 22:45）

### 1. 反馈

§53 把左栏改成纯透明（`Colors.transparent`）后，用户反馈**透明度太高、看不清**，
要求「参考右栏的背景及透明度」。

### 2. 右栏到底是什么值

不是猜的，代码里只有一档：`lib/ui/live/live_page.dart` 的频道栏容器

```dart
color: opaque ? AppTheme.surface : AppTheme.surface.withValues(alpha: 0.78),
```

即**常驻双栏态全不透明**（占宽、当实区用），**浮层态 `surface` @ 78%**
（22% 透出背后还在播的画面）。全工程唯一的半透明面板就是这个 0.78。

### 3. 修法：把 0.78 收成一个出口，两侧都引

`AppTheme` 新增：

```dart
static Color get panelScrim => surface.withValues(alpha: 0.78);
```

- 右栏：`opaque ? AppTheme.surface : AppTheme.panelScrim`
- 左栏：`final Color _railBackground = AppTheme.panelScrim;`（两处 rail 共用）

**为什么是 `final` 不是 `const`**：`panelScrim` 由 `surface.withValues()` 算出来，
写死成 `Color(0xC7121821)` 虽然能 const，但**改主题底色时会悄悄失同步** ——
宁可每次启动多算一次颜色，也不要留一个需要人工同步的魔数。

### 4. 为什么 78% 就够用（算过，不是感觉）

`surface #121821` 以 78% 压在各档画面上，合成后底色与对比度：

| 背后画面 | 合成底色 | 次要文字 `#9AA7B8` | 主要文字 `#EDF1F7` |
|---|---|---|---|
| 纯黑（片头/黑场） | `#0E131A` | 7.63:1 | 16.44:1 |
| 典型亮场景 | `#3A3A3B` | 4.65:1 | 10.02:1 |
| 纯白（雪景） | `#464B52` | 3.60:1 | 7.76:1 |

对照 §53 的纯透明：白画面下底色就是 `#FFFFFF`，次要文字只有约 **2.3:1**，
这就是「看不清」的量化解释。78% 把最坏情况抬到 3.60:1、常态 4.65:1（过 WCAG AA）。

### 5. 门禁

`flutter analyze` 0 问题；全量 **38 步 / 3664 断言全绿**。
E 段从 7 条扩到 11 条，改写成「锁同一个出口」而不是「锁透明」：

- `panelScrim` 只在 `theme.dart` 定义一次；
- 左栏 `_railBackground = AppTheme.panelScrim`、右栏 `opaque ? surface : panelScrim`；
- **别处不许再写死 `withValues(alpha: 0.78)`**（除 theme 外，两文件里搜不到）；
- 两处 rail 仍不画实心底色、宽度仍 140/184；
- **反向回归：`_railBackground` 不许再等于 `Colors.transparent`** ——
  纯透明是已经被用户否掉的方案，不能靠「改回去」蒙混。

### 6. 产物（同版重打，22:45）

| 产物 | 大小 | SHA-256 |
|---|---|---|
| `dist/Shunbo-1.0.5-full.apk` | 44,382,707 B | `2f30b7de…34a553c0` |
| `dist/Shunbo-1.0.5-windows-x64-setup.exe` | 25,832,919 B | `9b929ae0…da6de016` |
| `dist/Shunbo-1.0.5-windows-x64-portable.zip` | 33,477,369 B | `bf3ae6d3…ac731150` |

legacy 独立包未重打（`legacy/` 零改动）。**§53.7 的哈希已被本节取代**，
§52.6 同样作废。上一版三包归档在 `dist/_prev/`。

## §55 1.0.5 第八次修：点播顶部按设计稿重排 + 起播慢与播放卡（2026-11-11 23:00）

### 一、顶部布局

#### 1. 用户报的现象

截图是 814×74 的一条窄带，四样东西挤在一起：标题「电影 141 部 · 内置 + 第三方接口」、
一行接入说明、一个「加载更多」按钮、一个 320 宽的搜索框。没有层级、没有分类轴、
没有筛选，看着像调试面板而不是内容页。
要求「整体结构与样式参考设计稿，检索区域按设计稿的检索样式对齐」。

#### 2. 设计稿给的是三层结构

爱奇艺那一屏拆开是：

| 层 | 内容 | 视觉 |
|---|---|---|
| ① 一级轴 | 全部 / 电视剧 / 短剧 / 电影 / 综艺 / 动漫 / 少儿 / 漫剧 / 纪录片 / 知识 | 白字，选中项下有**绿色短横线** |
| ② 筛选区 | 类型 / 地区 / 时间 / 资费 / 奖项 / 推荐 | 行首是**深色圆角标签**，右侧是浅灰值词，选中值换主题色 |
| ③ 尾部 | 「展开 ∨」+ 最热 / 最新 / 高分 | 弱化文字 |

#### 3. 六行只做三维：**没有数据就不做**

设计稿有六行筛选，我们真拿得到的字段只有三个：

| 设计稿维度 | 我们的字段 | 能不能做 |
|---|---|---|
| 类型 | `vod_class`（`typeName`） | ✅ |
| 地区 | `vod_area`（`area`） | ✅ |
| 时间 | `vod_year`（`year`） | ✅ |
| 资费 / 奖项 / 推荐 | **无** | ❌ |

资费、奖项、推荐这三行如果按设计稿摆上去，就是一排**点了永远返回空**的死按钮。
用户会以为「这个源没有 VIP 片」，实际是这个维度根本不存在。所以不做，
并且在门禁里反向锁死（`F25`）：`_filterRow(` 的标签集合**必须正好**是
`类型/地区/时间/排序`，多出一个就是造假。

#### 4. 数据层：给 `VodItem` 补三个结构化字段

原来只有 `subtitle` 一行字（`2024 · 内地 · 更新至 40 集`）。**不能拿它反解**：
分隔符与顺序随源站变化（有的源只给年份、有的把「更新至 12 集」放最前），
反解一旦错位，用户看到的现象是「筛了没反应」——这类 bug 极难从截图看出来。

所以 `VodItem` 新增 `typeName` / `area` / `year`，在解析入口 `buildCmsItems` 一次性填好，
UI 只读不算。空串表示源站没给这个维度，**空就不出现在筛选条里**。

#### 5. 新文件 `lib/features/vod/vod_facets.dart`

- `VodFacets.fromItems()`：统计三个维度。
  - **类型拆词**：`喜剧,爱情` / `动作 科幻/悬疑` 都能拆（采集站的 `vod_class` 普遍是多值串）；
  - **长尾丢弃**：出现次数 < 2 的词不进筛选条（否则一排只命中一部的词占满屏幕）；
  - **排序**：类型与地区按命中数降序（同数按字典序，保证两次 build 顺序一致，
    否则光标会跑去别的词上）；时间按**真实时间倒序**而不是命中数 —— 筛时间时人是照时间轴找的。
  - **时间分档**：`>=2020` 用具体年份，更早按 `10年代 / 00年代 / 90年代 / 80年代 / 更早` 归并。
    为什么以 2020 分界：采集站给的老片年份断断续续，逐个列出来会变成几十个只命中一两部的档位。
- `applyVodFilter()`：三个维度是**与**关系，每个维度内部是**或**；排序用稳定排序
  （年份相同保持原顺序，否则卡片顺序每次渲染都乱跳）。
- `VodFilter` 实现 `==` / `hashCode`：它是 `_filteredFor` 的缓存键，
  不实现的话每次 `copyWith` 都是新对象，缓存永远命中不了。
- `VodFacetsCache`：按 `(revision, 源列表实例)` 缓存。几千条扫三遍在低端电视盒上是肉眼可见的掉帧。

#### 6. 顶部重排（`_header`）

```
[电影] [141 部 · 内置 + 第三方接口] ............ [🔍 搜索片名 / 简介 / 分集]
已接入第三方点播源：…（授权提示，保留）
（加载中 / 出错 / 加载更多，三选一）
──────────────────────────────
全部   喜剧   动作   爱情   恐怖  …        ← 选中项：白字 + 22×3 蓝色短横线
类型  [喜剧] [动作] [爱情] …              ← 深色圆角标签 + 值词
地区  [内地] [中国香港] [美国] …
时间  [2026] [2025] [10年代] …
排序  [默认] [最新年份] [片名]
展开 ∨
```

几处有意的取舍：

* **标题行 + 检索框同一行**：搜索不再单独吃掉一整行高度，也让「主标题在左、
  检索在右」与设计稿的分工一致。检索框固定 300 宽而不是撑满 —— 撑满会在深色页面上
  变成一条比标题还抢眼的长条。
* **检索框无边框、深色实底、左放大镜**：设计稿里所有输入面都是无边框的，跟随它。
* **分类 tab 用类型词，不搬「电视剧 / 综艺 / 动漫」**：本页已经在「电影」栏目内
  （栏目切换在左侧导航），再摆一排跨栏目的 tab 会点进不存在的页面。
  类型词是这个栏目里真实存在的一级维度，结构与设计稿一致，语义也站得住。
* **不搬爱奇艺绿**：本项目 accent 是蓝色（`#4C8DFF`）。搬绿色会让整个应用出现两套主色，
  所以「白字 + 短下划线」「深色圆角标签 + 彩色值词」这套结构照搬，颜色用本项目的。
* **「展开」只展开长尾词**：折叠时类型 18 个、地区 12 个，展开时全量。
  电视屏幕高度有限，默认全量会把卡片区挤下去。

#### 7. 检索与筛选是两套独立条件，叠加生效

`filterVodItems(applyVodFilter(all, _filter), _query)`：
先按类型/地区/时间过滤，再走关键词。缓存键里加了 `_filter`，
所以改筛选项会真正重算（`G11` 断言锁的正是这一行，没有退回「只认关键词」）。

### 二、进入视频加载很慢、播放中卡

按**影响大小**排，一共五处，都能从代码里指出来：

#### 1. `live.stop()` 排在 tune 后面等（最主要的一处「纯等待」）

`VodPage._play()` 起播前先 `await live.stop()`（防串台）。而
`LiveController.stop()` 拆成两半：

```dart
Future<void> stop() async {
  _epoch++; _stopWatchdog(); _phase = idle; _notify();   // ← 同步，立刻完成
  await _gate.run(_safePause);                            // ← 排队，等前面的 tune
}
```

`_gate` 是 `AsyncSerialGate`（严格串行）。直播正在 `_tuneLocked` 里跑网络请求时，
这个 `pause` 要**排在 tune 完成之后**才执行。弱源一次 tune 实测 8–12 秒，
于是「从直播切过来点一部电影」会先干等十几秒才轮到 `load`。

修法：`.timeout(const Duration(milliseconds: 900))`，超时继续。
安全性来自上面那半段 —— 串台真正依赖的是「同步部分已执行」+「点播 load 覆盖内核」
+「失活页不建渲染面」，不是 `pause` 有没有完成。

#### 2. 点播档预读 15 秒，起播阶段和首帧抢带宽

`demuxer-readahead-secs: 15` 让 demuxer 线程一起手就去抢 15 秒的数据，
而首帧解码要用同一条连接。弱源上两者抢带宽，首帧反而更晚出现。
改成 **6 秒**。

**抗抖能力一点没减**：抗抖靠的是 `cache-secs: 30` + `demuxer-max-bytes`（24 MB），
不是起手预读量 —— 这两项一个字没动。

#### 3. `cache-pause-wait: 2` → 1

起播要攒够 2 秒才开画。攒 1 秒就够挡住起播抖动，多等的 1 秒纯粹是延迟。

#### 4. 5 次 `setProperty` 串行 IPC + 每次起播都重设

`_applyMpvOptions` 原来是 for 循环逐个 `await`。每个 `setProperty` 都是一次
Dart→native 来回（Windows 走 FFI、Android 走 JNI），5 个就是 5 个来回，
而且这 5 个属性**互相没有顺序依赖**。改成 `Future.wait` 并发，失败仍然逐项隔离。

同时 `applyVodProfile()` 加幂等（`if (_vodProfile) return;`）：连播下一集、切集都会走它，
而 mpv 的 `cache-secs` / `demuxer-readahead-secs` 是播放器级全局属性，`open` 不会重置回默认。

#### 5. 播放中卡：`network-timeout` 默认 60 秒

上一条的「卡」有两种，必须分开说：

* **缓存掉到阈值以下 → mpv 主动暂停等数据**（`cache-pause=yes`）。这是**正确行为**，
  关掉只会变成花屏/跳帧。根因是源站带宽不够，参数改不出带宽。
* **连接挂死 → 干等 60 秒才报错**。这期间画面完全冻住，用户感知是「卡死」而不是「断流」。
  加 `network-timeout: 10`，让控制权更早交回上层重连 / 换源。

**如实说明**：`demuxer-lavf-o` 里的 `reconnect=1` 对 HLS 分片**不生效** ——
ffmpeg 的 hls demuxer 内部自建 AVIOContext，不继承 demuxer 级的 lavf 选项。
这条是上一版就有的参数，本轮没有动它（动了也无益，不动也无害）。

#### 6. 黑屏没有反馈：遮罩要盯「首帧」而不是「load 发出」

原来的 loading 只看 `_session == null`，而 `_session` 在 `startPlayback` 返回时就有值了 ——
那只是「load 命令发出去了」。mpv 真正拉到首个分片、解出第一帧还要几秒，
这段窗口里 `attachSurface` 画的是纯黑 ⇒ 用户看到的就是截图 3 那种「点了播放，全黑」。

改成盯 `PictureProbe.hasPicture`（与首帧同源，直播侧早就靠它判起播），
出画才撤遮罩；15 秒兜底（源端彻底不给画面时也要撤，一直转圈比黑屏更像卡死）。
详情页的播放按钮同步把图标换成转圈、文案变「正在打开…」，按钮变灰不再是唯一反馈。

### 三、门禁

`flutter analyze` 0 问题；全量 **38 步 / 3693 断言全绿**（3664 → 3693，+29）。

| 段 | 新增 | 锁什么 |
|---|---|---|
| E13/E14 | 改写 | 点播档 30 秒缓存 + **6** 秒预读、攒 **1** 秒（原锁 15 / 2，随实现如实改，不是放宽） |
| E17 | 1 | `network-timeout: 10` |
| E18 | 1 | 属性并发下发，且不再有「逐个 await」的 for 循环 |
| E19 | 1 | 点播档幂等 |
| I05/I07 | 改写+1 | 起播前停直播**且带 900 ms 超时** |
| F01–F25 | 25 | 拆词 / 时间分档 / 长尾丢弃 / 与关系 / 稳定排序 / 值相等 / 顶部四要素 / **筛选行只许四维** |
| G11 | 改写 | facet 过滤仍是页内纯 Dart（不依赖远端筛选参数），且 facet 有缓存 |

### 四、产物（同版重打，23:00）

| 产物 | 大小 | SHA-256 |
|---|---|---|
| `dist/Shunbo-1.0.5-full.apk` | 44,399,091 B | `8e67e776…cf9cc945` |
| `dist/Shunbo-1.0.5-windows-x64-setup.exe` | 25,840,515 B | `09d5aeeb…5cf17721` |
| `dist/Shunbo-1.0.5-windows-x64-portable.zip` | 33,489,087 B | `c526c7ba…d868d566` |

单包 `1.0.5 / code 6 / minSdk 16 / targetSdk 36`，组装 24/24；两平台 AOT 都检出
`正在打开…` / `收起` 等本轮新文案（APK `libapp.so` 7,144,328 B `d5589f1b…`，
桌面 `app.so` 8,274,824 B `17b057ef…`）。

本轮**产物重打过一次**：初版打完后补了标题行的窄窗口分支（`< 720` 时检索框
落到第二行，否则 300 宽输入框在手机竖屏会横向溢出），所以上面的哈希对应的是
补完之后的代码，不是初版。

legacy 独立包未重打：本轮 `legacy/` 零改动。**§52.6 / §53.7 / §54.6 的哈希已全部被本节取代。**
上一版三包归档在 `dist/_prev/`。

## §56 1.0.5 第九次修：点播播放页底部控制栏重做（2026-11-11 23:30）

### 1. 用户要什么

「参考爱奇艺等主流视频播放软件，设计视频播放界面的底部控制栏」，
控件清单：播放/暂停、进度条（拖动 / 缓冲进度 / 时间提示）、当前时长·总时长、
音量调节、清晰度切换、倍速播放、全屏切换；要求布局美观、间距合理、图标风格统一、
悬停与激活态反馈、进度条与音量悬浮时显示数值预览、兼顾桌面与移动端。

### 2. 改造前是什么样

`_bottomBar` 是一条 `Column`：一行 `位置 + Material Slider + 时长`，下面一个
`Wrap` 塞着 7 个 `IconButton`（上一集 / ±10s / 播放 / 音量开关 / 选集），
再下面一行 10px 的键盘提示。

有五个实际问题：

| 问题 | 后果 |
|---|---|
| 没有缓冲段 | 拖进度条时不知道「拖到那儿会不会立刻卡」，弱源上这个信息比进度本身有用 |
| 没有悬浮预览 | 拖动时只有 Slider 的拇指在动，看不出目标时间 |
| 音量和选集是「开关式」按钮 | 音量只能 0/100 二选一，没有连续调节 |
| `Wrap` 居中 | 宽屏上按钮挤在中间一小坨，与上方进度条两端不对齐 |
| `IconButton` 的悬停高亮根本看不见 | 水波纹画在最近的 Material 上，而 Material 在**视频画面下面**，被画面盖住 |

### 3. 新结构

```
┌──────────────────────────────────────────────────────────────────────┐
│  ▬▬▬▬▬▬▬▬▬▬▬▬●▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬  │  ← 三段轨
│  ⏸  ↺10  ↻10  ⏮  ⏭            12:34 / 45:00   [1080P] [1.0x] 🔊▬▬ ☰ ⛶ │
│  空格/OK 播放暂停 · ←→ 快退快进 10 秒 · ↑↓ 音量 · F 全屏 · Esc 退出播放   │
└──────────────────────────────────────────────────────────────────────┘
```

* **进度轨三段着色**：未缓冲 白 18% / 已缓冲 白 34% / 已播 主题蓝 `#4C8DFF`；
* 悬停时轨道 4px → 6px、滑杆淡入、指针上方浮出时间气泡；拖动时气泡跟着走；
* 左侧播放控制簇，右侧设置簇（时间 → 清晰度 → 倍速 → 音量 → 选集 → 全屏）；
* 所有控件统一 **38×38 命中区 + 9 圆角**，悬停白 12%、激活主题蓝 24%、禁用图标白 26%。

### 4. 逐项设计取舍

#### 4.1 进度条：为什么不用 `Slider`

Material `Slider` 三件事都做不到：画不出「已缓冲未播」的中间段；拇指自带 48×48
命中区与内边距，会把视觉长度吃掉一截，和画面左右边缘对不齐；悬浮气泡没有挂点。
所以自绘 `_TrackBar`（`CustomPaint` 画轨 + `GestureDetector` 收手势），
音量滑块复用同一个组件 —— 两者视觉语言一致，不会出现「进度条细、音量条粗」。

**拖动不 seek、松手才 seek**：`onHorizontalDragStart/Update` 只更新预览，
`onHorizontalDragEnd` 才调 `_seekTo`。弱源上连续 seek 会让画面黑一下。

**缓冲比例做了一次夹取**：`vodBufferedProgress` 保证「缓冲段不短于已播段」。
内核把出队数据从 cache 里扣掉时，`bufferedSeconds` 会短暂小于 `position`，
不夹的话已播蓝条中间会缺一块，看着像渲染坏了。

#### 4.2 悬停预览

气泡宽 64，左右各做一次夹取 —— 指针在最左/最右时若不做夹取，气泡会有一半跑到
控制栏外面被裁掉，露出半截文字。连续 `h:mm:ss` 也放得下。

数字全部用 `FontFeature.tabularFigures()`：等宽数字，否则 `01:11 → 01:12` 这种
进位会让文案左右抖一格，每秒抖一次很显眼。

#### 4.3 音量

* **宽屏（≥900）**：图标（点击静音）+ 悬停展开的 88px 横向滑块。音量不是每次播放
  都要调的东西，常驻 96px 会在右侧挤掉清晰度/倍速的位置。
* **中窄屏**：触屏没有 hover，音量收进内联面板（面板里有滑条 + 静音胶囊 + 百分比）。

**静音记旧值**：半夜把音量调到 15% 静音，取消静音回到 15% 而不是炸一声 100%。

#### 4.4 清晰度：只有一档，而且这不是偷懒

抓了一份真实数据（`http://caiji.dyttzyapi.com/.../?ac=detail&pg=1`）：

```
vod_play_from = 'dytt$$$dyttm3u8'        ← 是线路名，不是画质档
vod_play_url  = '第70集$https://…share/ad6fff…  #第71集$…'  ← 每集只有一个地址
```

采集接口里**根本没有「720P / 1080P」的档位**。摆一排点了永远不生效的清晰度选项，
就是假按钮 —— 与 §55 拒绝做「资费 / 奖项 / 推荐」筛选行是同一条原则。

所以清晰度控件做成两件事：

1. 徽标显示**内核实测解码分辨率**（`1080P`，未出画时显示「自动」）——
   这是真信息，用户能据此判断源站给的到底是什么画质；
2. 面板如实说明「采集源每条线路只提供一档清晰度（接口里没有画质档位），
   所以这里无法切换」。

为此给 `PictureProbe` 补了 `pictureWidth` / `pictureHeight`，`vodResolutionLabel`
按**长边**分档（`1920×800` 这种 letterbox 按高度会算出「800P」这种谁都没见过的档名）。

#### 4.5 倍速

0.5 / 0.75 / 1.0 / 1.25 / 1.5 / 2.0 六档。0.25× 与 4× 不放：前者几乎不出帧，
后者音轨开始丢样本。

内核不支持变速时**不改 UI**（`if (p is! PlaybackRateControl) return;`）——
标签变了却没生效，用户会以为「1.5 倍速听起来一样」是 bug。

#### 4.6 全屏

全屏状态由 `AppShell` 统一持有（和直播页共用同一个 `_fullscreen`），
`VodPage` 新增 `fullscreen` + `onToggleFullscreen` 两个参数。

为什么不在页内自己存一份：全屏要隐藏左侧导航与底部导航，那是外壳的结构；
两页各存一份还会出现「直播退出了全屏、点播还以为在全屏」。

`_back()` 改成**先退全屏再退播放**（与主流播放器一致，也与外壳
`canPop: !_fullscreen` 的语义对齐，否则外壳会先吃掉这次返回）。

#### 4.7 快捷键

新增 `F` = 全屏（YouTube / VLC / 爱奇艺的约定键）。`M` 仍是选集，没有被抢。

### 5. 为什么用「内联面板」而不是下拉菜单

这条控制栏同时要给遥控器用。弹出层在电视上有两个硬伤：焦点会跑出播放页
（方向键开始满屏乱跳），以及「按一次 OK 打开、再按一次 OK 才关」的两段式操作。

改成贴在控制条上方的内联面板后，选项本身就是一行胶囊，左右选、OK 确认，
与遥控器操作模型一致；鼠标端也省一次点击（选完自动收起）。

### 6. 响应式：三档密度，不是两档

| 密度 | 触发宽度 | 右侧放什么 | 倒推依据 |
|---|---|---|---|
| full | ≥ 900 | 时间 + 清晰度 + 倍速 + 音量滑条 + 选集 + 全屏 | 左右固定宽度约 640dp（含 `h:mm:ss`），留 260dp 余量 |
| medium | ≥ 560 | 去掉上下集，音量变图标 | 约 505dp |
| compact | < 560 | 时间 + 「更多」+ 全屏（清晰度/倍速/音量全进面板） | 约 304dp，360dp 竖屏放得下 |

两档不行：700–1000dp 这段（平板横屏、电视小窗）会把右侧控件挤成两行。

### 7. 性能：读数不进 `setState`

这是本轮唯一一处「不这么写会明显掉帧」的地方：

* 位置 / 时长 / 已缓冲 / 分辨率 / 音量五个读数全部是 `ValueNotifier`，
  用 `Listenable.merge` 合成一个 `_readout`，只重建**控制栏自己**；
  原来每秒一次 `setState` 会把整个点播页（含几千条卡片网格）重建一次。
* **音量也走 notifier**：拖音量滑块每帧都在变，用 `setState` 等于每帧重建整页。
* **拖动进度条的实时时间显示留在控制栏内部**（`_scrubPreview`），
  页面只收到「开始拖 / 松手」两个事件，不参与逐帧重建。

### 8. 内核能力（三处新增，都是独立接口）

沿用 `PlaybackTuner` / `PictureProbe` 的既定约定 —— **能力不放进主接口**，
否则占位内核只能返回假值：

| 接口 | 方法 | 用途 |
|---|---|---|
| `BufferProbe` | `bufferedSeconds` | 进度条中间那段缓冲轨 |
| `PlaybackRateControl` | `setRate` / `rate` | 倍速 |
| `PictureProbe`（扩展） | `pictureWidth` / `pictureHeight` | 清晰度徽标显示实测分辨率 |

`MediaKitPlayerController` 全部实现；`tooling/verify_official_playback.dart` 里的
`_FakePlayer` 同步补了 `pictureWidth/pictureHeight`（给 `1920×1080`，这样断言能区分
「画了 1080P」和「没画面时显示自动」）。

`bufferedSeconds` 取的是 `state.buffer`（解复用后已入队的位置），
恰好对应「用户能立刻拖到、不必等网络」的那一段。

### 9. 一处顺手修掉的旧问题

旧按钮用的是 `IconButton`，它的水波纹画在最近的 `Material` 上 —— 而这条控制栏浮在
视频画面之上、`Material` 在画面**下面**，所以悬停高亮和点击水波纹**一直是不可见的**。
新控件自己画 `AnimatedContainer` 底色，反馈才真的出现在画面之上。
门禁 `K18` 反向锁死：控制栏里不许再出现 `IconButton(` / `InkWell(`。

### 10. 门禁

`flutter analyze` 0 问题；全量 **38 步 / 3723 断言全绿**（3660 → 3723，+63。
其中点播门禁 150 → 180）。

**改写的 3 条**（随实现如实改，不是放宽）：

| 断言 | 原来锁什么 | 现在锁什么 |
|---|---|---|
| E04 快进/快退 10 秒 | 页面里有 `Icons.replay_10_rounded` | 控制栏出按钮 + 页面出 `onSkip` 回调，两头对齐 |
| E05 上下集 | 页面里有 `Icons.skip_*` | 同上（`onPrevious` / `onNext`） |
| E07 进度条可拖动 | 页面里有 `Slider(` + `onChangeEnd` | 拖动中只预览、松手才 seek，且**不许**再用 `Slider` |

**新增 K01–K30**（`verify_vod_playback.dart` 的 `testControlBar`）：

* 纯函数 13 条：倍速文案（`1.0x` 不是 `1x`）、六档、画质标签（含 letterbox 按长边、
  未出画返回空串）、音量文案夹取、缓冲比例不小于已播、`F` = 全屏且 `M` 不被抢；
* 结构 17 条：三段轨道真的参与绘制、气泡两端夹取、拖动预览/提交分离、
  三态色值、不许用 `IconButton`/`InkWell`、统一 9 圆角与 38 命中区、
  音量悬浮展开、清晰度只有一档、三档密度阈值、拖动不重建整页、
  音量走 notifier、全屏由外壳透传 4 处、返回键先退全屏、
  三个内核能力「声明 → 实现 → 页面按能力探测」链路完整。

### 11. 产物（同版重打，23:30）

| 产物 | 大小 | SHA-256 |
|---|---|---|
| `dist/Shunbo-1.0.5-full.apk` | 44,448,243 B | `7153a972…b1905c4f` |
| `dist/Shunbo-1.0.5-windows-x64-setup.exe` | 25,853,598 B | `f549786b…c7ccdd34` |
| `dist/Shunbo-1.0.5-windows-x64-portable.zip` | 33,508,950 B | `77b0508c…6f5b8d4d` |

单包 `1.0.5 / code 6 / minSdk 16 / targetSdk 36`，组装 24/24；两平台 AOT 都检出
`清晰度` / `播放倍速` / `退出全屏` / `静音` / `清晰度 / 倍速 / 音量`
（APK `libapp.so` 7,144,328 B `9e919dfd…`，桌面 `app.so` 8,323,976 B `9fb4e286…`）。

legacy 独立包未重打：本轮 `legacy/` 零改动。
**§52.6 / §53.7 / §54.6 / §55.四 的哈希已全部被本节取代。** 上一版三包归档在 `dist/_prev/`。

### 12. 没验证的

* **没有拉起 GUI 看实际观感**（规则上不擅自启动 GUI 进程）—— 字号、行距、
  面板在真实 1080p 电视上的比例、以及三档密度切换的实际手感，都只有静态确证 + 门禁；
* 倍速与缓冲轨只有接线与断言，**没在真机上确认 1.5× 时音画是否仍然同步**；
* 全屏只验证了「状态从外壳透传、返回键先退全屏」的代码路径，没有实际进入全屏观察；
* 源码仍未提交、未推送。

## §57 1.0.5 第十次修：短视频栏目 + 接口数据本地内容检索记录（2026-11-12 08:2x）

### 1. 用户要什么（一件 UI、一件数据）

1. 左侧菜单新增「短视频」栏目，把**已获取到的所有短视频点播内容**迁过去，后续新增内容
   也统一归入；原有菜单项与播放功能**不受影响**。
2. 把接口返回的片名 / 类型 / 上映年份 / 地区等基本信息**持久化**为本地内容检索记录，
   支持按字段检索；系统加载时**优先读本地记录**用于栏目展示与检索；参考主流播放软件
   对接口数据的常见处理；记录可随接口更新同步，**避免重复与过期**，并保证
   **栏目内容 / 本地记录 / 检索结果三者一致**。

### 2. 先查真实数据：短视频为什么认不出来

默认源 `config.json` 21 个站点（`wwzy` 短剧站超时）。逐个拉 `?ac=list` 看类目表：

| 站点 | 实测类目 | 说明 |
|---|---|---|
| `dyttzy` | `36 短剧` | 父类直接命中关键词 |
| `bfzy` | `58 短剧大全`，子类 `59 重生民国` / `61 现代言情` / `68 AI漫剧` | 子类 `type_pid=58`，**子类名里一个「短」字都没有** |
| `tyyszy` | `54 短剧` / `73 ai短剧` | 带「剧」字 |

三个真问题：

* 条目只带 `type_name=现代言情`、`type_id=61`，**光看文本完全认不出是短剧**；
* `短剧大全` / `AI短剧` 带「剧」字，旧 `sectionFromName()` 按「剧」归电视剧 ⇒ 会被分错；
* 老缓存里还有 `[电影解说]` 这类片名，既无「短剧」二字也无类目字段。

还有一条容易漏的：`?ac=detail&pg=N` 的响应**不带 `class`**（实测），分页器每页拿不到
类目表 ⇒ 必须额外并行请求一次 `?ac=list` 把类目表探下来。

⇒ 结论：归类必须**类目表父链 + 文本关键词**同时用，且父链优先。

### 3. 归类规则：三层判据 + 一个统一入口

| 层 | 判据 | 落点 |
|---|---|---|
| 1 | `type_name` / 类目父链上的名字命中关键词 | `sectionFromCms()` |
| 2 | `type_id` 沿 `type_pid` 上溯（`CmsCategoryTable.isShortVideo`） | 同上 |
| 3 | 片名 / 副标题 / 类型 / genre 文本、英文枚举 `shortVideo`/`shorts`… | `isShortVideoText()` / `isShortVideoItem()` |

关键词表：`短视频 / 短剧 / 微剧 / 漫剧 / 电影解说 / 预告片 / 片花 / 短片 / 微电影`。

`normalizeVodItem()` 是**所有入库路径的唯一归一入口**：接口新数据、老缓存恢复、
`VodContentRecord.fromJson()` 都过它，所以「后续新增内容统一归入」不是靠约定，是靠单点。

`_ensureCategories()`：每站只探一次（`categoriesProbed`），失败**不调 `_fail()`** ——
拿不到类目表只是归类退化成文本兜底，不该把整页内容判死；`isShortVideo()` 沿父链上溯
用 `seen` 集合防 `type_pid` 自指 / 成环。

### 4. 菜单只能追加在末尾（不是风格，是保活约束）

`AppSection.values` 同时决定左侧导航顺序和 `IndexedStack` 下标；`VodSection` 同理决定
栏目页。插在中间会让原来四个栏目整体错位（点「电视剧」打开纪录片这类）。
所以 `shortVideo('短视频')` / `shortVideos(...)` 都追加在**最后**，原四项一字未动；
`AppShell` 只多挂一个 `VodPage(section: VodSection.shortVideo, ...)`，
起播链路仍是原来的 `orchestrator.startPlayback(...)`。

### 5. 本地记录：只留一份真相，不建第二份索引

* 沿用 `vod-library.json`，**v1 → v2**；不引入 SQLite、不另开索引文件 —— 两份数据必然漂移。
* `VodContentRecord` 存 `title / typeName / genre / year / area` 四字段，外加
  `subtitle / description / license / posterUrl / section / episodes / sourceId / sourceName /
  headers / updatedAt`，即「能恢复成可播 `VodItem` 的全部元数据」。
* `VodContentIndex` 是**唯一真相**：`items` 派生出 `VodItem` 列表 →
  `VodLibrary.restore()` 用于栏目展示；`filterVodItems()` / `search()` 也只查这份派生列表。
  三者同源，**不需要事后「对齐」**。
* 去重 `vodContentKey()` = `片名(去空白·小写) | 年份`；更新 `vodContentFingerprint()`
  （指纹变了才就地替换并同步刷新播放地址表）；过期 `kVodRecordTtl = 30d`；
  `save()` 同 sourceId 增量 upsert、换 sourceId 整库重建；落盘 `.tmp` → delete → rename
  原子替换。`VodLibrary.append()` 同步升级成「追加 + 元数据就地更新 + 同名同年去重」。
* 12h freshness 仍归 `VodLibrary.cacheFresh()`，`kVodRecordRefreshAfter` 只是记录刷新
  语义常量，两者不混用。

### 6. 冷启动优先本地，网络不参与首屏

```
本地记录新鲜 ──> 立即用 records 渲染栏目 / 检索
                └─> 后台 _revalidateInBackground()：autoBatches=1 / budget=12s
                    / preserveExisting=true（单批差量核对，不参与首屏）
不新鲜或无记录 ─> 原 vodAutoSource.ensureLoaded() 全量加载
```

`preserveExisting` 是本轮必需的：后台刷新若沿用旧逻辑「换源就 `clearExternal()`」，
用户眼前几百张卡片会先清空再回来。契约 JSON 路径在 `preserveExisting` 时改用
`VodLibrary.append()`，不再 `install()` 清空重装。

### 7. 检索：字段前缀 + 自由文本，纯本地不发网络

字段前缀 `片名: / 标题: / 类型: / 分类: / 地区: / 年份: / 上映:`，多字段与自由文本
是「与」关系；自由文本命中片名 / 副标题 / 简介 / 类型 / 年份 / 地区 / 分集标题。
**空查询仍返回原列表引用**（1.0.4 语义，G 段门禁锁着）。

### 8. 老缓存迁移预演（真实文件，不是夹具）

`C:\Users\Administrator\AppData\Local\Shunbo\vod-library.json` 原有 **718 条 v1**：

| 项 | 结果 |
|---|---|
| 按 `片名\|年份` 去重后 | **614 条** |
| 栏目分布 | 电影 176 / 电视剧 426 / 纪录片 1 / **短视频 11** |
| 结构化字段回填 | `year` 376 / 614、`area` 376 / 614（从 `YYYY · 地区 · 备注` 如实回填，**不猜类型**） |
| 检索自证 | `年份:2026` → 346；`地区:大陆` → 169；自由文本 `短剧` → 10 |

短视频栏目 11 条而 `短剧` 只命中 10 条 —— 差的那条正是 `[电影解说]`：
片名里没有「短剧」二字、但被关键词标记归类。**不是漏，是规则生效**。
v1 首次读回后当场 `save()` 写回 v2，避免每次启动重解析。

### 9. 门禁

新增 `verify_vod_content_index.dart` **101 条**（A–F 组：v2 落盘 / v1 升级写回 /
增量不丢历史 / 换源重建 / TTL 清理 / 同名去重 / 四字段检索 / 字段前缀 /
栏目-记录-检索一致 / 静态装配护栏），接入 `verify_all.dart` 第 **39** 步。

既有门禁**随实现如实改写、没有放宽**：

| 断言 | 改动原因 |
|---|---|
| P14 / P15 | 新增类目探测会多一次 `?ac=list`，原断言把所有请求都算成翻页；拆成「翻页请求」与「类目探测」两套计数，并加 P14b / P15b 锁「每站只探一次」 |
| K25 | 多一个栏目页 ⇒ 全屏透传从「直播 1 + 点播 3」变为「直播 1 + 点播 4」 |

`flutter analyze` 0 问题；全量 **39 步 / 3826 断言全绿**（3723 → 3826，+103 = 新增 101
+ P14b/P15b 2）。

### 10. 产物（同版重打 1.0.5+6）

> **已被 §58.7 取代。** 下表是 §57 当时的产物；本轮（§58）改完四项后又同版重打了一遍，
> 三个包的大小与哈希都已变化，以 §58.7 为准。

| 产物 | 大小 | SHA-256 |
|---|---|---|
| `dist/Shunbo-1.0.5-full.apk` | 44,612,083 B | `83de6f2a2706b1a3e4de28ab9661dc6987edfedd664102e4a075ef30495a7d17` |
| `dist/Shunbo-1.0.5-windows-x64-setup.exe` | 25,862,854 B | `294e224fe47ea30b2d69371adbbd811e9181c029dea340cb67f52161997e701c` |
| `dist/Shunbo-1.0.5-windows-x64-portable.zip` | 33,680,463 B | `aa5b91c5378782e2d0564f00104fd452f2f87eacf7cfe380921ad113b382f43c` |

单包 `1.0.5 / code 6 / minSdk 16 / targetSdk 36`，组装 **24/24**（v1+v2 双签、
1046 台 / 2135 线路清单字节一致）。双 ABI 的 `libapp.so` 都检出
`VodContentIndex` / `vodContentFingerprint` / `shortVideo` / `parseCmsCategories` /
`preserveExisting` / `vod-library.json`，中文串（Dart 快照为 UTF-16LE）检出
`短视频` / `片名` / `本地检索记录` / `短剧` / `电影解说`。
**§56.11 的哈希已被本节取代**，上一版三包归档在 `dist/_prev/`。
（本节自身也已被 **§58.7** 取代。）

### 11. 没验证的 / 边界

* **没有拉起 GUI** 看短视频栏目实际观感，也没在真机上起播短视频；
* 本地记录与接口的差量同步只做了单批 12s 的静态确证 + 门禁，没有做「接口新增 /
  改名 / 下架」的长时间实测；
* `legacy/` 零改动 ⇒ legacy 独立包未重打；
* 源码**仍未提交、未推送**。

## §58 1.0.5 第十一次修：全屏回退 / 栏目图标 / 电影归属 / 一次加载（2026-11-12 10:1x）

用户一次给了四条，逐条落。前三条是「看起来像 UI 问题、根因在别处」，只有
找到根因才不会下次再犯；第四条是交互范式切换。

### 1. 全屏为什么会让页面「退回上一级」

用户原话是「点击全屏会触发页面回退到上一级」。第一反应是 `Navigator.pop`
被误调，但点播页全屏走的是 `AppShell` 的 `_fullscreen` 状态，**根本没有路由栈**。
真正的原因在 `AppShell.build()`：

```dart
// 旧写法（已删除）
if (_fullscreen) return Scaffold(body: content);
return Scaffold(body: Stack(children: [Positioned.fill(child: content), …rails]));
```

全屏与非全屏是**两棵不同的树**：`content` 的父节点从 `Stack` 变成
`Scaffold.body` 的直接子节点，同一位置上 widget 类型也变了（`Stack` ↔ `IndexedStack`）。
Flutter 的 Element 复用规则是「同位置 + 同类型 + 同 key」，三者只要有一项不满足
就**整棵子树 unmount 重建**。子树重建 = `State` 全部重新 `initState`，
点播页的 `_view`（browse/detail/playing）、`_item`（正在看哪部）、`_query` 全归零。
用户看到的就是「点全屏，页面跳回了列表」——它其实不是"回退"，是**状态被清空后
重新渲染成了初始视图**。

修法是**保持树形稳定**，不是加 `GlobalKey` 硬保 State：

| 分支 | 改法 |
|---|---|
| 宽屏（桌面/TV/平板） | 恒为 `Scaffold(body: Stack([Positioned.fill(content), if (!_fullscreen) rails…]))`；全屏只是让侧栏兄弟节点不渲染，`content` 的位置/父类型/序号完全不变 |
| 窄屏（手机竖屏） | 恒为三槽位 `Scaffold`；全屏只把 `appBar` / `bottomNavigationBar` 传 `null`，**槽位本身保留** |

用 `null` 而不是"另起一棵没有 AppBar 的 Scaffold"是同一个道理：`Scaffold` 的
三个槽位是固定参数，传 `null` 只是让该槽不渲染，父链没变。

退出全屏补齐三条路径（原来只有第一条能正常工作）：

1. 控制条全屏按钮 → `_toggleFullscreen()`；
2. 系统返回键 → `PopScope.onPopInvokedWithResult` 现在除了 `setState` 还调
   `_applyDisplayMode()`（只改状态不收回系统栏的话，Android 会停在
   `immersiveSticky` 且继续锁横屏，退出后竖屏仍被拒绝）；
3. 键盘 `Esc` / `F` → 新增 `_onGlobalKey`，用 `HardwareKeyboard.instance.addHandler`
   挂全局兜底。**只在「直播页 + 已全屏」时接管**，不抢点播页的 `Esc`/`F`
   （点播页自己有一套：`f` = 全屏、`escape` = 关闭播放，见
   `vod_playback_controls.dart` 的 `vodActionFor`）。

### 2. Windows 真全屏：三件事都要做，少一件就只是"窗口变大了"

Dart 侧 `SystemChrome` 在 Windows 上是空实现，所以新建 `lib/platform/window_channel.dart`
（`shunbo/window` 通道）+ `windows/runner/flutter_window.cpp`：

| 要做的事 | 调用 | 不做会怎样 |
|---|---|---|
| 去窗口边框 | `SetWindowLong(GWL_STYLE, (saved & ~WS_OVERLAPPEDWINDOW) \| WS_VISIBLE)` | 标题栏和粗边框还在，只是变大 |
| 铺满显示器 | `MonitorFromWindow` + `GetMonitorInfo(rcMonitor)` + `SetWindowPos(...SWP_FRAMECHANGED)` | 窗口最大只能到"工作区"，底部永远留一条 |
| 让任务栏让位 | `ITaskbarList2::MarkFullscreenWindow(hwnd, TRUE)` | 任务栏压在画面最下面一条上，盖住字幕 |

**刻意没用** `SHAppBarMessage(ABM_SETSTATE, ABS_AUTOHIDE)`：那是改用户的**全局**
任务栏偏好，进程崩溃或被强杀后任务栏会永久停在自动隐藏。`MarkFullscreenWindow`
只影响当前窗口的生命周期，作用域正好是我们想要的。

退出时还原 `GWL_STYLE` + `SetWindowPlacement`（不是 `SetWindowPos` 到某个固定尺寸）：
最大化进的全屏必须还原成**最大化**，只还原尺寸会掉成一个不大不小的窗口。
`SWP_FRAMECHANGED` 必须带，否则非客户区要等下一次 resize 才重新布局，看起来像"卡在全屏"。

`Alt+Enter` 是 Windows 通用全屏键，但会被 `DefWindowProc` 当系统菜单命令吞掉
（`WM_SYSCOMMAND` + `SC_KEYMENU` + `lparam == VK_RETURN`）。捕获后**不直接切窗口**，
而是 `InvokeMethod("toggleFullscreen")` 回 Dart，由 `_toggleFullscreen()` 统一翻转：
否则会出现「窗口已经全屏了，但 Dart 的 `_fullscreen` 还是 false」这种双真相，
下次点按钮会先把窗口"退出全屏"一次。

`DisplayMode.apply` 里桌面分支**排在** `if (!onAndroid) return;` 之前——原来那行
守卫会把桌面端直接短路掉，全屏请求永远发不出去。

### 3. 栏目图标：五个栏目同一份口径

左栏每项都有图标，页内标题却只有光秃秃一行字，短视频栏目最明显。
`vod_page.dart` 新增 `_sectionIcon`，五个 `VodSection` 全部覆盖
（`movie_outlined` / `video_library_outlined` / `public_outlined` /
`smart_display_outlined` / `category_outlined`），尺寸 22、颜色 `textSecondary`，
与标题 22sp/w600 并排 —— 图标不抢标题，但把"这是哪个栏目"从文字里解放出来。
`other` 也给了图标：它不在导航里，但检索结果可能落在它上面，没有图标会在
标题行留一个空洞。

### 4. 电影栏目混进综艺/球赛：根因是「认不出来就 return movies」

不是筛选写错，是**归类规则**写错。老 `sectionFromName()` 的兜底分支是
`return movies`：只要类目词不在已知表里，一律算电影。真实本地记录里电影栏目
470 条中，64 条「大陆综艺」、52 条「足球」、46+46 条日韩/港台综艺、61 条
「现代都市」短剧、9 条「记录片」——全是这么混进来的。

三条改动：

1. **新增 `VodSection.other`**，追加在枚举末尾（前四项的序号就是导航顺序与
   `IndexedStack` 下标，插中间会让已有栏目整体错位）。这类内容有个"不进任何
   内容栏目"的归属，仍留在本地检索记录里、可被检索命中，只是不出现在电影栏目。
2. **`vodSectionFromText()` 返回 `null` 表示证据不足**，不再兜底成电影。
   判据顺序有讲究：先短视频（`短剧大全`/`AI漫剧` 都带「剧」字），再纪录片/剧集，
   再排除综艺体育，最后才认电影。电影用「以『片』结尾」而不是 `contains('片')`——
   `片花`/`预告片` 是短视频，含「片」就判电影会把它们拉回来。
3. **`normalizeVodItem()` 是唯一归一入口**：接口新数据入库前、v1 老缓存恢复时、
   记录读回时都过它。落在电影栏目却拿不出电影类目证据的外部条目迁到 `other`。
   **不读 `genre`**：那是题材标签，真电影也带「纪录片」「喜剧」，拿它判栏目会把
   《止水之询》这种犯罪片整批踢出电影页。也不读副标题里的「正片」——真实数据里
   「2026 · 正片」的 9 条 NBA / 羽毛球赛事正是靠这两个字混进来的。

`isMovieSectionItem()` 是电影栏目的最后一道闸，防的是没走过归一的外部安装路径
（契约 JSON、直接 install）。内置 6 条公开授权素材的 `sourceId` 是
`VodCatalog.sourceId`，一律放行——它们本来就是给「电影栏目非空」兜底的。

### 5. 取消「加载更多」：从"点了才给"改成"打开就有"

主流播放软件的范式是：**打开就有完整目录，后台自己补新的**。改了三处：

| 层 | 改动 |
|---|---|
| 启动 | `main()` 里 `VodLibraryStore.load()` 把 `vod-library.json` 整份读回，几毫秒；栏目页首屏直接渲染本地目录，**不等网络** |
| 后台 | `_revalidateInBackground()` 按 `kVodFullSyncMaxBatches` 批 / `kVodFullSyncBudget` 预算把接口剩余分页**一次跑完**，逐批落盘；`preserveExisting: true` 保证不会先把眼前几百张卡片清空 |
| 列表 | `_moreRow()` 只剩状态告知（"目录同步中：已加载 N 部" / "目录已完整"），**按钮已删除**；滚到底只是「顺手再接一批」（`kAutoLoadExtentAfter = 800`），不点也会接 |

检索侧同步改成**本地优先**：`_filteredFor()` 先调
`vodLibrary.localMatches(q)` 拿到命中 id 集合，再在栏目列表里取交集，
最后才叠 facet + 关键词。这样「本地记录 → 检索结果 → 栏目卡片」是同一份数据，
不会出现"搜到了却点不开"。检索**不发网络**——本地记录是唯一检索源，
否则「优先读本地」就名不副实。

### 6. 门禁（如实改写，未放宽）

| 断言 | 改动原因 |
|---|---|
| `edge-handles`「全屏时左侧浮层整体不渲染」 | 旧断言锁的是 `if (_fullscreen) return Scaffold(body: content);` 这个**回退根因**；改成「浮层不出现 **且** 不再另起一棵树」双条件 |
| `edge-handles`「窄屏底栏导航未受影响」 | 旧断言 `contains('bottomNavigationBar: NavigationBar(')` 在加了 `_fullscreen ? null :` 后必然假失败；改成锁「只置空槽位值、槽位保留」 |
| `mobile-layout`（163 条） | 新增「桌面分支排在 Android 守卫之前」「桌面真的下发到窗口层」「两路互斥」「不另起树」「槽位传 null」「退全屏同步收回系统栏」「全局键盘兜底」 |
| `vod-content-index` F13 | 旧断言锁 `applyVodFilter(all, ...)` 直连全量；改成「本地优先 **且** 顺序不可颠倒」（`localMatches` 在 `filterVodItems` 之前） |
| `vod-source-address` G11 | 同上，改为「本地优先 + 纯 Dart 过滤 + facet 缓存」三件都在 |

`flutter analyze` 0 问题；全量 **39 步 / 3854 断言全绿**（3826 → 3854，+28）。
`flutter build windows --release` **61.7 s** 成功 —— 这一条是本轮唯一的 C++ 编译证据，
`MethodChannel<EncodableValue>` 模板实例化、`ITaskbarList2`（`ole32`）、
`GetMonitorInfo`（`user32`）、`ShellExecute`（`shell32`）全部链接通过。

### 7. 产物（同版重打 1.0.5+6）

三端同版重打，版本常量未动（`1.0.5+6`），旧产物归档在 `dist/_prev/`。

| 产物 | 大小 | SHA-256 |
|---|---|---|
| `dist/Shunbo-1.0.5-full.apk` | 44,612,083 B | `ed0f7cdcb4ad3ff11acebac8b90b8305ed449ba58b54ff70b4bbac1b6c9a66b6` |
| `dist/Shunbo-1.0.5-windows-x64-setup.exe` | 25,873,368 B | `070d72cd1432b530a45860ab8e780d4a18caf62f5932e8d9c7d5205ba20040c7` |
| `dist/Shunbo-1.0.5-windows-x64-portable.zip` | 33,542,328 B | `fb06c9ce58475d16b66e1c45d44f1403cf825a9e266c01be6097c8d7e147f3f8` |

**APK**：单包组装 **24/24**（v1+v2 双签、`1046 台 / 2135 线路`清单字节一致），
`1.0.5 / code 6 / minSdk 16 / targetSdk 36`。双 ABI 的 `libapp.so` 均检出
`shunbo/window` / `setFullscreen` / `toggleFullscreen` / `window_channel`
（英文标识符串在 Dart AOT 里是 **UTF-8**，`utf8=True / utf16le=False`），
以及 `vodSectionFromText` / `normalizeVodItem` / `isMovieSectionItem` / `localMatches`；
中文串（UTF-16LE）检出 `短视频` / `电影解说` / `目录已完整` / `后台自动补齐`。

**Windows**：`dist/windows/Shunbo-1.0.5/` 分发目录 **31 个文件**（20 个 DLL 含 10 个
VC++ CRT：`msvcp140*.dll` ×5 / `vcruntime140*.dll` ×3 / `concrt140.dll` /
`vccorlib140.dll`），`shunbo.exe` 131,584 B 与 `data/app.so` 8,373,128 B 均为本轮
10:13 的新构建（旧分发目录里是 08:23 的 92,160 B / 8,356,744 B）。
`data/app.so` 同样检出 `shunbo/window` / `setFullscreen` / `toggleFullscreen` /
`window_channel`（`utf8=True`），中文串 `短视频` / `目录已完整` / `后台自动补齐`
（`utf16le=True`）⇒ **四项改动都进了 Windows 产物**。

构建链与耗时：`flutter build windows --release` **61.7 s** → 覆盖分发目录（保留 CRT）
→ `ISCC.exe dist\windows\Shunbo-1.0.5.iss` **27.1 s** → 便携 zip **14.5 s**（`zipfile`
deflate level 9，**31 条目**，`testzip` 无坏项；本机无 `zip`/`7z`，故不用外部工具）。

烟测：静默安装 `/VERYSILENT /DIR=dist\_smoke105` 退出码 **0**，落地 **33 个文件 /
86,035,530 B**（多出的是 `unins000.exe` 与 `unins000.dat`），`data/app.so` 大小与构建
一致；静默卸载退出码 **0**，目录**彻底移除**、无残留。**未拉起 GUI**。

### 8. 没验证的 / 边界

* **没有在 Windows 上真的进一次全屏看观感**（任务栏是否真的让位、Alt+Enter 是否
  触发、退出后是否还原成最大化）——只做了编译 + 静态确证；
* **没有在 Android 真机上验证**「点全屏不再回退」——树形稳定是编译期可证的，
  但 Element 复用是运行期行为，严格说仍属"设计正确、未实测"；
* 电影栏目归属只做了规则与存量迁移的静态确证，没有拉起 GUI 数一遍 470 条
  实际落到哪个栏目；
* 后台全量同步没做「接口新增 / 改名 / 下架」的长时间实测；
* `legacy/` 零改动 ⇒ legacy 独立包未重打；
* 源码**仍未提交、未推送**。

## §59 1.0.5 第十二次修：点播播放中按返回必闪退（Surface use-after-release）

用户报一句：「影片播放过程中点返回上一级 系统会崩溃并闪退」。不是偶发、不是
某些片子，**只要在播放态按返回就崩**。这类「一按就崩、退出码非 0、无 Dart
异常栈」的现象，方向要先定在**原生层**，而不是 Dart 的 `setState`。

### 1. 崩溃时序链

返回键进的是 `PopScope(canPop: _view == _VodView.browse)`，播放态 `canPop=false`
⇒ 走 `_back()` ⇒ `_leavePlaying()`。它**同步改状态、异步停播**：

```
返回 → _back() → _leavePlaying()
    ├─ queue.detach()
    ├─ unawaited(_pauseForLeave())    // pause 还在飞行中，没生效
    ├─ _session = null
    └─ setState(_view = detail)       // 同一帧就把 PlayerStage 从树上摘掉
          → AndroidView dispose → PlayerSurface.dispose()
                → scale.detach(textureView)
                → surface?.release()        ← 先释放
                → host.detachSurface()      ← 只把字段置空
```

`MpvMethodHandler.detachSurface()` 的旧实现是这样的：

```kotlin
fun detachSurface() {
    surface = null
    // 不清 player 的 surface：Dart 侧可能正在换集，重新 attach 时会补上。
    // 真正的释放由 dispose 负责。
}
```

注释说「真正的释放由 dispose 负责」，但 **dispose 也从未调用过
`engine?.setSurface(null)`** —— 全仓库 `setSurface` 只有 `attachSurface` 里
那一处调用。于是 `ExoPlayerEngine` 一直持有一个已经 `release()` 过的
`Surface`，而 `pause()` 还在异步飞行中，渲染线程照旧往这个 Surface 提交帧。
Android 的 `Surface` 是 native 句柄，写到已释放的 buffer 就是 SIGSEGV，
进程直接死 —— **没有 Dart 栈，只有闪退**。

### 2. 为什么不是「重复释放」也不是 Dart 的错

排查时先排掉了三个看似更可疑的方向，避免改错地方：

* **不是重复释放**：`surface` 字段是「先 release 后置 null」，两条销毁路径
  （`onSurfaceTextureDestroyed` / `dispose`）谁先到谁生效，第二次拿到 null 直接
  跳过。真正的问题是**顺序**，不是次数。
* **不是 Dart 的 `setState` 时机**：`_leavePlaying()` 在返回时同步改 `_view`
  是**正确**的（`didUpdateWidget` 里那条 `rebuild: false` 就是为避开 build 期
  `setState` 才单独写的）。渲染面被摘掉是预期行为，摘掉时没解绑才是 bug。
* **不是 `_applyLiveProfile()`**：`LibMpvPlayerController` 在 Android 上**没有
  实现 `PlaybackTuner`**，那个 `await` 是 no-op，不构成时序风险。

### 3. 修法：把「解绑」排在「释放」之前

三处改动，全部在 Kotlin 侧，Dart 一行没动（**不动 `_leavePlaying()` 签名与
`_view = _item == null ? …` 那行**，`I04` 断言原样通过）：

**① `MpvMethodHandler.detachSurface()` 主动让播放器脱面**

```kotlin
fun detachSurface() {
    engine?.setSurface(null)   // 必须先解绑，再允许调用方 release
    surface = null
}
```

换集时 `attachSurface` 会重新补上，不影响续播；播放态退出时这才是正确的
「先断开再销毁」。

**② `PlayerSurfaceFactory` 的两条销毁路径都改成「先解绑、后释放」**

`onSurfaceTextureDestroyed` 与 `dispose()` 统一为：
`host.detachSurface()` → `surface?.release()` → `surface = null`。
`dispose()` 另外还要先 `removeOnLayoutChangeListener` + `scale.detach`。

**③ 布局监听存成字段，`dispose()` 时注销**

旧代码是匿名 `View.OnLayoutChangeListener`，**没有句柄可注销**，视图销毁过程中
（尺寸归零、脱离窗口）仍会回调 `scale.apply(v as TextureView)`，对正在销毁的
`TextureView` 做 `setTransform` —— 源码注释自己就写着「ANR/崩溃风险」。
现在存成 `private val layoutListener` 字段，`dispose()` 第一步就摘掉。

**④ `VideoScaleController.apply` 加最后一道闸**

```kotlin
if (!view.isAttachedToWindow) return
```

`detach()` 只从集合里移除，挡不住已经在飞行中的 `main.post { }`；这一行让
「已脱离窗口」的视图彻底不再被 `setTransform`。

### 4. 门禁（3854 → 3858，只追加不放宽）

`verify_mobile_layout.dart` D 段新增 4 条，并新增 `_orderOf()` 助手专门校验
**顺序敏感**的销毁逻辑（顺序反了编译器不会报错，只能靠门禁）：

| 断言 | 钉住什么 |
| --- | --- |
| 解绑渲染面时必须让播放器脱离 Surface | `engine?.setSurface(null)` 存在 |
| 原生销毁顺序：先解绑播放器，后释放 Surface | `detachSurface()` 早于 `release()` |
| 布局监听存成字段以便注销 | `layoutListener` + `removeOnLayoutChangeListener` |
| 缩放对已脱离窗口的视图不再 setTransform | `isAttachedToWindow` 守卫 |

`_orderOf()` 的语义是**配对**而不是全体比较：源码里有两处销毁路径，整体序列
是 `a b a b`，要求每个 `b` 就近配到一个未配对的 `a`。第一版写成「全体比较」
把两处混在一起，直接误报失败 —— 门禁助手本身也要按真实代码形态设计。

结果：`flutter analyze` **0**；`verify_mobile_layout` **167/167**（163→167）；
`verify_channel_contract` **19/19**（方法名集合未变，双向差集仍为空）；
全量 `verify_all` **39 步 / 3858 断言**全绿。

### 5. 产物

`1.0.5 / code 6` 单包重打（旧包归档 `dist/_prev/`），`legacy/` 零改动 ⇒ legacy
独立包未重打。取证：`classes*.dex` 里检出 `setSurface` / `removeOnLayoutChangeListener`
/ `isAttachedToWindow`，确认修复进了包。

### 6. 没验证的 / 边界

* **本机无 adb**，拿不到 logcat，无法本地复现「按返回闪退」再验证修复 ——
  崩溃时序链是**静态推断**（代码路径 + Android Surface 语义），修复是**按正确
  时序改写**，不是「复现后打补丁」；
* 没有在真机上确认「播放中点返回」现在是否真的不崩（**这一条必须用户实测**）；
* `isAttachedToWindow` 守卫理论上会让「刚 attach 就 refresh」的那一帧不设矩阵，
  但 `attach()` 本身会立刻 `apply` 一次，且窗口 attach 后必然还有一次布局回调，
  不会留下永久拉伸态；
* 源码**仍未提交、未推送**。


## §60 1.0.5 第十三次修：内置检索索引 + 启动校验 + 动漫栏目（2026-11-12 14:20）

用户三项需求：①把 `config.json` 里的索引目录单（约 119.7 万条）完整下进安装包，
按栏目分片压缩，检索时按栏目取；②启动时校验「用户设定的接口」与「内置 / 已下载
索引」是否一致，一致直接读本地进播放、不一致从接口同步，并说明一致性依据、
失败回退、各状态提示、内置索引的更新与覆盖策略；③左侧栏新增「动漫」栏目。

### 0. 口径变更：内置的不是「完整目录」，是「检索索引」

这一条必须先说清，否则后面全部看不懂。

`?ac=detail` 单条记录实测 **17,216 B**，其中 `vod_play_url` 占 **13,595 B**（79%）——
播放地址是大头。135 万条 × 17 KB ≈ **21 GB**，任何安装包都装不下，压缩也救不了
（地址串是随机 base64 风格，gzip 后仍有 4–5 GB）。

所以内置的是**精简检索索引**，只存四样东西：

```
站点下标 \t vod_id \t 类目字典下标 \t 片名
```

分工是：**索引负责「搜得到」，详情接口负责「播得了」**。用户点开某部片时，才用
`?ac=detail&ids=<vod_id>` 回源取那一条的播放地址。这与主流播放器的做法一致，
也是唯一能在「装完就能搜」与「装得下」之间同时成立的口径。

### 1. 体积是怎么压到 6.2 MB 的

三步，缺一不可：

| 手段 | 效果 |
|---|---|
| 只存四个字段 | 17,216 B/条 → 约 30 B/条（**573×**） |
| 文本而不是二进制（便于裸 `dart run` 门禁交叉校验） | 单条 30 B → 仍偏大，靠下一步 |
| **片名前端编码**：按片名排序后只存「与上一行的公共前缀长度 + 剩余后缀」 | 中文片名平均省 60%，落到 **13.24 B/条** |
| 按栏目分 6 片 + gzip -9 | 单文件压得更透，且支持「只解用户正在搜的那一片」 |

前端编码的边界很脆：Python 在 **UTF-8 字符边界**回退（不能切在多字节中间），
Dart 侧 `applyFrontCode` 对越界前缀做容错（脏数据不能崩）。两侧只要差一个字节，
症状就是「某些片名搜不到」——极隐蔽。所以有专门的门禁逐片逐行校验。

### 2. 分片与栏目归属

分片键 = `VodSection.name`，六片：`movies` / `series` / `documentaries` /
`shortVideo` / `anime` / `other`。**打包侧与读取侧共用同一套词表**：

* `sectionFromCms()` 顺序 = 文本短视频 → 父链短视频 → 父链动漫 → `sectionFromName()`；
* `_walk_parents` 带 `visited` 防成环（脏数据里 `type_pid` 自指过）；
* 纪录片 / 电影判据用 `endsWith('片')` 而非 `contains('片')`；
* **不读 `genre`**（真电影也带「纪录片/喜剧」标签，会误踢犯罪片）；
* 证据不足一律 `other`，**绝不兜底进电影栏目**。

Python 侧 `tooling/pack_vod_index.py` 是这几个函数的**逐字翻译**，门禁 F03/F04
会断言两侧词表里每个动漫 / 纪录片关键词都存在，防止日后单边改动。

### 3. 启动校验：一致性依据三档

顺序不能换，理由逐条：

| 档 | 判据 | 为什么是这个位置 |
|---|---|---|
| ① 接口地址 | `manifest.sourceUrl` vs 用户当前设定 | 地址变了 ⇒ 索引里的 `vod_id` 全指向另一个站。先加载再发现，用户看到的是一堆点不开的卡片。**必须在发网络之前判** |
| ② 新鲜度 | `generatedAt` 距今 ≤ 7 天 | 站点会加减影片，7 天是个折中；打包机时区错导致时间戳在未来时**不判过期**（否则每次启动都重下） |
| ③ 完整性 | 分片读不到 / `records == 0` | 渠道包可能裁掉资产。只读**分片存在性与尺寸**，不整片解析——为验完整性把 6 MB 全解一遍会让冷启动多花一秒 |

「接口地址」取代 ETag 的理由：`config.json` 只有 10 KB，拉一遍确认比读本地时间戳
更可靠，代价可忽略。但地址比对仍然放在发网络之前，因为它是**离线可判**的。

### 4. 六态状态机与用户提示

`VodBootPhase` 六态 + 每态一句人话（文案全在状态机里，页面只负责显示，
避免「诊断页说已加载、页面说正在下载」）：

| 状态 | 文案 |
|---|---|
| `idle` | （不显示） |
| `checking` | 正在校验本地索引… |
| `readyBuiltin` | 已加载内置索引 N 万条（YYYY-MM-DD 打包） |
| `syncingNetwork` | 接口地址与内置索引不一致，正在从接口同步… / 内置索引已过期，正在从接口同步最新索引… |
| `fallbackBuiltin` | 接口同步失败，已使用内置索引（可能不是最新） |
| `incomplete` | 接口同步失败，且无内置索引可用 / 内置索引缺失，正在从接口同步… |

回退链：**一致 → 本地分片，零网络**；不一致 → 从用户设定的接口同步；同步失败
→ 回退内置索引并明示「可能不是最新」。用户没开外部地址（默认）时 `allowSync=false`，
状态落 `fallbackBuiltin` 并说明「未联网校验」——默认不该偷偷联网。

启动校验挂在**首帧之后**（`addPostFrameCallback`）：本地读完只要几十毫秒，
但判定不一致就会触发网络同步（几秒到几十秒），放 `runApp` 之前会把首帧钉住。

### 5. 内置索引的更新与覆盖策略（`shouldReplaceCache`）

| 情形 | 动作 | 理由 |
|---|---|---|
| 内置索引比本地 `vod-library.json` 新 | **覆盖** | 用户升级 App 就是为了拿到新片；留着旧缓存会变成「升级了还是搜不到新片」 |
| 内置索引比缓存旧 | 不覆盖 | 降级安装 / 同版本重装时，用户本地已同步的数据比安装包新，覆盖等于删数据 |
| 接口地址变了 | 覆盖 | 旧缓存里的 id 全指向另一个站，留着全是错的 |

判据只看 `generatedAt` 与 `sourceUrl`，**不看条数**：站点挂掉会让条数变少，
但内容可能更新（老片下架、新片上架）。

### 6. 检索：按栏目分片懒加载 + 流式扫描

真机 Letv S50 Air / API 18 / armv7a，147 万条 `VodItem` 至少 400 MB，解完就 OOM。
所以全程只做两件事：

* 解 gzip → 按 `\n` 切行 → 逐行判断 → **命中才建对象**；
* 片名靠一个「上一行完整片名」的滚动变量还原（前缀编码的逆运算）。

一次检索的内存峰值 ≈ 一个分片的解压后字节数（最大片约 6 MB）+ 命中结果。
`BuiltinIndexService` 按 `sectionKey` 缓存解压后的文本，同一片只解一次；
并发检索走 `_loading` 去重（用户连打两个字的间隙不要解两遍）。

UI 侧两段式（`_filteredFor` 是**同步**的，不能 await）：
输入变化 → debounce 180 ms → 异步检索写进 `_indexHits` → `_filteredFor` 只做同步合并。
序号 `_indexSeq` 保证「先回来的旧结果不许覆盖后回来的新结果」。

合并顺序有意义：**本地命中在前、索引命中在后**（本地有播放地址、点开即播；
索引还要回源一次），同名片名去重，用户不会看到同一部片两个卡片。

### 7. 回源点开：为什么必须 `adoptResolved` 而不是 `append`

`VodLibrary.append()` 发现 `sourceId` 变了会 `_clearExternal()` —— 即「从内置索引
点开一部片」会把用户已经同步下来的几万条外部目录**整批清空**。这种事故不崩、
不报错，只是「升级后片库突然空了」，极难从现象反推。

`adoptResolved()` 只做两件事：注册剧集/地址表 + 保证该 `sourceId` 有适配器，
不碰 `_external`、不碰当前外部源指针。回源条目的 id 用 `源id:站点key:vod_id`，
与网络同步口径**完全一致**——同一部片从索引点开、还是从网络同步里点开，
续播记录是同一条。

回源条目不进栏目列表：索引有十几万条，塞进来既撑爆一万条缓存上限，
也会让「栏目」变成另一个检索结果页。

### 8. 第 3 项：动漫栏目

`VodSection.anime` 与 `AppSection.anime` 都**追加在枚举末尾**，因此六项下标的
对应关系天然成立（`IndexedStack` 下标 = 枚举序号 = 导航顺序），前五项一个都不动。

归类规则（真实动漫类目 15 个：`动漫`/`动漫片`/`动漫电影`/`国产动漫`/`日韩动漫`/
`欧美动漫`/`港台动漫`/`海外动漫`/`中国动漫`/`日本动漫`/`动画片`/`AI动漫`/`AI漫剧`/
`漫剧`/`有声动漫`）：

1. **短视频优先**：`AI漫剧`/`漫剧` 这类既是动漫又是竖屏短剧形态的，归短视频；
2. 再看类目父链（`type_pid`），子类目名字里没「动漫」两个字也能认出来；
3. 其余动漫类目归 `anime`；
4. 证据不足归 `other`。

判据与打包侧完全一致 ⇒ 分片归属、栏目展示、导航三处不会各说一套。

### 9. 门禁

新增三套（现 **42 步 / 4150 断言**，基线 39 步 / 3858）：

| 门禁 | 断言 | 覆盖 |
|---|---|---|
| `vod-builtin-index` | 91 | 用**真实打包产物**跑：manifest 自洽 / 唯一片名数与每名上限 / 分片行数与 sha256 / 前端编码还原 / 词表逐字一致 / 栏目归属 / 分片可检索 |
| `vod-boot-index` | 61 | 六态状态机全转移图：A 一致零网络 / B 地址不一致 / C 同步失败回退 / D 异常被吞 / E 无索引 / F manifest 抛异常 / G 分片缺失 / H `allowSync=false` / I 过期判定 / J idle 与 listener / K `shouldReplaceCache` 六条 / L 布尔版与理由版同口径 / M 源码静态护栏 |
| `vod-builtin-service` | 115 | 运行期服务：真实产物检索 / 栏目隔离 / limit / 缓存与 clearCache / 命中反查 / 回源参数不串 / **`adoptResolved` 不清外部目录且地址真可取** / **同名只出一张卡片** / **主站失败自动换源** / 源码静态护栏 |

`vod-playback` 的 K25 全屏透传断言在新栏目加入后从「写死 5 处」改为
「点播页实例数 + 1」，**如实改写未放宽**：加栏目不会破门禁，少给某个页面透传仍会红。

### 10. 实测数据（2026-11-12 全量重抓后）

**抓取**：13 站 / **29,318 页** / **1,473,395 条**原始记录。8 站抓不到（`wujin` 中途复活已纳入；
`wwzy`/`ruyi`/`ffzy`/`wolong`/`dbzy`/`ikun`/`suonizy` 全程不可用 —— 强关、DNS 失败、非 JSON、
502/10060 超时，站点可用性本身在波动）。

**打包产物**（`assets/vod_index/`，每名最多 2 条）：

| 分片 | 条数 | gz 字节 | B/条 |
|---|---|---|---|
| `movies` | 159,715 | 1,406,319 | 8.81 |
| `series` | 71,916 | 650,251 | 9.04 |
| `documentaries` | 14,270 | 177,193 | 12.42 |
| `shortVideo` | 179,176 | 2,207,773 | 12.32 |
| `anime` | 60,281 | 766,061 | 12.71 |
| `other` | 119,748 | 1,275,231 | 10.65 |
| **合计** | **605,106** | **6,482,828（6.18 MB）** | 10.71 |

唯一片名 **381,968** 个；去重丢弃 868,289 条（跨站镜像占绝大多数 —— 抽样实测**站内同名只占
0.5%**，同名平均出现在 1.9 个站）。安装包从 42.5 MB 涨到约 49 MB，仍在 60 MB 门禁内。

### 11. 为什么每名留 2 条（`--keep-per-title`）

147 万条原始记录里，同一个片名平均出现 3.85 次，全是各站转发的同一批资源池。两种极端做法都不对：

* **全留** ⇒ 19 MB 以上，顶满体积门禁；且同一部片 4 张卡片，用户以为片库乱了。
* **只留 1 条** ⇒ 省到 4.55 MB，但**丢掉换源能力**：那条记录指向的站一旦详情接口抽风，
  这部片就点不开，而索引里明明还有别的站有它。

留 2 条且**优先来自不同站**（同站同名的第二条没有换源价值）：8.81 B/条的单价把总量压在
6.18 MB，同时每个片名至少有一个备胎。Dart 侧对应两件事：检索时**同名归并成一张卡片**
（`_alts` 存备选），回源失败时**依次换源**（`resolve` 里的 `_tryResolve` 循环）。

### 12. 抓取/打包踩的四个坑（都不报错，只让产物「看起来自洽」）

| 坑 | 症状 | 处置 |
|---|---|---|
| 服务端**按站钳制 `pagesize`** | `dyttzy`/`bfzy` 给 100，`tyyszy`/`zuid`/`yinghua`/`wujin` 只给 **20**。按请求值算页数 ⇒ 那几站只抓到 20%，产物自洽、不报错 | 探测实测首屏条数再算页数；打包侧再按「真实条数 ≥ 接口 total × 90%」复核 |
| **类目表字段方言** | `dyttzy` 用 `type_id/type_pid/type_name`，其余站用 `id/pid/name`。只认一种 ⇒ 整站类目表解析为空 | `load_classes()` 同时认两套字段名 |
| **类目表缺失静默归错栏目** | `dyttzy` 类目表没抓到那轮，8.5 万条全掉进「其他」，行数/sha256/总数全对 | 打包时**硬检查**：有数据但无类目表的站直接报错（`--allow-missing-classes` 才放行） |
| **`dead` 标记误伤已抓数据** | 重启探活时 `dyttzy` 被 WAF 回 403 ⇒ manifest 标 `dead` ⇒ 整站 8.5 万条被静默排除 | 站点可用性改以**本地已抓页**为准：一页都没有才算死站 |

### 13. 明确不做的事（附理由）

* **不在打包时探活站点来调整优先级**：`dyttzy` 今天的 403 很可能只是我们三万次请求撞上的
  临时限流，把它判成坏站会把 8.5 万条降级。探活结果写进产物还会让构建不可复现。
  站点真挂了的现象是「部分卡片点开回源失败」，这时用户从**自己设定的接口**同步一次即可，
  不该由安装包去猜。
* **不把 147 万条全塞进去**：见 §60.11，体积与可用性都不允许。
* **回源条目不进栏目列表**：索引 60 万条，塞进片库会撑爆 `kVodCacheMaxItems = 10000`，
  也会把「栏目」变成另一个检索结果页。

### 14. 产物（2026-11-12 14:2x 同版重打，版本仍 1.0.5+6）

| 产物 | 大小 | sha256 |
|---|---|---|
| `dist/Shunbo-1.0.5-full.apk` | 51,149,994 B（48.78 MB） | `b1675cfa84651f445abe814b883e6f69bf0551ae6fca5eccd07c2ff9b77bff02` |
| `dist/Shunbo-1.0.5-windows-x64-setup.exe` | 32,374,374 B（30.87 MB） | `a813b34836278527…5f1b1b7a0cfb3106` |
| `dist/Shunbo-1.0.5-windows-x64-portable.zip` | 40,054,225 B（38.20 MB） | `7ffea53fe57500a2fce84f87e69345537ae647f757a288fd33f17787a9ea3adb` |

**进包取证**（不是「看构建日志说成功」）：

* 单包内 `assets/flutter_assets/assets/vod_index/` 七个文件全部**与 `assets/vod_index/` 逐字节一致**
  （6 个 `.tsv.gz` + `manifest.json`，合计 6,487,505 B）；
* 单包 `libapp.so` 检出 `assets/vod_index/`、`builtin:`、`builtin-index`（UTF-8）；
  中文状态文案 `内置索引` / `已加载内置索引` / `正在校验本地索引` / `接口地址与内置索引不一致`
  全部以 **UTF-16LE** 形式在 `libapp.so` 里；
* 单包 `aapt2 dump badging` = `versionCode 6 / versionName 1.0.5 / minSdk 16 / targetSdk 36`；
* Windows 分发目录 `data/flutter_assets/assets/vod_index/` 同样逐字节一致，
  `data/app.so` 检出同一批串；便携包 38 条目、`testzip` 无坏项。
* 合并单包的 24 条断言全过（`assets/channels.json` 与 legacy 源字节一致、三个 ijk so 只进
  armeabi-v7a、`apksigner @16/@18` 验签、API 18 不声明 `androidx.startup`）。

体积对比：单包 42.5 MB（无索引 / 旧单站索引）→ **48.78 MB**，距 60 MB 门禁还有 11 MB。
桌面安装版 25.8 → 30.87 MB，便携包 33.5 → 38.20 MB。

**未验证**：内置索引在真机上的表现（首屏耗时、6 MB 分片解压后的内存峰值、检索延迟、
点开回源的失败率）—— 本机无 adb，只能静态确证「资产在包内 + 代码路径存在」。

## §61 1.0.5 第十四次修：Windows 覆盖安装卡在 d3dcompiler_47.dll（code 5 拒绝访问）（2026-11-12 14:5x）

**现象**（用户实拍截图）：装 `Shunbo-1.0.5-windows-x64-setup.exe`，进度条走到一半弹框——

```
Error
D:\Programs\Shunbo\d3dcompiler_47.dll
An error occurred while trying to replace the existing file:
DeleteFile failed; code 5.
拒绝访问。
```

给 Try again / Skip this file / Cancel 三个选项。点 Try again 仍然同样报错 —— 占用它的进程
一直没退出，重试一千次结果一样。

### 61.1 根因：不是「文件权限」，是「映像已被映射」

`code 5` 很容易被误判成 ACL / 只读属性问题。实际不是。`shunbo.exe` 启动时，Windows 加载器把
`d3dcompiler_47.dll`、`flutter_windows.dll`、`libEGL.dll`、`libGLESv2.dll`、`libmpv-2.dll`
作为 **image section** 映射进进程地址空间。被映射的映像文件在进程存活期间**不允许删除**，
`DeleteFile` 直接返回 `ERROR_ACCESS_DENIED`。这不是权限不够，是内核语义：改动正在执行的代码段
会让已映射的页面失效。

判据（本次实测就用的这条）：以 `ReadWrite` + `FileShare.None` 独占打开目标 DLL ——
能打开 = 锁已释放；抛 `being used by another process` = 还被映射着。

### 61.2 现场实况：四个进程条目，两个真身

处置时 `Get-CimInstance Win32_Process` 查出：

| PID | 状态 | 说明 |
|---|---|---|
| 2184 | 运行中 713.9 MB | 14:34 启动，真实进程 |
| 28408 | 运行中 1365.9 MB | 14:35 启动，真实进程 |
| 9292 | 僵尸 0 MB | 11:04 启动，taskkill 报成功后仍在内核表里 |
| 29580 | 僵尸 0 MB | 11:25 启动，同上 |

即用户**先后起了两个实例都没关**，又叠加两个已终止但内核对象未回收的残留。
`CloseApplications` 依赖的 Restart Manager 只认得出它握得上手的那部分，
多实例 + 僵尸条目正是它漏掉的典型形态。

### 61.3 两道防线（三份 iss 同步补上）

`dist/windows/Shunbo-1.0.5.iss`、`tooling/windows_installer.iss`、`tooling/windows_release.iss`
三份脚本一起改：

```ini
CloseApplications=force
CloseApplicationsFilter=*.exe,*.dll
RestartApplications=no
```

```pascal
[Code]
function PrepareToInstall(var NeedsRestart: Boolean): String;
...
  for Attempt := 1 to 3 do
  begin
    if not Exec('taskkill.exe', '/F /IM shunbo.exe', '', SW_HIDE,
                ewWaitUntilTerminated, ResultCode) then Break;
    if ResultCode = 0 then begin Killed := True; Break; end;
    if ResultCode = 128 then Break;   { 128 = 本来就没这个进程 }
    Sleep(400);
  end;
  if Killed then Sleep(1000);         { 句柄释放有延迟，不能省 }
```

- **防线一 `CloseApplications=force`**：交给 Restart Manager 发 WM_CLOSE，程序能正常存盘退出，
  是「温和」路径。`force` 表示不弹确认框直接关。
- **防线二 `[Code]` taskkill**：Restart Manager 认不出的（多实例 / 僵尸 / 无响应窗口）强杀。
  退出码 0 = 杀到，128 = 本来没有，其余重试三次。杀完必须 `Sleep(1000)` —— 进程退出到句柄
  真正释放之间有延迟，紧接着的 `DeleteFile` 仍会 code 5。
- **`RestartApplications=no`**：`[Run]` 段自己会拉新程序，交给 Inno 重启会开成两份。

### 61.4 为什么不用另外两条路

| 方案 | 否决理由 |
|---|---|
| `[Files] Flags: restartreplace` | 把被占文件登记进 `PendingFileRenameOperations`（HKLM），per-user `PrivilegesRequired=lowest` 写不进去；且要重启才生效，用户以为装完了其实没换 |
| `[Setup] AppMutex=` | 干净，但要求 `shunbo.exe` 原生入口 CreateMutex，得改 `windows/runner/main.cpp`；为装包给运行时加一条全局约束，收益不抵改动面 |

### 61.5 实测（不是静态确证）

按最坏场景复现：先起两个真实实例把 DLL 占死，再静默跑新包。

```
Get-Process  → 2184 (713.9 MB) + 28408 (1365.9 MB) + 两个 0 MB 僵尸
DLL 独占测试 → "being used by another process"   ← 锁确实在
setup /VERYSILENT /SUPPRESSMSGBOXES /NORESTART
→ EXITCODE 0
→ 2184 / 28408 双双消失，只剩两个内核未回收的僵尸条目
```

装完逐字节比对 `dist/windows/Shunbo-1.0.5` 与 `D:\Programs\Shunbo`：

| 项 | 结果 |
|---|---|
| 源文件总数 | 38 |
| 一致（sha256 相同） | **38** |
| 缺失 / 不符 | 0 / 0 |
| 索引分片 | 7 文件，6,487,505 B（6.19 MB），与 APK 内同批一致 |

`shunbo.exe` 启动复验：PID 存活、52 线程、主窗口标题「顺播 shunbo」、加载索引后
工作集 1332.6 MB（与旧版同量级，非本次引入）。

### 61.6 副产品：清理失败安装的 tmp 残留

失败 / 中断的安装会在 `{app}` 里留 `is-XXXXXXXXXX.tmp`（Inno「先写临时名再改回真名」的中间态）：

```
is-D962JD8YVR.tmp   4,399,874 B  ← 与 unins000.exe 同尺寸
is-PYKVLLUB4H.tmp  29,764,622 B  ← 与 libmpv-2.dll 同尺寸
```

下一次安装不会自动清掉，属纯垃圾，可手工删。本次已清。

### 61.7 教训

1. **`code 5` 先查进程，别查权限。** 权限问题的文案通常是「你需要管理员权限」，
   而被映射文件的删除失败就是「拒绝访问」—— 长得像权限，其实是引用计数。
2. **`CloseApplications` 不是万能的。** 它走 Restart Manager，多实例 / 僵尸 / 无响应窗口会漏。
   覆盖升级类安装包必须配 `[Code]` 兜底。
3. **杀完要等。** `taskkill` 返回 0 不等于句柄已释放，`Sleep(1000)` 不能省，
   省掉就是「偶发」code 5 —— 最难查的那种。
4. **改 iss 必须保 UTF-8 BOM + CRLF。** 脚本改写后要复验 `BOM=True / LF-only=0`，
   否则 Inno 按 ANSI 解析，中文全变乱码（本次三份都已复验）。
5. **现场救济（不改代码也能过）**：任务管理器结束所有 `shunbo.exe` → 回安装向导点 Try again。
   本次先这么解了当下，再补脚本 —— 顺序反过来会让人以为「重装就能好」。

## §62 1.0.5 第十五次修：「类型」全是国家名 + 有内置索引还在同步（2026-11-12 15:2x）

用户两张截图，两个问题：

1. 「类型」筛选行排出来是 **欧美剧 / 国产剧 / 日本剧 / 韩国剧** —— 一排国家名，
   和下面的「地区」行撞车；顶部快捷 tab 行又是同一批词，一屏出现三遍。
2. 页面顶部写着「已加载内置索引 60.5 万条（2026-11-12 打包）」，下一行却是
   「目录同步中：已加载 10000 部，接口统计 1475989 部」。

---

### 62.1 「类型不对」是三层问题叠在一起

| 层 | 原因 | 证据 |
|---|---|---|
| 取词 | `vodTypesOf()` 读 `item.typeName`（栏目类目），从来没读 `item.genre`（`vod_class` 真题材） | `vod_facets.dart` 旧代码第一行 `final raw = item.typeName;`；而 `vod_catalog.dart:360` 的注释早就写着「`type_name` 是采集站的栏目类目，`vod_class` 才是用户理解的类型」 |
| 数据 | 列表接口（`?ac=list`）**不返回** `vod_class`，只有详情接口（`?ac=detail`）返回 | 本机 1 万条缓存实测：`type` 空值率 **0%**（78 个值）、`genre` 空值率 **71.5%**（128 个词） |
| 内置索引 | manifest 只存了 78 个类目 **ID**，没存名字；回填时写 `typeName: hit.typeId` | 旧 manifest `types: ["25", ...]`；从索引点开的片，类型会显示成「25」 |

栏目类目本身就是「地区 + 体裁」的命名法（欧美剧、国产剧、日韩动漫、大陆综艺），
所以只要读 `typeName`，「类型」行必然长成一排国家名。

### 62.2 修法：genre 优先，兜底时剔掉地区与纯体裁词

```dart
List<String> vodTypesOf(VodItem item) {
  final genre = _splitTypeWords(item.genre);      // 真题材优先
  if (genre.isNotEmpty) return genre;
  return [for (final t in _splitTypeWords(item.typeName))
            if (!isNonGenreLabel(t)) t];          // 兜底：剔地区 / 纯体裁
}
```

`isNonGenreLabel()` 的判据（剥掉体裁后缀 `电视剧/剧/片/动漫/综艺/电影…` 后比对）：

* 剥完是地区词 ⇒ 不进类型行（`欧美剧`→欧美、`国产动漫`→国产、`日韩剧`→日韩、`中国动漫`→中国）；
* 剥完什么都不剩 ⇒ 纯体裁，不进（`电影`、`动漫`、`剧`）；
* 其余保留（`动作片`、`纪录片`、`篮球`、`喜剧`）。

**为什么不干脆只用 `genre`**：71.5% 的条目没有它。纯用 `genre` 会让七成条目在
「类型」维度上彻底消失 —— 点任何筛选项都剩不下东西，比筛错更糟。

**实测（本机真实 1 万条缓存，改前 → 改后）**：

```
改前：AI漫剧 / 短剧 / 爽文短剧 / 现代都市 / 篮球 / 国产动漫 / 欧美剧 / 足球 / 国产剧 / 大陆综艺 …
改后：AI漫剧 / 剧情 / 爽文短剧 / 现代都市 / 篮球 / 奇幻 / 古装 / 足球 / 喜剧 / 爱情 …
```

类型词 36 个，仍有类型词的条目 **74.8%**（改前 100%，但其中七成是错的）。

### 62.3 顺带治「地区」行的脏数据

同一屏「地区」行混进了 `已完结`、`全80集（合全集）`、`正片` —— 有些采集站把
`vod_area` 当成更新状态 / 备注在用。新增 `looksLikeVodArea()`：

* 含数字 ⇒ 不是地名（`全80集`）；
* 含 `集 / 完结 / 更新 / 正片 / 预告 / 花絮 / 抢先` ⇒ 更新状态；
* 含 `HD / BD / TC` ⇒ 画质备注；
* 长度 > 8 ⇒ 不是地名。

改后地区行：`大陆 / 内地 / 中国大陆 / 美国 / 日本 / 韩国 / 泰国 / 台湾 / 英国 / 中国台湾 / 加拿大 / 印度`。
判据刻意保守 —— 宁可漏挡一个脏值，不可误杀一个真地区（误杀会让整片地区从筛选条消失）。

### 62.4 内置索引补上类目名表（`typeNames` + `typeSites`）

`pack_vod_index.py` 原本**已经拿到了类目名**（`table[tid]["name"]`，用于归栏目），
但只把 ID 写进 manifest，名字被丢掉。现在多写两条平行表：

| 字段 | 内容 | 用途 |
|---|---|---|
| `types` | 类目 id（下标对齐） | 回查 |
| `typeNames` | 类目中文名 | 界面显示（`25` → 「国产剧」） |
| `typeSites` | 该项属于哪个站（站点下标） | 消歧，见下 |

**为什么必须有 `typeSites`**：`type_id` 是**各站自己的编号**。第一版按裸 `type_id`
建全局表，实测 **314,179 行**同名冲突（`1` 在 A 站是「电影」、在 B 站是「电视剧」），
会把「电视剧」标到一部电影上 —— 不报错，只是标错。改成 `(站点, type_id)` 建表后
**站内冲突 0 行**，字典从 78 项变 523 项。

查不到名字返回**空串**，绝不回退成 id：宁可这一条没有类型，也不要用户看到「25」。

代价：索引 **6.18 MB → 6.31 MB**（6,482,828 → 6,613,466 B，+130 KB）。
下标从 78 项涨到 523 项，数字位变宽、压缩率略降；仍在 60 MB 体积门禁内。

### 62.5 为什么「有内置索引还在同步」：两条链路互不通气

| 链路 | 代码 | 触发时机 | 判据 |
|---|---|---|---|
| A 启动校验 | `vodBoot.boot()`（第十三次修） | 首帧之后（postFrame） | 地址 + 新鲜度 + 分片完整性 → `readyBuiltin` 就不联网 ✅ |
| B 后台全量同步 | `_ensureDefaultSource()` → `_revalidateInBackground()`（第十一次修） | **`initState`**（首帧之前） | 只看「开关开 + 默认源」，**没有 `vodBoot`** ❌ |

时序上是死结：B 在首帧前跑，A 在首帧后跑 —— B 读 `hasLocalIndex` 时 phase 还是
`idle`，即使加了判据也会判错。截图里的两行字分别来自 A（已加载 60.5 万条）和 B（同步中）。

而且这条同步**在结构上永远追不上**：

| 项 | 值 |
|---|---|
| 单次同步硬上限 | `kVodCacheMaxItems = 10000` |
| 接口总量 | 1,475,989 部 |
| 覆盖率 | 0.68% |
| 每轮预算 | 240 批 / 5 分钟，每批重写 16 MB JSON |
| 分页游标 | 纯内存、不持久化 ⇒ 冷启动从第 1 页重来 |

修法三道：

1. `VodBootController` 新增 `settled`：boot 未开始时**立刻返回**（不挂住调用方），
   在跑则等到出结论（本地读 manifest + 分片头，几十毫秒）；
2. `_ensureDefaultSource()`：先 `await boot.settled`，再判 `boot.hasLocalIndex` ——
   够用就直接 return，不启动同步；
3. `_revalidateInBackground()`：进入前 + 每一批循环里都复查 `!boot.hasLocalIndex`，
   防止「boot 在本函数让出执行权之后才出结论」。

### 62.6 文案：不再拿注定追不上的分母

旧：「目录同步中：已加载 10000 部，接口统计 1475989 部 · 后台自动补齐，无需手动翻页」
—— 那个分母永远到不了，用户读到的是「同步不完了」。

新：「后台增量同步中：已加载 N 部 · 内置索引 60.5 万条已可直接检索」。
内置索引就绪时这一行**整行不显示**（没有同步就没有转圈）。条数口径与启动校验
那行统一折成「万」，同一屏不出现「605106 条」和「60.5 万条」两种写法。

### 62.7 门禁：42 步 / 4186 断言（上轮 4150，+36）

| 门禁 | 新增 | 守什么 |
|---|---|---|
| `vod-playback` F03a–F03i | +9 | genre 优先 / 地区与纯体裁词剔除 / 真题材保留 / 真实混合样本（类型行只剩「剧情·动作片」）/ 脏 area 拦截 |
| `vod-builtin-index` A15–A21、F07–F08 | +9 | 名字表与站点表等长 / (站点,类目) 组合唯一 / 跨站同 id 按站点查对 / 查不到返回空串 / 源码不许出现 `typeName: hit.typeId` |
| `vod-boot-index` N01–N06、S01–S06 | +12 | `settled` 语义（未开始不挂住、结论前 `hasLocalIndex=false`）+ 同步让位于内置索引的接线护栏 |
| `vod-builtin-service` H09–H12 | +6 | `toItem` 回填中文名、副标题不含裸 id |

`flutter analyze` 0 issue。`S` 段只能静态断言（Widget 的 `initState` 裸 `dart run`
撑不起），守的是一个**真实发生过**的回归。

### 62.8 遗留

* 「大陆 / 内地 / 中国大陆」在地区行里仍是三个词（源站写法不同），要不要归一待定 ——
  归一需要一张别名表，且会改动用户已保存的筛选值，不在本轮范围。
* 类目消歧只做到「站点」级：同一站内若真有两个同名不同义的类目，仍会合并
  （实测站内冲突 0 行，暂不处理）。
* 真机未验：内置索引点开后的类型显示、`settled` 在真机冷启动的实际耗时。

## §63 1.0.5 第十六次修：进入点播即加载索引片源 + 接口校验五态（2026-11-12 16:0x，16:29 验收）

**需求**：进入点播时先检查「已保存的片源索引目录是否有有效片源」以及「该索引是否与当前设定的接口匹配」；匹配且有效就直接把索引里的片源加载到播放列表；校验不通过（索引片源缺失 / 接口未设定 / 接口与索引不匹配）则进入片源接口输入流程，初次使用且未设定接口**必须弹输入页面**。用户提交地址后，若已有索引且记录的接口地址与填写地址一致就直接加载，否则按填写地址重新获取片源并生成新的索引目录文件，新文件沿用默认索引目录文件的处理规则。要求明确区分各状态、各分支加载来源唯一、播放列表内容与最终采用的索引一致。

### 63.1 修之前的真实状态

前十五次修做完之后，「内置索引」其实**只在搜索框里存在**：

| 环节 | 修之前 |
|---|---|
| 启动校验 `vodBoot` | 判出 `readyBuiltin` 只表示「这份索引可以拿来检索」，不往列表里放一条片 |
| 播放列表 `_buildBrowse` | `VodLibrary.inSection(section)` = 内置 6 条示例 + `vod-library.json` 恢复的外部目录（上限 1 万条） |
| 内置索引 | 只在输入关键词时，由 `_indexHits` 追加最多 200 条命中 |
| `BuiltinIndexService.search()` | `query` 为空直接返回空列表，注释明写「浏览不走内置索引」 |
| 初次使用 | 静默用默认组合，从不弹任何输入页 |

也就是说：界面上写着「已加载内置索引 60.5 万条」，用户眼前的网格里却一部索引片源都没有。这次把索引本身变成列表的唯一来源。

### 63.2 五态状态机（`vod_index_gate.dart`，纯 Dart 无 IO）

| 状态 | 触发 | 用户看到 |
|---|---|---|
| `checking` | 进入栏目，正在读设定与两份目录清单 | 正在校验片源索引目录… |
| `ready` | 某份索引有效且记录的接口 == 当前设定 | 已加载内置/本地片源索引目录 N 条（日期） |
| `needAddress` | 三种不通过分支（见下） | 原因 + 「设定片源接口」按钮 + 空态卡片 |
| `building` | 提交新地址且无可复用索引 | 正在按新接口获取片源并生成索引目录… |
| `failed` | 接口不可达 / 无可播条目 / 写盘失败 | 失败原因 + 「重试 / 改地址」 |

判据顺序**不可换**（`evaluateVodIndexGate`）：

1. `!configured || selectedUrl.isEmpty` → `needAddress`，理由「尚未设定片源接口（初次使用）」。**离线可判**，初次必弹由它保证；
2. 生成目录有效且地址一致 → `ready(generated)`（用户最近生成的比随包的优先）；
3. 内置目录有效且地址一致 → `ready(builtin)`；
4. 其余 → `needAddress`，但理由要区分「片源索引目录缺失或不含有效片源」与「索引目录记录的接口地址与当前设定不一致」。

「有效片源」的判据是 `total > 0 && sourceUrl.trim().isNotEmpty`：缺地址的历史文件不能算有效，否则它会被当成「和任何地址都匹配」。

### 63.3 提交地址后的两条分支（`decideVodIndexSubmit`）

| 条件 | 动作 | 是否联网 |
|---|---|---|
| 已有索引目录且记录的接口 == 填写地址 | `loadExisting(origin)` → 重新跑一次完整校验后采用 | **零请求** |
| 地址不一致 / 没有任何有效索引 | `rebuild` → 按地址取片源 → 写新目录文件 → 重新校验 | 有 |

初次使用填默认源地址（`http://47.96.82.41:5188/config.json`）正好命中第一条：内置索引 manifest 记的就是它，于是**秒开 60.5 万条**，不用重新抓一遍 147 万条。这是输入页为什么要把内置索引记录的接口地址直接显示出来、并给「填入默认源地址」按钮的原因。

`submit()` 先落接口设定（`configured` 置真，之后不再弹首次输入页），再判分支。直接加载分支也**重新跑一遍完整校验**，而不是把提交时的临时结论硬塞给 UI —— 保证 `verdict.origin` 与「刚提交的地址」一致。

### 63.4 来源唯一：三道锁

用户特别要求「各分支加载来源唯一、播放列表内容与最终采用的索引一致」。落点是三道锁：

1. **单值来源**：`VodIndexGateVerdict.origin` 是一个枚举，`ready` 时非空，其余四态**恒为 null**（门禁 B19 锁住这条不变式）。列表代码没有第二份数据源可选。
2. **取数守卫**（`_buildBrowse`）：`gate.ready && _poolOrigin == gate.activeOrigin && _poolSourceUrl == gate.lastUrl` 三条全真才用池子，否则显示空列表。用户刚换接口、新列表还在加载的窗口里宁可空着，也不把上一份索引的片源混进来。
3. **离开 ready 即清空**（`_resetIndexPool`）：同时 `_poolSeq++` 让在途加载结果作废，杜绝「旧索引晚一步覆盖新列表」。

列表从此**不再读** `VodLibrary.inSection`（门禁 F14a 反向锁死）。旧口径断言 F14 改写成四条更强的新断言，不是删除或放宽。

### 63.5 索引片源怎么进列表：等距采样，不建 60 万对象

`BuiltinIndexScanner.collect()` 新增按行号等距采样：命中条件 `行号 >= offset && (行号 - offset) % stride == 0`，`stride = ceil(分片条数 / 每页条数)`。续载把 `offset` 加一，就取「每段的下一张卡」，`offset >= stride` 时 `browse()` 直接返回空。

**为什么不能顺序取前 N 行**：分片是按片名排序后做前端编码的，实测 `movies.tsv.gz` 前 20 行里 18 行是 `#` / `0.` / `&quot;` 开头的符号片名：

```
#PTGF出租女友 / #我在这里 / &quot;摇&quot;破天惊 / 0.0兆赫 / 0.5毫米 …
```

等距采样后首屏变成 `100英亩的地狱 / 2012冰河时期 / 27号集装箱 / Koko:红犬历险记 …`，一屏就覆盖整个分片。前端编码要求逐行维护 `previous`，所以**不命中的行也必须走完**，不能按行号跳跃。

仍然只解当前栏目那一片、只把命中行建成对象：60 万条全建 `VodItem` 在 API18 / armv7a 上必然 OOM。

### 63.6 新生成的索引目录文件（`vod-index.json`）

用户换接口后，内置索引里的 `vod_id` 全部指向别的站，不能再用。`rebuild` 按填写地址走既有 `VodSession` 取回片源，写成数据目录下的 `vod-index.json`。

**沿用默认索引目录的处理规则**：

- 同一份清单字段：`version` / `sourceUrl` / `generatedAt` / `total` / 按栏目分节的 `sections`（键与 manifest 的 `sections[].key` 同名）；
- 同一个「接口地址」一致性判据（`VodIndexSnapshot.matches`）；
- 同一套「按栏目加载、进入点播优先复用、命中就不发网络」流程；
- 同一套写盘纪律：先写 `.tmp` 再原子替换，坏文件按「没有索引」处理，体积护栏与 `vod-library.json` 同口径。

差别只有一处且是刻意的：新目录的条目来自已取回的**可播片源**，自带 `episodes`，点开即播；内置索引是打包时固化的精简数据，只能点开再回源。两种条目都通过 `VodItem` 交给同一个列表。

**能力边界（如实记录）**：`rebuild` 用 `VodSession.start(autoBatches: 12, budget: 90s)`，受 `kVodCacheMaxItems = 10000` 硬上限约束，生成的是「本次取回的片源目录」而不是接口全量 147 万条。全量抓取是打包侧 Python 脚本（30,169 页）的事，App 内既跑不完也没必要 —— 索引负责「进入即搜得到」，详情页回源负责「播得了」。

### 63.7 播放链路与检索口径的两处配套

- `VodLibrary.adoptMany()`：生成目录的条目冷启动后不在 `_external`，适配器也没注册。批量挂进播放链路（只 `notify` 一次，逐条 `adoptResolved` 会让首屏重建上百次），`startPlayback` 才能按 `sourceId + mediaId` 找到地址；条目自带的 Referer/UA 在 `_headers` 为空时补上，避免一播 403。
- `_filteredFor` 的关键词池：列表条目不进 `VodLibrary`（60 万条 vs 1 万上限），若只取 `localMatches(q)` 的命中 id，输入关键词会得到「索引明明有片却一部都搜不到」。现在把 `vodMatches(i, q)` 的池内匹配并进 id 集合，仍是纯内存、不发网络。

### 63.8 五态之外：后台同步彻底让位

第十五次修给后台全量同步加了三道闸，这次它连启动机会都没有了：`_ensureDefaultSource` 先 `await vodIndexGate.settled`，`ready` / `needAddress` / `building` / `failed` 全部提前 return。理由不只是「省一次请求」：那条同步单次上限 1 万条、接口 147 万条（覆盖率 0.68%），每批重写 16 MB JSON，游标不持久化，冷启动从第 1 页重来 —— 转圈结构上永远不会停，而且它属于另一个来源。索引目录既然成了唯一来源，旧链路就该退场。

### 63.9 门禁与回归

`flutter analyze` 0 issue；**43 步 / 4321 断言**（上轮 42 / 4186，+1 步 +135 断言）。新增 `verify_vod_index_gate.dart`（132 项）：A 值对象 / B 三分支全转移 / C 提交两分支 / D 控制器全流程（零网络、生成失败、settled、异常兜底、`allowExternalCode` 透传）/ E 生成目录编解码（格式、坏行、去重、非法播放地址）/ F 等距采样（覆盖全片、续载不重复、前端编码）/ G 服务浏览入口（栏目隔离、缓存、同名归并、clearCache）/ H 接线静态护栏。

冻结前最后一轮修掉的四处（都靠探针 / 复核才发现，故产物重打了两次）：

1. `rebuild` 初版硬编码 `allowExternalCode: true`，会让设置页的开关失效 ⇒ 改为三参数签名，从 `readSettings()` 透传；门禁 D26 / H26 锁死。
2. 状态文案「60.5 万 条」多一个空格。
3. 六个栏目页共享同一个 gate，一次状态广播会把 6 个分片全解压 ⇒ `_onIndexGateChanged()` 开头 `if (!widget.active) return;`。
4. 采用 `generated` 时关键词检索仍查内置分片、换来源后旧命中残留 ⇒ `_runIndexSearch()` 改查 `vod-index.json` 的 `doc.inSection(section)`；`_resetIndexPool()` 同时清空 `_indexHits` 并 `_indexSeq++` 让在途结果作废。

旧断言 F14「点播页从可变片库取数」按项目惯例改写成四条新的等价强度断言（F14 / F14a–c），`third-party-vod` 152 项全绿。

### 63.10 明确不做的三件

1. **不在 App 内全量抓 147 万条**。打包侧脚本的事，见 63.6 能力边界。
2. **不合并两份索引**（内置 + 生成）。地址不一致时只采用一份，旧的那份不会作为「补充」留在列表里 —— 那正是「来源唯一」要防的。
3. **不改 `legacy/`**，不改播放参数，版本仍 `1.0.5+6`，未提交未推送。

### 63.11 未验证

- 真机（API18 / armv7a）未验：等距采样解 6 MB 分片的内存峰值、首屏 120 张卡的滚动帧率、生成目录条目点开即播的实测。本机无 adb，只做了静态确证 + Windows GUI 实测。
- 「地址不一致 → 重新生成」这条分支在 GUI 上只做了逻辑门禁回归（D09–D13），没有真用一个第三接口跑完整流程；`rebuild` 的 90 s 预算与 12 批上限是保守值。

### 63.12 最终产物与验收（16:17 出包 / 16:29 复验）

| 产物 | 字节 | sha256 |
|---|---|---|
| `dist/Shunbo-1.0.5-full.apk` | 51,412,138 | `59778307619a156626b2fb0b4178c896e37bba378ad88c140ce2a39cba07f5f4` |
| `dist/Shunbo-1.0.5-windows-x64-setup.exe` | 32,527,590 | `65fb99f997bc047daa7a148dcc3e35725d402da10676cfbf822f3ef7ffcc9895` |
| `dist/Shunbo-1.0.5-windows-x64-portable.zip` | 40,214,643 | `404a30e2c0c0919b1bcde3db4ef6d0ffe09372852ae6366562f4591f25a5a7f6` |

单包合并 24/24 断言通过。**最终这版 setup 已做静默覆盖安装复核**：`/VERYSILENT /SUPPRESSMSGBOXES /NORESTART` **EXITCODE 0**，日志 `Installation process succeeded / Need to restart Windows? No`（第十四次修补的两道防线生效）；`dist/windows/Shunbo-1.0.5` ↔ `D:\Programs\Shunbo` **38/38 逐字节一致**（缺失 0、不符 0），索引 7 分片 **6,634,112 B**，manifest `total=605106 / sections=6 / typeNames=523`；`data/app.so` 检出 `vod-index.json` / `VodIndexGatePhase` / `loadExisting` / `allowExternalCode` 与中文串「正在校验片源索引目录」「设定片源接口」（中文按 UTF-16LE）。GUI 复验：PID 1316 存活、55 线程、主窗口「顺播 shunbo」、工作集 1187.9 MB。出包用 `dist/windows/Shunbo-1.0.5.iss` 复验 `BOM=True / LF-only=0 / 119 行 CRLF`。

收尾记录：临时探针 `tooling/_tmp_gate_probe.dart` 已删；门禁在冻结源码上复跑仍是 **43 步 / 4321 断言、`flutter analyze` 0 issue**。版本仍 `1.0.5+6`，未提交未推送，`legacy/` 零改动。

> 交付提醒：`assets/vod_index/` 目前仍是未跟踪目录（本轮按纪律不提交）。将来提交时必须一并纳入，否则干净克隆打出的包会缺内置索引；`dist/windows/Shunbo-1.0.5.iss` 在 `dist/` 忽略范围内，长期出包应依赖 `tooling/` 下两份留档。

---

## §64 1.0.5 第十七次修：可见条目海报异步补齐 + 检索条件改目录级 + 统计数与手动刷新（2026-11-12 18:2x）

### 64.0 两张截图指向的两个问题

1. **列表卡片全是色块**：内置索引条目没有海报，屏幕上只剩一排蓝底播放图标。
2. **检索条件来自「当前 120 条」**：类型只剩 8 个词，地区 / 时间两行整行消失；条件还会随续载变化，属于「过期 / 不一致」。

用户随后补充：条件必须是**全索引目录**的；「全部」后面要带统计数据，并再加一个**手动刷新**入口。

### 64.1 海报为什么恒为空

第十六次修把播放列表改成索引片源后，条目由 `BuiltinIndexService.toItem()` 生成。精简索引每行只有「站点下标 + `vod_id` + 类目下标 + 片名」四段，**没有 `vod_pic`**，于是 `posterUrl` 恒为 `''`，`_Poster` 全部走色块兜底。

而采集站的 `?ac=detail&ids=` 本来就带 `vod_pic` —— 以前只在**点开详情**时才去取。所以缺的不是数据，是「什么时候取」。

### 64.2 只对可见条目异步取图

`vod_poster_service.dart`（纯 Dart，不引 Flutter / io，可在裸 `dart run` 下回归）：

* **只取可见条目**：请求由 `_Poster` 的 `initState` 发出，而网格是 `SliverChildBuilderDelegate` —— 只有进入视口（含 cacheExtent）的卡片才会被 build。翻页 / 续载天然触发新一批卡片请求，不需要手工算视口。
* **合并成批**：`request()` 同步入队，60 ms 窗口把同一帧出现的卡片攒成一批；每批最多 8 条、最多 3 批在途。装配层再按站点分组，一次 `?ac=detail&ids=a,b,c…`（每组 10 条封顶 ≈ 170 KB）取回多张，避免一屏几十个请求。
* **不阻塞渲染**：`request()` 同步返回，`fetchMany` 在后台跑；加载中 / 失败 / 无图一律立即画色块，条目文字与点击行为完全不变（`loadingBuilder` / `errorBuilder` 都回落到同一个 `_fallback()`）。
* **失败不反复重试**：空结果记进 `_dead`，卡片被回收重建也不会再发；命中率低的条目不会把滚动变成一串超时。

### 64.3 图片与条目怎么保证不串

缓存键是 `scope \u0000 item.id`。`scope` 由「最终采用的索引来源 + 接口地址 + 目录时间戳 + 条数 + manifest 总数」拼成（`gate.directoryStamp` + 其它维度），因此：

* **列表新增**只是多了新 id，旧图继续命中；
* **刷新**复用同 id，图不跳；
* **切换片源**（换接口 / 重新生成目录）⇒ scope 变 ⇒ `switchScope()` 清空缓存、`_generation++` 让在途批次回来时整批作废 —— 否则上一份索引的 `vod_id` 会把 A 站的海报贴到 B 站的片子上；
* 单条回填按 `hit.id`（含站点下标）：各站 `vod_id` 都从 1 开始，只按 `vod_id` 映射必然串图；
* 缓存上限 2000 条，超了整体清空（老图重取一次，好过无限增长拖垮低端盒子）。

### 64.4 检索条件：从「当前 120 条」改成「整份目录」

旧口径 `VodFacetsCache.of(revision, all)` 统计的是**当前已加载进列表的那 120 条**，再叠三层截断（`minCount=2` 丢长尾、`maxTypes=36`、UI `take(9)/take(18)`）。实测内置索引电影栏目有 **159,715 条 / 23 个类目名**，界面只能看到 8 个词；地区与时间两行更是整行消失（精简索引根本没有 `vod_area` / `vod_year` 两列），且不说明原因。

`vod_facet_directory.dart`（纯 Dart）改为：

* **两种来源都能出条件**：内置索引 `facetOptionsFromShard()` 解本栏目那一片，逐行读类目下标 → `typeNames` 映射中文名 → 计数（只累加 `int`，不建 60 万个对象）；生成目录 `facetOptionsFromItems()` 遍历 `vod-index.json` 该栏目的 `genre / typeName / area / year`。
* **完整覆盖**：`minCount = 1`、无 `maxTypes`、UI 不再 `take(9)`。只剔除「点了必然筛不出东西」的值（与 `vodTypesOf` 同一套取词口径，抽出共用函数 `vodTypeWordsFromLabel`），保证「列出来的条件」与「点下去能匹配的条件」是同一个集合。
* **变更同步**：缓存键 = `目录身份 \u0000 栏目`。目录一换就是新键，自动重载；旧条件里已不存在的选中值会被清掉并提示「目录已更新，原筛选条件中不存在的项已自动清除」——否则换接口后 `伦理片` 仍生效、列表一直空。
* **空 / 异常可见且不阻断**：五态 `idle / loading / ready / empty / error`。loading 写「正在从片源索引目录读取筛选条件…」、error 写失败原因、empty 分「目录未就绪」与「目录没有可筛字段」两种；三者都带一个「重试」，并且都明确写「列表与检索可继续使用」。缺维度时不是静默隐藏，而是写「本目录未提供地区 / 时间字段」。
* **六个栏目页共享**：`VodFacetDirectory` 按 `目录身份 × 栏目` 分键缓存，切栏目不会串条件。

### 64.5 「全部」后面的统计数 + 手动刷新

* **统计数**：`全部` tab 后紧跟一个弱化小字，取**本栏目整份目录的条数**（内置索引 = 该分片 `records`；生成目录 = `vod-index.json` 该栏目条目数）。这是唯一诚实的口径 —— 拿已加载的 120 条去显示会被当成「目录只有 120 部」。目录没就绪时**不显示**这个数，而不是显示 0。门禁 D22 反向锁死「不许 `_sectionTotal = _indexPool.length`」。
* **手动刷新**：同一行右端常驻「刷新」按钮（不随类型词横向滚走）。点击后依次：① `_syncFacetDirectory(force: true)` 重新统计条件（error / empty 也一起救回来）；② 重算目录条数；③ `_loadIndexPage(restart: true)` 按当前唯一来源重排首屏；④ `vodPosters.switchScope()` 让海报按新 scope 重取。刷新中按钮转圈并禁点，**旧列表继续显示**；成功 / 失败都在按钮下方一行明说，失败文案固定带「列表保持原样，可重试」。

为什么需要它：条件虽然会自动跟随目录身份，但「同一接口重新生成了一批片源」时**身份没变**，自动同步不会重算；这是用户唯一可控的「现在就重新读一遍」入口。

### 64.6 门禁与回归

`flutter analyze` **0 issue**；**44 步 / 4397 断言**（上轮 43 / 4321，+1 步 +76 断言）。

* 新增 `verify_vod_posters_facets.dart`（**76 项**）：A 目录选项（真实分片统计、类型名映射一致性、降级为空条件）/ B 条件目录五态与变更同步、`force` 重试、异常不外溢 / C 海报服务（批量、并发上限、按 scope 隔离、在途作废、失败不重试、缓存上限、监听只带变化键）/ D 接线静态护栏 D01–D24。
* 旧断言 `G11`「点播页使用可回归的纯 Dart 筛选」原本锁 `_facetsCache.of(`，与新需求冲突 ⇒ 按项目惯例改写成**等价强度**的新断言：仍是纯 Dart 过滤 + `localMatches(q)`，但条件改由 `vodFacetDirectory.catalogFor(` 提供，且不再从当前列表统计。
* `python-m0` 等 44 步全绿，耗时 130.9 s。

### 64.7 未验证

- 真机（API18 / armv7a）未验：一屏 120 张卡的**海报批量请求**在弱网下的实际耗时与内存峰值；`facetOptionsFromShard` 解 6 MB 分片的统计耗时（Windows 上单栏目 1–2 s 量级）。
- 生成目录分支的 `facetOptionsFromItems` 只做了逻辑门禁回归，没有在真实第三接口生成的目录上跑过四维全量统计。
- 「刷新」按钮在电视遥控器上的可达性沿用既有 `TextButton` 行为（与「展开」「重试」同一套焦点规则），未上真机逐项走查。

### 64.8 最终产物与验收（18:18 出包 / 18:21 复验）

| 产物 | 字节 | sha256 |
|---|---|---|
| `dist/Shunbo-1.0.5-full.apk` | 51,461,290 | `b61a18547de6b3424c5af47839b5bd5a9a9f112671a818aa878c9c80ca3b5ff4` |
| `dist/Shunbo-1.0.5-windows-x64-setup.exe` | 32,543,376 | `7d82e6b6dd4d2b73d64fbd3c9348febcc71983ab5269bcba467fb058717ae6e3` |
| `dist/Shunbo-1.0.5-windows-x64-portable.zip` | 40,237,048 | `569a3622760d16b519b55141ce036d477d65ae53930af0ba7b6c7052aecde0e3` |

清空重建后重打的（上一版 16:17 的三件已归档到 `dist/_prev/1.0.5-fix16/`）：

* 安卓 `build_android_apks.sh`：full 46,998,475 B / lite 27,878,040 B；单包合并 **24/24 断言**通过（`minSdk=16`、单 dex 原生类、三个 ijk `so` 只进 armeabi-v7a、v1+v2 双签、`assets/channels.json` 字节一致）。
* Windows：`flutter build windows --release` 49.4 s；`dist/windows/Shunbo-1.0.5` 由 Release 目录覆盖同步（VC143 运行库 DLL 保留），ISCC 编译 32.1 s。
* **覆盖安装实测**：`/VERYSILENT /SUPPRESSMSGBOXES /NORESTART` **EXITCODE 0**，日志 `Installation process succeeded / Need to restart Windows? No`；`dist/windows/Shunbo-1.0.5` ↔ `D:\Programs\Shunbo` **38/38 逐字节一致**（缺失 0 / 不符 0），索引 7 分片 **6,634,112 B**，manifest `total=605106 / sections=6 / typeNames=523`；`data/app.so` 检出中文串「全部」「刷新中」「检索条件已从片源索引目录载入」「已按索引目录重新载入检索条件与列表」（UTF-16LE）与 `_manualRefresh` / `VodPosterService` / `facetOptionsFromShard`。
* **GUI**：PID 30196、82 线程、主窗口「顺播 shunbo」、工作集 1038.3 MB；验完已结束进程。
* 安装前观察到 3 个残留 `shunbo.exe` 进程对象（线程 0 / 内存 0，`taskkill` 报拒绝访问），未阻塞覆盖安装（EXITCODE 0）—— 它们不持有 DLL 映像句柄，与第十四次修的 `code 5` 不是同一回事。

版本仍 `1.0.5+6`，未提交未推送，`legacy/` 零改动，未改播放参数。

### 64.9 用户红标收尾：去掉重复统计、去掉重复类型词（18:5x 二次重打）

截图红字三条：

1. 标题行「内置索引 · 已展示 480 / 60.5 万条」—— **统计去除，不用显示**。
2. 「全部」后面那排「剧情片 / 喜剧片 / 恐怖片 / 动作片 / 伦理片 / 爱情片 / 科幻片 / 战争片 / 理论片」—— **去除**。
3. 把**片源统计放在这边**（即原来那排类型词的位置）。

改法：

* `_countLabel()` 在 `vodIndexGate.ready` 时直接 `return ''`；`_titleBar()` 收到空串就连前置 `SizedBox(width: 12)` 一起省掉，标题右侧不留空档。非索引模式（外部目录 / 内置样例）的计数文案完全不动。
* `_typeTabs()` 不再拼 `['全部', ...facets.types]`，只渲染一个 `全部` + 目录级统计 + 右端刷新。删掉这排词不丢功能：下方「类型」整行本来就是 `facets.types` 的全量铺开（`_filtersExpanded` 默认 true、`typeLimit = facets.types.length`），而这排 tab 与它词表与语义完全重复。
* `全部` 这个 tab 保留：下方类型行是 toggle（再点一次才取消），长尾词选中后需要一个「一键清空类型筛选」的出口。
* 统计改成 `共 ${_bigCount(_sectionTotal)}条`，`_bigCount()` 去掉「万」前的空格 —— 否则会拼成「60.5 万 条」（十六次修踩过同一个坑）。
* 统计仍走目录口径（内置 = 分片 `records`，生成 = 文档条目数），目录未就绪时**不显示**而不是显示 0。

门禁：`flutter analyze` 0 issue；**44 步 / 4399 断言**（上轮 44 / 4397，+2）。`vod-posters-facets` 从 76 项增到 **78 项**：

* `D04` 改写：不再断言 tab 行拼 `facets.types`，改为断言「类型行按目录全量铺开」（`final typeLimit = _filtersExpanded ? facets.types.length : 18` + `facets.types.take(typeLimit).toList()`）。
* `D21` 改写：统计文案断言改为 `'共 ${_bigCount(_sectionTotal)}条'` + `_sectionTotal > 0 ?`。
* 新增 `D25`：标题行不再重复统计（`countText` 空串守卫 + `ready` 分支 `return ''`）。
* 新增 `D26`：切片 `_typeTabs()` 方法体断言只含 `_tabItem('全部'` + `_refreshAction()`、**不含** `facets.types`。

二次重打产物（上一版 18:18 的三件已归档到 `dist/_prev/1.0.5-fix17/`）：

| 产物 | 字节 | sha256 |
|---|---|---|
| `dist/Shunbo-1.0.5-full.apk` | 51,461,290 | `5b531b83a31553ebba05f74567eda2e533766e2df8cf8385d896abd79911460c` |
| `dist/Shunbo-1.0.5-windows-x64-setup.exe` | 32,542,472 | `38a715537b7c1d7642ac7ddda92577ae0c90b6dadddb935e185f876ea2ba2a92` |
| `dist/Shunbo-1.0.5-windows-x64-portable.zip` | 40,236,026 | `5a451dabe5405f71aa75532eceb92940e29fe8b550ff46ed670ba283ee4582cd` |

* 安卓 `build_android_apks.sh`：full 46,998,473 B / lite 27,878,041 B；单包合并 **24/24 断言**通过。
* **覆盖安装实测**：`/VERYSILENT /SUPPRESSMSGBOXES /NORESTART` **EXITCODE 0**，日志 `Installation process succeeded / Need to restart Windows? No`。安装前有一个**活着**的 `shunbo.exe`（49 线程）没被 `Stop-Process` 拿到，是 `[Code] PrepareToInstall` 里的 `taskkill /F /IM shunbo.exe` 兜住的 —— 第十四次修那道防线这轮真拦下了一次。
* `dist/windows/Shunbo-1.0.5` ↔ `D:/Programs/Shunbo` **38/38 逐字节一致**（缺失 0 / 不符 0），索引 7 分片 **6,634,112 B**，manifest `total=605106 / sections=6 / typeNames=523`。
* **GUI**：PID 21808、49 线程、主窗口「顺播 shunbo」、工作集 1036.9 MB；验完已结束进程。

版本仍 `1.0.5+6`，未提交未推送，`legacy/` 零改动，未改播放参数。

## §65 1.0.5 第十八次修：切栏目自动带图 + 分桶缓存 + 检索框数字键被吞（2026-11-12 19:0x）

两条需求：①在点播栏目之间切换时自动加载对应片源背景图并缓存，切回已访问过的栏目**无需重新加载**；②修复检索条无法输入数字（如搜「2020」年份）。

### 65.1 「切回来又闪一下色块」的两个原因

* **原因一：缓存被整体清空。** `VodPosterService.kCacheCap = 2000`，写入时只要 `_urls.length >= kCacheCap` 就 `_urls.clear()` + `_dead.clear()`。六个栏目各 120 张首屏，划两屏就撞上限；一撞就把**所有栏目**的图一起清掉 —— 切回去当然要重取。
* **原因二：切回栏目时列表被重灌。** `didUpdateWidget`（`active` 变 true）→ `_enterIndexGate()` → `gate.check()` 广播 → `_onIndexGateChanged()` 无条件 `_loadIndexPage(restart: true)` → `_resetIndexPool()` → 120 张卡全部重建。即便海报 URL 还在缓存里，卡片也要重建一遍、图也要重新贴。

### 65.2 分桶缓存：一个栏目一个桶

`vod_poster_service.dart` 的存储从「一张大 Map」改成 `Map<bucketId, _PosterBucket>`：

* 桶 ID = `目录身份 \u0000 栏目`（`bucketKeyOf(scope, group)`）。同一份目录下六个栏目各自一个桶。
* 写入超限时**只清本桶**（`kGroupCap = 600`，够 120 张 × 5 屏）。别的栏目一张不动。
* 桶数量上限 `kMaxGroups = 24`，超出按「最久未用」淘汰（`_PosterBucket.tick` + `_trimBuckets`）。被淘汰桶的在途批次结果直接丢弃，不会把桶重建回来挤掉别人。
* `switchScope(scope)` 的语义收窄：**只丢弃不属于新目录身份的桶**（`_buckets.removeWhere((id, _) => !id.startsWith('$newScope\u0000'))`）。同目录身份直接 `return` —— 切栏目时这个函数其实是空操作，所以「切回已访问栏目」必然命中缓存。
* `posterOf` / `isDead` / `request` 都加了可选 `group` 参数，默认 `''` 归一个匿名桶（回归脚本、详情页单图预览继续可用）。新增 `cachedCountOf(scope, group)` 供诊断与门禁。

页面侧：`_VodCard` 新增 `posterGroup`、`_Poster` 新增 `group`，一律传 `widget.section.name`；`_Poster.didUpdateWidget` 把 `old.group != widget.group` 也算作「需要重新对齐」。

### 65.3 切回栏目不重灌列表

`vod_page.dart` 新增 `_poolStamp` 与 `_poolMatchesCurrentSource()`：

```dart
bool _poolMatchesCurrentSource() {
  final gate = widget.services.vodIndexGate;
  return _poolStamp.isNotEmpty &&
      gate.ready &&
      _poolOrigin == gate.activeOrigin &&
      _poolSourceUrl == gate.lastUrl &&
      _poolStamp == gate.directoryStamp;
}
```

`_onIndexGateChanged()` 里 `if (!_poolMatchesCurrentSource()) unawaited(_loadIndexPage(restart: true));`。三条判据（来源枚举 / 接口地址 / 目录时间戳）都对得上就复用已有池子 —— 与 `_buildBrowse` 的来源唯一守卫是同一套口径，不会因此混来源。

`_loadIndexPage` 在 `batch.isEmpty`（该栏目目录里确实没内容）时也写这三个字段，否则「空栏目」每次广播都会再解压一次分片。

### 65.4 检索框输不进数字：直播页那个全局钩子

`ChannelNumberInput` 用的是 `HardwareKeyboard.instance.addHandler` —— **全局**钩子，不要求焦点。而它挂在 `LivePage` 的播放器舞台里，`LivePage` 又在 `IndexedStack` 里保活：**只要直播页曾经被打开过，这个 handler 就一直注册着**，跟当前是不是在点播页无关。

数字键被它吃掉后 `_digitOf` → `_buffer.addDigit` → `return true`。Windows 上 framework 回「已处理」后引擎不再 `TranslateMessage`，于是 `WM_CHAR` 不产生、`TextInputPlugin` 收不到字符 —— `TextField` 里「2020」只剩下无法输入。字母与中文走 IME，不受影响，所以症状正好是「只有数字打不进去」。

两处修：

1. `live_page.dart`：`ChannelNumberInput(controller: ..., enabled: widget.active, ...)` —— 只有直播页激活才接管数字键。
2. `channel_number_input.dart`：`_onKey` 第二行加 `if (_editingText) return false;`，`_editingText` 用 `FocusManager.instance.primaryFocus.context` 判断是否落在 `EditableText`（含祖先查找）。这是兜底：直播页将来加搜索框、设置页的数字输入框，都不会再被这个钩子抢。

检索框本身没有任何 `inputFormatters` 限制（`keyboardType` 也没设死），门禁 D31 反向锁死「不许加 `FilteringTextInputFormatter`」。

### 65.5 门禁与产物

`flutter analyze` 0 issue；**44 步 / 4413 断言**（上轮 44 / 4399，+14）。`vod-posters-facets` 78 → **92 项**：

* 新增 E 组（9 条，纯 Dart）：两栏目互不覆盖 / 分桶计数独立 / **切回命中缓存不发请求** / 同身份 `switchScope` 空操作 / 换片源才清 / 单栏目超限只清本桶 / 桶数上限与 LRU / 最新访问的栏目一定还在 / 在途批次不污染新身份。
* 新增 D27–D31（5 条，静态接线）：`posterGroup: widget.section.name`、`_poolMatchesCurrentSource()`、分桶 `removeWhere`、`enabled: widget.active` + `_editingText` 守卫、检索框不限字符。
* `D07` / `D08` 按新签名改写（`request(... group: ...)` / `posterOf(... group: ...)` / `old.group != widget.group`）；`C14` 的缓存上限断言从 `kCacheCap` 收紧到 `kGroupCap`。

产物（同名 `1.0.5+6`，上一版 19:0x 的三件归档到 `dist/_prev/1.0.5-fix17b/`）：

| 产物 | 字节 | sha256 |
|---|---|---|
| `dist/Shunbo-1.0.5-full.apk` | 51,461,290 | `390f1fe6302007d5eeb3ee03582beeace2ddd9443924c14fba86bea231b9d48e` |
| `dist/Shunbo-1.0.5-windows-x64-setup.exe` | 32,544,503 | `268edbf0f10842efe16f2158e38fe5e1542aad7bdbfcfbb65d186a053d27af34` |
| `dist/Shunbo-1.0.5-windows-x64-portable.zip` | 40,236,767 | `0ab12df6058219d676ec3365a42b09883cb46ead3a07f74822a6e37e885a2ea7` |

* 安卓：full 46,998,476 B / lite 27,878,043 B；单包合并 **24/24 断言**通过；`dist` 与 `build` 的 `libapp.so`（arm64 / armv7a）哈希一致。
* Windows：覆盖安装 `/VERYSILENT` **EXITCODE 0**；`dist/windows/Shunbo-1.0.5` ↔ `D:/Programs/Shunbo` **38/38 逐字节一致**；索引 7 分片 6,634,112 B；`data/app.so` 检出 `bucketKeyOf` / `_poolMatchesCurrentSource` / `_editingText` 与中文串「检索条件已从片源索引目录载入」。
* GUI：PID 24532、52 线程、窗口「顺播 shunbo」、1056.5 MB；验完已结束进程。

### 65.6 未验证

* 真机上「电影 → 电视剧 → 电影」来回切的观感（缓存命中率、`ImageCache` 淘汰后是否重解码）。
* 遥控器数字键在**直播页**仍走原逻辑，但 `enabled: widget.active` 改动后没有真机复验（原来只在电视形态验证过一次）。
* `_editingText` 依赖 `FocusManager.primaryFocus`，桌面上「点一下输入框但焦点还没落进去就立刻按数字」这种竞态没有覆盖。

版本仍 `1.0.5+6`，未提交未推送，`legacy/` 零改动，未改播放参数。

## §66 1.0.5 十九次修：全目录检索与筛选 + 条件维度补全 + 海报两处根因 + 点播起播慢（2026-11-12 21:5x）

这一轮五件事：①卡片海报仍不显示；②检索要在**当前栏目的整份目录**里查，不是只查已加载的那一屏；③按红标改掉刷新提示语；④可筛选条件太少；⑤点播播放时加载慢、播放卡顿，排查原因。

### 66.1 检索与筛选改为「整份栏目目录」

旧口径有两个隐性截断，都会让用户以为「搜不到 = 没有」：

* `BuiltinIndexService.search` 只做 `limit` 截断后返回 `List`，页面拿不到真实命中总数；
* 页面 `_indexHitsTotal` 取的是**本地已加载的那一池**长度，不是目录口径。

现在扫描器一次扫完整片，只为拿到真实 `total`：

```dart
BuiltinScanResult scan(String body, {required BuiltinIndexMatcher match, int limit})
// matcher: bool Function(String lowerName, BuiltinIndexLine line)
```

服务侧 `searchDetailed` / `filterSection` 返回 `BuiltinIndexSearchResult(hits, total)`；`search` 保留为 `.hits` 包装（不破坏既有调用）。检索词现在同时匹配**片名 / 年份 / 地区 / 类目名**——索引 v2 里这三列本来就有，之前只用片名。

页面侧筛选也改成整目录：`_facetHits` / `_facetHitsKey` / `_facetHitsTotal` / `_facetScanSeq` / `_facetScanScheduled`，build 里用 microtask 触发 `_runFacetScan`，`_mergeFacetHits` 合并后**整体重排**（不是把新命中的接到尾巴上）。`_indexHitLimit` 200 → 400。

### 66.2 去掉重复提示语（红标第三条）

「同一件事只许说一遍」这条在第十八次修里已经立过，这一轮继续收紧：

* `_gateRow()`：`ready` 且非 busy 直接 `SizedBox.shrink()` —— 「已加载内置片源索引目录 60.5 万条…」整行删除，信息已经在「全部」右侧的统计数里。
* `_facetStatus`：`ready` 时只有 `_facetResetNotice` 非空才显示，否则 shrink。原来那行「检索条件已从片源索引目录载入 · 共 N 个可筛选项」删除。
* `_refreshAction`：**成功不播报**，只有失败才留一行；文案固定「列表保持原样，可重试」。
* 删掉 `_missingFacetNote`（它和条件行里的「本目录未提供地区 / 时间字段」重复）。

### 66.3 可筛选条件太少：按原始类目名统计 + 索引升级 v2

**根因**：`facetOptionsFromShard` 把类目名先过一遍 `vodTypeWordsFromLabel` → `isNonGenreLabel`，而后者会把「国产剧 / 欧美剧 / 香港剧 / 日本剧」这类带地区后缀的类目判成「非体裁词」剔掉。电视剧 22 个类目只剩 10 个，用户看到的类型行当然短。

**改法**：类型行按**原始类目名**统计，不再剔。现状（v2 索引）：

| 栏目 | 类型数 | 地区 | 时间 |
|---|---|---|---|
| 电影 | 23 | 20 | 4 档 |
| 电视剧 | 22 | 20 | 4 档 |
| 短视频 | 28 | 20 | 4 档 |
| 动漫 | 16 | 20 | 4 档 |
| 其他 | 33 | 20 | 4 档 |
| 纪录片 | 2 | 20 | 4 档 |

地区与年份**索引里本来没有**，所以顺带把索引从 v1 升到 v2：

* 抓取切到 `?ac=detail`（带 `vod_area` / `vod_year`）：30,178 页 / 1,458,263 条 / 4,974 s。164 页在三次重试后仍被上游 502 —— 不阻塞，13 站页数全部抓满，打包侧 90% 阈值通过。
* 行格式 7 段：`站点 \t vod_id \t 类目下标 \t 前缀长度 \t 年份 \t 地区下标 \t 后缀`（后缀永远在最后，允许含 tab）。v1 的 5 段仍可解析，`format` 缺省按 1。
* 地区走 20 项规范词表（内地 / 中国香港 / 中国台湾 / 中国澳门 / 美国 / 韩国 / 日本 / 泰国 / 英国 / 法国 / 德国 / 印度 / 俄罗斯 / 加拿大 / 澳大利亚 / 新加坡 / 马来西亚 / 意大利 / 西班牙 / 其他），行内只存下标；别名映射 Python `AREA_ALIASES` 与 Dart `_kAreaAliases` 逐字镜像，门禁 F09 交叉校验。
* 脏值继续拦：「已完结 / 全80集 / 正片 / HD / BD / TC / 含数字 / 超长」一律不进地区列。
* 尺寸 6.31 MB → **7.23 MB / 602,413 条 / 6 片**。年份与地区覆盖：

| 栏目 | 年份覆盖 | 地区覆盖 |
|---|---|---|
| movies | 99.4% | 99.6% |
| series | 98.1% | 99.7% |
| documentaries | 99.5% | 99.0% |
| shortVideo | 92.4% | 75.4% |
| anime | 99.5% | 86.9% |
| other | 57.4% | 33.9% |

### 66.4 海报不显示：接口没问题，是「超时被当成没图」+ 图床不通

先把链路三段分别实测，避免又是靠猜：

1. **批量详情接口**：`?ac=detail&ids=<10 个>` —— dyttzy 32,931 B / bfzy 30,371 B，**10/10 全部带 `vod_pic`**。接口没问题。
2. **解析链路**：拿真实回包跑 `parseCmsDetails(..., baseUrl: site.api)`，dyttzy / bfzy 各 10 条**全部解析出海报地址**；`detailUrl` 十连只有 124 字符，不存在被截断。解析没问题。
3. **图片直链**（Dart `HttpClient`，`findProxy DIRECT`）：取 12 个站的样本各一条，9 通 3 断：

| 图床 | 结果 |
|---|---|
| `img.dytt-tupian.com` | 200 / 24 KB / 1.2 s |
| `p.bfvp26.com` | **时通时断**（一次 200 / 789 ms，另一次握手被中断） |
| `tyyswimg.com` / `www.imgzy360.com` / `www.mdzypic.com` / `image.huyajs.com` / `p.lztutu.com` | 200 / 0.7–1.9 s |
| `mtzy2.com` | 200 / 271 KB / 6.6 s（单张 271 KB） |
| `img.jisuimage.com` | 200 / 12 KB / 4.7 s |
| `xl.xltupian.com` | `SocketException` |
| `ok.zuidapic.com` / `pic.youkupic.com` | `HandshakeException`（TLS 被中断） |

**根因一（应用层，已修）**：批量取海报原来是 10 连 + 8 s 超时，超时与「这部片确实没图」共用同一个空结果 ⇒ `bucket.dead.add(key)` **永久判死**。而实测同一个 10 连请求 2.3 s 与 24.4 s 都出现过 —— 一次超时，那一批卡片此后永远不出图，来回切栏目也不重试。这就是「一屏全是色块」的直接原因。

**根因二（网络层，修不了）**：三家图床的 TLS / TCP 直接断，`p.bfvp26.com` 时断。这些卡片**再重试也不会有图**，只能回落色块。

修法：

* `fetchPosters`：10 连 → **4 连**（单批 ~170 KB → ~11 KB），超时 8 s → **12 s**，**站内多批并发**、**站间并发**（原来 `for (final entry in bySite.entries)` 是串行，8 张卡分属 8 个站要排 8 次队）。
* `VodPosterFetch` 回包从 `Map<String,String>` 改成 `VodPosterBatch{urls, failed}`：`failed` 是「网络 / 超时 / 解析异常没取到」，**允许重试**；只有「接口解析成功但这条确实没有图」才进 dead。
* 网络失败隔 1.2 s 重排一次（`kMaxRetry = 1`）。重试仍失败才 dead —— 有上限，不会把弱网拖长。
* 卡片**加载中**在色块右下角加一个细转圈（`_loadingFallback`）。图床实测 0.6–3 s、慢时 6.6 s，没有角标时「正在下载」和「根本没图」在屏幕上完全一样。
* 图片层 `_dead` 从 `Set` 改成 `Map<url, 时刻>`，**60 s 后允许再试一次**（`kPosterDeadTtl`）。`p.bfvp26.com` 是时通时断，永久记死意味着图床一恢复用户也看不到。

实测 4 连 vs 10 连（各 3 次）：

| 站 | 10 连 | 4 连 |
|---|---|---|
| dyttzy | 3.96 / 1.90 / 2.91 s（32,931 B） | 0.97 / 0.81 / 1.00 s（11,701 B） |
| bfzy | 3.44 / 1.21 / 2.16 s（30,371 B） | 1.29 / 3.46 / 1.26 s（10,820 B） |

### 66.5 点播起播慢 / 播放卡顿：实测定性

**详情回源**（点开一部片要等多久）：`?ac=detail&ids=<1 个>` bfzy 2.4–2.6 s、dyttzy 0.7 s。响应只有 3 KB —— 慢在服务端处理，不在传输。

**播放列表**：m3u8 ttfb 1.2–2.6 s / 35 KB，一个列表 7000+ 分片，路径是中文（`…/HD国语/`）。

**单分片**（决定卡不卡）：`.ts` 单片 404–529 KB，耗时 4.9–14.3 s；3 片并发实测吞吐 **≈ 50–100 KB/s**（`…/HD国语/0000000.ts` 14.3 s / 529 KB）。按每片 8 秒的播放时长算，需要 ~55 KB/s 才刚好不卡 —— 实际是**贴边甚至不够**。

**结论**：卡顿主因是**源站分片吞吐 + 中文路径重定向**，不是客户端缓冲配置。项目里也没有 `bufferForPlayback` / `LoadControl` 一类可调项，且纪律明确「不凭嫌疑改播放参数」，所以这一轮**不动任何播放参数**。

顺带确认一处「看起来像 bug 其实是对的」：dyttzy 的 `vod_play_url` 首源是 `/share/<hash>`（`text/html` 网页，2.7 s），`parseVodPlayUrl` 按「直链数最多的源」已经自动选了第二源 m3u8。逻辑正确；`/share/` 型地址本身无法派生直链，这是源站形态问题。

**客户端能改且已改的**：`_openDetail` 原来是阻塞的 —— `await vodBuiltin.resolve(hit)` 期间只把 `_busy` 置真，卡片不转圈、页面不跳，用户看到的是「点了没反应」。这段纯等待 0.7–2.6 s，就是「加载慢」的一半观感来源。见 66.6。

### 66.6 点开卡片不再干等：乐观进详情页

```dart
// 旧：先等回源，成功才进详情页
if (_busy) return;
setState(() => _busy = true);
resolved = await widget.services.vodBuiltin.resolve(hit);

// 新：立刻进详情页，回源在后台
final seq = ++_resolveSeq;
setState(() { _item = item; _view = _VodView.detail; _resolving = true; ... });
await _resolveInto(item, hit, seq);
```

* 详情页新增常驻条 `_resolveNotice`：`_resolving` 时是转圈 + 「正在获取播放地址…」；`_resolveError` 非空时是灰图标 + 原因 + 「重试」按钮。用常驻条而不是 SnackBar —— SnackBar 2 秒就走，用户还没看清就没了。
* 回源失败**不退回列表**，留在详情页给重试。退回去等于让用户重新找这部片。
* `_resolveSeq` 代次隔离：换片 / 重试 / 离开详情 / `dispose` 都自增，晚到的回包直接丢弃。
* `_resumeOrPlay` 加空剧集守卫：回源还没回来时剧集表是空的，`episodes.first` 会抛 `StateError`；按钮此时已置灰，但遥控器焦点可能还停在旧位置。

### 66.7 门禁

`flutter analyze` 0 issue；`dart run tooling/verify_all.dart` → **44 步 / 4444 断言全绿**（十八次修 44 / 4436，本轮 +8）：

* `H27` 点开内置条目先乐观进详情页（切 `_openDetail` 里不再出现 `vodBuiltin.resolve(`）
* `H28` 回源失败留在详情页并可重试
* `H29` 回源代次隔离 + 空剧集守卫
* `C11a` 网络失败先重试一次、不立刻判死；`C11b` 重试仍失败才 dead（有上限）
* `D38` 海报回源小批 4 连 + 12 s 超时 + 站内站间并发
* `D39` 回源区分「网络失败」与「确实没图」
* `D40` 卡片加载中给出「正在取图」角标

### 66.8 未验证

* 真机「一屏 120 卡」的实际出图率：本机无 adb，只在桌面与 `dart run` 层验证；弱网下的重试收益没有量化（只有单次耗时样本）。
* `p.bfvp26.com` 的时通时断是否会随网络环境变化；三家 TLS 被中断的图床没有替代源（同片源只存 2 条，可能属于不同站）。
* 播放卡顿只定性到「源站吞吐不足」，没有做「换源后对比」的 A/B —— 因为接口只提供一档清晰度，多源要改 `parseVodPlayUrl` 的选择策略，属于播放链路，需单独开一轮。
* `_facetHits` 在 6 MB 分片上的整片扫描耗时没有在真机上量过（桌面是几十毫秒级）。

## §67 1.0.5 第二十次修：播放页单出口、切栏目清搜索、类型/分类拆分、爱奇艺式海报网格（2026-11-13 09:3x）

这一轮五张截图、四条红标 + 一条排版意见：①播放页去「返回」「选集」，改「关闭」；②切栏目时搜索框恢复初始；③「去除」常驻刷新按钮；④「类型不对」；⑤每行卡片间距太宽，参考爱奇艺调整。

### 67.1 播放页：三个重叠出口收成一个「关闭」

`_topBar` 原来左侧一个 `IconButton(Icons.arrow_back_rounded, tooltip: '返回（Esc / 返回键）')`、右侧一个「选集」`TextButton.icon`，底部控制条还有选集与返回语义的按钮。电视上焦点在这几个入口之间来回跳，用户反而不知道该按哪个。

按红标：

* **删**左上角返回箭头（tooltip 那颗）；
* **删**右上角「选集」；
* **换成**右上角唯一的「关闭」按钮（`Icons.close_rounded` + `关闭`），点了停播并返回上一页。

```dart
void _closePlayback() {
  if (widget.fullscreen) widget.onToggleFullscreen();
  _leavePlaying();   // 停播 + _view = _item == null ? browse : detail
}
```

「返回上一页」= 进播放前的详情页（没有详情条目时直接回片库列表），与原有导航层级一致。`_showEpisodes` 浮层、选集抽屉、全屏状态都由 `_leavePlaying` 一并收掉，不会留一个抽屉在详情页上。**Esc / 物理返回键仍走 `_back()` 的分层返回**（先关选集 → 再退全屏 → 再退播放），不受按钮调整影响；底部控制条的「选集（M）」保留，选集能力没有丢。

### 67.2 切栏目时搜索框恢复初始

六个栏目页在 `IndexedStack` 里保活，各自持有自己的 `TextEditingController`。不主动清的话，在「电影」里搜了词、切到「电视剧」再切回来，输入框还挂着旧词，列表却是新栏目的 —— 看起来像筛选没生效。

`didUpdateWidget` 里按 `widget.active` 翻转触发 `_resetSearchOnSectionSwitch()`：

* 清 `_search.text` 与 `_query`（输入框回到 hint「搜索片源」）；
* `_indexSeq++` 作废在途的全目录检索、`_indexTimer?.cancel()` 取消防抖；
* 清 `_indexHits` / `_indexHitsQuery` / `_indexHitsTotal` / `_filterQuery`，旧栏目的命中不会拼进新列表。

这里**刻意不 setState**：`didUpdateWidget` 发生在父级 build 期间，`setState` 会触发 "setState() called during build"。`TextEditingController` 自身是 Listenable，改 text 会通知输入框重建；其余字段在紧接着的本组件 build 里生效。筛选项（类型 / 分类 / 地区 / 时间）保留，清的是检索词。

### 67.3 「去除」常驻刷新按钮

第十八次修加的「⟳ 刷新」按钮按红标去掉：一级条现在只剩「全部 + 共 N 条」统计。

手动重读目录的能力**没有删**，挪进 `_facetStatus` 的非就绪态（empty / error）：那一行的「重试」原来只调 `_syncFacetDirectory(force: true)`，现在改调完整的 `_manualRefresh()`（条件 + 条数 + 列表重排 + 海报缓存 scope 一起刷新），`_refreshing` 期间禁点并显示「处理中」。提示文案也去掉「刷新」字样，改成「重试失败：…（列表保持原样，可再试）」；成功仍静默。

### 67.4 「类型不对」：类型 / 分类拆成两个维度

**根因**：第十九次修为治「可筛选条件太少」，把 `facetOptionsFromShard` 从 `vodTypeWordsFromLabel`（会剔地区型类目）改回**按原始类目名原样统计**。电视剧那一行的结果就是截图里的一排「国产剧 / 欧美剧 / 香港剧 / 日本剧 / 韩国剧 / 日剧 / 韩剧 / 港剧 / 台剧 …」—— 这些是**地区 / 来源**，不是体裁，和下面「地区」行（20 项规范词）语义重复。

直接退回剔词又会把电视剧从 22 个条件砍到 3 个，和用户上一轮「条件太少」冲突。所以拆成两行：

| 行 | 口径 | 例 |
|---|---|---|
| **类型** | 类目名经 `vodTypeWordsFromLabel` 展开后的**体裁 / 题材词**（`isNonGenreLabel` 剔地区与纯体裁词） | 剧情片 / 喜剧片 / 反转爽剧 / 古装仙侠 / AI漫剧 |
| **分类** | 站点**原始类目名**，原样统计 | 国产剧 / 欧美剧 / 香港剧 / 日剧 / 内地剧 |

`VodFacets` / `VodFilter` 各加 `categories` / `category` 字段（参与 `isActive`、`activeCount`、`==`、`hashCode`、`copyWith`）；「全部」一键清空时带上 category；`_facetKey()` 与 `filterSection` 的缓存键都纳入 category；目录换掉后 `_onFacetDirectoryChanged` 也会清掉新目录里不存在的分类值。

过滤链路四处同源：`facetOptionsFromShard` / `facetOptionsFromItems` 统计，`applyVodFilter`（生成目录 / 本地条目按 `typeName` 精确比）、`BuiltinIndexService.filterSection`（内置索引按 `label == category` 比，类型改走 `vodTypeWordsFromLabel(label).contains(type)`）。

另外补了 `_kAreaCores` 的**单字地区简称**：`日 / 韩 / 港 / 台 / 泰 / 马泰 / 港澳`。采集站把「日本剧」简写成「日剧」，剥掉「剧」只剩一个字，原来的词表只有「日本 / 韩国 / 香港」等全称，第一轮改完类型行还留着「日剧 / 韩剧 / 港剧 / 台剧 / 马泰剧」—— 等于没修净。

真实随包目录（v2，602,413 条）实测：

| 栏目 | 类型 | 分类 | 地区 | 时间 |
|---|---|---|---|---|
| 电影 | 22 | 23 | 20 | 16 |
| 电视剧 | 3 | 22 | 20 | 16 |
| 纪录片 | 2 | 2 | 20 | 14 |
| 短视频 | 27 | 28 | 20 | 15 |
| 动漫 | 8 | 16 | 19 | 15 |
| 其他 | 28 | 33 | 19 | 14 |

电视剧的「类型」只剩 `反转爽剧 / 连续剧 / Netflix自制剧` —— 这不是截断，是数据事实：这些采集站给电视剧**只按地区分类**，没有体裁字段。用户熟悉的「国产剧 / 香港剧 / 日剧」完整留在紧邻的「分类」行，条件总量从 22 变成 3+22=25，**没变少**。电影 / 短视频 / 其他栏目本来就有体裁类目，类型行几乎不受影响。

### 67.5 海报网格：根因不是 spacing，是海报没撑满卡片

截图里一行 5 张竖版海报，每张只有约 90 px 宽、卡片槽位却有约 325 px —— 左右各空一大块，看起来就是「一行中间距太宽」。

真正的根因：`mainAxisExtent` 被钉死在 186，而 `_VodCard` 的 `Column` 用 `crossAxisAlignment.start`，给子节点的是**宽松宽度约束**；`Image.network` 只按「固定高度 × 图片宽高比」取宽，于是海报宽 ≈ 135 × 2/3 = 90 px，槽位剩下的全变成空白。光调 `crossAxisSpacing: 14 → 10` 完全治不了。

按爱奇艺的竖版网格重排：

* `_VodCard` 改 `crossAxisAlignment: CrossAxisAlignment.stretch`，海报**吃满卡片宽度**；
* `mainAxisExtent` 不再是常数，按槽位宽度反算：`posterHeight = (cardWidth - 8) * 1.5`，`mainAxisExtent = posterHeight + 47`（47 = 内边距 8 + 片名间距 6 + 片名 ~17 + 2 + 副标题 ~14），海报保持 2:3 不裁切；
* 列数各 +1（≥1100: 5→6、≥820: 4→5、≥560: 3→4、否则 2→3），`crossAxisSpacing` / `mainAxisSpacing` 14 → 10，卡片内 padding 6 → 4，海报与片名间距 8 → 6。

以 1920 窗口、内容宽 1720 为例：6 列时 cardWidth ≈ 272 px，海报约 264 × 396 px（旧版 90 × 135 px），横向空白从约 235 px 降到 10 px。代价是一屏行数从 4–5 行变成 2–3 行 —— 这是爱奇艺 TV / PC 首页大卡片的同一取舍。

### 67.6 门禁

`flutter analyze` 0 issue；`dart run tooling/verify_all.dart` → **44 步 / 4460 断言全绿**（十九次修 44/4444，本轮 +16）。

* `vod-posters-facets` 107 → **121**：A07/A07b 改口径、A07f 分类维度、A09c/A09c3 真实目录两行、A09f 电视剧真实分片（国产剧 / 日剧只在分类行）；D24/D26/D33/D37 按新口径反向锁死；新增 D41–D51 逐条钉死五条红标（播放页单出口、关闭停播、切栏目清搜索、作废在途检索、无常驻刷新、类型/分类双维度、classification 贯通、海报撑满与间距）。
* `vod-playback` 193 → **195**：E02 改为「无顶栏返回箭头 + 单出口关闭」、F25 改为五维度、新增 F28/F29（分类有数据支撑 / 单字地区简称已剔）。

### 67.7 未验证 / 口径说明

* 图 3 的红标按「**去掉整个常驻刷新按钮**」处理（红字「去除」写在该按钮左侧空白）。若本意只是去掉「刷新」两字、保留圆形箭头图标，一句话即可改回。
* 大卡片的行数取舍（一屏 2–3 行）只做了桌面静态核对，真机遥控器的翻页手感、120 卡首屏帧率未量。
* 「分类 / 类型」双维度在**生成目录**（`vod-index.json`）下只到 `dart run` 层验证，没有真机走一遍异址 rebuild。
* 关闭按钮在**全屏 + 选集浮层同时打开**时的叠加态未上真机；代码路径是全屏先退、`_leavePlaying` 再收浮层。

## §68 1.0.5 第二十一次修：设置-点播源模块收敛 + 独立索引 + 24 小时增量更新（2026-11-13 10:4x）

这一轮只动「设置-点播源」这一个模块，四条需求：①界面只留一个第三方片源接口地址输入框，输入完成后自动获取索引并按默认索引的存储方式落本地，保留「地址与默认索引一致 ⇒ 直接复用默认记录、不重复获取」，新接口索引独立存放、不影响默认记录；②排查是否已具备自动获取最新片源，没有就加定时更新（周期明确、追加合并去重、不全量重取）；③新增手动获取入口，同样追加、不影响默认索引；④与现有获取/判断/存储逻辑兼容，界面简洁。

### 68.1 先排查：改之前**没有**定时自动更新

容易被名字误导的是 `VodAutoSource`。它的 `ensureLoaded()` 四个前置条件是「开关已开 + 选中的正好是默认源 + 片库里还没有外部条目 + 本进程没试过」，`_pending` 一旦赋值就固化，成功不再跑、失败也不重试，注释里明写「不重试」。它回答的是「第一次进栏目把片库填上」，不是「过一天把最新片源补进来」。`VodBootController` 同理，只在冷启动校验时跑一次，且判据是「内置索引能不能拿来检索」。全项目在改动前没有任何 `Timer.periodic` 与片源目录有关。

所以本轮新增的是真正的定时更新，周期按主流聚合播放器（TVBox / 影视仓一类）的通行做法明确设为 **24 小时**：片源站本身按天更新，小时级轮询只给接口添堵、给电视端添耗电，周级又让「今天上的片」要等一周。

### 68.2 界面：从「三个开关 + 七条候选 + 三个按钮」收敛成一个输入框

截图里的旧界面：三个 `SwitchListTile`（启用自定义地址 / 允许执行外部代码 / 允许明文 http）、「候选地址」七条单选（含两条禁用）、「我添加的地址」列表、一个 `TextField`、以及「添加并使用 / 应用当前地址 / 恢复默认」三个按钮。这些控件互相牵连（先开开关 → 再选候选 → 再点确认），电视遥控器上根本走不完。

现在只剩：

* **一个** `TextField`（「第三方片源接口地址（输入完成后自动获取）」），默认留空、不回填当前地址；
* 一行状态（当前生效地址 / 输入地址实时校验 / 提交结果）；
* **一个**「立即获取最新片源」按钮；
* 一行说明（24 小时周期、追加去重、默认索引独立、下次进入点播生效）。

底层一个没删：`enabled` / `allowInsecureHttp` / `allowExternalCode` / `customUrls` 等设定字段继续沿用；明文 http 仍需一次显式确认（确认动作本身即放行，界面上不再摆开关）；风险声明 `disclaimerAccepted` 检查保留；已知不可用地址仍在提交前拦下。

### 68.3 输入完成后自动获取，判断逻辑原样保留

回车（`onSubmitted`）或输入框失焦（`FocusNode` listener）即触发 `_submitAddress()`，同一地址不重复提交（文本变化或提交失败才允许重试）。提交交给**既有闸门**：

```dart
final verdict = await services.vodIndexGate.submit(raw, allowInsecureHttp: insecure);
```

`decideVodIndexSubmit` 的三条判据一个字没改：

| 填写地址 | 动作 |
|---|---|
| 与随包默认索引记录的 `sourceUrl` 一致 | `loadExisting` → `builtin`，**零网络直接复用默认记录** |
| 该地址已有独立目录文件 | `loadExisting` → `generated`，直接加载，不重复获取 |
| 其余 | `rebuild`，按地址取片源 → 生成该地址专属目录 → 重跑校验 |

另在 `rebuild` 装配里加了一道**双保险**：`if (!vodIndexStore.isIndependentSource(url)) return null;` —— 默认地址即便被别的路径绕过来，也不取数、不写盘。

### 68.4 独立存放：默认记录只读，旧文件兼容

之前所有新接口共用 `vod-index.json`，换一次地址就把上一份覆盖，切回去只能全量重抓。现在：

```dart
vodIndexFileForUrl(url) → 'vod-index-<FNV1a32(url)>.json'
```

* 文件名是纯函数派生的 8 位十六进制摘要，URL 里的 `://`、端口、查询串不会进文件名；同一地址恒得同一文件，不同地址互不覆盖；
* **默认片源索引地址永不派生文件名**：`fileFor()` 返回 null，`saveFor()` 直接抛错，`appendFor()` 返回 skipped，`save()` 也有守卫 —— 运行期数据没有任何路径能覆盖随包的 `assets/vod_index/`；
* 旧版 `vod-index.json` 降级为**只读兼容**：仅当它记录的 `sourceUrl` 与当前地址逐字一致时才会被读到，追加写盘一律写进新地址自己的派生文件（旧文件原样保留）；
* `readGenerated` 改为 `snapshotFor(当前设定的 effectiveUrl)`，闸门读到的永远是**当前地址对应的那份**，不会拿上一任接口的目录去判「地址不一致」而反复重建；
* 点播页原来 5 处直读 `vodIndexStore.load()` 统一收成 `_generatedIndexDoc()` → `loadFor(gate.lastUrl)`，列表 / 全目录检索 / 条件扫描 / 条数统计 / 可筛项统计全部跟着切到独立文件。

### 68.5 追加合并去重 + 只取最新一页

* `mergeVodIndexItems(existing, incoming)`：按 `VodItem.id` 去重（与 `decodeVodIndexDocument` 同口径），旧条目在前、新条目追加在后，顺序稳定；返回 `added / duplicates / total`。
* `appendFor(url, items)`：读该地址现有目录 → 合并 → `generatedAt` 更新为当前 UTC → `.tmp` + rename 原子写回**该地址自己的文件**；写入侧加了 `kMaxVodLibraryBytes`（72 MB）体积护栏，目录不会无限膨胀。
* 取数走新增的 `fetchLatestVodIndexItems()`：`ThirdPartyVodService.open()` 建分页器后，轮转若干批 `pager.next()` 把「每个采集站的第 1 页」覆盖到（CMS 的 `?ac=detail&pg=1` 按更新时间倒序），**绝不翻第 2 页**；批次上限 20、预算 90 秒、站点上限 100。对契约 JSON 则用一次给全的 `contractItems`。全程不碰 `VodLibrary` / `VodSession`，不会改播放列表、不会换源。

这与 `rebuild` 的「12 批 / 90 秒生成整份目录」是两条不同口径：初次接入才全量生成，之后的定时 / 手动更新只追加最新一批。

### 68.6 24 小时定时更新与手动入口

`VodIndexAutoUpdater`（纯逻辑，IO 全注入）：

* `kVodIndexUpdateInterval = Duration(hours: 24)`；首帧校验完成后 `start()` 先补一次，再 `Timer.periodic` 每 24 小时触发；
* 上次成功时间落 `config.json` 的 `vod-index-last-update` 键，重启不会把周期重置成「立刻又跑」；`shouldUpdate(last, now)` 用 `now - last >= interval` 判定，从没成功过时允许立即跑；
* **让位**：跑之前 `await vodBoot.settled` → `await vodIndexGate.settled`；未设定接口 / 外部地址关闭 / 默认地址一律提前 return；
* **单飞**：`_running` 挡住定时器与手动点击并发；
* 取数返回空或写盘失败**不写时间戳**，下次定时器还会重试；
* 只写盘、不 `gate.check()` —— 用户看片时不会把播放列表清掉，新片源在下次进入点播时生效（闸门 `checking` 会触发 `_resetIndexPool()` 清掉内存里的旧文档缓存）。

设置页「立即获取最新片源」= `runOnce(force: true)`：`force` 只跳过周期判断，**让位 / 单飞 / 默认地址只读三道闸照旧生效**，且与定时更新共用同一个 `appendFor` 写入函数。

### 68.7 门禁

`flutter analyze` 0 issue；`dart run tooling/verify_all.dart` 全绿（详见 CHECKLIST 五十六）。

* `vod-index-gate` 新增 `testSourceModule()` 一组 **34 条**纯函数 / 临时目录 IO / 调度器回归：文件名派生、默认地址只读、按 id 合并去重、两地址互不覆盖、旧单文件兼容、24 小时周期边界、让位、单飞、失败不写时间戳、默认地址跳过；H 组新增 H30–H42 十三条静态反向锁死（单输入框、无开关/候选、自动提交、明文确认、周期常量、让位、按地址读、独立写盘）。
* `vod-source-address` G04–G06c 按新口径改写 + G15–G20 六条新断言；`third-party-vod` F10/F12/F13 系列与 G15/G16 改写；`vod-playback` C15/C16 改写。旧断言锁的是被删掉的控件结构，改写后约束等价或更强（例如「候选列表已彻底移除」「默认地址写盘层双保险」），没有放宽。
* **44 步不变**，断言总数只增：上轮 4460 → 本轮 **4513**（+53）。

三件产物（同版重打，版本仍 1.0.5+6）：APK 52,444,330 B `900cc76b…74150f6`（full 47,981,692 / lite 28,861,258，单包 24/24）；setup 33,514,352 B `2b01d8eb…cd16b315`；portable 41,359,583 B / 38 文件 `ac80642e…a7ed3078`。静默覆盖安装 EXITCODE 0，`dist` ↔ `D:/Programs/Shunbo` 38/38 逐字节一致；AOT 检出 `_generatedIndexDoc` / `mergeVodIndexItems` / `VodIndexAutoUpdater` / `vodIndexFileForUrl` / `isIndependentSource` / `_submitAddress` 各 1（`_pickCandidate` / `kVodSourceCandidates` 为 0），UTF-16LE 命中「立即获取最新片源」「第三方片源接口地址」。

### 68.8 未验证 / 口径说明

* 24 小时周期是**运行期定时器**，没有做「关掉 App 三天后冷启动」的真机长时观测；逻辑上由落盘时间戳覆盖，但只到 `dart run` 层。
* 增量取数只取「各站第 1 页」，若某采集站把新片插在旧页（不按更新时间倒序），那批片源要等下次全量接入才会出现 —— 这是「不全量重取」的代价，实测的苹果 CMS 默认按 `vod_time` 倒序。
* 追加写盘每次都要重新编码整份目录；生成目录来自 `VodSession` 的 12 批（几千条），体量远小于 72 MB 护栏，但**百万级生成目录下的写盘耗时未量**。
* 新片源「下次进入点播生效」是有意为之：更新不打断当前播放列表。若用户一直停在同一页不离开，需要切走再回来才看得到。
* 手动入口与输入框失焦同时触发时，输入框的提交优先（按钮此时禁用），需要等提交完成再点一次；不会并发写盘。

## §69 1.0.5 第二十二次修：点片直接播 + 播放页右栏详情 + 8 秒自动收缩（2026-11-13 11:1x）

用户贴了一张详情页截图（「一千灵异夜之孽债危情」+「从头播放」），要求：**选中片源后跳过中间详情页，直接进播放页开始播**；影片介绍搬到播放页**右栏**；右栏无操作达到设定超时后**自动收缩**，交互时重新展开或刷新计时。并要求把这三点说清楚。

### 69.1 触发条件：只有「点卡片」这一条

| 项 | 结论 |
|---|---|
| 触发 | 用户在点播列表里**点击 / 遥控器确认某张卡片**（`_VodCard.onTap` → `_openAndPlay`） |
| 不触发 | 换集（控制条「选集」/ M 键 / 上一集下一集）只在播放页内部换源，不重新进页 |
| 防重入 | `_busy \|\| _resolving` 为真时直接 return（连点 / 连按 OK 不会起两次播） |
| 视图 | `_VodView` 从三态收敛成 **browse / playing** 两态，`detail` 与 `_buildDetail()` 整体删除 |

两条起播路径，都在**切到播放视图之后**才做耗时动作（乐观进页）：

1. **内置索引命中**（只有片名 + `vod_id`，没有剧集表）：立刻 `_view = playing`、遮罩显示「正在载入…」，后台调 `vodBuiltin.resolve()` 回源 → 取续播记录 → `_play()`。回源失败的**不停留在半路**，而是在右栏给出原因 + 「重试」（`_retryOpen`），不退回列表。
2. **已有完整条目**（网络同步来的，自带剧集表）：取一次续播记录后直接 `_play()`。

续播规则原样保留：有记录从记录点继续、已看完进下一集、无记录从头播。

### 69.2 右栏内容：来源与展示形式

**加载来源**：全部来自已经在内存里的 `VodItem`（回源后的完整条目）—— 没有新增任何网络请求。

| 区域 | 内容 | 来源字段 |
|---|---|---|
| 顶部 | 「详情」标题 + 收起按钮 | 常量 |
| 海报 | 16:9，走既有 `_Poster`（异步后端补图、失败回落色块） | `item.poster` / 海报服务 |
| 标题 | 最多两行，超出省略 | `item.title` |
| 类型行 | 「暴风资源 · 恐怖片」这类 | `item.subtitle` |
| 状态行 | 正在获取播放地址 / 取不到 + 重试 / 上次看到第 N 集 mm:ss | `_resolving` / `_resolveError` / `_resume` |
| 简介 | 正文，行高 1.65，可滚动 | `item.description` |
| 授权说明 | 小字灰 | `item.license` |

**展示形式**：右侧浮层，宽度按视口 32% 取、夹在 **340–440 px**（`vodDetailWidth`），黑底 84% 不透明 + 左侧 1 px 分隔线，内容可滚动（底部留 120 px 给控制条）。

**关键取舍：右栏覆盖画面，不缩小 `PlayerStage`**。改播放器的渲染几何会连带触发解码器/渲染面重建，切来切去最容易黑屏一帧；右栏是信息层，浮在上面最稳。

z 序上右栏排在**控制层下面**：顶栏的「关闭」与底部控制条压在它上面，所以进度条末端不会被面板挡住。

### 69.3 超时时长与收缩后的行为

* **时长 8 秒**（`kVodDetailIdleTimeout`）。不是抄控制条的 4 秒：4 秒是「按完按钮让出画面」，而详情是**读**——标题、类型、两行简介，8 秒刚够读完一遍。主流播放器的信息层（Netflix info、Plex 侧栏、爱奇艺桌面端）都在 5–10 秒，取中间偏长的一档。
* **进入播放页即展开**（详情页没了，进来不该是空的），并开始第一段 8 秒计时。
* **交互即展开 / 重置**：
  * 指针移到右栏、在右栏里滚动、点右栏任何位置 → 保持展开并重置 8 秒；
  * 点画面切换控制条、按音量键、快进快退、换集 → 若右栏开着，同样重置 8 秒（`_pokeControls` 里联动）；
  * 按 **I / D / 信息键** → toggle 展开/收起（遥控器没有鼠标，不给键位就等于「收起后再也要不回来」）。
* **收缩后**：右侧留一条 **44 px** 窄条（`Icons.info_outline` + 竖排「详情」），不是整个消失 —— 否则用户不知道还能拉出来。点窄条、指针移上去、按 I/D 都能重新展开。
* **不该收缩的两个时刻**：`_resolving`（正在取播放地址）与 `_resolveError != null`（取不到）时**不启动计时**，并把面板强制展开 —— 那是用户必须看见的状态，缩成窄条等于把「为什么没画面」藏起来。
* **唯一不改状态的输入**：点画面别处（`pointerElsewhere`）只刷新计时。控制条收起时用户会点画面，那一下不该把刚收起的详情又弹出来。

状态转移抽成纯函数 `vodDetailExpandedAfter(expanded, input)`（`VodDetailInput` 七种输入），`dart run` 可穷举回归。

### 69.4 顺带修掉的东西

* 删掉 `_VodView.detail` 后，`_back()` 的分层返回从三层变两层：选集浮层 → 全屏 → 播放页回列表。物理返回键与 Esc 行为不变。
* `_leavePlaying()` 现在回 `browse` 并 `_item = null`，同时**作废在途回源**（`_resolveSeq++`）—— 不回源作废的话，晚到的回包会接着调 `_resumeOrPlay`，表现是「已经从播放页退回列表，列表上莫名其妙开始放片」。
* `_resumeOrPlay()` 遇到空剧集不再静默 return，改为在右栏给「这个片源没有可播放的剧集」。
* `_play()` 的失败提示从 SnackBar 改到右栏（同一件事不说两遍，且 SnackBar 2 秒就走，用户看不清原因）。
* 详情页删除后 `_EpisodeChip`（详情页的选集按钮）无人引用，按 analyze 的 `unused_element` 一并删除；选集仍可从控制条「选集（M）」进。

### 69.5 门禁

`flutter analyze` 0 issue；`dart run tooling/verify_all.dart` 全绿（详见 CHECKLIST 五十七）。

* `vod-playback` 195 → **212**：新增 `testDetailPanel()` 一组 17 条 —— 8 秒与 4 秒相互独立、宽度三档夹取（1280 → 409.6 / 3840 → 440 / 800 → 340 / 0 与 NaN 兜底）、窄条 44 px、状态机七种输入穷举、右栏内容五要素、z 序在控制层之下、窄条可点可 hover、I/D/Info 键位、计时器取消、取地址中不收缩。
* `vod-index-gate` H27–H29 按新口径改写：不再要求 `_view = _VodView.detail`，改为「点卡片直连 `playing`」「`_VodView.detail` 与 `_buildDetail()` 在整个页面文件里都不存在」「`_retryOpen` 取代 `_retryResolve`」。
* `vod-playback` E10 / I04 改写：`_leavePlaying` 回 `browse`，并锁死 `_VodView.detail` 已消失。

三件产物（同版重打，版本仍 1.0.5+6）：APK 52,460,714 B `61cfaee5…0ed95`（full 47,997,737 / lite 28,877,312，单包 24/24）；setup 33,515,646 B `90f6804e…dd46b`；portable 41,366,217 B / 38 文件 `c516c944…8650f`。静默覆盖安装 EXITCODE 0，`dist` ↔ `D:/Programs/Shunbo` 38/38 逐字节一致；AOT 检出 `_openAndPlay` / `_playResolved` / `_detailPanel` / `_detailRail` / `_detailBody` / `_detailStatus` / `_toggleDetail` / `_pokeDetail` / `vodDetailWidth` 各 1，`VodDetailInput` 2，已删的 `_openDetail` / `_buildDetail` / `_retryResolve` / `_EpisodeChip` 全 0；UTF-16LE 命中「详情」「收起详情」「正在获取播放地址…」「上次看到」「播放失败：」「这个片源没有可播放的剧集」。

### 69.6 未验证

* 右栏滑入（`AnimatedPositioned` 180 ms）在 120 卡网格与 4K 窗口下的实际帧率未测。
* 遥控器上「信息键」的 `debugName` 各家盒子不同（`Info` / `Guide` / `KeyI` 都收，但真机未逐台验证）；字母键 I/D 在有输入焦点的场景不存在（播放页无输入框）。
* 8 秒是否舒服只在桌面鼠标下试过；电视端「读完简介要多久」缺真机主观验证 —— 改一个常量即可调。
* 右栏覆盖区在 1:2.35 超宽片源下会不会压住字幕（字幕位置由内核/设置决定），未实测。

## §70 1.0.5 第二十三次修：设置页去说明行 + 默认接口真能追加 + 筛选去「分类」/ 类型照爱奇艺 + 右栏悬停伸缩（2026-11-13 11:4x）

三张截图、四条红标。逐条如下。

### 70.1 设置-点播源：删掉说明行

* 输入框下那行 `helperText`（「默认留空，不回填当前地址；与默认索引地址一致时直接复用默认记录」）**整行删除**。下一行的状态行本来就写着「当前生效：…」，再挂一行解释只是噪音，还把这一格撑高。
* 门禁 `G14` / `H43` 反向锁死：`helperText` 与那句文案都不许回来（输入框仍不预填地址）。

### 70.2 「立即获取最新片源」对默认接口也必须真的取数

用户红标原文：「只要立即获取最新片源，这边就要追加方式去获取一遍，不是只读不能获取」。

改之前 `VodIndexAutoUpdater.runOnce()` 里有这一段：

```dart
if (isDefaultSource(settings.url)) {
  return skipped('默认片源索引随包只读，无需更新');
}
```

也就是说按钮在默认接口下**一次网络都不发**，只回一句「无需更新」——把「不实现」说成了「不需要」。现在的分工：

| 接口 | 随包索引 | 追加写哪里 | 谁读 |
|---|---|---|---|
| 默认接口 | 一个字节不动 | `vod-index-<hash>.json`（`appendFor` → `supplementFileFor`） | `loadSupplementFor(url)` |
| 自填接口 | — | `vod-index-<hash>.json`（整份目录，可重写可追加） | `loadFor(url)` |

两条红线都还在：

* **`fileFor(default)` 仍返回 null、`saveFor(default)` 仍抛错** —— 默认地址永远不能整份重写；
* **`loadFor(default)` 仍返回 null** —— 闸门读不到增补文件，所以 `decideVodIndexSubmit` 的三判据一点没变，不会误判成「默认目录被替换了」。

点播页把这批增补并进五处（`builtin` 分支才有意义）：

| 位置 | 做法 |
|---|---|
| 浏览首屏 | `_indexPage == 0` 时把增补条目排在整批目录**最前面**（它们就是各站最新一页），并按片名与本批去重；`adoptMany` 挂进 `VodLibrary` 否则点不开 |
| 关键词检索 | 追加 `filterVodItems(extra, q)` 的命中，总数相加 |
| 目录级筛选 | 追加 `applyVodFilter(extra, f)` 的命中，总数相加 |
| 筛选条件 | `mergeVodFacets(分片统计, facetOptionsFromItems(增补))`，类型计数相加、地区去重、时间重排 |
| 条数 | 「共 N 条」= 分片 records + 增补条数 |

`isDefaultSource` 这个注入点整个删掉了：调度器不再需要知道「谁是默认地址」，地址分流下沉到存储层。

**一个坑（首轮产物打完后自查发现，三件产物因此重打）**：增补目录的读取不能用 `bool _supplementLoaded` 这类标记。筛选条件统计与「共 N 条」在同一帧里各调一次 `_supplementItems()`，第二次进来时第一次的 `await` 还没回来，标记若是「已发起」就直接返回空列表 —— 上层把空当成结果统计，条件行与条数永久显示成 0（不崩、不报错，只是「新片源像没同步」）。现改成：

```dart
Future<List<VodItem>>? _supplementFuture;
// _supplementItems() 里：return _supplementFuture ??= _readSupplementItems();
```

存 Future 而不是存结果标记：同帧两次调用拿到的是**同一个** Future，既不会重复读盘，也不会把「还没读完」误当成「读完了」；`_resetIndexPool()` 里置 null 即可重读。

### 70.3 筛选条件：删「分类」整行，类型改爱奇艺固定词表

* `VodFacets.categories` / `VodFilter.category` / `_filter.category` / `filterSection(category: …)` / 分类行 UI **全部删除**。上一版为了让条件数变多把站点原始类目名单列一行，那一行既不是用户理解的类型，又和「类型」「地区」语义重叠。
* 类型行改成固定词表 `kVodGenreVocabulary`（33 词，顺序即界面顺序）：

```
喜剧 动画 动作 爱情 恐怖 战争 惊悚 枪战 科幻 犯罪 悬疑 奇幻 剧情
青春 冒险 家庭 少儿 警匪 历史 武侠 伦理 灾难 传记 运动 音乐 魔幻
歌舞 戏曲 玄幻 悲剧 史诗 西部 其他
```

* **归一才是关键**：采集站写「剧情片 / 动作片」，词表写「剧情 / 动作」。`vodGenreKeyOf()` 剥掉体裁后缀（`_kFormSuffixes`，长的先剥）再查词表；查不到就返回 `''` —— `4K电影` → `4K`、`Netflix电影` → `Netflix`、`邵氏电影` → `邵氏`、`欧美剧` → `欧美` 都不在词表里，于是不进类型行。这正是用户红标的「类型不对」。
* 顺序**不按命中数排**：词表顺序是认知习惯，不该因为某个词片多就跳到最前面。所以 `VodFacets` 内部存的是 `typeCounts`（词 → 计数），`types` 是从词表筛出「有片」的词组成的 getter。
* 代价（有意）：电视剧类目名基本是 `国产剧 / 日剧 / 香港剧`，归一后都不在词表里 ⇒ 电视剧的**类型行会是空的**，只剩地区 / 时间 / 排序。这比列一排「XX剧」诚实；用户给的参考图里也没有这种词。
* 筛选口径跟着改：`applyVodFilter` 走 `vodGenreKeysOfItem(it).contains(type)`（`genre` 优先、缺失回落 `typeName`，再归一），`filterSection` 走 `vodGenreKeysOf(label)`，两条路径同一套判据，所以「点下去一定能筛到」。

### 70.4 播放页右栏：像左栏那样悬停伸缩、同透明度、去掉收缩按钮

| 项 | 左栏（`_buildSideBarOverlay`） | 右栏（改后） |
|---|---|---|
| 展开 | 指针进栏 / 边缘热区 | `onEnter` → 展开 |
| 收缩 | `onExit` + 1.2 s（`_scheduleSideHide`） | `onExit` → 1.2 s（`kVodDetailHoverExitDelay`） |
| 指针停在栏上 | 取消计时 | 取消计时（`_detailHovering`） |
| 兜底 | 唤出后 6 s | 进播放页后 8 s（`kVodDetailIdleTimeout`，遥控器 / 触屏没有指针时唯一手段） |
| 底色 | `AppTheme.panelScrim`（surface @0.78） | 同左，不再自调 `black 0.84` / `0.55` |
| 收起态 | 滑出屏幕 + 30 px 热区 | 44 px 窄条（点 / hover / I·D 键可拉回） |

* `onHover` → `onEnter` + `onExit` 是这次的核心：原来每次鼠标移动都续命一次 8 秒，**停在栏上读久了也会缩回去**；现在停在栏上就一直是展开的，移出去才收。
* `MouseTracker` 会把命中路径上的所有 region 都算进去，所以指针在右栏里时外层 `onHover`（`_pokeControls`）也会触发。那条路径改成 `_touchDetailPanel()`：`_detailHovering` 为真时**不排**计时，否则会出现「悬停中 8 秒到点缩回」。
* 右上角「收起」箭头（`chevron_right_rounded` + tooltip）**删除**。收缩现在有三条出口：移出 1.2 s、8 s 兜底、I / D / 信息键。门禁 `T22` 反向锁死。

### 70.5 门禁

`flutter analyze` 0 issue；`dart run tooling/verify_all.dart` **44 步 / 4542 断言**（上轮 4530，+12）。

* `vod-index-gate` 182 → **186**：`I19` 改成「默认地址追加写进增补文件、`loadFor` 仍读不到」，新增 `I19b`（增补文件同样去重）、`I19c`（非默认不读增补通道）、`I31` 改成「默认接口也照走更新链路」（连带 `I32`/`I33` 的调用计数）、`H42` 文案口径、`H43`（说明行不许回来）、`H44`（点播页四处合并）。
* `vod-playback` 212 → **217**：新增 `T18`–`T22`（离栏 1.2 s / `onEnter`+`onExit` / 悬停不排计时 / 同一出口的底色 / 箭头已删）；`F03f`/`F25`/`F28`/`F29` 按「无分类行 + 词表口径」改写。
* `vod-posters-facets` 121 → **124**：`A01`/`A01b` 改词表顺序、`A02`/`A02b`（词表白名单 / 一个不漏）、`A07`/`A07b`/`A07f`（归一与词表外拒绝）、`A09b`/`A09c`/`A09c3`/`A09f`（真实分片只出词表内的词）、`D37`/`D46`/`D47`/`D50` 改写，新增 `D52`（词表本身）、`D53`（`mergeVodFacets`）。
* `third-party-vod` **152**：`G14` 反向改写（不许再挂说明行）。

### 70.6 未验证

* 默认接口首次启动会在后台跑一次增量取数（`last == null` 即允许跑），走的是 100 站第 1 页 / 90 s 预算；对「冷启动多了一次后台流量」没有做用户可关闭的开关。
* 「共 N 条」把增补条数直接相加，没有跟随包分片按片名去重；同一部新片两边都有时，这个数会多算（列表本身已按片名去重）。
* 悬停展开/收缩在 4K 全屏 + 240 卡网格下的帧率未测；触摸屏上「点一下就展开、再点画面收起」的手感未验证。
* 类型词表缺「古装」等词表外题材（严格照用户给的参考图），这些片子只能从「全部」进。

## §71 1.0.5 第二十四次修：去版本号 + 免责版权说明 + 自动更新间隔七档可选（2026-11-13 12:1x）

用户两张截图的红标，三条：

| # | 红标 | 落点 |
|---|---|---|
| ① | 「版本号去除」（标题「点播源（1.0.5）」） | `settings_page.dart` 区块标题改 `点播源` |
| ② | 「加一个简短的免责版权说明」 | 输入框下方那行灰字位置 |
| ③ | 「去除（每 24 小时…那行），改成可以手动设定更新时间：一天、三天、一周、一月、一季度、半年、一年」 | 删长说明，改成七档可选 + 调度器按档位判断 |

### 71.1 版本号从区块标题里去掉

`_Section(title: '点播源（1.0.5）')` → `'点播源'`。版本号本身没消失：设置页底部「关于与诊断」里仍有 `应用 / 渠道 / 版本号 / 应用标识` 四行，那里才是查版本的地方；区块标题挂版本号只是噪音（用户红标两次提到它）。

### 71.2 免责版权说明替换掉技术说明

第二十三次修删掉了 `helperText`（「默认留空，不回填当前地址…」），那位置一直空着。现在按红标放一句免责与版权归属：

> 仅聚合第三方公开接口的索引信息，不提供、不存储、不传播任何影音内容；片源与版权归各来源站点所有，请自行确认来源合法。

字号 11 / `textTertiary` / 行高 1.4，紧贴输入框下方，两行内收住。它只说事实，不做「我们尽力」这类承诺，也不替用户判断某个站点是否合法 —— 这句话的作用是**划清客户端边界**，不是给第三方内容背书。

### 71.3 自动更新间隔：从写死 24 小时改成七档可选

**改之前**：`const Duration kVodIndexUpdateInterval = Duration(hours: 24)`，`Timer.periodic(interval)` 直接 24 小时一跳，界面上只有一行说明文字讲这件事 —— 用户既改不了，也不知道能不能改。

**改之后**：

```dart
enum VodUpdateCadence {
  day(1, '一天'), threeDays(3, '三天'), week(7, '一周'), month(30, '一月'),
  quarter(90, '一季度'), halfYear(180, '半年'), year(365, '一年');
  final int days; final String label; Duration get duration => Duration(days: days);
}
```

* 新文件 `lib/data/onboarding/vod_update_cadence.dart`：纯枚举、零依赖。单独成文件的理由是三处都要读 —— 设置持久化（只存天数、读回来容错）、调度器（按档位判断到点没）、设置页 UI（渲染七个选项）。
* 月按 30 天、季度 90、半年 180、年 365。这里要的是「用户能理解的间隔」，不是日历精确值。
* `fromDays()` / `tryParse()` 都只认这七档：落盘值不在表里、非整数、负数一律回落「一天」。不认识的数字不能变成「永不更新」，也不能被放行成「半小时一次」。

**调度器怎么跟着改**：

| 项 | 改之前 | 改之后 |
|---|---|---|
| 周期来源 | 构造参数 `interval` | `VodIndexUpdateSettings.updateIntervalDays`（每次 `runOnce` 现读） |
| 定时器 | `Timer.periodic(interval)`（24 h 一跳） | `Timer.periodic(kVodIndexUpdateTick)`（**1 h 一跳**，只问「到点了吗」） |
| 改档位生效时机 | 得重启定时器 | 下一次 tick 就生效，无需重启 |
| 跳过文案 | 「距上次更新不足 24 小时」 | 「距上次更新不足三天」（读档位 `label`） |

用「短 tick + 现读设定」而不是把档位直接当周期，是因为档位随时可改；代价只是每小时读一次设置文件（几毫秒），真正到点前 `runOnce` 在周期判断处就返回了，**不发任何网络请求**。`shouldUpdate(last, now, [every])` 保留可选第三参数，门禁的固定档位断言照旧成立。

**持久化**：`VodSourceAddressSettings` 新增 `updateIntervalDays`（默认 1），落 `config.json` 的 `vodUpdateIntervalDays`。反序列化把档位**最先**解析，后面几条「坏地址回默认」的早退也不会把它丢掉（`fallback()` 带上档位）—— 否则用户改了间隔，只要地址那栏有点脏，重启就回到一天。

**界面**：`立即获取最新片源` 按钮下方一行「自动更新间隔」+ 七个 chip（`Wrap` 自动换行，遥控器可聚焦）。chip 是自己写的 `_CadenceChip`（选中 = `accentDim` 底 + `accent` 描边），不用 `ChoiceChip`：默认 Material 配色的边框和勾选标记在深色设置页里比正文还亮。点档位**只落盘、不取数** —— 改周期不该顺手触发一次网络请求。

### 71.4 门禁

`flutter analyze` 0 issue；`dart run tooling/verify_all.dart` **44 步 / 4554 断言**（上轮 4542，+12）。

* `vod-index-gate` 186 → **189**：`I24` 改成「默认一天 + tick 一小时 + 七档表逐值核对」、`I25`–`I27` 保留、新增 `I27b`（选三天：两天不跑 / 三天跑）、`I27c`（选一年：半年不跑 / 一年跑）、`I29b`（周期读设置档位：选三天且只过两天 ⇒ 跳过且文案写明「三天」）；`H35` 改成「周期由档位决定 + 1 h tick」、`H42` 反向改写（不许再写死 24 小时，要有免责说明 + 七档）。
* `vod-source-address` 128 → **137**（+9）：`G03` 反加「标题不带版本号」；`G18` 改写为七档 + tick；新增 `G21`（免责版权说明在、旧技术说明不在）、`G22`（七档点选且切换不取数）、`G23`（UI 与调度器读同一份设置）；`D21`–`D26`（默认一天 / 往返 / 坏值回落 / 坏地址不丢档位 / 七档表 / 容错函数）。

### 71.5 未验证

* 七档里「一季度 / 半年 / 一年」在真机上要等那么久才跑一次，只做了纯函数与计数验证，**没有跨月跨年的实测**。
* 每小时 tick 在电视端长期后台的耗电未测（每跳只读一次设置文件，理论上可忽略）。
* 改了档位之后「上次更新时间」不清零：把一年改成一天时，如果上次更新就在昨天，会立刻到点并在下次 tick 取一次；这是有意的（用户改小周期就是想更勤），但没在界面上解释。

## §72 1.0.5 第二十五次修：索引记录误报失效 + 右栏完全隐藏（2026-11-13 12:5x）

用户两张截图的红标，两条：

| # | 现象 | 结论 |
|---|---|---|
| ① | 点卡片弹「这条索引记录已失效，请重新检索」，过一会又好了 | 不是索引坏了，是**命中反查表被清空**（会话级缓存 + 到顶整表 `clear`）。改「按 id 结构重建命中」+ 淘汰最早 1/4 |
| ② | 右栏自动隐藏后屏幕上还留一条 44 px「详情」竖条 | 照左栏整块滑出屏幕（`right: -width`、240 ms），由右边缘热区 + I·D / 信息键唤出；竖条组件删除 |

### 72.1 「索引记录已失效」的真凶

链路是：卡片 `onTap` → `_openAndPlay` → `hitById(item.id)` → 为 null 就 `_leavePlaying()` + toast。

而 `hitById` 查的是 `BuiltinIndexService._byId`，这张表的性质：

* **只在 `toItem()` 里写入** —— 即「本次会话把命中转成卡片」时才记一条；
* 上限 `kHitIndexCap = 4000`，老实现 `if (_byId.length >= kHitIndexCap) _byId.clear();` —— **整表清空**；
* 不落盘，进程重启即空。

于是「浏览 ~33 页（120 条/页）→ 再切几次栏目、点几次筛选（每次最多 400 条命中）→ 表满 → 整表清空」
之后，**屏幕上还摆着的卡片全部查不到命中**，点一下就报「已失效」。列表本身没坏：
切走栏目再切回来会重新载入一页，`browse()` 命中 `_hitCache` 几乎是瞬时的，命中表被重新填了一批
—— 这就是「过一会就好了」。

两条修法：

1. **不再把「缓存里没有」当成「记录失效」**（`vod_builtin_service.dart`）。新增
   `parseBuiltinHitId()`（顶层纯函数）与 `BuiltinIndexService.hitByIdOrRebuild()`：条目 id 的结构是
   `builtin:<站点下标>:<vod_id>`，而回源（`fetchDetail`）要的正好就是这两个字段 ⇒ 只要 id 结构完好、
   站点下标还落在 manifest 里，这条记录**一定可回源**，根本不需要缓存。片名 / 栏目只是展示用，
   按调用方（卡片上的 `VodItem`）给的补上；`typeId` 缺失只影响「类型」一栏的显示，回源不读它。
2. **淘汰而不是清空**：`_remember()` 到顶时按插入顺序丢掉最早的 1/4（Dart 的 `Map` 保序，
   `keys.take(drop)` 就是最早进表的那批）。工作集不再被一次溢出整片铲掉。

改完之后只剩两种情形会真报「失效」，而且这两种提示是**准确的**：

* id 结构解析不出来（非 `builtin:` 前缀 / 缺分隔符 / 负下标 / 空 `vod_id`）；
* 站点下标越界（目录换过、站点被删）。

`_openAndPlay` 里新增了 `if (!mounted || seq != _resolveSeq) return;`（await 之后必须复检），
`_retryOpen` 同样走这条口径并以 `identical(_item, item)` 拦住「回包晚到、用户已经换了片子」。

### 72.2 右栏：从「留一条竖条」改成「完全滑出屏幕」

左栏的收起是 `AnimatedPositioned(left: _sideOpen ? 0 : -188)` —— 整个滑出屏幕，屏幕上什么都不留，
再由 `EdgeRevealHandle(side: EdgeSide.left)` 负责唤出。右栏这次照抄这套结构：

| 项 | 之前（二十二～二十四次修） | 现在 |
|---|---|---|
| 收起形态 | `width` 从 409 动画到 **44 px**，露出「ⓘ 详情」竖条 | `right` 从 0 动画到 **-width**，整块移出屏幕 |
| 滑动时长 | 180 ms | **240 ms**（`kVodDetailSlideDuration`，与左栏 `AnimatedPositioned` 完全同档） |
| 收起态内容 | `AnimatedSwitcher` 换成另一套 `_detailRail()` | 只有同一块 `_detailBody`，不换 UI ⇒ 子树不重建、滚动位置与海报不重取 |
| 鼠标唤出 | 点 / 悬停那条 44 px | **右边缘 30 px 热区**（`EdgeRevealHandle`，贴边 400 ms 自动展开，也可点、可从边缘往内拖） |
| 遥控器唤出 | I / D / 信息键 | 不变（I / D / info / guide 四个 `debugName`） |
| 收起阈值 | 8 秒兜底 + 离栏 1.2 秒 | 不变（悬停中不排计时） |

`kVodDetailRailWidth` 这个常量跟着删掉；`VodDetailInput.pointerOnRail` 改名 `pointerOnEdge`
（含义变了：不再是「点在竖条上」，而是「指针进了右边缘热区」）。

播放页 Stack 里这一层从「一个 widget」变成「一个列表」——`EdgeRevealHandle` 自己就是
`Positioned`，只能直接放进 Stack：

```dart
..._detailLayer(item),   // [面板本身, if (!_detailExpanded) EdgeRevealHandle(side: right)]
```

热区在控制层**下面**（与面板同层、排在控制层之前）：控制条淡出时完全不挡，控制条出现时底部
那一小段会被控制条盖住，中间竖段照常可热 —— 与左栏「中段留 80 px 边距」的口径一致。

### 72.3 门禁

`flutter analyze` 0 issue；`dart run tooling/verify_all.dart` **44 步 / 4566 断言**（上轮 4554，+12）。

* `vod-playback` 217 → **219**：`T04` 改「收起不是窄条而是整块滑出，时长与左栏同为 240 ms」（并反向锁死
  `kVodDetailRailWidth` / `_detailRail(` 不许回来）、`T06` 改 `pointerOnEdge`、`T13` 改认 `..._detailLayer(item),`、
  `T14` 改「收起后屏幕上不留任何东西，靠右边缘热区唤出（同左栏）」、新增 `T23`（只滑同一块面板、不换 UI）、
  `T24`（两个方向同一个 setState 驱动）。
* `vod-builtin-service` 119 → **129**：新增 `J07`–`J09`（id 结构拆分：正常 / vod_id 带冒号整段保留 /
  六种畸形一律 null）、`J10`–`J15`（真实 manifest 下按 id 重建命中 → 直接回源成功且参数是 `0|xyz` /
  下标越界返回 null / 非内置 id 不重建）、`J16`（源码层反向锁定：到顶不许整表 `clear`，必须是淘汰 1/4）。

### 72.4 未验证

* 「表满 → 淘汰」这条路径只用源码断言锁住，**没有真跑到 4000 条**再点卡片的实测（要造 4000 条命中得连着翻 33 页）。
* 右边缘热区在**全屏播放 + 控制条可见**时，底部与顶部的 80 px 边距内不可热（与左栏同一策略），
  鼠标恰好停在这两段会呼不出面板 —— 键盘 I / D 仍可用。
* 触屏 / 遥控器没有「边缘悬停」概念，唤出仍只靠 I / D / info / guide 键；这次没有为触屏加常驻手柄。

## §73 1.0.5 第二十六次修：获取进度条 + 不许死循环 + 输入页「当前接口」（2026-11-13 13:0x）

用户两张截图的红标，两条：

| # | 红标 | 结论 |
|---|---|---|
| ① | 「正常能获取时要有进度条，无法获取时会一直闪，当获取不到要有提醒，不能死循环」 | 生成新接口目录全程有**真实进度条**（站点数当分母）；另发现并修掉三条会导致「一直闪」的路径：提交未通过后自动重弹输入页、生成没有硬截止、提交期间输入框丢焦点 |
| ② | 「改成当前接口，如果没有就是空，初次加载也是空，要有简短免责说明」 | 输入页那行固定显示随包默认地址的块，改成**用户当前设定的接口**（没设过整块不渲染），并加一句免责与版权说明 |

### 73.1 进度从哪来：`VodSession` 逐批上报 → 闸门广播 → 两处界面

以前只有一个 `CircularProgressIndicator` 转圈，转多久、到哪一步全靠猜。现在的数据链路：

```
VodSourcePager（知道 finishedSites / siteCount）
        ↓ 每批一次
VodSession._runStart → onProgress(VodBuildProgress)
        ↓ 装配层转交
VodIndexGateController.reportBuildProgress → 通知监听者
        ↓
设置页 / 点播页读 gate.buildProgress → LinearProgressIndicator
```

* 新文件 `lib/features/vod/vod_build_progress.dart`：纯数据，`VodBuildStage`（connecting / fetching / saving / done / failed）+ 站点数 + 条数，`fraction` 与 `note` 都是纯函数，`dart run` 能整张表核完。
* `fraction` 的三条刻意处理：**站点翻完封顶 0.9**（写盘还没完成，先到 100% 再停住比停在 90% 更像卡死）；**0/45 给 0.02**（条形图空着看不出已经启动）；**总站点数未知时返回 null**（走不确定进度条）。
* 文案用「已完成 12/45 个站，已取 1,240 条」而不是百分数 —— 用户关心的是「还在不在动」，具体数字比 27% 更能回答这件事。
* 设置页再补一行「已用 N 秒」（500 ms 一次的本地计时器，只在获取期间跑），这是「没卡死」最直接的证据。

### 73.2 「一直闪」的三条真因

排查下来不是一条，而是三条路径都会表现成「同一个界面反复闪」：

**① 提交未通过 ⇒ 自动弹回输入页 ⇒ 再提交（死循环）**
`VodPage._maybePromptAddress` 在 `needAddress` 时自动弹输入页；用户提交后如果仍然不 ready（例如填了随包默认地址、而随包索引恰好不可用），闸门会重新判成 `needAddress` ⇒ 又弹。**对话框一闪一闪关不掉**。
现在：`await gate.submit(...)` 之后 `if (!verdict.ready)` ⇒ `_addressPromptDismissed = true`，只留一句 toast，用户要重试必须自己点「重试 / 改地址」。
配套：装配层 `rebuild` 遇到默认地址时不再静默 `return null`（那是这条循环的燃料），改成回一句「随包默认索引目录不可用（缺失或未记录接口地址），请换一个接口地址」。

**② 生成过程没有硬截止**
`VodSession` 有 90 秒预算，但预算是**按批检查**的：某次 `pager.next()` 卡住时整轮会越过预算继续等。现在闸门在外面再加一道 `kVodIndexBuildDeadline = 3 分钟`，到点一律判失败并给出可读理由（「获取超时：超过 180 秒仍未取到可播片源，已中止本次生成（未写入目录）」）。
细节坑：`Future.timeout` 在 VM 里按**接收者的运行时泛型**检查 `onTimeout`，实现若只 `return null` 就是 `Future<Null>`，返回 String 的回调会被判类型不符直接抛 `TypeError`。所以先 `.then<String?>((v) => v)` 把回包规范化，与实现怎么写无关。

**③ 提交期间输入框被置灰 ⇒ 丢焦点 ⇒ 又触发一次失焦提交**
`enabled: !_busy` 会让输入框在提交瞬间丢焦点，`_onFocusLost` 立刻再调一次 `_submitAddress`（虽被 `_busy` 挡住，但光标闪一下、状态行闪一下）。现在改 `readOnly: _busy || _updating`：禁编辑但保住焦点。

另外两条一致性保证：

* **进度一定收场**：`_submit` 里 `_buildProgress` 的置位与清除包在 `try/finally`，无论成功、失败、超时都清；设置页的 `_busy` / `_updating` 也都加了 `catch` 兜底，异常也必须给出结论文本。
* **迟到上报必须丢弃**：超时之后底层可能还在跑并回报进度，`reportBuildProgress` 在 `_buildProgress == null` 时直接 return —— 否则界面会从「失败」跳回「正在获取 87%」，那正是用户说的「一直闪」。

### 73.3 输入页：从「随包默认地址」改成「当前接口」

| 项 | 之前 | 现在 |
|---|---|---|
| 那行地址 | 固定显示随包目录记录的接口地址 | **用户当前设定的接口**（`selectedUrl`），没设过整块不渲染 |
| 输入框预填 | 没设过时预填随包默认地址 | 没设过就**空**（只预填当前设定） |
| 辅助说明 | 「填同一个地址可直接加载已有片源，无需重新获取。」 | 删除（它解释的是那行已不存在的地址） |
| 免责说明 | 无 | 「仅聚合第三方公开接口的索引信息，不提供、不存储、不传播任何影音内容；片源与版权归各来源站点所有，请自行确认来源合法。」 |
| 「填入内置索引地址」按钮 | 有（跟那行地址配套） | 删除；保留「填入默认源地址」 |
| 空输入报错 | 一打开就顶一行红字 | 只在点过「确定」之后才报（`_attempted`） |

`kVodDefaultSourceUrl` 仍然保留 —— 「填入默认源地址」按钮还在，用户想用随包索引随时能一键填。

### 73.4 门禁

`flutter analyze` 0 issue；`dart run tooling/verify_all.dart` **44 步 / 4583 断言**（上轮 4566，+17）。

* `vod-index-gate` 189 → **204**：新增 J 组 14 条（fraction / note 逐值、值相等、控制器四步广播、结束即清、迟到上报丢弃、3 分钟截止、失败文案、两处界面都绑真实进度）；`H12` 改成「显示当前接口 + 免责说明，且不许再出现随包地址那行」；`H18`/`H32` 改成「默认地址给明确理由，不许静默 return null」；新增 `H45`（提交未通过不再自动重弹）。
* `vod-source-address` 137 → **139**：`G15` 同步默认地址口径；新增 `G24`（进度条 + 已用秒数 + `readOnly` 且反向锁死 `enabled: !_busy`）、`G25`（异常兜底 + 失败用告警色）。
* `third-party-vod` 152 → 152：`G16` 改写成「守住的位置不变，但必须给理由」（不是放宽）。

### 73.5 未验证

* 进度条的**真实数字**只在替身分页器上验过；真机上 45 个站的 `finishedSites` 爬升是否均匀未测（弱网下可能长时间停在 0.02）。
* 「3 分钟超时」没有真跑到超时（要构造一个卡死的站），只用源码断言 + 条件路径锁住；超时后底层那次 `saveFor` 若最终完成，会写出一份**闸门当前没在用**的目录文件，下次进入点播重新校验时才生效 —— 行为可接受，但没有实测。
* 对话框反复弹的循环只用 `H45` 的源码断言锁住，没有在 UI 上真的连点十次确认。

## §74 1.0.5 第二十七次修：状态句「默认」→「当前」（2026-11-13 13:4x）

用户在设置页红标框住这一行：

> 与**默认**片源索引地址一致，已直接复用**默认**记录（未发起网络请求）

箭头批注「把『默认』文字改成『当前』」。改的是 `VodIndexOrigin.builtin` 分支那条成功提示，两处「默认」一起换：

```
与当前片源索引地址一致，已直接复用当前记录（未发起网络请求）
```

### 74.1 为什么必须两处一起换

这句话的读者是「刚把地址填成随包那个地址、然后点了确定」的人。对**他**来说那个地址不是「默认」（默认是「不填」），而是「当前生效的这个」—— 上一行状态行写的正是「当前生效：…」。留着后半句「复用默认记录」就等于同一格里两种口径，用户会以为「默认记录」是另一份东西。

口径统一后：**「当前」= 此刻生效的那套片源索引**，无论它来自随包资产还是用户自己填的地址。

### 74.2 只改文案，不动判断链

`decideVodIndexSubmit()` 三判据、`builtin.matches(url)` → `loadExisting` 的零网络分支、`fileFor(default) == null` 的护栏**全部未改**。这轮没有一行逻辑改动，改的是 `_submitAddress()` 里那个三元表达式的一条字符串字面量。

同一格还有两处含「默认」，**有意保留**：

| 位置 | 原文 | 为什么留 |
| --- | --- | --- |
| 状态行无地址时 | `当前生效：默认片源索引（随包）` | 这里「默认」修饰的是**随包资产本身**（`assets/vod_index/`），不是「当前 vs 默认」的选择关系；前缀已经是「当前生效：」，改「当前」会变成「当前生效：当前片源索引」 |
| 默认地址 rebuild 失败 | `随包默认索引目录不可用` | 同上，「随包默认」是一个名词（随安装包分发的那份），不是口径对照 |

### 74.3 门禁

`flutter analyze` 0 issue；`dart run tooling/verify_all.dart` **44 步 / 4584 断言**（上轮 4583，+1）。

* `vod-source-address` 139 → **140**：新增 `G26` —— 正向锁「与当前片源索引地址一致，已直接复用当前记录（未发起网络请求）」必须存在，反向锁 `与默认片源索引地址一致` 必须为 0（留一处就还是混口径）。

### 74.4 产物（三件，同版重打）

版本仍 `1.0.5+6`。字符串是**同长度替换**（「默认」→「当前」，各 2 个汉字 = 6 字节），所以三件产物的**字节数几乎不变**，只有 sha 变 —— 这不是打错包，别拿体积当判据。

| 产物 | 字节 | sha256 |
| --- | --- | --- |
| `dist/Shunbo-1.0.5-full.apk` | 52,608,170（full 48,145,149 / lite 28,893,643，单包 24/24） | `bb1f0b23…ae594b1` |
| `dist/Shunbo-1.0.5-windows-x64-setup.exe` | 33,526,521 | `cbf3867e…55d075` |
| `dist/Shunbo-1.0.5-windows-x64-portable.zip` | 41,225,312 / 38 文件 | `0412ab46…c2ca4df091` |

归档 `dist/_prev/fix27/`。**注意**：本轮重打是直接覆盖写的，上轮的 setup / portable 没先归档就被替换掉了（只有 APK 有 `merge_single_apk.py` 自动落下的 `.bak` `46d737ef…`）。回退基线仍是 `1.0.4`（APK + setup + portable 都在 `dist/` 与 `dist/_prev/`），不受影响。

安装实测：先 `CloseMainWindow()` 关掉开着的实例（PID 31172 → 后来又冒出一个 18216，两个都关），静默覆盖安装 **EXITCODE=0**、`/LOG` 正常生成；`dist/windows/Shunbo-1.0.5` ↔ `D:/Programs/Shunbo` **38/38 逐字节一致**（多出 `unins000.dat` / `unins000.exe` 两个卸载器）；`data/app.so` 8,586,120 B `3137001f…5ee01b`；启动后 PID 2204 / 54 线程 / 1091 MB / 窗口「顺播 shunbo」，**保留运行**供直接看效果。

AOT 串取证（`data/app.so` 与 APK 内两套 `libapp.so` 同验）：UTF-16LE「与当前片源索引地址一致，已直接复用当前记录（未发起网络请求）」= **1**、「与当前片源索引地址一致」= 1、「已直接复用当前记录」= 1；「与默认片源索引地址一致」= **0**、「已直接复用默认记录」= **0**；「当前生效：」= 1（状态行未受影响）。单包两 ABI：arm64 7,472,008 / armv7a 8,192,584，两边都是 new=1 / old=0。

### 74.5 未验证

纯字符串字面量替换，无可测行为面。唯一风险是**旧截图对不上**（用户手里的红标图是旧版），不影响功能。

## §75 1.0.6：选集右栏 6 秒无响应自动收起 + 版本升版（2026-11-13 14:1x）

两件事在同一轮做：第二十八次修（行为）+ 用户指令「将当前版本升为 1.0.6」。

### 75.1 需求

用户红标播放页选集抽屉截图：

> 播放页面，选集弹出的右边栏如图，当无响应 6 秒需要自动隐藏

这个抽屉是播放页上**唯一还留着常驻关闭按钮**的浮层（右上角 X）。点开之后去倒水、接电话，回来它还占着画面右侧 320 px —— 而左栏控制条 4 秒就淡出、右栏详情移开 1.2 秒就滑走。

### 75.2 实现：`PanelIdleHider`（`lib/ui/vod/panel_idle_hider.dart`）

**为什么抽成独立外壳，而不是在页面里再加一个 `Timer` 字段**：抽屉是条件渲染的（`if (_showEpisodes) _episodePanel(...)`），它的生命周期正好就是「打开 → 关闭」。计时器跟着 widget 走 —— `initState` 起、`dispose` 取消 —— 天然没有「页面还在、timer 却指向一个已经不存在的抽屉」这种悬挂状态，也不会因为漏掉某条关闭路径（点条目 / 点 X / 按 Esc / 换集 / 退出播放）而留下一个还在跑的 timer。

**什么算「有响应」**（任意一种都重置计时）：

| 信号 | 为什么必须接 |
| --- | --- |
| `onHover` / `onPointerMove` / `onPointerDown` | 鼠标用户的基本盘 |
| `onPointerSignal` | **滚轮**：在 Flutter 里既不触发 `onHover` 也不改焦点，只发 pointer signal |
| `ScrollNotification` | 拖滚动条 / 触控板双指滑，同样不经过 hover |
| `Focus.onFocusChange` | 电视端遥控器把焦点移进面板 |
| `Focus.onKeyEvent` | 面板内方向键换条目；键事件从焦点节点沿树冒泡，这个 `Focus` 是面板祖先，**比页面级全局按键处理更早**收到。返回 `KeyEventResult.ignored` 让它继续往上冒泡，不改任何既有键位 |

只接 `onHover` 是不够的：遥控器没有指针，滚轮翻列表也不产生 hover —— 那样「正在翻集数」的用户会被 6 秒收掉。

**收起动作**走既有开合状态：`onIdle` 里先复核 `if (!mounted || !_showEpisodes) return;`（到点时可能已经被别的路径关掉了），再 `setState(() => _showEpisodes = false)`，最后 `_pokeControls()` 让控制条亮回来 —— 用户下一步多半是拖进度或换集。

常量 `kVodEpisodeIdleHide = Duration(seconds: 6)` 放在 `vod_playback_controls.dart`，与 `kVodControlsIdleTimeout`(4 s)、`kVodDetailHoverExitDelay`(1.2 s)、`kVodDetailIdleTimeout`(8 s) 排在一起：**6 秒夹在「控制条 4 秒」与「详情读文字 8 秒」中间** —— 扫一眼集数标题够用，又不至于看完一集还在挡画面。

UI 上 `_episodePanel` 的结构只多一层：

```
Positioned(right: 0, top: 0, bottom: 0, width: 320)
└ PanelIdleHider(idle: kVodEpisodeIdleHide, onIdle: …)
  └ Material(… SafeArea → Column[标题行, ListView] )
```

### 75.3 版本升到 `1.0.6+7`

| 文件 | 改动 |
| --- | --- |
| `pubspec.yaml` | `version: 1.0.6+7` |
| `lib/platform/system_channel.dart` | `kAppVersionName = '1.0.6'`、`kAppVersionCode = 7` |
| `tooling/windows_installer.iss` | `#define AppVersion "1.0.6"` |
| `dist/windows/Shunbo-1.0.6.iss` | **新建**（由 1.0.5.iss 复制改版本）：`MyAppVersion "1.0.6"`、`SrcDir …\Shunbo-1.0.6`、`OutputBaseFilename=Shunbo-1.0.6-windows-x64-setup`、`VersionInfoVersion=1.0.6.7`、`ProductVersion=1.0.6`、`TextVersion=1.0.6+7`。**UTF-8 BOM + CRLF 保持**（否则 Inno 按 ANSI 解析中文乱码） |
| `dist/windows/Shunbo-1.0.6/` | 由 `build\windows\x64\runner\Release\` 复制 + 从 1.0.5 目录补 10 个 VC++ 运行库 DLL（`msvcp140*` / `vcruntime140*` / `concrt140` / `vccorlib140`） |
| 门禁 4 个文件 | `verify_android_form` R12×4、`verify_legacy_compat` I01/N09、`verify_version_compat` G14/G36、`verify_vod_source_address` H01/H02/H03 |

单包合并必须显式传版本：`python tooling/merge_single_apk.py --skip-flutter-build --version-name 1.0.6 --version-code 7`（它不会去 pubspec 猜；`N09` 专门锁「报告与 pubspec 同源」）。

### 75.4 踩坑：`dart format` 把断言里的一句话拆了行

`dart format lib/ui/vod/vod_page.dart` 把

```dart
await widget.services.live.stop().timeout(const Duration(milliseconds: 900));
```

拆成 `widget.services.live` / `.stop()` / `.timeout(…)` 三行，于是 `verify_vod_playback` 的 `I05`（`page.contains('widget.services.live.stop()')`）当场失败。断言改成容忍换行的正则 `RegExp(r'services\.live\s*\.\s*stop\(\)')` —— **锁的语义没变**（起播前必须先调 `live.stop()`），只是不再依赖格式化风格。

### 75.5 门禁

`flutter analyze` 0 issue；`dart run tooling/verify_all.dart` **44 步 / 4588 断言**（上轮 4584，+4）。

* `vod-playback` 219 → **223**：新增 `T25`（`kVodEpisodeIdleHide` 6 秒 + 抽屉套上外壳）、`T26`（到点复核 + 走既有 `_showEpisodes` + `_pokeControls`）、`T27`（六类响应信号齐全）、`T28`（`initState` 起 / `dispose` 取消，且回调后不再重启计时）；`I05` 改成正则。

### 75.6 产物（三件，1.0.6）

| 产物 | 字节 | sha256 |
| --- | --- | --- |
| `dist/Shunbo-1.0.6-full.apk` | 52,608,170（full 48,145,142 / lite 28,893,638，单包 24/24） | `253dbc6d…dc35d7` |
| `dist/Shunbo-1.0.6-windows-x64-setup.exe` | 33,527,503 | `ff8eb08a…eef503d` |
| `dist/Shunbo-1.0.6-windows-x64-portable.zip` | 41,229,215 / 38 文件 | `6c88f60d…050b24c` |

上一版（1.0.5 三件，含 27 次修的文案改动）已归档 `dist/_prev/fix27/`，`dist/` 根目录现在只剩**当前 1.0.6** 与 **1.0.4 回退基线**。

安装实测：先 `CloseMainWindow()` 关掉 1.0.5 实例 → 静默覆盖 **EXITCODE=0**、`/LOG` 生成；`dist/windows/Shunbo-1.0.6` ↔ `D:/Programs/Shunbo` **38/38 逐字节一致**（多 `unins000.dat` / `unins000.exe`）；`data/app.so` 8,586,120 B `5197e4ab…0cfe9d7a`；setup 版本信息 `FileVersion=1.0.6.7` / `ProductVersion=1.0.6+7`；启动 PID 28104 / 49 线程 / 1063 MB / 窗口「顺播 shunbo」，**保留运行**。

AOT 串取证：`PanelIdleHider`=2、`_PanelIdleHiderState`=1、`_restart`=3；UTF-16LE「与当前片源索引地址一致，已直接复用当前记录（未发起网络请求）」=1、「与默认片源索引地址一致」=0、「选集（」=2、`1.0.6`=1；APK 内两套 `libapp.so`（arm64 7,472,008 / armv7a 8,192,584）均 `PanelIdleHider`=2、新文案=1。`kVodEpisodeIdleHide` 为字符串 0 —— `const Duration` 被编译期内联，**不产生符号是正常的**（不是没进包，`PanelIdleHider` 与 `_restart` 在）。

### 75.7 未验证

* **6 秒的实际手感没在真机上量过**：`flutter test` 在本工程不可用，`PanelIdleHider` 是 widget 层逻辑，只能靠源码断言 + 用户验收。要确认的是三件事：①点开后什么都不做，6 秒准点收；②在列表里滚动 / 按方向键换条目不会被误收；③收起后控制条确实亮回来。
* **触屏 / 电视端**：`onPointerSignal`、`Focus` 两条路径在桌面鼠标环境下走了哪条没分别打点，理论上遥控器按键走 `Focus.onKeyEvent`，但没有真机（S50 Air）实测。
* 抽屉收起是**直接消失**（条件渲染），不是像详情右栏那样 240 ms 滑出 —— 用户这轮只要求「自动隐藏」，没有提动画；如果观感上觉得突兀，下一轮再补 `AnimatedSlide`。
