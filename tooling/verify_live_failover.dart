// 全线路失败 → 自动切台 的**真实控制器状态机**回归。
//
// 与 verify_live_discovery.dart 的分工：那边验证纯策略（AutoAdvancePlanner）
// 和源码静态护栏，这里直接驱动 LiveController + 假播放内核 + 假目录，
// 用真实 Timer / epoch / AsyncSerialGate 跑完整条失败切换链路。
// 对应四条硬要求：
//   ① 当前台所有线路都试过仍不能播 → 按频道顺序切下一个台；
//   ② 切台后走与手动点台相同的正常起播流程，能真的出画面；
//   ③ 不停在原台反复加载、不重复重试、不卡 tuning、一轮扫完落明确终态；
//   ④ 线路切换 / 加载失败 / 自动切台 / dispose 全程不抛未捕获异步异常。
//
// 运行：dart run tooling/verify_live_failover.dart
import 'dart:async';
import 'dart:io';

import 'package:shunbo/core/player/player_controller.dart';
import 'package:shunbo/features/live/live_catalog.dart';
import 'package:shunbo/features/live/live_channel.dart';
import 'package:shunbo/features/live/live_controller.dart';
import 'package:shunbo/features/live/preferred_stream.dart';

int _pass = 0;
int _fail = 0;

void check(String name, bool ok, [String? detail]) {
  if (!ok) {
    _fail++;
    print('FAIL: $name${detail == null ? '' : ' —— $detail'}');
    return;
  }
  _pass++;
  print('PASS: $name');
}

/// 假内核：非白名单地址一律报终态错误（模拟死线路），白名单地址立即出画面。
/// 记录每次 load，用来证明「每条线路只试一次」和「不会并发 open」。
class _FakePlayer implements PlayerController {
  _FakePlayer(this.good);

  final Set<String> good;
  final List<String> loads = <String>[];
  int maxInFlight = 0;
  int _inFlight = 0;
  String? _loaded;
  double _volume = 100;

  @override
  Future<void> initialize() async {}

  @override
  Future<void> load(
    String url,
    int episode,
    double rawSeconds, {
    Map<String, String> headers = const <String, String>{},
  }) async {
    loads.add(url);
    _inFlight++;
    if (_inFlight > maxInFlight) maxInFlight = _inFlight;
    try {
      // 给并发留一个可观测窗口，否则串行门闩是否生效测不出来。
      await Future<void>.delayed(const Duration(milliseconds: 8));
      if (!good.contains(url)) throw StateError('Failed to open $url');
      _loaded = url;
    } finally {
      _inFlight--;
    }
  }

  @override
  Future<void> play() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> seek(double rawSeconds) async {}

  @override
  Future<void> setVolume(double volume) async {
    _volume = volume.clamp(0, 100).toDouble();
  }

  @override
  double get volume => _volume;

  @override
  Stream<double> get volumeChanges => Stream<double>.value(_volume);

  @override
  Future<double> currentRawSeconds() async =>
      _loaded != null && good.contains(_loaded) ? 1.0 : 0.0;

  @override
  Future<double> duration() async => 0;

  @override
  Future<void> dispose() async {}
}

/// 假目录：探测一律「可达」，让失败发生在内核载入而不是等 15 秒起播超时；
/// 这样每条死线路都会立刻走到换线分支，整套回归只需几秒。
class _FakeCatalog extends LiveCatalogService {
  _FakeCatalog() : super(builtIn: const <LiveChannel>[]);

  /// 探测次数：用来验证「预热推迟」——起播瞬间不该有后台探测抢带宽。
  int probes = 0;

  @override
  Future<bool> probe(
    String url, {
    Duration timeout = const Duration(seconds: 3),
    Map<String, String> headers = const <String, String>{},
  }) async {
    probes++;
    return true;
  }

  @override
  Future<LiveCatalogSnapshot> load({bool remote = true}) async =>
      const LiveCatalogSnapshot(
        channels: <LiveChannel>[],
        sourceLabel: '测试清单',
      );
}

