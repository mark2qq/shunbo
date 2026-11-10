// 逻辑自验证：用 dart run 直接执行，绕过 flutter test 的本地 loopback 限制。
// 复刻 test/alignment_test.dart 与 test/source_adapter_test.dart 的等价断言。
import 'dart:convert';
import 'dart:io';

import 'package:shunbo/core/cast/cast_fallback.dart';
import 'package:shunbo/core/diagnostics/file_diagnostic_sink.dart';
import 'package:shunbo/data/onboarding/onboarding_flow.dart';
import 'package:shunbo/data/onboarding/source_config_validator.dart';
import 'package:shunbo/data/sync/resume_sync_engine.dart';
import 'package:shunbo/data/sync/sync_transport.dart';
import 'package:shunbo/core/scheduler/alignment.dart';
import 'package:shunbo/core/scheduler/playback_orchestrator.dart';
import 'package:shunbo/core/source/memory_source_adapter.dart';
import 'package:shunbo/core/source/source_adapter.dart';
import 'package:shunbo/core/source/source_parser_factory.dart';
import 'package:shunbo/core/source/dart_backend.dart';
import 'package:shunbo/core/source/rule_source_parser.dart';
import 'package:shunbo/core/source/site_rule.dart';
import 'package:shunbo/core/source/source_fetcher.dart';
import 'package:shunbo/core/source/parsed_source_adapter.dart';
import 'package:shunbo/core/source/source_profile.dart';
import 'package:shunbo/core/source/source_registry.dart';
import 'package:shunbo/core/scheduler/source_catalog.dart';
import 'package:shunbo/data/memory_resume_store.dart';
import 'package:shunbo/core/player/mock_player_controller.dart';
import 'package:shunbo/core/player/mpv/libmpv_player_controller.dart';
import 'package:shunbo/core/player/mpv/player_metrics.dart';
import 'package:shunbo/core/player/mpv/fake_mpv_native.dart';
import 'package:shunbo/core/player/mpv/metrics_sampler.dart';
import 'package:shunbo/core/player/mpv/mpv_backend_resolver.dart';
import 'package:shunbo/core/scheduler/playback_failure.dart';
import 'package:shunbo/core/scheduler/source_failover.dart';
import 'package:shunbo/core/diagnostics/diagnostic_sink.dart';
import 'package:shunbo/core/player/mpv/mpv_event.dart';
import 'package:shunbo/core/player/mpv/mpv_event_loop.dart';
import 'package:shunbo/core/player/mpv/mpv_event_pipeline.dart';
import 'package:shunbo/core/player/mpv/mpv_property_observer.dart';
import 'package:shunbo/data/file_config_store.dart';
import 'package:shunbo/data/file_resume_store.dart';
import 'package:shunbo/data/resume_record.dart';

int _checkCount = 0;

void check(String name, bool ok) {
  if (!ok) throw StateError('FAIL: $name');
  _checkCount++;
  print('PASS: $name');
}

