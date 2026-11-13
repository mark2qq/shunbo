import '../core/diagnostics/file_diagnostic_sink.dart';
import '../core/player/player_controller.dart';
import '../core/scheduler/playback_orchestrator.dart';
import '../core/scheduler/playback_queue.dart';
import '../core/scheduler/progress_reporting.dart';
import '../core/scheduler/source_catalog.dart';
import '../core/source/source_registry.dart';
import '../data/config_store.dart';
import '../data/live_region_store.dart';
import '../data/onboarding/onboarding_flow.dart';
import '../data/onboarding/source_import_service.dart';
import '../data/onboarding/source_trust.dart';
import '../data/onboarding/third_party_vod_service.dart';
import '../data/onboarding/vod_index_directory_store.dart';
import '../data/onboarding/vod_index_updater.dart';
import '../data/onboarding/vod_source_address_store.dart';
import '../data/sync/resume_sync_engine.dart';
import '../features/live/channel_settings_store.dart';
import '../features/vod/vod_auto_source.dart';
import '../features/vod/vod_boot_index.dart';
import '../features/vod/vod_builtin_service.dart';
import '../features/vod/vod_facet_directory.dart';
import '../features/vod/vod_index_gate.dart';
import '../features/vod/vod_poster_service.dart';
import '../features/vod/vod_library.dart';
import '../features/vod/vod_session.dart';
import '../features/live/live_controller.dart';
import '../features/live/live_geo_ip.dart';
import '../platform/network_watch.dart';
import '../platform/system_channel.dart';
import '../platform/version_compat.dart';
import 'form_factor_controller.dart';

/// 应用级依赖集合。
///
/// 为什么要有这一层：`main()` 装配出来的对象有十来个，如果一路当构造参数
/// 往下传，每个页面都会被无关依赖污染（点播页根本用不上 DLNA 与引导状态）。
/// 聚合之后页面只依赖它真正需要的那几个字段，装配点也只剩 `main()` 一处。
class ShunboServices {
  const ShunboServices({
    required this.orchestrator,
    required this.registry,
    required this.catalog,
    required this.player,
    required this.syncEngine,
    required this.diagnostics,
    required this.onboarding,
    required this.sourceImport,
    required this.progress,
    required this.queue,
    required this.live,
    required this.config,
    required this.ipLocator,
    required this.liveRegion,
    required this.formFactor,
    required this.systemChannel,
    required this.buildInfo,
    required this.compatDecision,
    required this.channelStore,
    required this.networkWatch,
    required this.sourceTrust,
    required this.vodSourceStore,
    required this.vodLibrary,
    required this.thirdPartyVod,
    required this.vodAutoSource,
    required this.vodSession,
    required this.vodBoot,
    required this.vodBuiltin,
    required this.vodIndexGate,
    required this.vodIndexStore,
    required this.vodIndexUpdater,
    required this.vodBuiltinSourceUrl,
    required this.vodPosters,
    required this.vodFacetDirectory,
  });

  /// 点播播放编排（搜索 → 选源 → 解析 → 对齐 → 载入）。
  final PlaybackOrchestrator orchestrator;

  final SourceRegistry registry;
  final SourceCatalog catalog;
  final PlayerController player;
  final ResumeSyncEngine syncEngine;
  final FileDiagnosticSink diagnostics;
  final OnboardingFlow onboarding;
  final SourceImportService sourceImport;
  final ProgressReporter progress;

  /// 播放列表（自动连播 / 片尾推进的唯一消费方）。
  final PlaybackQueue queue;

  /// 直播调台控制器。
  final LiveController live;

  /// 偏好存储（收藏、最近观看等会复用同一套落盘机制）。
  final ConfigStore config;

  /// 依据公网 IP 推断当前城市（地方频道默认定位用）。
  ///
  /// 放在服务容器里而不是让页面自己 new：装配点集中在 `main()`，
  /// 回归脚本才能把 HTTP 客户端换成指向本机 HttpServer 的替身。
  final IpCityLocator ipLocator;

  /// 「地方频道当前城市」的用户选择落盘。
  final LiveRegionStore liveRegion;

  /// 设备形态判定（R1）。布局只读它，不再用屏幕宽度猜。
  final FormFactorController formFactor;

  /// 原生系统能力通道（形态探测 / 构建信息 / 播放保活）。
  final SystemChannel systemChannel;

