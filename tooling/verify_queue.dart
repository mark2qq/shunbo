// 播放列表 / 自动连播回归（「自动连播可关闭」写在设计稿 MVP 里，此前只有回调没有实现）。
//
// 为什么单独一套：自动连播是唯一一处「事件回调 → 跨集起播 → 会话状态更新」的链路，
// 出错的表现不是报错，而是「看完一集就停住」或者「莫名其妙跳过一集」，
// 用户很难描述、日志里也没有异常。所以这里逐条钉住语义：
//   ① 排序去重   ② 迟到事件丢弃   ③ 最后一集不重播   ④ 开关真能关掉
//   ⑤ 当前源坏了换下一个源   ⑥ 全坏如实失败   ⑦ 并发去重（同一片尾不重复起播）
//
// 运行：dart run tooling/verify_queue.dart
import 'dart:async';
import 'dart:io';

import 'package:shunbo/core/diagnostics/diagnostic_sink.dart';
import 'package:shunbo/core/player/mock_player_controller.dart';
import 'package:shunbo/core/scheduler/playback_orchestrator.dart';
import 'package:shunbo/core/scheduler/playback_queue.dart';
import 'package:shunbo/core/scheduler/source_catalog.dart';
import 'package:shunbo/core/source/source_adapter.dart';
import 'package:shunbo/core/source/source_profile.dart';
import 'package:shunbo/core/source/source_registry.dart';
import 'package:shunbo/data/memory_resume_store.dart';

int _checkCount = 0;
int _failCount = 0;

void check(String name, bool ok, [String? detail]) {
  if (!ok) {
    _failCount++;
    print('FAIL: $name${detail == null ? '' : ' —— $detail'}');
    return;
  }
  _checkCount++;
  print('PASS: $name');
}

/// 可注入失败 / 延迟的测试适配器。
///
/// - [missingEpisodes]：这些集数解析不到地址（模拟单集 404）。
/// - [gate]：非空时 `resolvePlayUrl` 会挂在这里，用于制造「上一次连播还没结束」。
class TestAdapter implements SourceAdapter {
  @override
  final String id;
  @override
  final SourceProfile profile;
  @override
  final int qualityRank;
  @override
  final Set<SourcePlatform> supportedPlatforms;

  final Map<String, List<EpisodeInfo>> episodes;
  final Map<String, List<PlayUrl>> urls;
  final Set<int> missingEpisodes;
  Completer<void>? gate;
  int resolveCalls = 0;

  TestAdapter({
    required this.id,
    required this.profile,
    this.qualityRank = 0,
    this.supportedPlatforms = const {
      SourcePlatform.android,
      SourcePlatform.desktop,
      SourcePlatform.tv,
    },
    this.episodes = const <String, List<EpisodeInfo>>{},
    this.urls = const <String, List<PlayUrl>>{},
    this.missingEpisodes = const <int>{},
  });

  @override
  Map<String, String> get playbackHeaders => const <String, String>{};

  @override
  Future<List<MediaSearchResult>> search(String keyword) async =>
      const <MediaSearchResult>[];

  @override
  Future<List<EpisodeInfo>> getEpisodes(String mediaId) async =>
      episodes[mediaId] ?? const <EpisodeInfo>[];

  @override
  Future<List<PlayUrl>> resolvePlayUrl(String mediaId, int episode) async {
    resolveCalls++;
    final g = gate;
    if (g != null) await g.future;
    if (missingEpisodes.contains(episode)) return const <PlayUrl>[];
    return urls['$mediaId#$episode'] ?? const <PlayUrl>[];
  }
}

List<EpisodeInfo> eps(List<int> numbers) =>
    numbers.map((e) => EpisodeInfo(episode: e, title: '第$e集')).toList();

Map<String, List<PlayUrl>> urlsFor(String prefix) => <String, List<PlayUrl>>{
      for (var e = 1; e <= 5; e++)
        'm1#$e': <PlayUrl>[PlayUrl(url: '$prefix/$e.m3u8', qualityRank: 1)],
    };