Future<void> main() async {
  // --- 换源对齐（alignment_test 6 项）---
  final a = SourceProfile(name: 'A');
  final r0 = switchSource(a, a, 5, 100.0);
  check('同源原样返回', r0.$1 == 5 && r0.$2 == 100.0);

  final b = SourceProfile(name: 'B', episodeOffset: 1);
  final r1 = switchSource(a, b, 5, 100.0);
  check('集数偏移+1', r1.$1 == 6 && r1.$2 == 100.0);
  final back1 = switchSource(b, a, r1.$1, r1.$2);
  check('偏移往返一致', back1.$1 == 5 && back1.$2 == 100.0);

  final bAd = SourceProfile(name: 'B', adInterval: 600.0, adDuration: 30.0);
  final r2 = switchSource(a, bAd, 1, 650.0);
  check('广告错位对齐', r2.$1 == 1 && r2.$2 == 680.0);
  final back2 = switchSource(bAd, a, r2.$1, r2.$2);
  check('广告往返一致', back2.$1 == 1 && back2.$2 == 650.0);

  final a2 = SourceProfile(name: 'A', episodeOffset: -1, adInterval: 900.0, adDuration: 20.0);
  final b2 = SourceProfile(name: 'B', episodeOffset: 2, adInterval: 600.0, adDuration: 30.0);
  const original = (7, 1234.5);
  final r3 = switchSource(a2, b2, original.$1, original.$2);
  final back3 = switchSource(b2, a2, r3.$1, r3.$2);
  check('偏移+广告跨源往返', back3.$1 == original.$1 && (back3.$2 - original.$2).abs() < 1e-6);

  final bCal = calibrate(a, SourceProfile(name: 'B', adInterval: 600.0, adDuration: 0.0), 1, 650.0, 1, 680.0);
  check('校准反解 adDuration', bCal.episodeOffset == 0 && (bCal.adDuration - 30.0).abs() < 1e-6);

  final bCal2 = calibrate(a, SourceProfile(name: 'B', episodeOffset: 0), 5, 100.0, 6, 100.0);
  check('仅校准偏移', bCal2.episodeOffset == 1);

  // --- 源适配（source_adapter_test 2 项，异步）---
  final eps = const [EpisodeInfo(episode: 1, title: 'E1'), EpisodeInfo(episode: 2, title: 'E2')];
  final urls = {
    'm#1': const [PlayUrl(url: 'a.mp4', qualityRank: 1), PlayUrl(url: 'b.mp4', qualityRank: 2)],
  };
  final adapter = MemorySourceAdapter(
    id: 'demo',
    profile: const SourceProfile(name: 'demo'),
    episodes: {'m': eps},
    urls: urls,
  );
  final found = await adapter.search('m');
  check('搜索命中 1 条', found.length == 1 && found.first.mediaId == 'm');
  final gotEps = await adapter.getEpisodes('m');
  check('剧集 2 条', gotEps.length == 2 && gotEps.first.episode == 1);
  final gotUrls = await adapter.resolvePlayUrl('m', 1);
  check('多清晰度候选', gotUrls.length == 2 && gotUrls.map((u) => u.qualityRank).toSet().containsAll({1, 2}));

  // --- 源注册表平台裁剪 ---
  final reg = SourceRegistry()
    ..register(MemorySourceAdapter(
      id: 'a-only',
      profile: const SourceProfile(name: 'a-only'),
      supportedPlatforms: {SourcePlatform.android},
    ))
    ..register(MemorySourceAdapter(
      id: 'uni',
      profile: const SourceProfile(name: 'uni'),
      supportedPlatforms: {SourcePlatform.android, SourcePlatform.desktop, SourcePlatform.tv},
    ));
  final desktop = reg.availableOn(SourcePlatform.desktop).map((e) => e.id).toList();
  check('桌面仅 uni', desktop.length == 1 && desktop.first == 'uni');
  final android = reg.availableOn(SourcePlatform.android).map((e) => e.id).toList();
  check('安卓含 a-only 与 uni', android.toSet().containsAll({'a-only', 'uni'}));

  // --- 播放编排 + 换源对齐端到端（MVP 核心）---
  final ykP = const SourceProfile(name: 'yk');
  final fqP = const SourceProfile(name: 'fq', episodeOffset: 1, adInterval: 600.0, adDuration: 30.0);
  const mid = 'qyn';
  final epsQ = const [EpisodeInfo(episode: 1, title: 'E1'), EpisodeInfo(episode: 2, title: 'E2')];
  final urlsYK = {
    '$mid#1': const [PlayUrl(url: 'yk1.m3u8', qualityRank: 2)],
    '$mid#2': const [PlayUrl(url: 'yk2.m3u8', qualityRank: 2)],
  };
  final fqUrls = {
    '$mid#1': const [PlayUrl(url: 'fq1.m3u8', qualityRank: 1)],
    '$mid#2': const [PlayUrl(url: 'fq2.m3u8', qualityRank: 1)],
  };
  final reg2 = SourceRegistry()
    ..register(MemorySourceAdapter(id: 'yk', profile: ykP, episodes: {mid: epsQ}, urls: urlsYK))
    ..register(MemorySourceAdapter(id: 'fq', profile: fqP, episodes: {mid: epsQ}, urls: fqUrls));
  final cat2 = SourceCatalog()..register(ykP)..register(fqP);
  final player = MockPlayerController();
  final resume = MemoryResumeStore();
  final orch = PlaybackOrchestrator(registry: reg2, catalog: cat2, player: player, resumeStore: resume);

  final hits2 = await orch.search('qyn', SourcePlatform.desktop);
  check('编排搜索命中 2 源', hits2.length == 2);

  // 初始在 yk 播第 1 集内容 0 秒（yk 无偏移无广告 → 原始即内容）。
  final s0 = await orch.startPlayback(
    sourceId: 'yk',
    mediaId: mid,
    mediaTitle: '庆余年',
    canonicalEpisode: 1,
    canonicalSeconds: 0.0,
  );
  check('yk 初始原始=内容', s0.rawEpisode == 1 && s0.rawSeconds == 0.0);
  check('yk 已载入播放器', player.loadedUrl == 'yk1.m3u8' && player.playing);

  // E6 续播落盘：初始播放后应有续播记录（规范坐标）。
  final rec0 = await orch.resumeFor(mid);
  check('续播记录已落盘(初始)', rec0 != null && rec0.canonicalEpisode == 1 && rec0.canonicalSeconds == 0.0 && rec0.sourceId == 'yk');

  // 把播放进度推到第 1 集 650s（模拟看了 10 分钟），再换到 fq 源。
  await player.seek(650.0); // 模拟播放器内部位置
  final sw = await orch.switchSourceAligned(
    fromSourceId: 'yk',
    toSourceId: 'fq',
    mediaId: mid,
    mediaTitle: '庆余年',
    fromRawEpisode: 1,
    fromRawSeconds: 650.0,
  );
  // 关键断言：换源前后「内容坐标」必须一致（第1集 650s）。
  check('换源内容集不变', sw.session.contentEpisode == 1);
  check('换源内容秒不变', (sw.session.contentSeconds - 650.0).abs() < 1e-6);
  // fq 有偏移+1 → 原始集应为 2；广告映射应使原始秒为 680。
  check('fq 原始集对齐+1', sw.alignedRawEpisode == 2);
  check('fq 原始秒广告对齐', (sw.alignedRawSeconds - 680.0).abs() < 1e-6);
  check('换源后载入 fq', player.loadedUrl == 'fq2.m3u8');

  // E6 续播：换源后续播记录应反映「内容坐标」（与源无关），而非源原始坐标。
  final rec1 = await orch.resumeFor(mid);
  final resumeRec = rec1!;
  check('续播记录内容坐标=换源后内容位置', resumeRec.canonicalEpisode == 1 && (resumeRec.canonicalSeconds - 650.0).abs() < 1e-6 && resumeRec.sourceId == 'fq');
  // 跨端续播：用同一 resume store 新建编排（模拟换端/换源），从记录恢复，内容坐标须一致。
  final orch2 = PlaybackOrchestrator(registry: reg2, catalog: cat2, player: MockPlayerController(), resumeStore: resume);
  final sR = await orch2.startPlayback(
    sourceId: 'yk',
    mediaId: mid,
    mediaTitle: '庆余年',
    canonicalEpisode: resumeRec.canonicalEpisode,
    canonicalSeconds: resumeRec.canonicalSeconds,
  );
  check('跨端续播内容坐标一致', sR.contentEpisode == 1 && (sR.contentSeconds - 650.0).abs() < 1e-6);
  // remove
  await resume.remove(mid);
  check('续播记录可删除', await orch.resumeFor(mid) == null);

  // --- E3 libmpv 封装契约 + 指标门禁（纯 Dart 验证，不依赖原生构建）---
  final fake = FakeMpvNative();
  final ctrl = LibMpvPlayerController(native: fake);
  await ctrl.initialize();
  await ctrl.load('yk1.m3u8', 2, 680.0);
  check('libmpv 已载入 url', fake.loaded && fake.lastUrl == 'yk1.m3u8');
  check('libmpv 已定位原始秒', fake.time == 680.0);
  check('libmpv 默认指标门禁通过', ctrl.lastGate!.passed);
  check('libmpv 采样首帧达标', ctrl.lastMetrics!.firstFrameMs == 300);

  // 门禁失败场景：首帧严重超标（压低首帧与降内存的博弈被打破）。
  final fakeBad = FakeMpvNative(
    metrics: const PlayerMetrics(firstFrameMs: 2000, memoryMb: 80.0, droppedFrameRate: 0.005),
  );
  final ctrlBad = LibMpvPlayerController(native: fakeBad);
  await ctrlBad.load('bad.m3u8', 1, 0.0);
  check('libmpv 门禁失败(首帧超标)', !ctrlBad.lastGate!.passed && ctrlBad.lastGate!.failures.isNotEmpty);

  // 门禁失败场景：内存超标。
  final fakeMem = FakeMpvNative(
    metrics: const PlayerMetrics(firstFrameMs: 300, memoryMb: 200.0, droppedFrameRate: 0.005),
  );
  final ctrlMem = LibMpvPlayerController(native: fakeMem, gate: const PlayerMetricGate(maxMemoryMb: 120));
  await ctrlMem.load('mem.m3u8', 1, 0.0);
  check('libmpv 门禁失败(内存超标)', !ctrlMem.lastGate!.passed);

  // --- E2 真实适配器（桌面 Dart 解析子集 + 注入 fetcher，不联网）---
  final fetcher = MockFetcher({
    'search:庆余年':
        '<div class="item" data-id="qyn"><a>庆余年</a></div>',
    'detail:qyn':
        '<a class="ep" data-ep="1" href="/play/qyn/1">第1集</a>'
        '<a class="ep" data-ep="2" href="/play/qyn/2">第2集</a>',
    'play:qyn:/play/qyn/1':
        '<video src="qyn1.m3u8"></video>'
        '<a class="q" data-rank="2" href="qyn1-720.m3u8">720</a>',
  });
  final dartProfile = const SourceProfile(name: 'dart-yk');
  final dartAdapter = ParsedSourceAdapter(
    id: 'dart-yk',
    profile: dartProfile,
    parser: DartSourceParser(),
    fetcher: fetcher,
    supportedPlatforms: {
      SourcePlatform.desktop,
      SourcePlatform.android,
      SourcePlatform.tv,
    },
  );
  final found2 = await dartAdapter.search('庆余年');
  check('E2 解析搜索命中', found2.length == 1 && found2.first.mediaId == 'qyn');
  final eps2 = await dartAdapter.getEpisodes('qyn');
  check('E2 解析剧集(2集)', eps2.length == 2 && eps2.first.episode == 1);
  final urls2 = await dartAdapter.resolvePlayUrl('qyn', 1);
  check('E2 解析播放地址含多清晰度',
      urls2.length == 2 && urls2.any((u) => u.url == 'qyn1.m3u8') && urls2.any((u) => u.qualityRank == 2));

  // E2 真实适配器驱动「编排 → 对齐 → 播放」全链路闭合。
  final p2 = MockPlayerController();
  final reg3 = SourceRegistry()..register(dartAdapter);
  final cat3 = SourceCatalog()..register(dartProfile);
  final orch3 = PlaybackOrchestrator(
    registry: reg3,
    catalog: cat3,
    player: p2,
    resumeStore: MemoryResumeStore(),
  );
  final s3 = await orch3.startPlayback(
    sourceId: 'dart-yk',
    mediaId: 'qyn',
    mediaTitle: '庆余年',
    canonicalEpisode: 1,
    canonicalSeconds: 0.0,
  );
  // 编排层按 qualityRank 择优，故载入 rank=2 的 720 地址（证明多清晰度择优生效）。
  check('E2 真实适配器驱动编排播放(择优最高清晰度)',
      p2.loadedUrl == 'qyn1-720.m3u8' && p2.playing && s3.contentEpisode == 1);

  // E2 桌面/TV 工厂路由（jar 仅 Android，由 jar_backend 直接构造，不在此通用工厂）。
  check('E2 工厂返回 Dart 解析器', createParser() is DartSourceParser);
  check('E2 工厂返回 Dart fetcher',
      createFetcher(baseUrl: 'https://e') is DartHttpFetcher);

  // E2 健壮性：全新适配器未先调 getEpisodes，直接 resolvePlayUrl 应自愈（补拉详情页）。
  final fresh = ParsedSourceAdapter(
    id: 'dart-yk',
    profile: dartProfile,
    parser: DartSourceParser(),
    fetcher: fetcher,
    supportedPlatforms: {SourcePlatform.desktop},
  );
  final freshUrls = await fresh.resolvePlayUrl('qyn', 1);
  check('E2 未取剧集直接取址可自愈',
      freshUrls.length == 2 && freshUrls.any((u) => u.url == 'qyn1.m3u8'));

  // --- E3 真实指标采样器 + 三者牵制模型 + 后端决议（纯 Dart，不依赖原生库）---
  final fclk = FakeSamplerClock(0);
  final sampler = MetricsSampler(clock: fclk, memoryProbe: () => 80.0);
  sampler.onLoadStart();
  fclk.advance(300);
  sampler.onFirstFrame();
  for (var i = 0; i < 995; i++) {
    sampler.onFrameRendered();
  }
  for (var i = 0; i < 5; i++) {
    sampler.onDroppedFrame();
  }
  fclk.advance(1000);
  final sm = sampler.sample();
  check('采样器首帧耗时=300ms', sm.firstFrameMs == 300);
  check('采样器丢帧率=0.005', (sm.droppedFrameRate - 0.005).abs() < 1e-9);
  check('采样器三项门禁通过',
      const PlayerMetricGate().evaluate(sm).passed && sm.memoryMb == 80.0);

  // 首帧未到达 → 哨兵值，门禁必判失败（防止"没采样到"被误放行）。
  final sampler0 = MetricsSampler(clock: FakeSamplerClock(0), memoryProbe: () => 80.0);
  sampler0.onLoadStart();
  check('首帧未到达=不达标', sampler0.sample().firstFrameMs == kFirstFramePendingMs &&
      !const PlayerMetricGate().evaluate(sampler0.sample()).passed);

  // 三者相互牵制模型：单压首帧会顶高内存/卡顿，必须取平衡解。
  const model = KernelTradeoffModel();
  final aggressive = model.estimate(const KernelTuning(prebufferFrames: 24, cacheMb: 32));
  check('单压首帧+大缓存→内存超标', aggressive.firstFrameMs <= 800 &&
      !const PlayerMetricGate().evaluate(aggressive).passed);
  final lowCache = model.estimate(const KernelTuning(prebufferFrames: 24, cacheMb: 0));
  check('无缓存→卡顿率超标', lowCache.droppedFrameRate > 0.01);
  final balanced = model.findBalancedTuning();
  check('牵制模型存在三项达标平衡解', balanced != null &&
      const PlayerMetricGate().evaluate(model.estimate(balanced)).passed);
  check('平衡解=预解码4帧/缓存24MB(内存76MB最省)',
      balanced != null && balanced.prebufferFrames == 4 && balanced.cacheMb == 24 &&
      model.estimate(balanced).memoryMb == 76.0);

  // 后端决议：库可用走 FFI，缺失降级到平台通道（ExoPlayer 回退）。
  final rFfi = resolveMpvBackend(const FakeMpvLibraryProbe(true));
  check('libmpv 可用→FFI 后端', rFfi.backend == MpvBackend.ffi);
  final rFallback = resolveMpvBackend(const FakeMpvLibraryProbe(false, 'libmpv-2.dll'));
  check('libmpv 缺失→平台通道降级',
      rFallback.backend == MpvBackend.platformChannel && rFallback.reason.contains('降级'));

  // --- E6 真实持久化：JSON 落盘 + 原子写 + 重启回读 + 损坏降级 ---
  final diskDir = await Directory.systemTemp.createTemp('shunbo_resume_');
  final diskFile = File('${diskDir.path}/resume.json');
  final diskStore1 = FileResumeStore(diskFile);
  final diskRec = ResumeRecord(
    mediaId: 'qyn',
    title: '庆余年',
    sourceId: 'yk',
    canonicalEpisode: 2,
    canonicalSeconds: 612.5,
    updatedAt: DateTime.parse('2026-11-05T12:00:00'),
  );
  await diskStore1.save(diskRec);
  check('E6 真实落盘文件已生成', await diskFile.exists());

  final diskStore2 = FileResumeStore(diskFile); // 模拟进程重启 / 换端
  final diskBack = await diskStore2.load('qyn');
  check('E6 重启回读内容坐标一致',
      diskBack != null &&
          diskBack.canonicalEpisode == 2 &&
          (diskBack.canonicalSeconds - 612.5).abs() < 1e-9 &&
          diskBack.sourceId == 'yk');
  check('E6 记录列表含 1 条', (await diskStore2.all()).length == 1);

  final leftovers = await diskDir
      .list()
      .map((e) => e.path)
      .where((p) => p.endsWith('.tmp') || p.endsWith('.bak'))
      .toList();
  check('E6 原子写无临时文件残留', leftovers.isEmpty);

  await diskStore2.remove('qyn');
  final diskStore3 = FileResumeStore(diskFile);
  check('E6 删除后重启仍为空', await diskStore3.load('qyn') == null);

  await diskFile.writeAsString('{broken json');
  final diskStore4 = FileResumeStore(diskFile);
  check('E6 文件损坏降级不抛异常',
      await diskStore4.load('qyn') == null && diskStore4.degraded);
  await diskDir.delete(recursive: true);

  // --- E7 自动换源韧性：失效 → 跳过坏源 → 对齐恢复 → 全失效兜底 ---
  const fProfileA = SourceProfile(name: 'fa'); // 当前源：基准
  const fProfileB = SourceProfile(name: 'fb', episodeOffset: 1); // 坏源：解析不到地址
  const fProfileC = // 好源：每 600s 插 30s 广告
      SourceProfile(name: 'fc', adInterval: 600.0, adDuration: 30.0);
  const fMid = 'failmedia';
  const fEps = [
    EpisodeInfo(episode: 1, title: 'E1'),
    EpisodeInfo(episode: 2, title: 'E2'),
  ];
  final fReg = SourceRegistry()
    ..register(MemorySourceAdapter(
      id: 'fa',
      profile: fProfileA,
      episodes: const {fMid: fEps},
      urls: const {
        '$fMid#1': [PlayUrl(url: 'fa1.m3u8')],
      },
    ))
    ..register(MemorySourceAdapter(
      id: 'fb',
      profile: fProfileB,
      episodes: const {fMid: fEps},
      urls: const <String, List<PlayUrl>>{}, // 模拟站点失效：无地址
    ))
    ..register(MemorySourceAdapter(
      id: 'fc',
      profile: fProfileC,
      episodes: const {fMid: fEps},
      urls: const {
        '$fMid#1': [PlayUrl(url: 'fc1.m3u8')],
      },
    ));
  final fCat = SourceCatalog()
    ..register(fProfileA)
    ..register(fProfileB)
    ..register(fProfileC);
  final fPlayer = MockPlayerController();
  final fResume = MemoryResumeStore();
  final fOrch = PlaybackOrchestrator(
    registry: fReg,
    catalog: fCat,
    player: fPlayer,
    resumeStore: fResume,
  );
  final fFailover = SourceFailover(
    orchestrator: fOrch,
    registry: fReg,
    catalog: fCat,
  );

  // 失效语义：解析不到地址抛「可恢复失效」，而非程序员错误；且绝不落盘假进度。
  var fThrew = false;
  try {
    await fOrch.startPlayback(
      sourceId: 'fb',
      mediaId: fMid,
      mediaTitle: '测试剧',
      canonicalEpisode: 1,
      canonicalSeconds: 0.0,
    );
  } on PlaybackFailureException catch (e) {
    fThrew = e.reason == PlaybackFailureReason.emptyPlayUrl;
  }
  check('E7 无地址源抛可恢复失效(非 StateError)', fThrew);
  check('E7 失效不落盘假进度', await fOrch.resumeFor(fMid) == null);

  final fSession = PlaybackSession.fromRaw(
    mediaId: fMid,
    mediaTitle: '测试剧',
    sourceId: 'fa',
    profile: fProfileA,
    rawEpisode: 1,
    rawSeconds: 650.0,
    playUrl: 'https://example.invalid/f.m3u8',
  );
  const fFailure = PlaybackFailureException(
    reason: PlaybackFailureReason.stallTimeout,
    sourceId: 'fa',
    message: '模拟：卡顿超时',
  );

  // 策略上限：只允许试 1 个备用源（恰好是坏源 fb）→ 应判定全失效。
  final fLimited = SourceFailover(
    orchestrator: fOrch,
    registry: fReg,
    catalog: fCat,
    policy: const FailoverPolicy(maxAttempts: 1),
  );
  final fLimitedResult = await fLimited.recover(
    failedSession: fSession,
    failure: fFailure,
    platform: SourcePlatform.desktop,
  );
  check('E7 策略上限生效(最多1次尝试)',
      !fLimitedResult.recovered && fLimitedResult.attempts.length == 1);

  final fResult = await fFailover.recover(
    failedSession: fSession,
    failure: fFailure,
    platform: SourcePlatform.desktop,
  );
  final fS = fResult.session;
  check('E7 自动换源成功恢复(跳过坏源)',
      fResult.recovered && fS != null && fS.sourceId == 'fc');
  check('E7 尝试轨迹=失败 fb→成功 fc',
      fResult.attempts.length == 2 &&
          !fResult.attempts.first.succeeded &&
          fResult.attempts.last.succeeded);
  check('E7 内容坐标守恒(自动换源)',
      fS != null &&
          fS.contentEpisode == fSession.contentEpisode &&
          (fS.contentSeconds - fSession.contentSeconds).abs() < 1e-9);
  check('E7 恢复后载入真实地址', fPlayer.loadedUrl == 'fc1.m3u8');
  check('E7 目标源广告错位对齐=680s',
      (fPlayer.loadedRawSeconds - 680.0).abs() < 1e-9);

  // 全源失效：不崩溃、不伪造会话，给出可执行兜底文案。
  final fAll = await fFailover.recover(
    failedSession: fSession,
    failure: fFailure,
    platform: SourcePlatform.desktop,
    excludeSources: const {'fb', 'fc'},
  );
  check('E7 全源失效→兜底而非崩溃',
      !fAll.recovered && fAll.session == null && fAll.attempts.isEmpty);
  check('E7 兜底文案给出可执行下一步',
      fAll.userMessage.contains('稍后重试') || fAll.userMessage.contains('源配置'));

  // --- E3 事件循环 / Property 观察 / 指标管线（真机集成的数据通路）---
  check('E3 坏行解析返回 null', MpvEvent.tryParse('{oops') == null);
  final pe = MpvEvent.tryParse(
      '{"event":"property-change","name":"time-pos","data":12.5}');
  check('E3 property-change 解析',
      pe != null &&
          pe.kind == MpvEventKind.propertyChange &&
          pe.name == 'time-pos' &&
          pe.numericData == 12.5);
  final ee = MpvEvent.tryParse('{"event":"end-file","reason":"eof"}');
  check('E3 end-file reason 解析', ee != null && ee.data == 'eof');
  final ue = MpvEvent.tryParse('{"event":"new-kind-v9"}');
  check('E3 未知事件不丢弃',
      ue != null && ue.kind == MpvEventKind.unknown && ue.eventName == 'new-kind-v9');

  final lp = MpvEventLoop();
  var propCount = 0;
  var allCount = 0;
  lp.on(MpvEventKind.propertyChange, (_) => propCount++);
  lp.on(null, (_) => allCount++);
  final throwing = lp.on(null, (_) => throw StateError('boom'));
  lp.acceptRaw('{"event":"file-loaded"}');
  lp.acceptRaw('{bad json');
  lp.acceptRaw('{"event":"playback-restart"}');
  lp.pump();
  check('E3 循环分发+类型过滤', propCount == 0 && allCount == 2);
  check('E3 坏行只计数不分发', lp.malformed == 1 && lp.dispatched == 2);
  check('E3 订阅者异常被隔离', lp.handlerErrors == 2 && allCount == 2);
  throwing.cancel();
  lp.acceptRaw('{"event":"property-change","name":"pause","data":true}');
  lp.pump();
  check('E3 取消订阅生效',
      lp.handlerErrors == 2 && propCount == 1 && allCount == 3);

  final qp = MpvEventLoop(maxQueueSize: 2);
  qp.acceptRaw('{"event":"file-loaded"}');
  qp.acceptRaw('{"event":"playback-restart"}');
  qp.acceptRaw('{"event":"end-file","reason":"eof"}');
  check('E3 背压丢弃最旧', qp.dropped == 1 && qp.queued == 2);
  final queueKinds = <MpvEventKind>[];
  qp.on(null, (e) => queueKinds.add(e.kind));
  qp.pump();
  check('E3 背压保留最新',
      queueKinds.length == 2 &&
          queueKinds[0] == MpvEventKind.playbackRestart &&
          queueKinds[1] == MpvEventKind.endFile);

  final pp = MpvEventLoop();
  var ppCount = 0;
  pp.on(null, (_) => ppCount++);
  pp.setPaused(true);
  pp.acceptRaw('{"event":"file-loaded"}');
  pp.pump();
  check('E3 暂停不分发', ppCount == 0 && pp.queued == 1);
  pp.setPaused(false);
  check('E3 恢复后补发', ppCount == 1 && pp.queued == 0);

  // Property 观察 → 采样器 → 门禁 全链路事件驱动。
  // 用 attach 逐行即时分发（真机 EventChannel 路径）：若批量入队后统一 pump，
  // 多个事件会落在同一时钟刻，首帧耗时会被算成 0 —— 这是必须避免的集成陷阱。
  final oclk = FakeSamplerClock(0);
  final osampler = MetricsSampler(clock: oclk, memoryProbe: () => 80.0);
  final obs = MpvPropertyObserver(sampler: osampler, sampleEveryFrames: 1000);
  final olp = MpvEventLoop();
  obs.bindTo(olp);
  final ofeed = MpvEventFeed();
  final osub = olp.attach(ofeed);
  ofeed.emit('{"event":"file-loaded"}');
  oclk.advance(300);
  ofeed.emit('{"event":"playback-restart"}');
  ofeed.emit('{"event":"property-change","name":"time-pos","data":42.5}');
  ofeed.emit(
      '{"event":"property-change","name":"demuxer-cache-duration","data":3.5}');
  ofeed.emit('{"event":"property-change","name":"pause","data":true}');
  ofeed.emit(
      '{"event":"property-change","name":"estimated-frame-count","data":995}');
  ofeed.emit(
      '{"event":"property-change","name":"drop-frame-count","data":5}');
  check('E3 事件驱动自动采样(累计1000帧)',
      obs.sampleCount == 1 && obs.lastMetrics != null);
  final om = obs.lastMetrics;
  check('E3 观察器指标=首帧300ms/丢帧0.005/门禁通过',
      om != null &&
          om.firstFrameMs == 300 &&
          (om.droppedFrameRate - 0.005).abs() < 1e-9 &&
          obs.lastGate != null &&
          obs.lastGate!.passed);
  check('E3 运行态累积(time/cache/pause/帧计数)',
      obs.state.timePos == 42.5 &&
          obs.state.cacheSeconds == 3.5 &&
          obs.state.paused &&
          obs.state.droppedFramesTotal == 5 &&
          obs.state.renderedFramesTotal == 995);

  // 首帧未到达：门禁必判失败（防止「没采样到」被误放行）。
  final nclk = FakeSamplerClock(0);
  final nsampler = MetricsSampler(clock: nclk, memoryProbe: () => 80.0);
  final gateHits = <GateResult>[];
  final nobs = MpvPropertyObserver(
      sampler: nsampler, onSample: (m, g) => gateHits.add(g));
  final nlp = MpvEventLoop();
  nobs.bindTo(nlp);
  nlp.acceptRaw('{"event":"file-loaded"}');
  nlp.pump();
  nobs.forceSample();
  check('E3 首帧未到达→门禁失败并回调',
      gateHits.length == 1 &&
          !gateHits.first.passed &&
          nobs.lastMetrics!.firstFrameMs == kFirstFramePendingMs);

  // seek 导致累计帧数回退时，不得产生负增量/重复计数。
  ofeed.emit(
      '{"event":"property-change","name":"drop-frame-count","data":3}');
  check('E3 累计值回退不重复计数', obs.state.droppedFramesTotal == 5);
  await osub.cancel();
  await ofeed.close();

  // 事件管线：原生流 → 事件循环 → 观察器 → 门禁 → 诊断埋点。
  final feed = MpvEventFeed();
  final psink = MemoryDiagnosticSink();
  final pclk = FakeSamplerClock(0);
  final pipeline = MpvEventPipeline.attach(
    feed,
    sampler: MetricsSampler(clock: pclk, memoryProbe: () => 200.0), // 内存超标
    sampleEveryFrames: 1,
    diagnostics: psink,
  );
  feed.emit('{"event":"file-loaded"}');
  pclk.advance(100);
  feed.emit('{"event":"playback-restart"}');
  feed.emit(
      '{"event":"property-change","name":"estimated-frame-count","data":1}');
  feed.emit('{bad');
  pipeline.reportMalformed();
  check('E3 管线端到端(门禁失败自动埋点)',
      psink.ofKind(DiagnosticKind.metricGateFailed).length == 1 &&
          psink
              .ofKind(DiagnosticKind.metricGateFailed)
              .first
              .detail
              .contains('内存'));
  check('E3 管线坏行上报',
      psink.ofKind(DiagnosticKind.mpvEventMalformed).length == 1);
  pipeline.reportMalformed();
  check('E3 管线坏行不重复上报',
      psink.ofKind(DiagnosticKind.mpvEventMalformed).length == 1);
  pipeline.dispose();
  await feed.close();

  // --- E7 结构化诊断埋点（FailoverAttempt 轨迹直接作线上排障数据源）---
  final diag = MemoryDiagnosticSink();
  final diagFailover = SourceFailover(
    orchestrator: fOrch,
    registry: fReg,
    catalog: fCat,
    diagnostics: diag,
  );
  final diagResult = await diagFailover.recover(
    failedSession: fSession,
    failure: fFailure,
    platform: SourcePlatform.desktop,
  );
  check('E7 埋点序列=失效→尝试×2→恢复',
      diagResult.recovered &&
          diag.kinds.length == 4 &&
          diag.kinds[0] == DiagnosticKind.playbackFailure &&
          diag.kinds[1] == DiagnosticKind.failoverAttempt &&
          diag.kinds[2] == DiagnosticKind.failoverAttempt &&
          diag.kinds[3] == DiagnosticKind.failoverRecovered);
  final diagFirst = diag.events.first;
  check('E7 埋点含结构化属性',
      diagFirst.attributes['reason'] == 'stallTimeout' &&
          diagFirst.attributes['platform'] == 'desktop' &&
          diagFirst.attributes['candidates'] == 2);
  final diag2 = MemoryDiagnosticSink();
  final diagFailover2 = SourceFailover(
    orchestrator: fOrch,
    registry: fReg,
    catalog: fCat,
    diagnostics: diag2,
  );
  await diagFailover2.recover(
    failedSession: fSession,
    failure: fFailure,
    platform: SourcePlatform.desktop,
    excludeSources: const {'fb', 'fc'},
  );
  check('E7 全失效埋点=exhausted',
      diag2.kinds.contains(DiagnosticKind.failoverExhausted) &&
          !diag2.kinds.contains(DiagnosticKind.failoverRecovered));

  // --- E6 跨端续播同步：Lamport 逻辑时钟 / 墓碑 / 离线队列 / 幂等 ---
  final syTransport = InMemorySyncTransport();
  final syLocalA = SyncAwareResumeStore(MemoryResumeStore());
  final syEngineA = ResumeSyncEngine(
      local: syLocalA, transport: syTransport, deviceId: 'device-A');
  final syRecA = ResumeRecord(
    mediaId: 'm1',
    title: '跨端剧',
    sourceId: 'yk',
    canonicalEpisode: 1,
    canonicalSeconds: 100.0,
    updatedAt: DateTime.parse('2026-11-05T10:00:00'),
  );
  await syLocalA.save(syRecA);
  check('E6 同步装饰器拦截本地写入', syEngineA.pendingCount == 1);
  final syFirst = await syEngineA.sync();
  check('E6 首次同步上行并清空队列',
      !syFirst.offline && syFirst.pushed == 1 && syEngineA.pendingCount == 0);
  check('E6 远端快照含规范内容坐标',
      syTransport.remote.entries['m1'] != null &&
          syTransport.remote.entries['m1']!.record!.canonicalSeconds == 100.0);

  final syLocalB = SyncAwareResumeStore(MemoryResumeStore());
  final syEngineB = ResumeSyncEngine(
      local: syLocalB, transport: syTransport, deviceId: 'device-B');
  final sySecond = await syEngineB.sync();
  check('E6 设备B下行进度(跨端续播)',
      sySecond.pulled == 1 &&
          (await syLocalB.load('m1'))!.canonicalSeconds == 100.0);
  check('E6 应用远端变更不产生回声写入', syEngineB.pendingCount == 0);
  final syStampBefore = syTransport.remote.entries['m1']!.stamp;
  await syEngineB.sync();
  check('E6 无新写入时同步幂等',
      syTransport.remote.entries['m1']!.stamp == syStampBefore &&
          (await syLocalB.load('m1'))!.canonicalSeconds == 100.0);

  // 时钟偏移暗坑：A 把挂钟改到 2035 年并同步；B 仍在 2020 年但「后写」。
  // 若按 updatedAt 取最新，B 的进度会被永久压制；Lamport stamp 应让 B 胜出。
  await syLocalA.save(syRecA.copyWith(
      canonicalSeconds: 200.0,
      updatedAt: DateTime.parse('2035-01-01T00:00:00')));
  await syEngineA.sync();
  await syLocalB.save(syRecA.copyWith(
      canonicalSeconds: 300.0,
      updatedAt: DateTime.parse('2020-01-01T00:00:00')));
  await syEngineB.sync();
  check('E6 时钟偏移不压制后写者(逻辑时钟裁决)',
      syTransport.remote.entries['m1']!.record!.canonicalSeconds == 300.0);
  await syEngineA.sync();
  check('E6 冲突后两端收敛一致',
      (await syLocalA.load('m1'))!.canonicalSeconds == 300.0 &&
          (await syLocalB.load('m1'))!.canonicalSeconds == 300.0);

  // 删除复活暗坑：墓碑必须让旧设备的过期记录无法把已删进度推回来。
  await syLocalA.remove('m1');
  await syEngineA.sync();
  check('E6 删除写入墓碑而非抹除条目',
      syTransport.remote.entries['m1']!.isTombstone);
  await syEngineB.sync();
  check('E6 旧设备同步不会复活已删除进度',
      await syLocalB.load('m1') == null);

  // 离线队列：断网不损伤本地进度，恢复后原样重传且不重复。
  syTransport.offline = true;
  await syLocalB.save(ResumeRecord(
    mediaId: 'm2',
    title: '离线剧',
    sourceId: 'fq',
    canonicalEpisode: 2,
    canonicalSeconds: 42.0,
    updatedAt: DateTime.parse('2026-11-05T11:00:00'),
  ));
  final syOffline = await syEngineB.sync();
  check('E6 离线同步保留待同步项且本地可读',
      syOffline.offline &&
          syOffline.pending == 1 &&
          (await syLocalB.load('m2')) != null);
  syTransport.offline = false;
  final syRetry = await syEngineB.sync();
  final syM2Stamp = syTransport.remote.entries['m2']!.stamp;
  check('E6 恢复后自动重传',
      !syRetry.offline &&
          syEngineB.pendingCount == 0 &&
          syTransport.remote.entries['m2']!.record!.canonicalSeconds == 42.0);
  await syEngineB.sync();
  check('E6 重传后重复同步幂等(stamp不变)',
      syTransport.remote.entries['m2']!.stamp == syM2Stamp);

  // 对端数据损坏：坏条目逐条跳过，坏 JSON 整体降级空集，不阻断播放。
  final syBad = InMemorySyncTransport();
  syBad.seedRaw(jsonEncode({
    'version': 1,
    'entries': [
      {
        'mediaId': 'ok',
        'record': {
          'mediaId': 'ok',
          'title': 'T',
          'sourceId': 's',
          'canonicalEpisode': 1,
          'canonicalSeconds': 9.0,
          'updatedAt': '2026-11-05T00:00:00'
        },
        'stamp': 3,
        'writerDeviceId': 'x'
      },
      {'bad': 1},
      'garbage',
    ]
  }));
  final syBadLocal = SyncAwareResumeStore(MemoryResumeStore());
  final syBadEngine = ResumeSyncEngine(
      local: syBadLocal, transport: syBad, deviceId: 'bad-dev');
  final syBadResult = await syBadEngine.sync();
  check('E6 对端脏数据隔离(坏条目跳过)',
      syBadResult.pushed == 1 &&
          (await syBadLocal.load('ok'))!.canonicalSeconds == 9.0);
  check('E6 快照坏 JSON 降级空集',
      SyncSnapshot.fromJsonText('{oops').entries.isEmpty);

  // 并发冲突计数 + 结构化诊断埋点。
  final syConfT = InMemorySyncTransport();
  final syConfRec = ResumeRecord(
    mediaId: 'cx',
    title: 'X',
    sourceId: 's',
    canonicalEpisode: 1,
    canonicalSeconds: 10.0,
    updatedAt: DateTime.parse('2026-11-05T00:00:00'),
  );
  await syConfT.push(SyncSnapshot({
    'cx': SyncEntry(
        mediaId: 'cx',
        record: syConfRec,
        stamp: 1,
        writerDeviceId: 'other-dev')
  }));
  final syConfDiag = MemoryDiagnosticSink();
  final syConfLocal = SyncAwareResumeStore(MemoryResumeStore());
  final syConfEngine = ResumeSyncEngine(
      local: syConfLocal,
      transport: syConfT,
      deviceId: 'me',
      diagnostics: syConfDiag);
  await syConfLocal.save(syConfRec.copyWith(canonicalSeconds: 20.0));
  final syConfResult = await syConfEngine.sync();
  check('E6 并发冲突被裁决并计数/埋点',
      syConfResult.conflicts == 1 &&
          syConfDiag.kinds.contains(DiagnosticKind.syncConflict) &&
          syConfDiag.kinds.contains(DiagnosticKind.syncApplied));

  // 共享目录传输（LAN 降级路径）：另一实例可读到同一快照。
  final syDir = await Directory.systemTemp.createTemp('shunbo_sync_');
  final syFileT = FileSyncTransport.at('${syDir.path}/snap.json');
  final syFileLocal = SyncAwareResumeStore(MemoryResumeStore());
  final syFileEngine = ResumeSyncEngine(
      local: syFileLocal, transport: syFileT, deviceId: 'file-dev');
  await syFileLocal.save(syRecA.copyWith(mediaId: 'f1', canonicalEpisode: 2));
  await syFileEngine.sync();
  final syFilePull = await FileSyncTransport.at('${syDir.path}/snap.json').pull();
  check('E6 共享目录传输跨实例读写',
      syFilePull.entries['f1'] != null &&
          syFilePull.entries['f1']!.record!.canonicalEpisode == 2);
  await syDir.delete(recursive: true);

  // --- E9 源配置安全白名单 + 首次配置引导 ---
  const obGood = <String, dynamic>{
    'id': 's1',
    'name': '示例源',
    'baseUrl': 'https://example.com',
    'searchPath': '/search?q=:kw',
    'parser': 'dart',
    'headers': <String, dynamic>{'User-Agent': 'shunbo'}
  };
  check('E9 合法纯数据配置通过', validateSourceConfig(obGood).ok);
  check('E9 禁止脚本字段',
      !validateSourceConfig(<String, dynamic>{
        'baseUrl': 'https://e.com',
        'script': 'alert(1)'
      }).ok);
  check('E9 任意层级禁止 jar/class 字段',
      !validateSourceConfig(<String, dynamic>{
        'baseUrl': 'https://e.com',
        'headers': <String, dynamic>{'className': 'x'}
      }).ok);
  check('E9 拒绝 javascript scheme',
      !validateSourceConfig(<String, dynamic>{
        'baseUrl': 'https://e.com',
        'searchPath': 'javascript:alert(1)'
      }).ok);
  check('E9 拒绝非 http(s) baseUrl',
      !validateSourceConfig(<String, dynamic>{
        'baseUrl': 'file:///etc/passwd'
      }).ok);
  check('E9 外部配置默认禁止 jar 后端',
      !validateSourceConfig(<String, dynamic>{
        'baseUrl': 'https://e.com',
        'parser': 'jar'
      }).ok);
  check('E9 显式授权后允许 jar 后端',
      validateSourceConfig(
          <String, dynamic>{'baseUrl': 'https://e.com', 'parser': 'jar'},
          allowUnsafeBackends: true).ok);
  check('E9 未知顶层字段被拒',
      !validateSourceConfig(<String, dynamic>{
        'baseUrl': 'https://e.com',
        '__proto__': 1
      }).ok);
  Object obDeep = 1;
  for (var i = 0; i < 10; i++) {
    obDeep = <Object>[obDeep];
  }
  check('E9 超深嵌套被拒',
      !validateSourceConfig(<String, dynamic>{
        'baseUrl': 'https://e.com',
        'platforms': obDeep
      }).ok);

  final obFlow = OnboardingFlow();
  check('E9 首次启动需引导且处于 welcome',
      obFlow.needsOnboarding &&
          obFlow.state.step == OnboardingStep.welcome);
  var obBlocked = false;
  try {
    await obFlow.importSourceConfig(obGood);
  } on StateError {
    obBlocked = true;
  }
  check('E9 未接受免责声明禁止导入(安全不变量)',
      obBlocked && obFlow.state.step == OnboardingStep.welcome);
  await obFlow.acceptDisclaimer();
  final obUnsafe = await obFlow.importSourceConfig(<String, dynamic>{
    'baseUrl': 'https://e.com',
    'parser': 'jar'
  });
  check('E9 不安全配置拒绝且不推进流程',
      !obUnsafe.ok && obFlow.state.step == OnboardingStep.sourceImport);
  final obSafe = await obFlow.importSourceConfig(obGood);
  check('E9 安全配置导入后进入平台确认',
      obSafe.ok &&
          obFlow.state.sourceImported &&
          obFlow.state.step == OnboardingStep.platformConfirm);
  await obFlow.confirmPlatform('desktop');
  check('E9 引导完成且记录设备形态',
      !obFlow.needsOnboarding && obFlow.state.platform == 'desktop');
  final obRestored =
      OnboardingFlow(initial: OnboardingState.fromJson(obFlow.state.toJson()));
  check('E9 引导状态可持久化回读', !obRestored.needsOnboarding);

  // --- E7 诊断真实落盘：JSONL / 轮转 / 缓冲上限 ---
  final dgDir = await Directory.systemTemp.createTemp('shunbo_diag_');
  final dgFile = File('${dgDir.path}/d.jsonl');
  final dgSink = FileDiagnosticSink(dgFile, maxBytes: 200);
  for (var i = 0; i < 2; i++) {
    dgSink.record(DiagnosticEvent(
      kind: DiagnosticKind.syncApplied,
      at: DateTime.parse('2026-11-05T00:00:00'),
      mediaId: 'm$i',
      detail: '落盘验证',
    ));
  }
  await dgSink.drain();
  final dgText = await dgFile.readAsString();
  final dgLines = dgText.trim().split('\n');
  check('E7 诊断 JSONL 落盘且缓冲清空',
      await dgFile.exists() && dgSink.buffered == 0 && dgLines.length == 2);
  check('E7 诊断每行可解析且 kind 正确',
      jsonDecode(dgLines.first)['kind'] == 'syncApplied' &&
          jsonDecode(dgLines.last)['mediaId'] == 'm1');
  for (var i = 0; i < 30; i++) {
    dgSink.record(DiagnosticEvent(
      kind: DiagnosticKind.failoverExhausted,
      at: DateTime.parse('2026-11-05T00:00:00'),
      detail: '轮转验证 $i',
    ));
  }
  await dgSink.drain();
  check('E7 诊断文件超限自动轮转',
      await File('${dgFile.path}.1').exists() && !dgSink.degraded);
  final dgSmall =
      FileDiagnosticSink(File('${dgDir.path}/s.jsonl'), maxBuffer: 2);
  for (var i = 0; i < 5; i++) {
    dgSmall.record(DiagnosticEvent(
      kind: DiagnosticKind.syncOffline,
      at: DateTime.parse('2026-11-05T00:00:00'),
    ));
  }
  await dgSmall.drain();
  check('E7 诊断缓冲上限生效(溢出计数)', dgSmall.dropped == 3);
  await dgDir.delete(recursive: true);

  // --- E2 桌面解析子集扩充：站点规则驱动 + 真实站点结构回归 ---
  // 规则是纯数据，必须能 JSON 往返（外部配置导入路径）。
  final srLegacy = SiteRule.fromJson(SiteRulePresets.legacy.toJson());
  check('E2 站点规则 JSON 往返无损',
      srLegacy.id == 'legacy' &&
          srLegacy.search.patterns.first.contains('(?<mediaId>') &&
          srLegacy.playUrls.fields['qualityRank'] == '?qualityRank');
  check('E2 三个内置预设均通过规则安全校验',
      validateSiteRule(SiteRulePresets.legacy).ok &&
          validateSiteRule(SiteRulePresets.vodHtml).ok &&
          validateSiteRule(SiteRulePresets.jsonApi).ok);
  check('E2 规则 Map 静态校验通过',
      validateSiteRuleMap(SiteRulePresets.legacy.toJson()).ok &&
          !validateSiteRuleMap(<String, dynamic>{}).ok &&
          !validateSiteRuleMap('bad').ok);

  // 结构 A：兼容旧 DartSourceParser 约定结构（含重复项/乱序集数/多清晰度）。
  final srLegacyParser = RuleSourceParser(srLegacy);
  final srSearchA = await srLegacyParser.parseSearch(
      '<div class="item" data-id="qyn"><a>庆余年</a></div>'
      '<div class="item" data-id="qyn"><a>重复项</a></div>'
      '<div class="item" data-id="snd"><a>第二部</a></div>');
  check('E2 结构A 搜索解析且按 mediaId 去重',
      srSearchA.length == 2 &&
          srSearchA.first.mediaId == 'qyn' &&
          srSearchA.first.title == '庆余年');
  final srEpsA = await srLegacyParser.parseEpisodes(
      '<a class="ep" data-ep="2" href="/play/2">第2集</a>'
      '<a class="ep" data-ep="1" href="/play/1">第1集</a>'
      '<a class="ep" data-ep="2" href="/play/2b">重复</a>');
  check('E2 结构A 剧集乱序去重且地址补全',
      srEpsA.length == 2 &&
          srEpsA.first.episode == 1 &&
          srEpsA.first.playPagePath == 'https://example.com/play/1');
  final srUrlsA = await srLegacyParser.parsePlayUrls(
      '<video src="https://cdn/a.m3u8"></video>'
      '<a class="q" data-rank="3" href="https://cdn/a-1080.m3u8">1080</a>');
  check('E2 结构A 多清晰度按 rank 降序(可选组回退默认)',
      srUrlsA.length == 2 &&
          srUrlsA.first.url == 'https://cdn/a-1080.m3u8' &&
          srUrlsA.first.qualityRank == 3 &&
          srUrlsA.last.qualityRank == 1);

  // 结构 B：常见影视站 li[data-id] + option 选集 + JSON 内转义 m3u8。
  final srVod = RuleSourceParser(SiteRulePresets.vodHtml);
  final srSearchB = await srVod.parseSearch(
      '<li data-id="100"><h3>某剧</h3></li>'
      '<li data-id="101"><h3>另一部</h3></li>');
  check('E2 结构B li/h3 搜索解析',
      srSearchB.length == 2 && srSearchB.first.mediaId == '100');
  final srEpsB = await srVod.parseEpisodes(
      '<option value="/vod/100-2.html">第2集</option>'
      '<option value="/vod/100-1.html">第1集</option>');
  check('E2 结构B option 选集升序',
      srEpsB.length == 2 &&
          srEpsB.first.episode == 1 &&
          srEpsB.first.playPagePath == 'https://vod.example.com/vod/100-1.html');
  final srPageB = 'var cfg={"url":"https:\\/\\/cdn.example.com\\/hls\\/1.m3u8"};';
  final srUrlsB = await srVod.parsePlayUrls(srPageB);
  check('E2 结构B JSON 转义斜杠 URL 还原',
      srUrlsB.length == 1 &&
          srUrlsB.first.url == 'https://cdn.example.com/hls/1.m3u8');

  // 结构 C：JSON API（正则无法可靠解析），含实体解码与危险 scheme 过滤。
  final srApi = RuleSourceParser(SiteRulePresets.jsonApi);
  final srSearchC = await srApi.parseSearch(
      '{"data":{"list":[{"vod_id":7,"vod_name":"庆余年 &amp; 第二季"},'
      '{"vod_id":8,"vod_name":"其他"}]}}');
  check('E2 结构C JSON 搜索(数值ID+实体解码)',
      srSearchC.length == 2 &&
          srSearchC.first.mediaId == '7' &&
          srSearchC.first.title == '庆余年 & 第二季');
  final srEpsC = await srApi.parseEpisodes(
      '{"data":{"episodes":[{"ep":2,"url":"/api/play/2"},'
      '{"ep":1,"url":"/api/play/1"}]}}');
  check('E2 结构C JSON 剧集升序且补全绝对地址',
      srEpsC.length == 2 &&
          srEpsC.first.episode == 1 &&
          srEpsC.first.playPagePath == 'https://api.example.com/api/play/1');
  final srUrlsC = await srApi.parsePlayUrls(
      '{"data":{"urls":[{"play_url":"https://api/x.m3u8","rank":1},'
      '{"play_url":"https://api/x-720.m3u8","rank":2},'
      '{"play_url":"javascript:alert(1)","rank":9}]}}');
  check('E2 结构C 拒绝 javascript scheme 且不抬高清晰度',
      srUrlsC.length == 2 && srUrlsC.first.qualityRank == 2);
  check('E2 坏 JSON 降级空集不抛异常',
      (await srApi.parsePlayUrls('{oops')).isEmpty);

  // 脏数据隔离 + 输入长度上限。
  final srDirty = RuleSourceParser(SiteRulePresets.vodHtml);
  final srEpsD = await srDirty.parseEpisodes(
      '<option value="javascript:alert(1)">第2集</option>'
      '<option value="/p/3">第3集</option>');
  check('E2 脏数据逐条隔离(危险地址跳过)',
      srEpsD.length == 1 &&
          srEpsD.first.episode == 3 &&
          srDirty.skippedRows >= 1);
  final srTiny = RuleSourceParser(srLegacy, maxInputChars: 40);
  await srTiny.parseSearch(
      '<div class="item" data-id="qyn"><a>庆余年</a></div>${List.filled(200, 'x').join()}');
  check('E2 超长输入截断不崩溃(ReDoS 防护)', srTiny.truncatedCount == 1);

  // 规则安全校验：外部导入的正则必须拒绝 ReDoS / 缺字段 / 非法 baseUrl。
  final srBadLong = SiteRule(
    id: 'bad',
    baseUrl: 'https://e.com',
    search: ExtractionRule(
      patterns: <String>['(?<mediaId>${List.filled(1100, 'a').join()})'],
      fields: const <String, String>{'mediaId': 'mediaId', 'title': 't'},
    ),
    episodes: SiteRulePresets.legacy.episodes,
    playUrls: SiteRulePresets.legacy.playUrls,
  );
  check('E2 规则校验拒绝超长正则', !validateSiteRule(srBadLong).ok);
  final srBadRe = SiteRule(
    id: 'bad',
    baseUrl: 'https://e.com',
    search: ExtractionRule(
      patterns: <String>[r'(?<mediaId>(\w+)+)(?<title>\w+)'],
      fields: const <String, String>{'mediaId': 'mediaId', 'title': 'title'},
    ),
    episodes: SiteRulePresets.legacy.episodes,
    playUrls: SiteRulePresets.legacy.playUrls,
  );
  check('E2 规则校验拒绝嵌套量词(ReDoS)',
      !validateSiteRule(srBadRe).ok);
  final srBadField = SiteRule(
    id: 'bad',
    baseUrl: 'https://e.com',
    search: const ExtractionRule(
      patterns: <String>[r'(?<mediaId>\d+)'],
      fields: <String, String>{'mediaId': 'mediaId'},
    ),
    episodes: SiteRulePresets.legacy.episodes,
    playUrls: SiteRulePresets.legacy.playUrls,
  );
  check('E2 规则校验拒绝缺少必需字段', !validateSiteRule(srBadField).ok);
  check('E2 规则校验拒绝非 http(s) baseUrl',
      !validateSiteRule(SiteRule(
        id: 'bad',
        baseUrl: 'file:///etc/passwd',
        search: SiteRulePresets.legacy.search,
        episodes: SiteRulePresets.legacy.episodes,
        playUrls: SiteRulePresets.legacy.playUrls,
      )).ok);

  // E9 闭环：外部配置携带站点规则时，先过白名单再过正则安全校验。
  check('E9 携带合法站点规则的配置通过',
      validateSourceConfig(<String, dynamic>{
        'id': 's1',
        'baseUrl': 'https://example.com',
        'parser': 'dart',
        'rules': SiteRulePresets.legacy.toJson(),
      }).ok);
  check('E9 携带 ReDoS 规则的配置被拒',
      !validateSourceConfig(<String, dynamic>{
        'baseUrl': 'https://example.com',
        'rules': srBadRe.toJson(),
      }).ok);
  check('E9 rules.baseUrl 与配置 baseUrl 主机不一致被拒',
      !validateSourceConfig(<String, dynamic>{
        'baseUrl': 'https://attacker.example.net',
        'rules': SiteRulePresets.legacy.toJson(),
      }).ok);

  // 工厂 + 编排层闭合：规则解析结果真实驱动「搜索→剧集→取址→对齐→播放」。
  check('E2 工厂按规则路由解析器',
      createParser() is DartSourceParser &&
          createParser(rule: srLegacy) is RuleSourceParser);
  final srFetcher = MockFetcher({
    'search:规则剧': '<div class="item" data-id="rm1"><a>规则剧</a></div>',
    'detail:rm1': '<a class="ep" data-ep="1" href="/play/rm1/1">第1集</a>',
    'play:rm1:https://example.com/play/rm1/1':
        '<video src="https://cdn/rm1.m3u8"></video>',
  });
  final srProfile = const SourceProfile(name: '规则源');
  final srAdapter = ParsedSourceAdapter(
    id: srProfile.name,
    profile: srProfile,
    parser: RuleSourceParser(srLegacy),
    fetcher: srFetcher,
    supportedPlatforms: const {
      SourcePlatform.android,
      SourcePlatform.desktop,
      SourcePlatform.tv,
    },
  );
  final srHits = await srAdapter.search('规则剧');
  final srEps = await srAdapter.getEpisodes('rm1');
  check('E2 规则适配器搜索/剧集链路',
      srHits.length == 1 &&
          srHits.first.mediaId == 'rm1' &&
          srEps.length == 1 &&
          srEps.first.episode == 1);
  final srReg = SourceRegistry()..register(srAdapter);
  final srCat = SourceCatalog()..register(srProfile);
  final srPlayer = MockPlayerController();
  final srOrch = PlaybackOrchestrator(
    registry: srReg,
    catalog: srCat,
    player: srPlayer,
    resumeStore: MemoryResumeStore(),
  );
  final srSession = await srOrch.startPlayback(
    sourceId: srProfile.name,
    mediaId: 'rm1',
    mediaTitle: '规则剧',
    canonicalEpisode: 1,
    canonicalSeconds: 0,
  );
  check('E2 规则源驱动编排→对齐→播放全链路',
      srPlayer.loadedUrl == 'https://cdn/rm1.m3u8' &&
          srPlayer.playing &&
          srSession.contentEpisode == 1);

  // --- E5 投屏兜底：失败 / 掉线时进度守恒地降级本机播放 ---
  const csTv1 = CastDevice(id: 'tv-1', name: '客厅电视');
  const csTv2 = CastDevice(id: 'tv-2', name: '卧室电视');
  final csDiag = MemoryDiagnosticSink();

  final csNo = FakeCastTransport(devices: const <CastDevice>[]);
  final csNoRes = await CastFallbackController(transport: csNo, diagnostics: csDiag)
      .startCast(
          mediaId: 'm', url: 'https://x/1.m3u8',
          rawEpisode: 2, rawSeconds: 680.0);
  check('E5 无投屏设备→降级本机且物理坐标守恒',
      csNoRes.fallbackToLocal &&
          csNoRes.reason == CastFailureReason.noDevice &&
          csNoRes.rawSeconds == 680.0);

  final csOk = FakeCastTransport(devices: const <CastDevice>[csTv1, csTv2]);
  final csOkRes = await CastFallbackController(transport: csOk, diagnostics: csDiag)
      .startCast(
          mediaId: 'm', url: 'https://x/1.m3u8',
          rawEpisode: 2, rawSeconds: 680.0,
          preferredDeviceId: 'tv-2');
  check('E5 投屏成功并优先连接首选设备',
      csOkRes.casting &&
          csOkRes.device?.id == 'tv-2' &&
          csOk.playCalls == 1 &&
          csOk.position == 680.0);
  check('E5 投屏成功埋点 castStarted',
      csDiag.kinds.contains(DiagnosticKind.castStarted));

  final csRetry = FakeCastTransport(
      devices: const <CastDevice>[csTv1, csTv2],
      connectFails: const <String>{'tv-1'});
  final csRetryRes = await CastFallbackController(transport: csRetry).startCast(
      mediaId: 'm', url: 'u', rawEpisode: 1, rawSeconds: 10);
  check('E5 连接失败自动尝试下一台设备',
      csRetryRes.casting &&
          csRetry.connectCalls == 2 &&
          csRetryRes.attempts.length == 2);

  final csPlay = FakeCastTransport(
      devices: const <CastDevice>[csTv1],
      playFails: true,
      position: 900.0);
  final csPlayRes = await CastFallbackController(
          transport: csPlay, diagnostics: csDiag)
      .startCast(
          mediaId: 'm', url: 'u', rawEpisode: 2, rawSeconds: 680.0);
  check('E5 起播失败→降级且采用设备已前进位置',
      csPlayRes.fallbackToLocal &&
          csPlayRes.reason == CastFailureReason.playbackError &&
          csPlayRes.rawSeconds == 900.0 &&
          csPlay.disconnected);

  final csBack = FakeCastTransport(
      devices: const <CastDevice>[csTv1], position: 100.0);
  await CastFallbackController(transport: csBack).startCast(
      mediaId: 'm', url: 'u', rawEpisode: 1, rawSeconds: 650.0);
  csBack.position = 300.0; // 设备缓冲落后 / 时间倒退
  final csLost1 = await CastFallbackController(transport: csBack)
      .onConnectionLost(
          mediaId: 'm', rawEpisode: 1, lastKnownRawSeconds: 650.0);
  check('E5 掉线时设备位置倒退不回拉进度', csLost1.rawSeconds == 650.0);
  csBack.position = 800.0;
  final csLost2 = await CastFallbackController(transport: csBack)
      .onConnectionLost(
          mediaId: 'm', rawEpisode: 1, lastKnownRawSeconds: 650.0);
  check('E5 掉线后已前进的进度被保留',
      csLost2.rawSeconds == 800.0 &&
          csLost2.reason == CastFailureReason.connectionLost);

  final csThrow = FakeCastTransport(
      devices: const <CastDevice>[csTv1],
      throwOnDiscover: true,
      throwOnPosition: true);
  final csThrowRes = await CastFallbackController(transport: csThrow)
      .startCast(mediaId: 'm', url: 'u', rawEpisode: 1, rawSeconds: 42.0);
  check('E5 设备发现异常不崩溃且按原坐标降级',
      csThrowRes.fallbackToLocal &&
          csThrowRes.rawSeconds == 42.0 &&
          csThrowRes.attempts.first.contains('异常'));
  final csPosThrow = FakeCastTransport(
      devices: const <CastDevice>[csTv1], throwOnPosition: true);
  final csPosRes = await CastFallbackController(transport: csPosThrow)
      .onConnectionLost(
          mediaId: 'm', rawEpisode: 1, lastKnownRawSeconds: 55.0);
  check('E5 位置查询异常回退本地坐标', csPosRes.rawSeconds == 55.0);

  check('E5 兜底文案可执行(含集数/进度/重试指引)',
      csNoRes.userMessage.contains('第2集') &&
          csNoRes.userMessage.contains('11:20') &&
          csNoRes.userMessage.contains('Wi-Fi'));
  final csFbEvents = csDiag.ofKind(DiagnosticKind.castFallback);
  check('E5 降级埋点含结构化属性',
      csFbEvents.length == 2 &&
          csFbEvents.first.attributes['reason'] == 'noDevice' &&
          csFbEvents.first.attributes['rawSeconds'] == 680.0);

  // 关键闭环：投屏端看到的是「源原始坐标（含广告）」，降级后必须交回调度层
  // 用 rawToContent 换算成规范内容坐标，否则广告错位会让进度凭空跳变。
  final csProfile = const SourceProfile(
      name: 'cast-src', adInterval: 600.0, adDuration: 30.0);
  final csBeforeRaw = contentToRaw(csProfile, 1, 650.0);
  check('E5 投屏前内容坐标→物理坐标(含广告逆映射)',
      csBeforeRaw.$1 == 1 && csBeforeRaw.$2 == 680.0);
  final csAfter = rawToContent(csProfile, csLost2.rawEpisode, csLost2.rawSeconds);
  check('E5 降级物理坐标经调度层换算为内容坐标(进度守恒且前进)',
      csAfter.$1 == 1 && csAfter.$2 == 770.0 && csAfter.$2 > 650.0);
  check('E5 换算结果往返一致(可安全重新起播)',
      contentToRaw(csProfile, csAfter.$1, csAfter.$2).$2 == 800.0);

  // --- E6 配置真实落盘：源配置 / 进度 / 引导状态 ---
  final cfDir = await Directory.systemTemp.createTemp('shunbo_cfg_');
  final cfPath = '${cfDir.path}/config.json';
  final cf = FileConfigStore.at(cfPath);
  await cf.saveSourceConfig(<String, dynamic>{
    'id': 's1',
    'baseUrl': 'https://e.com',
  });
  await cf.savePlaybackProgress('m1', 2, 123.5);
  check('E6 配置落盘：源配置与进度可读',
      (await cf.loadSourceConfig())!['id'] == 's1' &&
          (await cf.loadPlaybackProgress('m1'))!.$2 == 123.5);
  check('E6 配置原子写无 tmp/bak 残留',
      !await File('$cfPath.tmp').exists() &&
          !await File('$cfPath.bak').exists());
  final cfRestart = FileConfigStore.at(cfPath);
  check('E6 配置模拟重启回读一致',
      (await cfRestart.loadSourceConfig())!['id'] == 's1' &&
          (await cfRestart.loadPlaybackProgress('m1'))!.$1 == 2);
  await cfRestart.savePlaybackProgress('m2', 1, 5.0);
  check('E6 重启实例写入不覆盖已有条目',
      (await cfRestart.loadPlaybackProgress('m1'))!.$2 == 123.5 &&
          (await cfRestart.loadPlaybackProgress('m2'))!.$1 == 1);
  check('E6 未记录的进度返回 null',
      await cfRestart.loadPlaybackProgress('nope') == null);

  final cfObPath = '${cfDir.path}/onboarding.json';
  final cfObStore = FileConfigStore.at(cfObPath);
  final cfFlow = OnboardingFlow(
      persist: (s) => cfObStore.saveState('onboarding', s));
  await cfFlow.acceptDisclaimer();
  await cfFlow.skipImport();
  await cfFlow.confirmPlatform('tv');
  final cfObSaved =
      await FileConfigStore.at(cfObPath).loadState('onboarding');
  final cfObRestored =
      OnboardingFlow(initial: OnboardingState.fromJson(cfObSaved!));
  check('E6 引导状态真实落盘且重启不再打断',
      !cfObRestored.needsOnboarding &&
          cfObRestored.state.platform == 'tv' &&
          cfObRestored.state.disclaimerAccepted);
  await File('${cfDir.path}/bad.json').writeAsString('{oops');
  final cfBad = FileConfigStore.at('${cfDir.path}/bad.json');
  check('E6 配置坏 JSON 降级为空且不抛异常',
      await cfBad.loadSourceConfig() == null && cfBad.degraded);
  await cfDir.delete(recursive: true);

  print('--- 全部断言通过：共 $_checkCount 项（覆盖 M0 换源对齐 / E2 源适配与'
      '站点规则 / E3 libmpv 指标与事件链路 / E5 投屏兜底 / E6 续播同步与配置落盘 /'
      ' E7 自动换源与诊断 / E9 引导与安全白名单）---');
}