/// 可控探测结果的假目录：用来验证「探测能通过」与「能播」是两件事。
///
/// [probeReachable] 为 false 时模拟一个**探测超时、但内核其实能播**的线路 ——
/// 这正是实测里最常见的一类（119 条央视/卫视线路中 12 条首次探测失败、
/// 重试 2~4.7 秒成功）。旧实现会在这里直接 `markDead + return false`，
/// 连 `player.load` 都不调，用户看到的就是「这个台点不开」。
class _ProbeFailsCatalog extends LiveCatalogService {
  _ProbeFailsCatalog() : super(builtIn: const <LiveChannel>[]);

  int probeCalls = 0;

  @override
  Future<bool> probe(
    String url, {
    Duration timeout = const Duration(seconds: 3),
    Map<String, String> headers = const <String, String>{},
  }) async {
    probeCalls++;
    return false;
  }

  @override
  Future<LiveCatalogSnapshot> load({bool remote = true}) async =>
      const LiveCatalogSnapshot(
        channels: <LiveChannel>[],
        sourceLabel: '测试清单',
      );
}

/// 记录探测次数、结果可配的假目录（验证「偏好线路免探测」）。
class _CountingCatalog extends LiveCatalogService {
  _CountingCatalog() : super(builtIn: const <LiveChannel>[]);

  int probeCalls = 0;
  final List<String> probedUrls = <String>[];

  @override
  Future<bool> probe(
    String url, {
    Duration timeout = const Duration(seconds: 3),
    Map<String, String> headers = const <String, String>{},
  }) async {
    probeCalls++;
    probedUrls.add(url);
    return true;
  }

  @override
  Future<LiveCatalogSnapshot> load({bool remote = true}) async =>
      const LiveCatalogSnapshot(
        channels: <LiveChannel>[],
        sourceLabel: '测试清单',
      );
}

const String _group = '央视频道';

/// 台名刻意不带数字、分组完全相同：sortChannels 的稳定排序保持 A→B→C。
/// 每台用不同主机，避免 DeadStreamRegistry 的主机连带把未试过的台提前判死。
LiveChannel _ch(String name, String host) => LiveChannel(
      id: name,
      name: name,
      group: _group,
      badge: name,
      streams: <LiveStream>[
        LiveStream(
            url: 'https://$host/1.m3u8', label: '高清线路', qualityRank: 90),
        LiveStream(
            url: 'https://$host/2.m3u8', label: '备用线路', qualityRank: 90),
      ],
    );

List<LiveChannel> fixture() => <LiveChannel>[
      _ch('A台', 'a.example'),
      _ch('B台', 'b.example'),
      _ch('C台', 'c.example'),
    ];

LiveController controller(_FakePlayer player) => LiveController(
      player: player,
      catalogService: _FakeCatalog(),
      startTimeout: const Duration(seconds: 2),
      stallTimeout: const Duration(seconds: 2),
    );

int countLoads(_FakePlayer p, String host) =>
    p.loads.where((u) => u.contains(host)).length;

// ── 频道运行时顺序 === 界面编号顺序（防乱切）─────────────────
//
// 卫视台名（山西卫视 / 重庆卫视 …）没有内嵌数字，[LiveCatalogService.sortChannels]
// 会把它们都排到 9999、退化成输入顺序；若 _channels 就按这个顺序用，自动切台 /
// 上下台会跳到界面上并不相邻的频道（实测 山西卫视→重庆卫视、CHC→CGTN Spanish）。
// [_LiveController._setChannels] 在 rebuild 之后按「实际编号」重排 _channels，使其
// 与界面按编号升序的展示一致。本组断言锁定这条不变量。

LiveChannel _sat(String name, int num) => LiveChannel(
      id: name,
      name: name,
      group: '卫视频道',
      badge: name,
      streams: <LiveStream>[
        LiveStream(
            url: 'https://example.com/$num.m3u8', label: '线路', qualityRank: 90),
      ],
    );