/// 组装一套「两源三集」的基本环境。
({
  SourceRegistry registry,
  SourceCatalog catalog,
  MockPlayerController player,
  PlaybackOrchestrator orchestrator,
  PlaybackQueue queue,
  MemoryDiagnosticSink sink,
}) build({
  Set<int> missingOnA = const <int>{},
  Set<SourcePlatform> sourceA = const {
    SourcePlatform.android,
    SourcePlatform.desktop,
    SourcePlatform.tv,
  },
  Set<SourcePlatform> sourceB = const {
    SourcePlatform.android,
    SourcePlatform.desktop,
    SourcePlatform.tv,
  },
  bool autoNext = true,
}) {
  final registry = SourceRegistry();
  final catalog = SourceCatalog();
  final a = TestAdapter(
    id: 'a',
    profile: const SourceProfile(name: 'a'),
    supportedPlatforms: sourceA,
    episodes: <String, List<EpisodeInfo>>{'m1': eps(<int>[1, 2, 3])},
    urls: urlsFor('a'),
    missingEpisodes: missingOnA,
  );
  final b = TestAdapter(
    id: 'b',
    profile: const SourceProfile(name: 'b'),
    supportedPlatforms: sourceB,
    episodes: <String, List<EpisodeInfo>>{'m1': eps(<int>[1, 2, 3])},
    urls: urlsFor('b'),
  );
  registry.register(a);
  registry.register(b);
  catalog.register(a.profile);
  catalog.register(b.profile);

  final player = MockPlayerController()..durationSeconds = 2700;
  final orchestrator = PlaybackOrchestrator(
    registry: registry,
    catalog: catalog,
    player: player,
    resumeStore: MemoryResumeStore(),
  );
  final sink = MemoryDiagnosticSink();
  final queue = PlaybackQueue(
    orchestrator: orchestrator,
    registry: registry,
    catalog: catalog,
    diagnostics: sink,
    autoNext: autoNext,
  );
  return (
    registry: registry,
    catalog: catalog,
    player: player,
    orchestrator: orchestrator,
    queue: queue,
    sink: sink,
  );
}