  /// 构建信息（渠道 + 版本，R10 诊断项）。启动时已经取好，诊断页同步可读。
  final AppBuildInfo buildInfo;

  /// 版本兼容分支决策（启动时锁存一次，运行期不再切换）。
  /// 比较对象 = 设备 Android API 等级，阈值 24；布局与能力层只读这个结果。
  final CompatDecision compatDecision;

  /// 通道设置与地址表快照的落盘（组播开关 / 网关 / 手动覆盖 / 版本回滚）。
  /// 放在服务容器里，设置页与启动装配共用同一份实例，避免各读各的。
  final ChannelSettingsStore channelStore;

  /// Android 精确网络快照 / 变化事件。桌面端不注册原生通道，
  /// `NetworkWatch.isSupported` 为 false，所有调用都是零成本的确定性回落。
  final NetworkWatch networkWatch;

  /// E9 来源信任库：URL 配置导入与频道地址表订阅共用同一份已确认来源，
  /// 避免「同一个发布者在两个入口各确认一次」或一边授信一边不授信。
  final SourceTrustPolicy sourceTrust;

  /// 1.0.5 G1 开放接口地址设置。默认关闭，落盘与设置页共用同一实例。
  final VodSourceAddressStore vodSourceStore;

  /// 1.0.5：运行期可变点播片库。默认只有内置片库，第三方条目接入后
  /// 由点播页监听刷新，播放链路仍走同一套编排器。
  final VodLibrary vodLibrary;

  /// 1.0.5：第三方点播数据的纯数据协议适配（契约 JSON / 苹果 CMS 采集站）。
  /// 不执行任何外部 jar / JS。
  final ThirdPartyVodService thirdPartyVod;

  /// 1.0.5：默认加载源的一次性装载器（单飞、不重试，只对默认源生效）。
  final VodAutoSource vodAutoSource;

  /// 第三方点播分页会话（加载更多 / 已加载条数 / 接口统计总片量）。
  final VodSession vodSession;

  /// 1.0.5：启动期「索引一致性校验 + 加载」状态机。
  ///
  /// 只持有状态与文案，不做 IO —— 加载器与网络同步在 `main()` 注入，
  /// 因此它可以在裸 `dart run` 下回归整张转移图（见 `verify_vod_boot_index.dart`）。
  final VodBootController vodBoot;

  /// 1.0.5：安装包内置检索索引的运行期服务（按栏目懒加载分片 + 命中转条目 +
  /// 详情回源）。与 [vodLibrary] 解耦：后者有条数上限，内置索引是百万级。
  final BuiltinIndexService vodBuiltin;

  /// 1.0.5 第十六次修：进入点播时的「索引校验 + 分支加载」状态机。
  ///
  /// 与 [vodBoot] 分工不同：后者回答「内置索引能不能用来检索」，
  /// 前者回答「播放列表该用哪一份索引的片源」，并给出唯一的 [VodIndexOrigin]。
  final VodIndexGateController vodIndexGate;

  /// 用户换接口后生成的片源索引目录文件（数据目录，非随包资产）。
  /// 第二十一次修起按接口地址独立存放，默认地址只读随包资产。
  final VodIndexDirectoryStore vodIndexStore;

  /// 片源索引的 24 小时定时 / 手动增量更新（只追加、去重、不影响默认索引）。
  final VodIndexAutoUpdater vodIndexUpdater;

  /// 默认索引目录（随包）记录的接口地址。输入页展示它，用户填同一个地址
  /// 就能命中「地址一致 ⇒ 直接加载已有片源」分支，不必重新抓取。
  final String vodBuiltinSourceUrl;

  /// 1.0.5 第十七次修：卡片海报的「可见条目异步补齐」服务。
  ///
  /// 列表条目来自精简索引、自带字段里没有 `vod_pic`；由它在卡片进入视口时
  /// 按站点批量回源取海报，缓存键含目录身份，换片源即在途作废。
  final VodPosterService vodPosters;

  /// 1.0.5 第十七次修：从**整份索引目录**加载筛选条件的目录服务。
  ///
  /// 与「按当前已加载的 120 条统计」不同：它覆盖目录内全部可筛项，
  /// 并给出 loading / ready / empty / error 四态；空与异常只影响筛选区，
  /// 不阻断列表渲染与关键词检索。
  final VodFacetDirectory vodFacetDirectory;
}