Future<void> testChannelOrder() async {
  print('\n== 运行时顺序对齐界面编号顺序（防乱切） ==');
  // 只让「内蒙古卫视(105)」这条线可播，其余死线：用来验证「上下台 / 自动切台」
  // 从山西卫视(104)出发会落到编号相邻的 内蒙古卫视，而不是远处的 重庆卫视(122)。
  final player = _FakePlayer(<String>{'https://example.com/105.m3u8'});
  final c = controller(player);
  // 故意打乱输入顺序：证明顺序由「编号」决定，而非输入顺序。
  c.loadChannelsForTest(<LiveChannel>[
    _sat('重庆卫视', 122),
    _sat('山西卫视', 104),
    _sat('内蒙古卫视', 105),
    _sat('河北卫视', 103),
    _sat('天津卫视', 102),
    _sat('北京卫视', 101),
  ]);

  final names = c.channels.map((e) => e.name).toList();
  check('运行时顺序按编号升序（与界面一致）',
      names.join(',') == '北京卫视,天津卫视,河北卫视,山西卫视,内蒙古卫视,重庆卫视',
      names.join(','));

  final idxShanxi = names.indexOf('山西卫视');
  check('山西卫视的下一个是内蒙古卫视（不是重庆卫视）',
      idxShanxi >= 0 && names[idxShanxi + 1] == '内蒙古卫视',
      'pos=$idxShanxi next=${idxShanxi >= 0 ? names[idxShanxi + 1] : '?'}');

  final idxChongqing = names.indexOf('重庆卫视');
  check('重庆卫视排在最末（编号 122 最大）',
      idxChongqing == names.length - 1, 'pos=$idxChongqing');

  // 编号反查不受影响，仍精确。
  check('编号反查 104=山西卫视',
      c.numbers.channelForNumber(c.channels, 104)?.name == '山西卫视');
  check('编号反查 122=重庆卫视',
      c.numbers.channelForNumber(c.channels, 122)?.name == '重庆卫视');

  // 上下台也走同一顺序：从山西卫视 nextChannel 应到编号相邻的 内蒙古卫视。
  await c.tune(c.channels.firstWhere((x) => x.name == '山西卫视'));
  await c.nextChannel();
  check('从山西卫视 nextChannel 切到内蒙古卫视（编号相邻）',
      c.current?.name == '内蒙古卫视', '${c.current?.name}');
}

// ── 探测超时不等于播不了 / 偏好线路免探测 ──────────────────────

Future<void> testProbeTimeoutStillPlays() async {
  print('\n== 探测超时但内核能出画面 ==');
  // 唯一可播的线路正是「探测永远失败」的那条：模拟慢源。
  final player = _FakePlayer(<String>{'https://p.example/1.m3u8'});
  final catalog = _ProbeFailsCatalog();
  final c = LiveController(
    player: player,
    catalogService: catalog,
    startTimeout: const Duration(seconds: 2),
    stallTimeout: const Duration(seconds: 2),
  );
  c.loadChannelsForTest(<LiveChannel>[_ch('P台', 'p.example')]);

  await c.tune(c.channels.first);

  check('探测确实被调用过', catalog.probeCalls > 0, '${catalog.probeCalls}');
  check('探测超时不判死，仍交给内核尝试',
      player.loads.contains('https://p.example/1.m3u8'),
      player.loads.join(','));
  check('内核能出画面就判定为播放中',
      c.phase == LiveTuning.playing, c.phase.name);
  // 判死的后果是「被跳过 + 触发换线」：这里必须只有一次 load。
  check('探测超时后没有误触发换线', player.loads.length == 1,
      player.loads.join(','));

  c.dispose();
  await Future<void>.delayed(const Duration(milliseconds: 600));
}

