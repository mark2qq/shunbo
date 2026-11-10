import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:shunbo/app/app_shell.dart';
import 'package:shunbo/app/display_mode.dart';
import 'package:shunbo/app/form_factor_controller.dart';
import 'package:shunbo/app/services.dart';
import 'package:shunbo/app/startup_trace.dart';
import 'package:shunbo/app/theme.dart';
import 'package:shunbo/features/live/live_catalog.dart';
import 'package:shunbo/features/live/live_channel.dart';
import 'package:shunbo/features/live/official_satellite.g.dart';
import 'package:shunbo/features/live/verified_channels.g.dart';
import 'package:shunbo/features/live/live_controller.dart';
import 'package:shunbo/features/live/live_geo_ip.dart';
import 'package:shunbo/features/live/live_health.dart';
import 'package:shunbo/features/live/carrier_detector.dart';
import 'package:shunbo/features/live/channel_settings_store.dart';
import 'package:shunbo/features/live/network_channel.dart';
import 'package:shunbo/features/live/preferred_stream.dart';
import 'package:shunbo/features/vod/vod_catalog.dart';
import 'package:shunbo/app/cast_support.dart';
import 'package:shunbo/core/cast/cast_fallback.dart';
import 'package:shunbo/core/cast/cast_metrics.dart';
import 'package:shunbo/core/cast/cast_session.dart';
import 'package:shunbo/core/cast/dlna/dlna_transport.dart';
import 'package:shunbo/core/diagnostics/file_diagnostic_sink.dart';
import 'package:shunbo/core/player/media_kit_player_controller.dart';
import 'package:shunbo/core/player/mpv/libmpv_player_controller.dart';
import 'package:shunbo/core/player/player_bootstrap.dart';
import 'package:shunbo/core/scheduler/alignment.dart';
import 'package:shunbo/core/scheduler/playback_failure.dart';
import 'package:shunbo/core/scheduler/playback_orchestrator.dart';
import 'package:shunbo/core/scheduler/playback_queue.dart';
import 'package:shunbo/core/scheduler/progress_reporting.dart';
import 'package:shunbo/core/scheduler/source_catalog.dart';
import 'package:shunbo/core/scheduler/source_failover.dart';
import 'package:shunbo/core/source/memory_source_adapter.dart';
import 'package:shunbo/core/source/source_adapter.dart';
import 'package:shunbo/core/source/source_profile.dart';
import 'package:shunbo/core/source/source_registry.dart';
import 'package:shunbo/core/source/parsed_source_adapter.dart';
import 'package:shunbo/core/source/dart_backend.dart';
import 'package:shunbo/core/source/rule_source_parser.dart';
import 'package:shunbo/core/source/site_rule.dart';
import 'package:shunbo/core/source/source_fetcher.dart';
import 'package:shunbo/core/source/source_parser.dart';
import 'package:shunbo/data/app_paths.dart';
import 'package:shunbo/data/channel_number_store.dart';
import 'package:shunbo/data/file_config_store.dart';
import 'package:shunbo/data/file_resume_store.dart';
import 'package:shunbo/data/form_factor_store.dart';
import 'package:shunbo/data/live_health_store.dart';
import 'package:shunbo/data/live_region_store.dart';
import 'package:shunbo/data/preferred_stream_store.dart';
import 'package:shunbo/data/onboarding/onboarding_flow.dart';
import 'package:shunbo/data/onboarding/sample_source_config.dart';
import 'package:shunbo/data/onboarding/source_import_service.dart';
import 'package:shunbo/data/onboarding/source_trust.dart';
import 'package:shunbo/data/onboarding/source_trust_store.dart';
import 'package:shunbo/data/resume_record.dart';
import 'package:shunbo/data/sync/resume_sync_engine.dart';
import 'package:shunbo/data/sync/sync_transport.dart';
import 'package:shunbo/platform/network_watch.dart';
import 'package:shunbo/platform/system_channel.dart';
import 'package:shunbo/platform/version_compat.dart';
import 'package:shunbo/ui/media_kit_surface.dart';
import 'package:shunbo/ui/player_surface.dart';

/// 编译期真实源开关（不改变未设置时的演示行为）：
/// ```bash
/// flutter run --dart-define=SHUNBO_LIVE_BASE_URL=http://127.0.0.1:8080 \
///             --dart-define=SHUNBO_LIVE_RULE=legacy
/// ```
/// 可用规则名见 [SiteRulePresets.all]：`legacy` / `vod-html` / `json-api`。
/// 配合 `dart run tooling/serve_fixture_site.dart` 可在无外部站点的情况下完整演示。
const String kLiveBaseUrl = String.fromEnvironment('SHUNBO_LIVE_BASE_URL');
const String kLiveRuleName =
    String.fromEnvironment('SHUNBO_LIVE_RULE', defaultValue: 'legacy');

/// 一键示例配置（App / 演示服务 / 回归脚本共用同一份定义）。
/// E9 来源确认弹窗。
///
/// 必须在下载**之后**、解析与注册**之前**弹出：只有在看到真实来源与变化原因后，
/// 用户的确认才有意义。拿不到 Navigator 时一律返回 false（拒绝），绝不静默放行。
Future<bool> confirmSourceTrust(
    GlobalKey<NavigatorState> navigatorKey, String reason) async {
  final ctx = navigatorKey.currentState?.overlay?.context;
  if (ctx == null) return false;
  final result = await showDialog<bool>(
    context: ctx,
    builder: (c) => AlertDialog(
      title: const Text('确认配置来源'),
      content: Text(
        '$reason\n\n'
        '只有在你信任该发布者、并确认这次下载的内容是你预期的配置时再继续。'
        '确认后 App 会固定这份内容的摘要，之后内容变化会再次询问。',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(c).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(c).pop(true),
          child: const Text('确认并固定摘要'),
        ),
      ],
    ),
  );
  return result ?? false;
}

String _sampleConfigText() => sampleSourceConfigJson(
      baseUrl: kLiveBaseUrl,
      ruleName: kLiveRuleName,
    );

/// 演示数据：注册两个画像差异显著的源，用于直观展示换源对齐。
void _buildDemoRegistry(SourceRegistry registry, SourceCatalog catalog) {
  // 源 A：无偏移无广告（基准）。
  final ykProfile = const SourceProfile(name: '优酷镜像');
  // 源 B：集数 +1、每 600s 插 30s 广告（跨端通用，桌面/TV 也展示）。
  final fanqieProfile = const SourceProfile(
    name: '番茄影视',
    episodeOffset: 1,
    adInterval: 600.0,
    adDuration: 30.0,
  );
  // 源 C：集数 -1，且仅 Android 可用（演示平台裁剪）。
  final jsProfile = const SourceProfile(name: '极速源', episodeOffset: -1);

  const mediaId = 'qyn';
  const title = '庆余年';
  final eps = [
    const EpisodeInfo(episode: 1, title: '$title 第1集'),
    const EpisodeInfo(episode: 2, title: '$title 第2集'),
    const EpisodeInfo(episode: 3, title: '$title 第3集'),
  ];
  final urls = {
    '$mediaId#1': const [PlayUrl(url: 'https://yk/a1.m3u8', qualityRank: 2)],
    '$mediaId#2': const [PlayUrl(url: 'https://yk/a2.m3u8', qualityRank: 2)],
    '$mediaId#3': const [PlayUrl(url: 'https://yk/a3.m3u8', qualityRank: 2)],
  };
  final fanqieUrls = {
    '$mediaId#1': const [PlayUrl(url: 'https://fq/b1.m3u8', qualityRank: 1)],
    '$mediaId#2': const [PlayUrl(url: 'https://fq/b2.m3u8', qualityRank: 1)],
    '$mediaId#3': const [PlayUrl(url: 'https://fq/b3.m3u8', qualityRank: 1)],
  };
  final jsUrls = {
    '$mediaId#1': const [PlayUrl(url: 'https://js/c1.m3u8', qualityRank: 3)],
    '$mediaId#2': const [PlayUrl(url: 'https://js/c2.m3u8', qualityRank: 3)],
    '$mediaId#3': const [PlayUrl(url: 'https://js/c3.m3u8', qualityRank: 3)],
  };

  final yk = MemorySourceAdapter(
    id: ykProfile.name,
    profile: ykProfile,
    episodes: {mediaId: eps},
    urls: urls,
  );
  final fanqie = MemorySourceAdapter(
    id: fanqieProfile.name,
    profile: fanqieProfile,
    episodes: {mediaId: eps},
    urls: fanqieUrls,
  );
  final js = MemorySourceAdapter(
    id: jsProfile.name,
    profile: jsProfile,
    supportedPlatforms: {SourcePlatform.android},
    episodes: {mediaId: eps},
    urls: jsUrls,
  );

  // 源 D：E2 真实解析链路，演示「搜索→解析→取址」。
  // 默认用 MockFetcher 注入约定结构 HTML；设置 kLiveBaseUrl 后切换成真实 HTTP
  // 取数 + SiteRule 解析，让 App 本体（而不只是验证脚本）也能跑真实链路。
  final dartProfile = const SourceProfile(name: 'Dart解析源');
  final SourceFetcher fetcher;
  final SourceParser parser;
  if (kLiveBaseUrl.isEmpty) {
    fetcher = MockFetcher({
      'search:$title':
          '<div class="item" data-id="$mediaId"><a>$title</a></div>',
      'detail:$mediaId': eps
          .map((e) => '<a class="ep" data-ep="${e.episode}" href="/play/$mediaId/${e.episode}">第${e.episode}集</a>')
          .join(),
      for (final e in eps)
        'play:$mediaId:/play/$mediaId/${e.episode}':
            '<video src="https://dart/${e.episode}.m3u8"></video>'
            '<a class="q" data-rank="3" href="https://dart/${e.episode}-1080.m3u8">1080</a>',
    });
    parser = DartSourceParser();
  } else {
    final rule = SiteRule.fromJson(<String, dynamic>{
      ...(SiteRulePresets.all[kLiveRuleName] ?? SiteRulePresets.legacy).toJson(),
      'baseUrl': kLiveBaseUrl,
    });
    parser = RuleSourceParser(rule);
    // 本地样本站点固定直连，避免系统代理改写 loopback 请求。
    fetcher = DartHttpFetcher(
      kLiveBaseUrl,
      useSystemProxy: false,
      headers: const <String, String>{'User-Agent': 'shunbo/1.0'},
    );
  }
  final dart = ParsedSourceAdapter(
    id: dartProfile.name,
    profile: dartProfile,
    parser: parser,
    fetcher: fetcher,
    supportedPlatforms: {
      SourcePlatform.android,
      SourcePlatform.desktop,
      SourcePlatform.tv,
    },
  );

  for (final a in <SourceAdapter>[yk, fanqie, js, dart]) {
    registry.register(a);
    catalog.register(a.profile);
  }
}

