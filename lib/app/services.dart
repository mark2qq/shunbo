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
import '../data/sync/resume_sync_engine.dart';
import '../features/live/channel_settings_store.dart';
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
}