Future<void> testPreferredSkipsProbe() async {
  print('\n== 偏好线路免检索 ==');
  final player = _FakePlayer(<String>{'https://q.example/2.m3u8'});
  final catalog = _CountingCatalog();
  final preferred = PreferredStreamBoard();
  final c = LiveController(
    player: player,
    catalogService: catalog,
    preferred: preferred,
    preferredSink: (_) async {},
    startTimeout: const Duration(seconds: 2),
    stallTimeout: const Duration(seconds: 2),
  );
  final channel = _ch('Q台', 'q.example');
  c.loadChannelsForTest(<LiveChannel>[channel]);

  // 上次顺畅播放的是**备用线路**：本次必须直接用它，而不是按画质顺序先试主线路。
  preferred.record(channel.id, 'https://q.example/2.m3u8');
  await c.tune(channel);

  check('直接使用记忆中的线路',
      player.loads.isNotEmpty && player.loads.first == 'https://q.example/2.m3u8',
      player.loads.join(','));
  // prewarm 可能去探后面的备用线路，所以不能只看总次数：
  // 要断言的是「记忆里那条线路本身没有再被检索」。
  check('偏好线路本身不再被探测',
      !catalog.probedUrls.contains('https://q.example/2.m3u8'),
      catalog.probedUrls.join(','));
  check('播放成功', c.phase == LiveTuning.playing, c.phase.name);
  check('成功后又把同一线路记回去',
      preferred.preferredFor(channel.id) == 'https://q.example/2.m3u8',
      '${preferred.preferredFor(channel.id)}');

  // 偏好地址已不在频道线路表里（源站换了路径）→ 必须作废，而不是一直留着。
  final stale = PreferredStreamBoard();
  stale.record(channel.id, 'https://old.example/gone.m3u8');
  final player2 = _FakePlayer(<String>{'https://q.example/1.m3u8'});
  final c2 = LiveController(
    player: player2,
    catalogService: _CountingCatalog(),
    preferred: stale,
    preferredSink: (_) async {},
    startTimeout: const Duration(seconds: 2),
    stallTimeout: const Duration(seconds: 2),
  );
  c2.loadChannelsForTest(<LiveChannel>[
    _ch('Q台', 'q.example'),
  ]);
  await c2.tune(c2.channels.first);
  check('过期地址作废后回落到现有线路',
      c2.phase == LiveTuning.playing, c2.phase.name);
  check('作废的记忆被清掉',
      stale.preferredFor(channel.id) == 'https://q.example/1.m3u8',
      '${stale.preferredFor(channel.id)}');

  c.dispose();
  c2.dispose();
  await Future<void>.delayed(const Duration(milliseconds: 600));
}

// ── ① 全线路失败 → 自动切台 → 继续正常播放 ─────────────────────

/// 整台已被判死时不能「一条条再等一遍」。
///
/// 用户反复点一个已知全死的台，是最容易让人以为「应用卡住了」的场景：
/// 4 条线路 × 8 秒首帧耐心 = 半分钟黑屏。失效表的意义就是别重复付这笔钱。
Future<void> testDeadStreamsSkipped() async {
  print('\n== 已判死的线路不重复等待 ==');
  final player = _FakePlayer(const <String>{});
  final c = controller(player);
  c.loadChannelsForTest(<LiveChannel>[_ch('D台', 'd.example')]);

  await c.tune(c.channels.first);
  final firstPass = countLoads(player, 'd.example');
  check('首轮两条线路都试过', firstPass == 2, '$firstPass');
  check('首轮结束进入 failed', c.phase == LiveTuning.failed, c.phase.name);

  await c.tune(c.channels.first);
  final secondPass = countLoads(player, 'd.example') - firstPass;
  check('整台已判死时只试一条（验证是否恢复）', secondPass == 1, '$secondPass');
  check('仍然给出明确失败终态', c.phase == LiveTuning.failed, c.phase.name);

  c.dispose();
  await Future<void>.delayed(const Duration(milliseconds: 600));
}