Future<void> main() async {
  // ① 剧集表：乱序 + 重复 → 去重升序。
  {
    final env = build();
    env.queue.setEpisodes(<EpisodeInfo>[
      const EpisodeInfo(episode: 3, title: 'c'),
      const EpisodeInfo(episode: 1, title: 'a'),
      const EpisodeInfo(episode: 3, title: 'c2'),
      const EpisodeInfo(episode: 2, title: 'b'),
    ]);
    final order = env.queue.episodes.map((e) => e.episode).toList();
    check('剧集表按集数升序去重', order.join(',') == '1,2,3', '$order');
    check('重复集数保留首次出现的那条',
        env.queue.episodes.firstWhere((e) => e.episode == 3).title == 'c');
  }

  // ② 没有活跃会话。
  {
    final env = build();
    env.queue.setEpisodes(eps(<int>[1, 2, 3]));
    final r = await env.queue.handleEpisodeFinished(1);
    check('无会话时不推进', r.reason == QueueAdvanceReason.noSession, '${r.reason}');
    check('无会话时不碰播放器', env.player.loadedUrl == null);
  }

  // ③ 开关关掉就真的不连播。
  {
    final env = build(autoNext: false);
    env.queue.setEpisodes(eps(<int>[1, 2, 3]));
    final s = await env.orchestrator.startPlayback(
        sourceId: 'a', mediaId: 'm1', mediaTitle: 'M', canonicalEpisode: 1, canonicalSeconds: 0);
    env.queue.attach(s);
    env.player.loadedUrl = null; // 清掉开播那次的载入记录，便于判断「有没有再起播」
    final r = await env.queue.handleEpisodeFinished(1);
    check('自动连播关闭时不推进', r.reason == QueueAdvanceReason.disabled, '${r.reason}');
    check('关闭状态下不会再 load 任何地址', env.player.loadedUrl == null);
    var persisted = <bool>[];
    final q2 = PlaybackQueue(
      orchestrator: env.orchestrator,
      registry: env.registry,
      catalog: env.catalog,
      autoNext: false,
      persistAutoNext: (v) async => persisted.add(v),
    );
    await q2.setAutoNext(true);
    check('开关变更走持久化回调', persisted.length == 1 && persisted.first);
    await q2.setAutoNext(true);
    check('开关未变化不重复落盘', persisted.length == 1);
  }

  // ④ 正常连播：第 1 集看完 → 第 2 集，沿用当前源。
  {
    final env = build();
    env.queue.setEpisodes(eps(<int>[1, 2, 3]));
    final s = await env.orchestrator.startPlayback(
        sourceId: 'a', mediaId: 'm1', mediaTitle: 'M', canonicalEpisode: 1, canonicalSeconds: 0);
    env.queue.attach(s);
    final adv = <int>[];
    env.queue.onAdvanced = (r) {
      if (r.advanced) adv.add(r.nextEpisode!);
    };
    final r = await env.queue.handleEpisodeFinished(1);
    check('看完第 1 集自动起播第 2 集', r.advanced && r.nextEpisode == 2, '${r.reason}/${r.nextEpisode}');
    check('连播沿用当前源', r.session?.sourceId == 'a', '${r.session?.sourceId}');
    check('连播从下一集开头起播', env.player.loadedRawEpisode == 2 && env.player.loadedRawSeconds == 0.0,
        '${env.player.loadedRawEpisode}/${env.player.loadedRawSeconds}');
    check('连播更新会话（供下一次片尾比对）', env.queue.current?.contentEpisode == 2);
    check('连播回调带出新会话', adv.length == 1 && adv.first == 2, '$adv');
    check('连播成功后落一条诊断',
        env.sink.ofKind(DiagnosticKind.autoNextAdvanced).length == 1);
  }

  // ⑤ 迟到事件：用户已经手动换到第 2 集，第 1 集的片尾回调不该把第 3 集顶上来。
  {
    final env = build();
    env.queue.setEpisodes(eps(<int>[1, 2, 3]));
    final s = await env.orchestrator.startPlayback(
        sourceId: 'a', mediaId: 'm1', mediaTitle: 'M', canonicalEpisode: 2, canonicalSeconds: 0);
    env.queue.attach(s);
    env.player.loadedUrl = null;
    final r = await env.queue.handleEpisodeFinished(1);
    check('过期片尾事件被丢弃', r.reason == QueueAdvanceReason.staleEvent, '${r.reason}');
    check('过期事件不触发任何起播', env.player.loadedUrl == null);
  }

  // ⑥ 最后一集：不重播、不抛异常、给出可展示文案。
  {
    final env = build();
    env.queue.setEpisodes(eps(<int>[1, 2, 3]));
    final s = await env.orchestrator.startPlayback(
        sourceId: 'a', mediaId: 'm1', mediaTitle: 'M', canonicalEpisode: 3, canonicalSeconds: 0);
    env.queue.attach(s);
    env.player.loadedUrl = null;
    final r = await env.queue.handleEpisodeFinished(3);
    check('最后一集不连播', r.reason == QueueAdvanceReason.noNextEpisode, '${r.reason}');
    check('最后一集不重播', env.player.loadedUrl == null);
    check('最后一集文案可读（不是枚举名）',
        r.message.contains('最后一集') && !r.message.contains('noNextEpisode'), r.message);
  }

  // ⑦ 源站跳集：1、2、5 → 第 2 集看完接第 5 集。
  {
    final env = build();
    env.queue.setEpisodes(eps(<int>[1, 2, 5]));
    final s = await env.orchestrator.startPlayback(
        sourceId: 'a', mediaId: 'm1', mediaTitle: 'M', canonicalEpisode: 2, canonicalSeconds: 0);
    env.queue.attach(s);
    final r = await env.queue.handleEpisodeFinished(2);
    check('跳集时接下一个存在的集数', r.advanced && r.nextEpisode == 5,
        '${r.reason}/${r.nextEpisode}');
  }

  // ⑧ 当前源这一集解析不到 → 换下一个可用源（不是直接失败）。
  {
    final env = build(missingOnA: <int>{2});
    env.queue.setEpisodes(eps(<int>[1, 2, 3]));
    final s = await env.orchestrator.startPlayback(
        sourceId: 'a', mediaId: 'm1', mediaTitle: 'M', canonicalEpisode: 1, canonicalSeconds: 0);
    env.queue.attach(s);
    final r = await env.queue.handleEpisodeFinished(1);
    check('当前源缺集时切到备用源', r.advanced && r.session?.sourceId == 'b',
        '${r.reason}/${r.session?.sourceId}');
    check('备用源从同一集起播', env.player.loadedRawEpisode == 2);
  }

  // ⑨ 平台裁剪：备用源只在 Android 可用 → 桌面端不得用它。
  {
    final env = build(
      missingOnA: <int>{2},
      sourceB: const <SourcePlatform>{SourcePlatform.android},
    );
    env.queue.platform = SourcePlatform.desktop;
    env.queue.setEpisodes(eps(<int>[1, 2, 3]));
    final s = await env.orchestrator.startPlayback(
        sourceId: 'a', mediaId: 'm1', mediaTitle: 'M', canonicalEpisode: 1, canonicalSeconds: 0);
    env.queue.attach(s);
    final r = await env.queue.handleEpisodeFinished(1);
    check('桌面端不会使用 Android 专属源', !r.advanced && r.reason == QueueAdvanceReason.failed,
        '${r.reason}');
    check('失败文案列出尝试过的源', r.message.contains('a'), r.message);
    check('全部失败落一条失败诊断',
        env.sink.ofKind(DiagnosticKind.autoNextFailed).length == 1);
  }

  // ⑩ 并发去重：上一次起播还挂在网络上，第二次片尾事件必须被挡掉。
  {
    final env = build();
    env.queue.setEpisodes(eps(<int>[1, 2, 3]));
    final s = await env.orchestrator.startPlayback(
        sourceId: 'a', mediaId: 'm1', mediaTitle: 'M', canonicalEpisode: 1, canonicalSeconds: 0);
    env.queue.attach(s);
    final adapter = env.registry.get('a')! as TestAdapter;
    final gate = Completer<void>();
    adapter.gate = gate;
    final first = env.queue.handleEpisodeFinished(1);
    // 让第一次推进真正进入等待状态。
    await Future<void>.delayed(const Duration(milliseconds: 10));
    final second = await env.queue.handleEpisodeFinished(1);
    check('连播进行中丢弃重复片尾事件', second.reason == QueueAdvanceReason.busy,
        '${second.reason}');
    adapter.gate = null;
    gate.complete();
    final r1 = await first;
    check('放行后第一次连播正常完成', r1.advanced, '${r1.reason}');
  }

  // ⑪ detach 之后片尾事件不再推进（返回搜索页 / 换片）。
  {
    final env = build();
    env.queue.setEpisodes(eps(<int>[1, 2, 3]));
    final s = await env.orchestrator.startPlayback(
        sourceId: 'a', mediaId: 'm1', mediaTitle: 'M', canonicalEpisode: 1, canonicalSeconds: 0);
    env.queue.attach(s);
    env.queue.detach();
    final r = await env.queue.handleEpisodeFinished(1);
    check('detach 后片尾事件不推进', r.reason == QueueAdvanceReason.noSession, '${r.reason}');
  }

  print('-' * 60);
  if (_failCount == 0) {
    print('回归通过：$_checkCount/$_checkCount 断言通过');
    exit(0);
  }
  print('回归失败：${_checkCount - _failCount}/$_checkCount 断言通过');
  exit(1);
}