Future<void> main() async {
  // R7：冷启动打点从这一行开始算，到首帧渲染完成为止。
  StartupTrace.start();
  WidgetsFlutterBinding.ensureInitialized();
  // M0 自校验：换源对齐核心可用（同源应原样返回）。
  final a = SourceProfile(name: 'A');
  final r = switchSource(a, a, 5, 100.0);
  assert(r.$1 == 5 && r.$2 == 100.0, 'M0 对齐自校验失败');

  final registry = SourceRegistry();
  final catalog = SourceCatalog();
  _buildDemoRegistry(registry, catalog);
  // 内核按平台选择：Android 走原生平台通道（ExoPlayer 回退，真机可出画面），
  // 桌面端走 media_kit（随包分发的 libmpv，真能出画面），都不依赖系统预装库。
  final player = createPlatformPlayer();
  // 原生能力通道先建：下面要它给出 Android 的真实数据目录（R8）与形态信号（R1）。
  final systemChannel = SystemChannel();
  // R8：Android 上 `Directory.systemTemp` 是**缓存**目录，系统可随时清空，
  // 进度/收藏会跟着消失。改成应用私有 files 目录；拿不到才退回旧行为并标降级。
  AppPaths.configure(await systemChannel.dataDir());

  // 「资源准备」阶段：播放器内核初始化与数据目录准备彼此独立，并行做，
  // 把这段串行等待压到最短（首帧只在两者都完成后才需要它们）。
  // 初始化必须显式调用：`PlayerController.initialize()` 此前全工程无调用方，
  // 原生侧靠 `ensureEngine()` 惰性兜底才没暴露；换成 media_kit 后不初始化就是空指针。
  // 目录按平台解析（桌面走 %LOCALAPPDATA%，Android 走应用私有目录），
  // 不能再用 systemTemp —— 桌面临时目录会被系统清理，进度会「莫名其妙丢失」。
  await Future.wait(<Future<void>>[
    player.initialize(),
    AppPaths.ensureDataDir(),
  ]);

  // R1 形态判定：**必须在 runApp 之前**完成。
  // 否则电视用户会先看到一帧手机布局（底部导航栏）再跳成横屏电视布局。
  // 探测走一次 MethodChannel 往返（微秒级）+ 读一个几十字节的偏好文件，
  // 对 R7 的冷启动门槛没有实质影响。
  final formFactor = FormFactorController(
    store: FormFactorStore.at(AppPaths.file(AppPaths.formFactorFile)),
    systemChannel: systemChannel,
  );
  final buildInfo = await systemChannel.buildInfo();

  // 版本兼容分支：比较对象是设备 Android API 等级（不是应用版本、不是
  // Android 4.3 这类展示字符串、不是 eUI 版本），阈值 24 / 严格小于判定。
  // 全程只决策一次并锁存，运行期不再切换；defaultFlow 时下面所有装配
  // 与改动前逐字一致（NetworkWatch 的 legacyCompat 默认 false）。
  final compat = CompatBranchSelector().select(
    buildInfo.compatDecision(isAndroid: Platform.isAndroid),
  );
  debugPrint('[compat] ${compat.diagnosticText().replaceAll('\n', ' | ')}');

  await formFactor.load();
  debugPrint('[form] ${formFactor.report.diagnosticText()}');
  // R4：首帧前就把方向/系统栏定下来（电视锁横屏 + 沉浸，手机横竖屏均可）。
  unawaited(DisplayMode(onAndroid: formFactor.onAndroid)
      .apply(form: formFactor.form, fullscreen: false));
  final diskStore = FileResumeStore.at(AppPaths.file(AppPaths.resumeFile));
  // E6 跨端续播同步：装饰器拦截写入 → 待同步队列；演示用共享目录传输（LAN 降级路径）。
  final syncStore = SyncAwareResumeStore(diskStore);
  final syncTransport =
      FileSyncTransport.at(AppPaths.file(AppPaths.syncSnapshotFile));
  final syncEngine = ResumeSyncEngine(
    local: syncStore,
    transport: syncTransport,
    deviceId: 'demo-desktop',
  );
  // E7 诊断落盘：失效轨迹 / 门禁退化 / 同步事件写入 JSONL。
  final diagnostics =
      FileDiagnosticSink(File(AppPaths.file(AppPaths.diagnosticsFile)));
  // E6 播放中进度上报：此前只在载入时写一次续播记录（等于永远存「本集起点」），
  // 这里把播放中的真实位置按节流策略持续落盘，并复用同一 syncStore 自动进入跨端同步。
  // 片尾回调接到播放列表层：看完一集自动进下一集（开关可关），此前只暴露回调无人消费。
  late final PlaybackQueue queue;
  final progress = ProgressReporter(
    player: player,
    store: syncStore,
    diagnostics: diagnostics,
    onEpisodeFinished: (episode) {
      unawaited(queue.handleEpisodeFinished(episode));
    },
  );
  final orchestrator = PlaybackOrchestrator(
    registry: registry,
    catalog: catalog,
    player: player,
    resumeStore: syncStore,
    progress: progress,
  );
  // E9 引导状态真实落盘：重启后不重复打断已完成引导的用户。
  final configStore = FileConfigStore.at(AppPaths.file(AppPaths.configFile));
  // 运营商通道设置：新装读出的是「组播关闭 + 自动识别」，即档位 C 的默认形态。
  // 必须在 LiveController 构造之前读出来，否则首帧会先用默认策略跑一轮。
  final channelStore = ChannelSettingsStore(configStore);
  final channelSettings = await channelStore.load();
  final savedOnboarding = await configStore.loadState('onboarding');
  // 播放偏好（自动连播开关）与引导状态同库同机制：重启后保持用户选择。
  final savedPlayback = await configStore.loadState('playback');
  final savedAutoNext = savedPlayback?['autoNext'];
  queue = PlaybackQueue(
    orchestrator: orchestrator,
    registry: registry,
    catalog: catalog,
    diagnostics: diagnostics,
    autoNext: savedAutoNext is bool ? savedAutoNext : true,
    persistAutoNext: (enabled) async {
      await configStore.saveState('playback', <String, dynamic>{
        'version': 1,
        'autoNext': enabled,
      });
    },
  );
  final onboarding = OnboardingFlow(
    initial: savedOnboarding == null
        ? null
        : OnboardingState.fromJson(savedOnboarding),
    persist: (state) => configStore.saveState('onboarding', state),
  );
  // E9 引导导入闭环：外部源配置真正注册进业务能力层，并在重启时自动恢复。
  // 恢复失败（磁盘损坏 / 免责声明未接受 / id 冲突）不打断启动，结果由 UI 展示。
  // E9 内容层：来源信任库（TOFU 摘要固定 + 可选 HMAC 签名）。
  // 老版本没有这个键 → 空库 → 所有来源回到「首次使用需确认」，不会静默授信。
  final trustFileStore = SourceTrustFileStore(configStore);
  final trust = SourceTrustPolicy(
    state: await trustFileStore.load(),
    persist: trustFileStore.save,
  );
  final rootNavigatorKey = GlobalKey<NavigatorState>();
  final importService = SourceImportService(
    registry: registry,
    catalog: catalog,
    flow: onboarding,
    trust: trust,
    confirmTrust: (reason) => confirmSourceTrust(rootNavigatorKey, reason),
    readSaved: () async {
      final saved = await configStore.loadState('sourceConfig');
      final text = saved?['text'];
      return text is String ? text : null;
    },
    writeSaved: (text) async {
      final degradedBefore = configStore.degraded;
      await configStore.saveState('sourceConfig', <String, dynamic>{
        'version': kSourceConfigStateVersion,
        'text': text,
      });
      // FileConfigStore 写失败会静默降级为内存态；如实抛回，让 UI 提示
      // 「重启后会丢失」，而不是假装已保存。
      if (configStore.degraded && !degradedBefore) {
        throw StateError('源配置写入降级为内存态');
      }
    },
  );
  await importService.restore();

  // 内置点播片库注册成普通源：点播因此直接复用既有的续播、进度落盘、
  // 自动连播与换源对齐能力，不需要为「内置片库」另写一套播放链路。
  final vodAdapter = VodCatalog.buildAdapter();
  registry.register(vodAdapter);
  catalog.register(vodAdapter.profile);

  // 直播选源：读回上次测出来的线路质量（越快越稳的源排越前），
  // 并在每次换线/起播后写回。读不到就是「所有线路等价」，不影响开播。
  final healthBoard = StreamHealthBoard();
  healthBoard.loadEncoded(await LiveHealthStore.at(AppPaths.file(AppPaths.liveHealthFile)).load());

  // 每频道「上次顺畅播放」的线路缓存：跨会话直达最优线路，切换/启动都更快。
  final preferredBoard = PreferredStreamBoard();
  preferredBoard.loadEncoded(
      await PreferredStreamStore.at(AppPaths.file(AppPaths.livePreferredFile)).load());

  // R14：Android 上用 ConnectivityManager 的精确传输类型判定 Wi-Fi/蜂窝/VPN，
  // 桌面端与未注册通道的旧包自动回落到接口名推断，不会抛平台异常。
  // 兼容分支只停掉 API 24+ 专属的原生精确网络回调，播放/换源/投屏/续播不变。
  final networkWatch = NetworkWatch(legacyCompat: compat.isLegacyCompat);
  final channelPolicy = NetworkChannelPolicy(
    settings: channelSettings,
    detector: CarrierDetector(networkProvider: networkWatch.provider),
  );
  // 直播调台控制器：频道表由内置清单 + 公开索引自动合并，无需用户配置。
  // `streamIndexUrl` 提供同台的多条备用流（M3U 索引每个台只给一条）。
  final live = LiveController(
    player: player,
    // 通道策略：本户实测为档位 C（OTT 单播），组播默认关闭；
    // 未配置网关时不会发起任何组播探测，公网源行为与接入前完全一致。
    channelPolicy: channelPolicy,
    health: healthBoard,
    healthSink: (json) =>
        LiveHealthStore.at(AppPaths.file(AppPaths.liveHealthFile)).save(json),
    // 频道数字编号落盘：同一个台永远同一个号，
    // 遥控器输入的频道号才不会因为一次索引刷新就漂移。
    numberStore: FileChannelNumberStore.at(
      AppPaths.file(AppPaths.channelNumbersFile),
    ),
    preferred: preferredBoard,
    preferredSink: (json) =>
        PreferredStreamStore.at(AppPaths.file(AppPaths.livePreferredFile))
            .save(json),
    catalogService: LiveCatalogService(
      // 内置清单有三部分，语义不同，别混：
      //  * `BuiltInLiveChannels` —— 一条公开 HLS 测试流，只用来区分「信号源坏了」
      //    和「播放内核坏了」，没有任何节目意义；
      //  * `kVerifiedLiveChannels` —— 从昭昭TV 的 7270 条源表里筛出来、**逐条用
      //    libmpv 播过确认零解码错误**的真实频道（440 个台 / 515 条线路，
      //    央视 11 个台 + CGTN 两个、卫视 5 个台、其余是各省市县台）。
      //    它解决的是「首屏 CCTV 一个台都放不出来」：远端索引对 CCTV 给的多是境外
      //    中转 IP，抽风时整批归零，而这份清单里的央视走的是另一个转播域。
      //    清单有保质期，见 verified_channels.g.dart 的 `kVerifiedLiveAt`。
      //  * `kOfficialSatelliteChannels` —— 广电/持牌平台**自有 CDN** 的官方源
      //    （12 个台 / 13 条线路，7 条实测 3840×2160，去重后 5 个官方 4K 源）。
      //    四川卫视4K 那条 1080p 补充源实测是「反盗链提示片」，解码门禁判不出
      //    内容对错，已从清单剔除并在 official_sources.dart 里按主机拉黑。
      //    与上一份不冲突：它走的是官方 CDN，首帧中位数约 0.7s，比境外中转
      //    的 3.3s 快一档；带 `resolverUrl` 的线路起播前会换新令牌，
      //    带 `decodeVerified` 的线路在选源里优先于「只标了 4K 字样」的猜测线路。
      //    时间戳见 `kOfficialSatelliteAt`。
      builtIn: <LiveChannel>[
        ...BuiltInLiveChannels.all,
        ...kVerifiedLiveChannels,
        ...kOfficialSatelliteChannels,
      ],
      remotePlaylistUrls: kDefaultLiveIndexUrls,
      streamIndexUrl: kDefaultStreamIndexUrl,
      streamIndexUrls: kDefaultStreamIndexUrls,
      citySupplementUrls: kDefaultCitySupplementUrls,
      // 全网检索：在 iptv-org 目录之外并入中国全线路表、4K 聚合表、
      // 全球总索引的中国条目，以及苏州台的第二份格式 + 第二镜像。
      discoverySources: kDefaultDiscoverySources,
    ),
  );

  final services = ShunboServices(
    orchestrator: orchestrator,
    registry: registry,
    catalog: catalog,
    player: player,
    syncEngine: syncEngine,
    diagnostics: diagnostics,
    onboarding: onboarding,
    sourceImport: importService,
    progress: progress,
    queue: queue,
    live: live,
    config: configStore,
    // 地方频道按 IP 定位默认显示本市；定位失败/该市无收录频道时，
    // UI 会自动退回「全部城市」并给出提示，不影响开播。
    ipLocator: IpCityLocator(),
    liveRegion: LiveRegionStore.at(AppPaths.file(AppPaths.liveRegionFile)),
    formFactor: formFactor,
    systemChannel: systemChannel,
    buildInfo: buildInfo,
    compatDecision: compat,
    channelStore: channelStore,
    networkWatch: networkWatch,
    sourceTrust: trust,
  );

  runApp(MaterialApp(
    navigatorKey: rootNavigatorKey,
    title: '顺播 shunbo',
    theme: AppTheme.build(),
    debugShowCheckedModeBanner: false,
    home: AppShell(
      services: services,
      // 原 MVP 面板降级为「高级工具」，只能从设置页进入；
      // 主界面不再出现任何调试按钮或配置表单。
      advancedBuilder: (_) => HomeScreen(
        orchestrator: orchestrator,
        registry: registry,
        catalog: catalog,
        syncEngine: syncEngine,
        diagnostics: diagnostics,
        onboarding: onboarding,
        sourceImport: importService,
        progress: progress,
        queue: queue,
        formFactor: formFactor,
      ),
    ),
  ));
  // R7：首帧回调里记一笔，诊断页据此给出「冷启动 ≤ N 秒」的实测值。
  WidgetsBinding.instance.addPostFrameCallback((_) {
    StartupTrace.markFirstFrame();
    debugPrint('[startup] ${StartupTrace.summary()}');
  });
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.orchestrator,
    required this.registry,
    required this.catalog,
    required this.syncEngine,
    required this.diagnostics,
    required this.onboarding,
    required this.sourceImport,
    required this.progress,
    required this.queue,
    required this.formFactor,
  });

  /// 形态判定（R12e：投屏入口只在手机与桌面形态出现）。
  final FormFactorController formFactor;

  final PlaybackOrchestrator orchestrator;
  final SourceRegistry registry;
  final SourceCatalog catalog;
  final ResumeSyncEngine syncEngine;
  final FileDiagnosticSink diagnostics;
  final OnboardingFlow onboarding;
  final ProgressReporter progress;

  /// 播放列表 / 自动连播能力层（片尾回调的唯一消费方）。
  final PlaybackQueue queue;
  final SourceImportService sourceImport;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  SourcePlatform _platform = SourcePlatform.desktop;
  final _keyword = TextEditingController();
  List<SearchHit> _hits = [];
  bool _searching = false;
  ImportOutcome? _lastImport;

  SearchHit? _selectedHit;
  List<EpisodeInfo> _episodes = [];
  int? _selectedEpisode;
  ResumeRecord? _resume;

  PlaybackSession? _session;
  ProgressTick? _lastProgress;
  FailoverResult? _lastFailover;
  bool _failoverBusy = false;
  bool _syncBusy = false;
  SyncResult? _lastSync;

  // E5 投屏：真实 DLNA（SSDP 发现 + AVTransport 控制）。
  final DlnaCastTransport _dlna = DlnaCastTransport();

  /// R12b「记住该源」的落盘（`cast-mode.json`）。
  late final CastModeMemory _castModes = CastModeMemory();

  /// 当前点播投屏会话（null = 未投屏）。
  ///
  /// 中继必须挂在会话上而不是本类的字段里：会话是「一次投屏一个」的，
  /// 界面重建（切栏、旋转、热重载）都可能把本类的临时字段弄丢，
  /// 而电视那边一旦断了中继就是黑屏。
  CastSession? _vodCast;

  /// 上一次投屏的实测指标（R12d 的可见性）。
  CastReport? _castReport;
  List<CastDevice> _lanDevices = const <CastDevice>[];
  bool _lanBusy = false;
  String? _lanHint;

  // 演示用假传输：只为在没有电视的环境里跑通「成功 / 掉线 / 无设备」三条路径。
  final _castTransport = FakeCastTransport(
    devices: const <CastDevice>[CastDevice(id: 'tv-1', name: '客厅电视')],
  );
  CastResult? _lastCast;
  bool _castBusy = false;

  /// 当前正在投屏的传输与设备（null = 本机播放）。结束投屏时用它们断开，
  /// 不能想当然地用 `_dlna`：演示路径用的是假传输。
  CastTransport? _activeCastTransport;
  CastDevice? _activeCastDevice;

  CastFallbackController get _cast => CastFallbackController(
        transport: _castTransport,
        diagnostics: widget.diagnostics,
      );

  /// 搜索局域网内的 DLNA 渲染器。发现失败不是异常路径，而是「没有设备可用」。
  Future<void> _discoverLan() async {
    if (_lanBusy) return;
    setState(() {
      _lanBusy = true;
      _lanHint = null;
    });
    try {
      final devices = await _dlna.discover();
      if (!mounted) return;
      setState(() {
        _lanDevices = devices;
        _lanBusy = false;
        _lanHint = devices.isEmpty
            ? (_dlna.discoveryNotes.isEmpty
                ? '未发现设备。请确认电视已开机、与本机在同一 Wi-Fi，并已开启投屏/DLNA。'
                : _dlna.discoveryNotes.take(2).join('；'))
            : '发现 ${devices.length} 台设备';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _lanBusy = false;
        _lanHint = '发现失败：$e';
      });
    }
  }

  /// 投屏到选中的真实设备。降级逻辑与演示路径共用 [_settleCast]。
  ///
  /// R12b 双模式在这里接线：控制器需要**四样外部能力**才能做出
  /// 「直推还是串流」的判断 —— 记忆读、记忆写、起中继、无头探测。
  Future<void> _castToLan(CastDevice device) async {
    final s = _session;
    if (s == null || _lanBusy || s.playUrl.isEmpty) return;
    setState(() => _lanBusy = true);
    final result = await CastFallbackController(
      transport: _dlna,
      diagnostics: widget.diagnostics,
      relayFactory: startCastRelay,
      probeUrlStatus: probeCastUrlStatus,
      readMode: _castModes.read,
      writeMode: _castModes.write,
    ).startCast(
      mediaId: s.mediaId,
      url: s.playUrl,
      rawEpisode: s.rawEpisode,
      rawSeconds: s.rawSeconds,
      preferredDeviceId: device.id,
      sourceId: s.sourceId,
      // 源站要求的 Referer/UA：直推给不了电视，只能由中继补。
      headers: s.headers,
    );
    if (!mounted) return;
    setState(() => _lanBusy = false);
    if (result.casting) {
      // 投屏成功：本机停播，避免两路同时拉流、也避免进度被两份来源写乱。
      await widget.orchestrator.player.pause();
      if (!mounted) return;
      await _settleCast(result, transport: _dlna);
      return;
    }
    await _settleCast(result);
  }

  /// 结束投屏回到本机：先取回设备侧真实位置再断开，然后按降级路径重新起播。
  ///
  /// 此前 `CastFallbackController.stopCasting` 已实现但**全工程无调用方**——
  /// 用户点了投屏就再也回不来（本机已暂停，且没有入口断开设备）。
  Future<void> _stopCasting() async {
    final s = _session;
    final t = _activeCastTransport;
    final d = _activeCastDevice;
    if (s == null || t == null || d == null || _castBusy) return;
    setState(() => _castBusy = true);
    final result = await CastFallbackController(
      transport: t,
      diagnostics: widget.diagnostics,
    ).stopCasting(
      mediaId: s.mediaId,
      rawEpisode: s.rawEpisode,
      lastKnownRawSeconds: s.rawSeconds,
    );
    if (!mounted) return;
    setState(() {
      _castBusy = false;
      _activeCastTransport = null;
      _activeCastDevice = null;
    });
    // 结束投屏必须同时关掉中继：否则手机还在为电视转发流量，
    // 用户看不出任何迹象，流量却一直跑。
    await _dropVodCast();
    await _settleCast(result);
  }

  /// 停掉点播投屏会话（含中继）。
  Future<void> _dropVodCast() async {
    final c = _vodCast;
    _vodCast = null;
    if (c == null) return;
    try {
      await c.stop();
    } catch (_) {
      // 停不掉不影响本机续播。
    }
  }

  /// 降级收尾：把设备侧的**源原始坐标**换算成内容坐标后重新起播，进度不丢。
  ///
  /// [transport] 只在投屏成功时记录：之后「结束投屏」要用**同一个**传输去断开
  /// （真实 DLNA 与演示假传输不是同一个对象）。
  Future<void> _settleCast(CastResult result, {CastTransport? transport}) async {
    final s = _session;
    if (s == null) return;
    if (result.casting) {
      // 会话接管中继（result.relay）：之后换源重下发有了着落点，
      // 而不是把中继丢在本类字段里、界面一重建就断。
      _vodCast = CastSession.fromResult(
        result,
        transport: transport ?? _dlna,
        relayFactory: startCastRelay,
        diagnostics: widget.diagnostics,
      );
      setState(() {
        _lastCast = result;
        _castReport = result.report;
        _activeCastTransport = transport;
        _activeCastDevice = result.device;
      });
      return;
    }
    // 降级回本机：中继没有存在意义了，继续开着只是白耗流量。
    await _dropVodCast();
    if (!mounted) return;
    final profile = widget.catalog.get(s.sourceId);
    if (profile == null) {
      setState(() => _lastCast = result);
      return;
    }
    final c = rawToContent(profile, result.rawEpisode, result.rawSeconds);
    final resumed = await widget.orchestrator.startPlayback(
      sourceId: s.sourceId,
      mediaId: s.mediaId,
      mediaTitle: s.mediaTitle,
      canonicalEpisode: c.$1,
      canonicalSeconds: c.$2,
    );
    if (!mounted) return;
    setState(() {
      _session = resumed;
      _lastCast = result;
    });
    _attach(resumed);
  }

  /// 演示投屏成功 / 掉线 / 无设备三种路径。降级时把物理坐标交回调度层
  /// 换算为规范内容坐标后重新起播，确保「切回本机」不丢进度。
  Future<void> _simulateCast({
    required bool dropMidPlay,
    bool noDevice = false,
  }) async {
    final s = _session;
    if (s == null || _castBusy) return;
    setState(() => _castBusy = true);
    final t = _castTransport;
    t.devices = noDevice
        ? const <CastDevice>[]
        : const <CastDevice>[CastDevice(id: 'tv-1', name: '客厅电视')];
    t.playFails = false;
    t.connectFails = const <String>{};
    t.position = s.rawSeconds;
    try {
      var result = await _cast.startCast(
        mediaId: s.mediaId,
        // 投屏必须交给电视**本机正在播的那个地址**：另编一个地址等于换个资源，
        // 演示路径之前用的 `https://cast/...` 就是投屏"成功"却播不出来的根源。
        url: s.playUrl,
        rawEpisode: s.rawEpisode,
        rawSeconds: s.rawSeconds,
      );
      if (dropMidPlay && result.casting) {
        t.position = s.rawSeconds + 120.0; // 投屏端又看了 120s（物理坐标）
        result = await _cast.onConnectionLost(
          mediaId: s.mediaId,
          rawEpisode: result.rawEpisode,
          lastKnownRawSeconds: t.position,
        );
      }
      if (!mounted) return;
      setState(() => _castBusy = false);
      await _settleCast(result, transport: result.casting ? t : null);
    } catch (_) {
      if (!mounted) return;
      setState(() => _castBusy = false);
    }
  }

  // 换源决策唯一收敛到业务能力层（R1）：UI 只上报失效，不自行挑源。
  SourceFailover get _failover => SourceFailover(
        orchestrator: widget.orchestrator,
        registry: widget.registry,
        catalog: widget.catalog,
        diagnostics: widget.diagnostics,
      );

  /// E6 跨端续播同步：手动触发一次双向同步（真实产品由网络状态 / 定时驱动）。
  Future<void> _syncNow() async {
    if (_syncBusy) return;
    setState(() => _syncBusy = true);
    final result = await widget.syncEngine.sync();
    if (!mounted) return;
    setState(() {
      _syncBusy = false;
      _lastSync = result;
    });
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(result.userMessage)));
  }

  /// E9 首次配置引导：逐步推进（安全不变量由 OnboardingFlow 内部保证）。
  Future<void> _advanceOnboarding({bool skipAll = false}) async {
    final flow = widget.onboarding;
    if (skipAll) {
      await flow.skipAll();
    } else {
      switch (flow.state.step) {
        case OnboardingStep.welcome:
          await flow.acceptDisclaimer();
        case OnboardingStep.sourceImport:
          await flow.skipImport(); // demo 使用内置源，跳过外部配置导入
        case OnboardingStep.platformConfirm:
          await flow.confirmPlatform(_platform.name);
        case OnboardingStep.done:
          break;
      }
    }
    if (mounted) setState(() {});
  }

  /// E9 真实导入入口：粘贴 JSON / 本机文件 → 安全校验 → 注册 → 落盘 → 推进引导。
  /// 两条入口共用 `SourceImportService` 的同一条净化链路；
  /// 未接受免责声明（含「跳过引导」）的用户必须先补签，导入按钮才可点。
  Future<void> _showSourceConfigDialog() async {
    final svc = widget.sourceImport;
    final flow = widget.onboarding;
    final controller = TextEditingController(
        text: svc.currentConfigText ?? _sampleConfigText());
    final pathController = TextEditingController();
    final urlController = TextEditingController();
    bool busy = false;
    bool allowOverwrite = false;
    String? exportNotice;
    bool exportOk = false;
    bool disclaimer = flow.state.disclaimerAccepted;
    ImportOutcome? outcome;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          final theme = Theme.of(ctx);
          return AlertDialog(
            title: const Text('源配置导入'),
            content: SizedBox(
              width: 560,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '仅接受纯数据站点规则。外部配置默认禁止 jar / QuickJS 等代码加载后端，'
                      '并逐条校验：非法字段、跨站地址、与内置源同名的 id 都会被拒绝。',
                      style: TextStyle(fontSize: 12),
                    ),
                    const SizedBox(height: 8),
                    if (!disclaimer)
                      Card(
                        color: Colors.orange.shade50,
                        child: Padding(
                          padding: const EdgeInsets.all(10),
                          child: Row(
                            children: [
                              const Expanded(
                                child: Text(
                                  '外部源配置可能夹带可执行脚本。请先阅读并接受风险声明。',
                                  style: TextStyle(fontSize: 12),
                                ),
                              ),
                              TextButton(
                                onPressed: busy
                                    ? null
                                    : () async {
                                        await flow.acceptDisclaimerLater();
                                        setDialogState(() => disclaimer = true);
                                      },
                                child: const Text('我已了解风险'),
                              ),
                            ],
                          ),
                        ),
                      ),
                    Row(
                      children: [
                        TextButton(
                          onPressed: busy
                              ? null
                              : () => setDialogState(
                                  () => controller.text = _sampleConfigText()),
                          child: const Text('填入本地示例'),
                        ),
                        const Spacer(),
                        Text('${controller.text.length} 字符',
                            style: const TextStyle(fontSize: 11)),
                      ],
                    ),
                    const Divider(height: 16),
                    const Text(
                      '或填写本机配置文件路径（支持带引号的复制路径与 file:// URI；'
                      '仅接受 UTF-8 纯文本，最大 256 KB）。导出写入的是当前已生效配置，'
                      '不含编辑框草稿。',
                      style: TextStyle(fontSize: 11),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: pathController,
                            enabled: !busy,
                            decoration: const InputDecoration(
                              isDense: true,
                              labelText: '配置文件路径',
                              hintText: r'C:\sources\my-sources.json',
                              border: OutlineInputBorder(),
                            ),
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                        const SizedBox(width: 8),
                        TextButton.icon(
                          onPressed: busy || !disclaimer
                              ? null
                              : () async {
                                  setDialogState(() {
                                    busy = true;
                                    outcome = null;
                                  });
                                  final result = await svc.importFromFile(
                                      pathController.text);
                                  if (!ctx.mounted) return;
                                  setDialogState(() {
                                    busy = false;
                                    outcome = result;
                                    // 成功后回填净化配置，用户可继续查看/微调。
                                    final current = svc.currentConfigText;
                                    if (result.ok && current != null) {
                                      controller.text = current;
                                    }
                                  });
                                  if (mounted) {
                                    setState(() => _lastImport = result);
                                  }
                                },
                          icon: const Icon(Icons.file_open_outlined, size: 18),
                          label: const Text('从文件导入'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      '或填写配置链接（仅 https，最多跟随 2 次同主机重定向，'
                      '上限 256 KB；下载成功不代表内容安全，仍会逐条过白名单）。',
                      style: TextStyle(fontSize: 11),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: urlController,
                            enabled: !busy,
                            decoration: const InputDecoration(
                              isDense: true,
                              labelText: '配置链接',
                              hintText: 'https://example.com/sources.json',
                              border: OutlineInputBorder(),
                            ),
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                        const SizedBox(width: 8),
                        TextButton.icon(
                          onPressed: busy || !disclaimer
                              ? null
                              : () async {
                                  setDialogState(() {
                                    busy = true;
                                    outcome = null;
                                  });
                                  final result =
                                      await svc.importFromUrl(urlController.text);
                                  if (!ctx.mounted) return;
                                  setDialogState(() {
                                    busy = false;
                                    outcome = result;
                                    final current = svc.currentConfigText;
                                    if (result.ok && current != null) {
                                      controller.text = current;
                                    }
                                  });
                                  if (mounted) {
                                    setState(() => _lastImport = result);
                                  }
                                },
                          icon: const Icon(Icons.link, size: 18),
                          label: const Text('从链接导入'),
                        ),
                      ],
                    ),
                    Row(
                      children: [
                        Checkbox(
                          value: allowOverwrite,
                          onChanged: busy
                              ? null
                              : (v) => setDialogState(
                                  () => allowOverwrite = v ?? false),
                        ),
                        const Text('允许覆盖已有文件',
                            style: TextStyle(fontSize: 12)),
                        const Spacer(),
                        TextButton.icon(
                          // 不禁用：没有生效配置时点一下会得到明确原因，
                          // 比一个灰掉且不给解释的按钮更好懂。
                          onPressed: busy
                              ? null
                              : () async {
                                  setDialogState(() {
                                    busy = true;
                                    exportNotice = null;
                                  });
                                  final result = await svc.exportToFile(
                                      pathController.text,
                                      overwrite: allowOverwrite);
                                  if (!ctx.mounted) return;
                                  setDialogState(() {
                                    busy = false;
                                    exportNotice = result.message;
                                    exportOk = result.ok;
                                  });
                                },
                          icon: const Icon(Icons.save_alt_outlined, size: 18),
                          label: const Text('导出到该路径'),
                        ),
                      ],
                    ),
                    if (exportNotice != null)
                      Text(
                        exportNotice!,
                        style: TextStyle(
                          fontSize: 12,
                          color: exportOk
                              ? Colors.green.shade700
                              : theme.colorScheme.error,
                        ),
                      ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: controller,
                      maxLines: 12,
                      enabled: !busy,
                      decoration: const InputDecoration(
                        labelText: '源配置 JSON',
                        alignLabelWithHint: true,
                        border: OutlineInputBorder(),
                      ),
                      style: const TextStyle(
                          fontFamily: 'monospace', fontSize: 12),
                    ),
                    if (outcome != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        outcome!.message,
                        style: TextStyle(
                          fontSize: 12,
                          color: outcome!.ok
                              ? Colors.green.shade700
                              : theme.colorScheme.error,
                        ),
                      ),
                      if (outcome!.originLabel != null)
                        Text('来源文件：${outcome!.originLabel}',
                            style: const TextStyle(fontSize: 11)),
                      if (outcome!.sourceIds.isNotEmpty)
                        Text('已生效：${outcome!.sourceIds.join('、')}',
                            style: const TextStyle(fontSize: 11)),
                      for (final r in outcome!.rejections.take(4))
                        Text('• $r', style: const TextStyle(fontSize: 11)),
                      if (outcome!.rejections.length > 4)
                        Text('另有 ${outcome!.rejections.length - 4} 条被拒绝',
                            style: const TextStyle(fontSize: 11)),
                    ],
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: busy ? null : () => Navigator.of(ctx).pop(),
                child: const Text('关闭'),
              ),
              ElevatedButton(
                onPressed: busy || !disclaimer
                    ? null
                    : () async {
                        setDialogState(() {
                          busy = true;
                          outcome = null;
                        });
                        final result =
                            await svc.importFromText(controller.text);
                        if (!ctx.mounted) return;
                        setDialogState(() {
                          busy = false;
                          outcome = result;
                        });
                        if (mounted) setState(() => _lastImport = result);
                      },
                child: busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('校验并导入'),
              ),
            ],
          );
        },
      ),
    );
    controller.dispose();
    pathController.dispose();
    urlController.dispose();
    if (mounted) setState(() {});
  }

  /// 常驻状态条：显示当前生效的外部源，以及启动恢复/写入降级的异常提示。
  Widget _buildImportStatus() {
    final svc = widget.sourceImport;
    final outcome = _lastImport ?? svc.lastOutcome;
    final ids = svc.activeSourceIds;
    final warning = outcome != null &&
        !outcome.ok &&
        outcome.kind != ImportOutcomeKind.nothingToRestore;
    if (ids.isEmpty && !warning) return const SizedBox.shrink();
    return Card(
      color: warning ? Colors.orange.shade50 : Colors.green.shade50,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Row(
          children: [
            Icon(
                warning
                    ? Icons.warning_amber_rounded
                    : Icons.check_circle_outline,
                size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (ids.isNotEmpty)
                    Text('已启用外部源 ${ids.length} 个：${ids.join('、')}',
                        style: const TextStyle(fontSize: 12)),
                  if (warning)
                    Text(outcome.message,
                        style: const TextStyle(fontSize: 12)),
                ],
              ),
            ),
            TextButton(
                onPressed: _showSourceConfigDialog,
                child: const Text('管理配置')),
          ],
        ),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 自动连播的 UI 出口：片尾事件由 ProgressReporter 触发 → 队列起播下一集 →
    // 这里刷新会话。队列自己不持有 Widget，避免 core 层依赖 Flutter。
    widget.queue.platform = _platform;
    widget.queue.onAdvanced = (r) {
      if (!mounted) return;
      setState(() {
        if (r.advanced) _session = r.session;
      });
      if (r.message.isNotEmpty) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(r.message)));
      }
    };
  }

  /// 会话变更的统一出口：同步给播放列表层，保证片尾事件能对上「当前是第几集」。
  void _attach(PlaybackSession s) => widget.queue.attach(s);

  /// 切后台 / 被系统回收前是移动端最容易丢进度的一刻：强制落盘一次。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      unawaited(widget.progress.flush());
    }
  }

  /// E6 演示：Mock 内核不会自行走时间，这里推进后再采样，验证落盘值随播放刷新。
  Future<void> _advancePlayback(double seconds) async {
    final s = _session;
    if (s == null) return;
    final player = widget.orchestrator.player;
    final cur = await player.currentRawSeconds();
    final next = cur + seconds;
    await player.seek(next);
    final tick = await widget.progress.tick();
    if (!mounted) return;
    final profile = widget.catalog.get(s.sourceId);
    setState(() {
      _lastProgress = tick;
      if (profile != null) {
        _session = PlaybackSession.fromRaw(
          mediaId: s.mediaId,
          mediaTitle: s.mediaTitle,
          sourceId: s.sourceId,
          profile: profile,
          rawEpisode: s.rawEpisode,
          rawSeconds: next,
          playUrl: s.playUrl,
        );
      }
    });
  }

  /// E6 片尾演示：跳到「距结尾 20 秒」再采样，验证记录变成「本集看完」而不是末尾秒数。
  Future<void> _advanceToEnding() async {
    final s = _session;
    if (s == null) return;
    final player = widget.orchestrator.player;
    final dur = await player.duration();
    if (dur <= 0) return;
    await player.seek(dur - 20);
    final tick = await widget.progress.tick(force: true);
    if (!mounted) return;
    final profile = widget.catalog.get(s.sourceId);
    setState(() {
      _lastProgress = tick;
      if (profile != null) {
        _session = PlaybackSession.fromRaw(
          mediaId: s.mediaId,
          mediaTitle: s.mediaTitle,
          sourceId: s.sourceId,
          profile: profile,
          rawEpisode: s.rawEpisode,
          rawSeconds: dur - 20,
          playUrl: s.playUrl,
        );
      }
    });
  }

  /// 暂停并强制保存：真实产品在用户按暂停 / 切后台 / 换源前都会走这条路径。
  Future<void> _pauseAndSave() async {
    if (_session == null) return;
    await widget.orchestrator.player.pause();
    await widget.progress.flush();
    if (!mounted) return;
    setState(() => _lastProgress = null);
  }

  String _progressSummary() {
    final saved = widget.progress.lastSaved;
    final base = saved == null
        ? '本次会话尚未落盘'
        : '上次落盘：第 ${saved.canonicalEpisode} 集 · '
            '${saved.canonicalSeconds.toStringAsFixed(1)} s（内容坐标）'
            '${saved.finished ? ' · 已看完' : ''}';
    final t = _lastProgress;
    if (t == null) return '$base ｜ 采样周期 ${widget.progress.policy.tickInterval.inSeconds}s';
    if (!t.skipped) {
      return '$base ｜ 最近采样：第 ${t.contentEpisode} 集 · '
          '${t.contentSeconds.toStringAsFixed(1)} s '
          '${t.finished ? '（片尾判定：本集看完）' : '已提交'}';
    }
    final reason = switch (t.skip!) {
      ProgressSkip.noSession => '没有活跃会话',
      ProgressSkip.noAdvance => '位置未前进（暂停中或刚载入）',
      ProgressSkip.throttled => '未到落盘间隔',
      ProgressSkip.invalidPosition => '播放器位置不可用',
      ProgressSkip.ending => '已在片尾区且本集已记为看完（不再覆盖）',
    };
    return '$base ｜ 最近采样被跳过：$reason';
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // 退出前尽力落盘一次（同步 dispose 拿不到 await；需要确定性收尾用 stop()）。
    widget.progress.dispose();
    // 退出时中继必须关：监听端口若留着，应用「已关闭」但手机还在替电视拉流。
    unawaited(_dropVodCast());
    _keyword.dispose();
    super.dispose();
  }

  /// E7 演示：模拟播放中断 → 自动换源；[allSourcesFailed] 演示全失效兜底 UX。
  Future<void> _simulateFailure({bool allSourcesFailed = false}) async {
    final s = _session;
    if (s == null || _failoverBusy) return;
    setState(() {
      _failoverBusy = true;
      _lastFailover = null;
    });
    final result = await _failover.recover(
      failedSession: s,
      failure: PlaybackFailureException(
        reason: PlaybackFailureReason.stallTimeout,
        sourceId: s.sourceId,
        message: '模拟：播放中断 / 卡顿超时',
      ),
      platform: _platform,
      excludeSources:
          allSourcesFailed ? _availableSourceIds.toSet() : const <String>{},
    );
    if (!mounted) return;
    setState(() {
      _failoverBusy = false;
      _lastFailover = result;
      if (result.recovered) _session = result.session;
    });
    if (result.recovered && result.session != null) {
      _attach(result.session!);
    }
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(result.userMessage)));
  }

  Future<void> _doSearch() async {
    setState(() => _searching = true);
    final hits = await widget.orchestrator.search(_keyword.text.trim(), _platform);
    setState(() {
      _hits = hits;
      _searching = false;
      _selectedHit = null;
      _episodes = [];
      _selectedEpisode = null;
      _resume = null;
      _session = null;
      _lastFailover = null;
    });
    widget.queue.detach();
    widget.queue.setEpisodes(const <EpisodeInfo>[]);
  }

  Future<void> _selectHit(SearchHit hit) async {
    final adapter = widget.registry.get(hit.sourceId);
    final eps = adapter == null ? <EpisodeInfo>[] : await adapter.getEpisodes(hit.result.mediaId);
    final resume = await widget.orchestrator.resumeFor(hit.result.mediaId);
    setState(() {
      _selectedHit = hit;
      _episodes = eps;
      _selectedEpisode = null;
      _resume = resume;
      _session = null;
    });
    // 剧集表进播放列表层：自动连播要靠它判断「下一集是第几集、还有没有」。
    widget.queue.setEpisodes(eps);
    widget.queue.detach();
  }

  /// 从续播记录恢复：优先沿用上次源（若当前平台可用），否则回退到首个可用源。
  ///
  /// 记录标记为「已看完」时不能从末尾秒数起播（那正是片尾判定要解决的问题）：
  /// 有下一集就接着看下一集，没有则退化为本集重看。
  Future<void> _resumePlay() async {
    final r = _resume;
    if (r == null || _selectedHit == null) return;
    final avail = _availableSourceIds;
    final src = avail.contains(r.sourceId) ? r.sourceId : avail.first;
    final nextEp = r.canonicalEpisode + 1;
    final hasNext = _episodes.any((e) => e.episode == nextEp);
    final startEp =
        r.finished ? (hasNext ? nextEp : r.canonicalEpisode) : r.canonicalEpisode;
    final startSec = r.finished ? 0.0 : r.canonicalSeconds;
    final session = await widget.orchestrator.startPlayback(
      sourceId: src,
      mediaId: _selectedHit!.result.mediaId,
      mediaTitle: _selectedHit!.result.title,
      canonicalEpisode: startEp,
      canonicalSeconds: startSec,
    );
    _attach(session);
    setState(() => _session = session);
  }

  Future<void> _playOnSource(String sourceId, int canonicalEpisode) async {
    final session = await widget.orchestrator.startPlayback(
      sourceId: sourceId,
      mediaId: _selectedHit!.result.mediaId,
      mediaTitle: _selectedHit!.result.title,
      canonicalEpisode: canonicalEpisode,
      canonicalSeconds: 0.0,
    );
    _attach(session);
    setState(() => _session = session);
  }

  Future<void> _switchTo(String toSourceId) async {
    final s = _session;
    if (s == null) return;
    try {
      final res = await widget.orchestrator.switchSourceAligned(
        fromSourceId: s.sourceId,
        toSourceId: toSourceId,
        mediaId: s.mediaId,
        mediaTitle: s.mediaTitle,
        fromRawEpisode: s.rawEpisode,
        fromRawSeconds: s.rawSeconds,
      );
      if (!mounted) return;
      setState(() {
        _session = res.session;
        _lastFailover = null;
      });
      _attach(res.session);
    } on PlaybackFailureException catch (e) {
      // 真实失效（含 E2 真实联网后的超时 / 非 2xx / 连接失败）直接进入 E7
      // 自动换源，并把真实 reason 传给诊断，不再只弹一句「可尝试自动换源」。
      // 决策权仍在业务能力层：UI 只上报失效，不自行挑源。
      if (!mounted) return;
      final result = await _failover.recover(
        failedSession: s,
        failure: e,
        platform: _platform,
      );
      if (!mounted) return;
      setState(() {
        _lastFailover = result;
        if (result.recovered) _session = result.session;
      });
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(result.userMessage)));
    }
  }

  List<String> get _availableSourceIds =>
      widget.registry.availableOn(_platform).map((a) => a.id).toList();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(kLiveBaseUrl.isEmpty
            ? '顺播 shunbo · MVP'
            : '顺播 shunbo · 真实源'),
        actions: [
          IconButton(
            tooltip: '跨端续播同步',
            icon: _syncBusy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.sync),
            onPressed: _syncBusy ? null : _syncNow,
          ),
          IconButton(
            tooltip: '源配置导入 / 管理',
            icon: const Icon(Icons.extension_outlined),
            onPressed: _showSourceConfigDialog,
          ),
          DropdownButton<SourcePlatform>(
            value: _platform,
            items: const [
              DropdownMenuItem(value: SourcePlatform.android, child: Text('Android')),
              DropdownMenuItem(value: SourcePlatform.desktop, child: Text('桌面')),
              DropdownMenuItem(value: SourcePlatform.tv, child: Text('TV')),
            ],
            onChanged: (p) {
              if (p == null) return;
              setState(() => _platform = p);
              // 平台裁剪会影响「下一集能在哪些源上播」，播放列表层必须同步。
              widget.queue.platform = p;
            },
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: _session != null
            ? _buildPlayerPanel()
            : _selectedEpisode != null
                ? _buildSourcePicker()
                : _selectedHit != null
                    ? _buildEpisodes()
                    : _buildSearch(),
      ),
    );
  }

  Widget _buildSearch() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildOnboardingCard(),
        _buildImportStatus(),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _keyword,
                decoration: const InputDecoration(labelText: '搜索片名', border: OutlineInputBorder()),
                onSubmitted: (_) => _doSearch(),
              ),
            ),
            const SizedBox(width: 8),
            ElevatedButton(onPressed: _doSearch, child: const Text('搜索')),
          ],
        ),
        const SizedBox(height: 12),
        if (_lastSync != null)
          Text(_lastSync!.userMessage,
              style: TextStyle(color: _lastSync!.offline ? Colors.orange : Colors.green)),
        if (_searching) const CircularProgressIndicator(),
        ..._hits.map((h) => ListTile(
              title: Text(h.result.title),
              subtitle: Text('源：${h.sourceId}'
                  '${h.qualityRank > 0 ? ' · 优先级 ${h.qualityRank}' : ''}'),
              onTap: () => _selectHit(h),
            )),
      ],
    );
  }

  /// E9 首次配置引导卡片：未接受免责声明前不提供任何外部源配置导入入口。
  Widget _buildOnboardingCard() {
    final flow = widget.onboarding;
    if (!flow.needsOnboarding) return const SizedBox.shrink();
    final s = flow.state;
    final String prompt;
    final String action;
    switch (s.step) {
      case OnboardingStep.welcome:
        prompt = '首次使用：外部源配置可能包含可执行脚本，请先确认风险声明。';
        action = '我已了解并继续';
      case OnboardingStep.sourceImport:
        prompt = '可粘贴外部源配置 JSON（须通过安全白名单逐条校验），或直接使用内置源。';
        action = '导入源配置';
      case OnboardingStep.platformConfirm:
        prompt = '确认当前设备形态，用于遥控器交互与平台源裁剪。';
        action = '确认（${_platform.name}）';
      case OnboardingStep.done:
        prompt = '';
        action = '';
    }
    final isImport = s.step == OnboardingStep.sourceImport;
    return Card(
      color: Colors.indigo.shade50,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('$prompt  [步骤 ${s.step.name}]'),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 2,
              alignment: WrapAlignment.end,
              children: [
                if (isImport)
                  TextButton(
                      onPressed: () => _advanceOnboarding(),
                      child: const Text('使用内置源')),
                TextButton(
                    onPressed: () => _advanceOnboarding(skipAll: true),
                    child: const Text('跳过引导')),
                ElevatedButton(
                    onPressed: isImport
                        ? _showSourceConfigDialog
                        : () => _advanceOnboarding(),
                    child: Text(action)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEpisodes() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('《${_selectedHit!.result.title}》剧集', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        if (_resume != null)
          Card(
            color: Colors.indigo.shade50,
            child: ListTile(
              leading: const Icon(Icons.history, color: Colors.indigo),
              title: Text(_resume!.finished
                  ? '已看完：第 ${_resume!.canonicalEpisode} 集'
                  : '继续观看：第 ${_resume!.canonicalEpisode} 集 · '
                      '${(_resume!.canonicalSeconds / 60).toStringAsFixed(0)} 分'),
              subtitle: Text(_resume!.finished
                  ? '上次源：${_resume!.sourceId} · 续播将直接进入下一集开头'
                  : '上次源：${_resume!.sourceId}'),
              trailing: ElevatedButton(
                  onPressed: _resumePlay,
                  child: Text(_resume!.finished ? '播放下一集' : '续播')),
            ),
          ),
        Wrap(
          spacing: 8,
          children: _episodes
              .map((e) => ElevatedButton(
                    onPressed: () => setState(() => _selectedEpisode = e.episode),
                    child: Text('第${e.episode}集'),
                  ))
              .toList(),
        ),
        const SizedBox(height: 12),
        const Text('选择要播放的源：', style: TextStyle(color: Colors.grey)),
      ],
    );
  }

  Widget _buildSourcePicker() {
    final candidates = _availableSourceIds;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('第${_selectedEpisode}集 · 选择源播放', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        ...candidates.map((sid) => ListTile(
              leading: const Icon(Icons.play_circle_outline),
              title: Text(sid),
              subtitle: Text('画像：${widget.catalog.get(sid)}'),
              onTap: () => _playOnSource(sid, _selectedEpisode!),
            )),
        const SizedBox(height: 8),
        TextButton(onPressed: () => setState(() => _selectedEpisode = null), child: const Text('返回选集')),
      ],
    );
  }

  /// 按当前内核算渲染面：Android 走 PlatformView，桌面走 media_kit 纹理。
  ///
  /// 返回 null 表示这个内核没有画面（Mock），UI 不该留一块黑。
  Widget? _buildSurface() {
    final p = widget.orchestrator.player;
    if (p is MediaKitPlayerController) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: MediaKitSurface(controller: p.videoController),
      );
    }
    if (needsRenderSurface(p) && p is LibMpvPlayerController) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: const PlayerSurface(),
      );
    }
    return null;
  }

  Widget _buildPlayerPanel() {
    final s = _session!;
    final others = _availableSourceIds.where((id) => id != s.sourceId).toList();
    final surface = _buildSurface();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('正在播放：${s.mediaTitle}', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
        Text('内核：${playerBackendLabel(widget.orchestrator.player)}',
            style: const TextStyle(fontSize: 12, color: Colors.grey)),
        const SizedBox(height: 8),
        // 真实内核才挂渲染面；Mock 没有画面，挂了只会留一块黑。
        if (surface != null) ...[
          surface,
          const SizedBox(height: 8),
        ],
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('当前源：${s.sourceId}', style: const TextStyle(fontSize: 16)),
                const Divider(),
                Text('原始坐标（含广告）：第 ${s.rawEpisode} 集 · ${s.rawSeconds.toStringAsFixed(1)} s'),
                Text('内容坐标（去广告）：第 ${s.contentEpisode} 集 · ${s.contentSeconds.toStringAsFixed(1)} s',
                    style: const TextStyle(color: Colors.indigo, fontWeight: FontWeight.bold)),
                const SizedBox(height: 6),
                const Text('换源时，内容坐标保持不变，仅原始坐标按目标源画像重新映射 —— 这就是「无感对齐」。',
                    style: TextStyle(color: Colors.grey, fontSize: 12)),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        const Text('换源（对齐续播）：', style: TextStyle(fontSize: 16)),
        Wrap(
          spacing: 8,
          children: others
              .map((id) => ElevatedButton.icon(
                    icon: const Icon(Icons.swap_horiz),
                    label: Text(id),
                    onPressed: () => _switchTo(id),
                  ))
              .toList(),
        ),
        const SizedBox(height: 16),
        const Text('播放进度落盘（E6）：', style: TextStyle(fontSize: 16)),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          children: [
            ElevatedButton.icon(
              icon: const Icon(Icons.fast_forward),
              label: const Text('模拟播放 +30 秒'),
              onPressed: () => _advancePlayback(30),
            ),
            OutlinedButton.icon(
              icon: const Icon(Icons.pause_circle_outline),
              label: const Text('暂停并保存进度'),
              onPressed: _pauseAndSave,
            ),
            OutlinedButton.icon(
              icon: const Icon(Icons.skip_next),
              label: const Text('模拟播到片尾'),
              onPressed: _advanceToEnding,
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(_progressSummary(),
            style: const TextStyle(fontSize: 12, color: Colors.grey)),
        if (widget.progress.degraded)
          const Text('进度写入已降级：重启可能丢失最近进度（已上报诊断）',
              style: TextStyle(fontSize: 12, color: Colors.orange)),
        const SizedBox(height: 16),
        const Text('连播（播放列表）：', style: TextStyle(fontSize: 16)),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: const Text('看完自动播放下一集', style: TextStyle(fontSize: 14)),
          subtitle: Text(
            widget.queue.episodes.isEmpty
                ? '当前没有剧集表：先选集才会连播'
                : '共 ${widget.queue.episodes.length} 集 · '
                    '片尾判定命中后推进；最后一集不会重播',
            style: const TextStyle(fontSize: 11),
          ),
          value: widget.queue.autoNext,
          onChanged: (v) async {
            await widget.queue.setAutoNext(v);
            if (mounted) setState(() {});
          },
        ),
        const SizedBox(height: 8),
        const Text('自动换源韧性（E7）：', style: TextStyle(fontSize: 16)),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          children: [
            ElevatedButton.icon(
              icon: const Icon(Icons.healing),
              label: Text(_failoverBusy ? '正在换源…' : '模拟当前源失效'),
              onPressed: _failoverBusy ? null : () => _simulateFailure(),
            ),
            OutlinedButton.icon(
              icon: const Icon(Icons.error_outline),
              label: const Text('模拟全部源失效'),
              onPressed: _failoverBusy
                  ? null
                  : () => _simulateFailure(allSourcesFailed: true),
            ),
          ],
        ),
        if (_lastFailover != null) ...[
          const SizedBox(height: 10),
          Card(
            color: _lastFailover!.recovered
                ? Colors.green.shade50
                : Colors.orange.shade50,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_lastFailover!.userMessage),
                  const SizedBox(height: 4),
                  Text(
                    '尝试记录：${_lastFailover!.attempts.isEmpty ? '无可用备用源' : _lastFailover!.attempts.map((a) => a.toString()).join(' / ')}',
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                  Text(
                    '当前内容坐标：第 ${s.contentEpisode} 集 · ${s.contentSeconds.toStringAsFixed(1)} s（换源前后守恒）',
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ],
              ),
            ),
          ),
        ],
        const SizedBox(height: 16),
        if (widget.formFactor.castEntryVisible) _buildCastSection(),
        TextButton(
            onPressed: () {
              widget.queue.detach();
              setState(() => _session = null);
            },
            child: const Text('返回选源')),
      ],
    );
  }

  /// 投屏区块（R12）。
  ///
  /// 电视形态**不显示**（R12e）：本机就是输出端，让用户在电视上「投屏到电视」
  /// 只会得到一圈无意义的设备列表。手机与桌面形态才渲染这一块。
  Widget _buildCastSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
              const Text('投屏（DLNA）：', style: TextStyle(fontSize: 16)),
              const SizedBox(height: 6),
              Row(
                children: [
                  OutlinedButton.icon(
                    icon: const Icon(Icons.search),
                    label: Text(_lanBusy ? '搜索中…' : '搜索局域网设备'),
                    onPressed: _lanBusy ? null : _discoverLan,
                  ),
                  const SizedBox(width: 8),
                  if (_lanHint != null)
                    Expanded(
                      child: Text(
                        _lanHint!,
                        style: const TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                    ),
                ],
              ),
              if (_lanDevices.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final d in _lanDevices)
                        ActionChip(
                          avatar: const Icon(Icons.tv, size: 18),
                          label: Text(d.name),
                          onPressed: (_session == null || _lanBusy)
                              ? null
                              : () => _castToLan(d),
                        ),
                    ],
                  ),
                ),
              const SizedBox(height: 12),
              if (_activeCastDevice != null)
                Card(
                  color: Colors.green.shade50,
                  child: ListTile(
                    dense: true,
                    leading: const Icon(Icons.cast_connected),
                    title: Text('正在投屏到「${_activeCastDevice!.name}」'),
                    subtitle: Text(
                      '${_castReport?.summary ?? '本机已暂停。'}'
                      '\n结束投屏会先取回设备侧真实位置，再按源画像换算成本机进度续播。',
                      style: const TextStyle(fontSize: 11),
                    ),
                    trailing: TextButton(
                      onPressed: _castBusy ? null : _stopCasting,
                      child: const Text('结束投屏'),
                    ),
                  ),
                ),
              if (_activeCastDevice != null) const SizedBox(height: 8),
              const Text('投屏兜底演示（无需真实设备）：',
                  style: TextStyle(fontSize: 13, color: Colors.grey)),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                children: [
                  ElevatedButton.icon(
                    icon: const Icon(Icons.cast),
                    label: const Text('模拟投屏成功'),
                    onPressed: _castBusy
                        ? null
                        : () => _simulateCast(dropMidPlay: false),
                  ),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.cast_connected),
                    label: const Text('模拟投屏掉线'),
                    onPressed: _castBusy
                        ? null
                        : () => _simulateCast(dropMidPlay: true),
                  ),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.wifi_off),
                    label: const Text('模拟无投屏设备'),
                    onPressed: _castBusy
                        ? null
                        : () => _simulateCast(dropMidPlay: false, noDevice: true),
                  ),
                ],
              ),
              if (_lastCast != null) ...[
                const SizedBox(height: 10),
                Card(
                  color: _lastCast!.casting
                      ? Colors.green.shade50
                      : Colors.orange.shade50,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(_lastCast!.userMessage),
                        const SizedBox(height: 4),
                        Text(
                          '尝试记录：${_lastCast!.attempts.join(' / ')}',
                          style: const TextStyle(fontSize: 12, color: Colors.grey),
                        ),
                        Text(
                          '当前内容坐标：第 ${_session!.contentEpisode} 集 · '
                          '${_session!.contentSeconds.toStringAsFixed(1)} s（降级后由调度层换算，进度守恒）',
                          style: const TextStyle(fontSize: 12, color: Colors.grey),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 12),
      ],
    );
  }
}