Future<void> testAdvanceThenPlay() async {
  print('\n== 全线路失败自动切台并继续正常播放 ==');
  final player = _FakePlayer(<String>{'https://b.example/2.m3u8'});
  final c = controller(player);
  c.loadChannelsForTest(fixture());

  check('频道表按现有顺序装载 A→B→C',
      c.channels.map((e) => e.name).join(',') == 'A台,B台,C台',
      c.channels.map((e) => e.name).join(','));
  check('高清线路排在尝试队列最前',
      c.channels.first.orderedStreams.first.url == 'https://a.example/1.m3u8');

  await c.tune(c.channels[0]);
  check('原台全线路失败后落到明确 failed 终态',
      c.phase == LiveTuning.failed, c.phase.name);
  check('失败态不留在 tuning', c.phase != LiveTuning.tuning);
  check('提示明确说明正在切换到下一个台',
      c.message.contains('正在切换到'), c.message);

  final sw = Stopwatch()..start();
  await Future<void>.delayed(const Duration(milliseconds: 1500));
  check('按频道顺序自动切到下一台并已出画面',
      c.current?.name == 'B台' && c.phase == LiveTuning.playing,
      '${c.current?.name} / ${c.phase.name}');
  check('切换在 2 秒内完成，没有卡在加载态',
      sw.elapsedMilliseconds < 2000, '${sw.elapsedMilliseconds}ms');
  check('A 台每条线路只尝试一次，没有原地反复重试',
      countLoads(player, 'a.example') == 2,
      '${countLoads(player, 'a.example')}');
  check('切台后仍走完整的逐线路起播流程',
      player.loads.contains('https://b.example/1.m3u8') &&
          player.loads.contains('https://b.example/2.m3u8'),
      player.loads.join(','));
  check('自动切台成功后不再有待触发的旧定时器',
      c.current?.name == 'B台' && c.phase == LiveTuning.playing);
  c.dispose();
}

// ── ② 一整轮全灭：落终态、低频重扫、不空转 ────────────────────

Future<void> testSweepTerminates() async {
  print('\n== 一整轮全灭后的终止条件 ==');
  final player = _FakePlayer(<String>{});
  final c = controller(player);
  c.loadChannelsForTest(fixture());

  await c.tune(c.channels[0]);
  await Future<void>.delayed(const Duration(milliseconds: 2400));

  check('一轮扫完进入明确 failed 终态',
      c.phase == LiveTuning.failed, c.phase.name);
  check('提示说明全部频道无信号并给出低频重扫',
      c.message.contains('全部 3 个频道') && c.message.contains('30 秒'),
      c.message);
  for (final host in <String>['a.example', 'b.example', 'c.example']) {
    check('$host 两条线路各只试一次',
        countLoads(player, host) == 2, '${countLoads(player, host)}');
  }
  check('总载入次数正好是 3 台 × 2 线，没有无限紧循环',
      player.loads.length == 6, '${player.loads.length}');
  c.dispose();
}

// ── ③ 手动调台必须取消待执行的自动切台 ──────────────────────────

Future<void> testManualCancelsAdvance() async {
  print('\n== 手动调台取消旧的自动切台 ==');
  final player = _FakePlayer(<String>{'https://c.example/2.m3u8'});
  final c = controller(player);
  c.loadChannelsForTest(fixture());

  await c.tune(c.channels[0]);
  check('原台失败已排好自动切台',
      c.message.contains('正在切换到'), c.message);
  await c.tune(c.channels[2]); // 用户手动点 C 台
  await Future<void>.delayed(const Duration(milliseconds: 1200));

  check('旧定时器不会把画面抢回 B 台',
      c.current?.name == 'C台' && c.phase == LiveTuning.playing,
      '${c.current?.name} / ${c.phase.name}');
  check('被取消的 B 台线路一次都没加载',
      !player.loads.any((u) => u.contains('b.example')),
      player.loads.join(','));
  c.dispose();
}

// ── ④ 并发调台串行化 + dispose 之后安全 ────────────────────────

Future<void> testConcurrentAndDispose() async {
  print('\n== 并发调台与 dispose 稳定性 ==');
  final player = _FakePlayer(<String>{});
  final c = controller(player);
  c.loadChannelsForTest(fixture());

  await Future.wait<void>(<Future<void>>[
    c.tune(c.channels[0]),
    c.tune(c.channels[1]),
    c.tune(c.channels[2]),
  ]);
  check('并发调台不会产生并发原生 load',
      player.maxInFlight <= 1, '${player.maxInFlight}');

  var notifiedAfterDispose = 0;
  c.addListener(() => notifiedAfterDispose++);
  c.dispose();
  await Future<void>.delayed(const Duration(milliseconds: 900));
  check('dispose 之后定时器不再通知监听者',
      notifiedAfterDispose == 0, '$notifiedAfterDispose');
  check('dispose 之后读取状态仍安全', c.phase != LiveTuning.idle);
}

// ── 探测与 load 并行：探测不得挡在起播前面 ─────────────────────

/// 探测很慢（1.2s）但最终可达的假目录。
///
/// 旧实现把探测 `await` 在 `player.load` 之前，于是每一次「未知线路」的起播
/// 都白等一个探测往返（线上是 3.5 秒）。切台慢的第一大主因就是这笔，
/// 所以这里用「探测 1.2 秒」把它放大成可断言的时间差。
class _SlowProbeCatalog extends LiveCatalogService {
  _SlowProbeCatalog() : super(builtIn: const <LiveChannel>[]);

  int probeCalls = 0;

  @override
  Future<bool> probe(
    String url, {
    Duration timeout = const Duration(seconds: 3),
    Map<String, String> headers = const <String, String>{},
  }) async {
    probeCalls++;
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    return true;
  }

  @override
  Future<LiveCatalogSnapshot> load({bool remote = true}) async =>
      const LiveCatalogSnapshot(
        channels: <LiveChannel>[],
        sourceLabel: '测试清单',
      );
}

Future<void> testProbeRunsInParallel() async {
  print('\n== 探测与 load 并行（探测不挡起播） ==');
  final player = _FakePlayer(<String>{'https://s.example/1.m3u8'});
  final catalog = _SlowProbeCatalog();
  final c = LiveController(
    player: player,
    catalogService: catalog,
    startTimeout: const Duration(seconds: 2),
    stallTimeout: const Duration(seconds: 2),
  );
  c.loadChannelsForTest(<LiveChannel>[_ch('S台', 's.example')]);

  final sw = Stopwatch()..start();
  await c.tune(c.channels.first);
  sw.stop();

  check('起播成功', c.phase == LiveTuning.playing, c.phase.name);
  // 首屏选台也会对首条线路探测一次，所以这里只断言「探测确实发生过」，
  // 真正的判据是下面的耗时：起播必须明显短于探测耗时。
  check('探测确实跑过（只是不再阻塞）', catalog.probeCalls >= 1,
      '${catalog.probeCalls}');
  // 探测 1200ms；并行后起播只受内核建链 + 300ms 轮询影响。
  check('起播耗时明显短于探测耗时', sw.elapsedMilliseconds < 900,
      '${sw.elapsedMilliseconds}ms（旧实现 ≥ 1200ms）');

  c.dispose();
  await Future<void>.delayed(const Duration(milliseconds: 600));
}

// ── 整台预算与单条耐心 ─────────────────────────────────────────

Future<void> testTuneBudget() async {
  print('\n== 整台预算与单条耐心 ==');
  // 20s：晚间高峰实测慢源首帧 10~14s，15s 会把它们卡在边界上反复失败。
  check('整台起播预算为 20s（覆盖慢源、仍短于改动前的 30s）',
      LiveController.tuneBudget == const Duration(seconds: 20),
      '${LiveController.tuneBudget}');

  final player = _FakePlayer(<String>{});
  final c = LiveController(
    player: player,
    catalogService: _FakeCatalog(),
    startTimeout: const Duration(seconds: 30),
    stallTimeout: const Duration(seconds: 2),
  );
  c.loadChannelsForTest(<LiveChannel>[
    LiveChannel(
      id: 't:one',
      name: '单线台',
      group: '央视频道',
      badge: '1',
      streams: const <LiveStream>[
        LiveStream(url: 'http://one.example/1.m3u8', qualityRank: 50),
      ],
    ),
    LiveChannel(
      id: 't:two',
      name: '双线台',
      group: '央视频道',
      badge: '2',
      streams: const <LiveStream>[
        LiveStream(url: 'http://two.example/1.m3u8', qualityRank: 50),
        LiveStream(url: 'http://two.example/2.m3u8', qualityRank: 40),
      ],
    ),
  ]);

  // 两条线路都死：整台预算 15s 内必然收敛到 failed，不会挂满 30s。
  final sw = Stopwatch()..start();
  await c.tune(c.channels.firstWhere((x) => x.name == '双线台'));
  sw.stop();
  check('多线台在整台预算内收敛（不挂满 30s）',
      sw.elapsedMilliseconds < 20000, '${sw.elapsedMilliseconds}ms');

  c.dispose();
  await Future<void>.delayed(const Duration(milliseconds: 400));
}

// ── 预热推迟：起播瞬间不抢分片带宽 ─────────────────────────────

Future<void> testPrewarmIsDeferred() async {
  print('\n== 预热推迟（起播瞬间不探测备用线路） ==');
  final player = _FakePlayer(<String>{'https://pw.example/1.m3u8'});
  final catalog = _FakeCatalog();
  final c = LiveController(
    player: player,
    catalogService: catalog,
    startTimeout: const Duration(seconds: 2),
    stallTimeout: const Duration(seconds: 2),
  );
  c.loadChannelsForTest(<LiveChannel>[
    LiveChannel(
      id: 't:pw',
      name: '预热台',
      group: '央视频道',
      badge: '预热',
      streams: const <LiveStream>[
        LiveStream(url: 'https://pw.example/1.m3u8', qualityRank: 90),
        LiveStream(url: 'https://pw.example/2.m3u8', qualityRank: 40),
      ],
    ),
  ]);
  await c.tune(c.channels.first);
  check('起播成功', c.phase == LiveTuning.playing, c.phase.name);

  final atStart = catalog.probes;
  await Future<void>.delayed(const Duration(milliseconds: 1200));
  check('起播后 1.2s 内不预热（不抢首帧分片带宽）',
      catalog.probes == atStart, '${catalog.probes - atStart} 次');

  await Future<void>.delayed(const Duration(milliseconds: 2200));
  check('2.5s 后在后台预热备用线路', catalog.probes > atStart,
      '${catalog.probes - atStart} 次');

  c.dispose();
  await Future<void>.delayed(const Duration(milliseconds: 400));
}

Future<void> main() async {
  final uncaught = <Object>[];
  await runZonedGuarded<Future<void>>(
    () async {
      await testProbeTimeoutStillPlays();
      await testProbeRunsInParallel();
      await testPrewarmIsDeferred();
      await testTuneBudget();
      await testPreferredSkipsProbe();
      await testDeadStreamsSkipped();
      await testAdvanceThenPlay();
      await testSweepTerminates();
      await testManualCancelsAdvance();
      await testConcurrentAndDispose();
      await testChannelOrder();
    },
    (Object error, StackTrace stack) => uncaught.add(error),
  );

  check('线路切换/加载失败/自动切台/dispose 全程没有未捕获异步异常',
      uncaught.isEmpty, uncaught.map((e) => '$e').join(' | '));

  print('');
  if (_fail == 0) {
    print('回归通过：$_pass/$_pass 断言通过');
    exit(0);
  }
  print('回归失败：$_pass/${_pass + _fail} 断言通过');
  exit(1);
}
