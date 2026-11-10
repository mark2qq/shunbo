// 官方源「运行时解析 + 解码门禁换线」的真实控制器回归。
//
// verify_decode_gate.dart 验的是纯策略；这里驱动 LiveController + 假内核 +
// 本地 HttpServer 解析器，钉住三件只有跑起来才会暴露的事：
//   ① 有 resolverUrl 的线路，player.load 收到的是**解析后的官方直连地址**；
//   ② 解析失败必须退回原地址，不能让新能力把原本能播的台变黑屏；
//   ③ 播放中出现加扰日志时，按身份键（原地址）拉黑并换到下一条线路，
//      且上一条线路的迟到事件不会误伤刚播好的新线路。
//
// 运行：dart run tooling/verify_official_playback.dart
library;

import 'dart:async';
import 'dart:io';

import 'package:shunbo/core/player/player_controller.dart';
import 'package:shunbo/features/live/decode_gate.dart';
import 'package:shunbo/features/live/live_catalog.dart';
import 'package:shunbo/features/live/live_channel.dart';
import 'package:shunbo/features/live/live_controller.dart';
import 'package:shunbo/features/live/official_sources.dart';

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

class _FakePlayer implements PlayerController, PictureProbe, DecodeFaultSource {
  final List<String> loads = <String>[];
  final StreamController<DecodeFaultEvent> _faults =
      StreamController<DecodeFaultEvent>.broadcast();
  String? _loaded;
  double _volume = 100;
  int _epoch = 0;

  /// 置 true 时下一次 `load` 抛错（模拟死链），用于验证解析缓存的作废逻辑。
  bool failNextLoad = false;

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
    // 用于验证「起播失败后解析缓存必须作废」。
    if (failNextLoad) {
      failNextLoad = false;
      throw StateError('Failed to open $url');
    }
    _loaded = url;
    _epoch++;
  }

  @override
  Future<void> play() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> seek(double rawSeconds) async {}

  @override
  Future<void> setVolume(double volume) async => _volume = volume;

  @override
  double get volume => _volume;

  @override
  Stream<double> get volumeChanges => Stream<double>.value(_volume);

  @override
  Future<double> currentRawSeconds() async => _loaded == null ? 0 : 1.0;

  @override
  Future<double> duration() async => 0;

  @override
  Future<void> dispose() async => _faults.close();

  @override
  bool get hasPicture => _loaded != null;

  @override
  int get pictureEpoch => _epoch;

  @override
  bool get isBuffering => false;

  @override
  String? get lastError => null;

  @override
  Stream<DecodeFaultEvent> get decodeFaults => _faults.stream;

  void fault(String url, {int count = 3}) => _faults.add(DecodeFaultEvent(
        url: url,
        kind: DecodeFaultKind.scrambled,
        count: count,
        sample: 'h264: error while decoding MB 1 0',
        at: DateTime.now(),
      ));

  void benign(String url) => _faults.add(DecodeFaultEvent(
        url: url,
        kind: DecodeFaultKind.network,
        count: 1,
        sample: 'HTTP error 502',
        at: DateTime.now(),
      ));
}

class _FakeCatalog extends LiveCatalogService {
  _FakeCatalog() : super(builtIn: const <LiveChannel>[]);

  int probes = 0;
  final List<String> probedUrls = <String>[];

  @override
  Future<bool> probe(
    String url, {
    Duration timeout = const Duration(seconds: 3),
    Map<String, String> headers = const <String, String>{},
  }) async {
    probes++;
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

Future<void> _waitFor(bool Function() done, {int millis = 2500}) async {
  final sw = Stopwatch()..start();
  while (!done() && sw.elapsedMilliseconds < millis) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

Future<void> main() async {
  // 本地解析器：/hop → 官方 CDN，/dead → 404，/creds → 记录跨 origin 头。
  final seen = <String, String?>{};
  // 解析器被真实请求的次数：用来钉「缓存命中不重复解析」与「失败后必须重解析」。
  var hopHits = 0;
  // 解析器「失败路径」被请求的次数（/dead 返回 404）。
  var deadHits = 0;
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final base = 'http://localhost:${server.port}';
  server.listen((req) async {
    final res = req.response;
    seen['cookie'] = req.headers.value('cookie');
    switch (req.uri.path) {
      case '/hop':
        hopHits++;
        res.statusCode = HttpStatus.found;
        res.headers.set(HttpHeaders.locationHeader, '$base/cdn/live.m3u8');
        await res.close();
      case '/cdn/live.m3u8':
        seen['ua'] = req.headers.value('user-agent');
        res.write('#EXTM3U\n');
        await res.close();
      case '/dead':
        deadHits++;
        res.statusCode = HttpStatus.notFound;
        await res.close();
      default:
        res.statusCode = HttpStatus.notFound;
        await res.close();
    }
  });

  final resolver = OfficialSourceResolverForTest();
  try {
    final player = _FakePlayer();
    final catalog = _FakeCatalog();
    final board = DecodeGateBoard();
    final c = LiveController(
      player: player,
      catalogService: catalog,
      startTimeout: const Duration(seconds: 2),
      stallTimeout: const Duration(seconds: 2),
      resolver: resolver.actual,
      decodeBoard: board,
    );
    const first = 'http://relay.example/live.php?id=zjws4k';
    const second = 'http://backup.example/2.m3u8';
    final channel = LiveChannel(
      id: 't',
      name: '浙江卫视4K',
      group: '卫视频道',
      badge: '4K',
      streams: <LiveStream>[
        LiveStream(
          url: first,
          label: '官方解析',
          qualityRank: 100,
          decodeVerified: true,
          resolverUrl: '$base/hop',
          headers: <String, String>{'User-Agent': 'AptvPlayer-UA'},
        ),
        LiveStream(url: second, label: '备用', qualityRank: 40),
      ],
    );
    c.loadChannelsForTest(<LiveChannel>[channel]);
    await c.tune(channel);
    await _waitFor(() => c.isPlaying);
    check('官方源起播成功', c.isPlaying, c.message);
    check('load 收到解析后的官方直连地址',
        player.loads.first == '$base/cdn/live.m3u8', player.loads.first);
    check('解析成功时 UA 透传到官方 CDN', seen['ua'] == 'AptvPlayer-UA');
    // 起播前的短探测可以省掉；播放稳定后 `_prewarm` 仍会探备用线路，
    // 所以只钉「解析型线路自己没被重复探」，不能要求探测总数为 0。
    check('解析型线路跳过起播探测', !catalog.probedUrls.contains(first),
        catalog.probedUrls.join(','));
    check('实测线路排在备用线路之前', c.currentStreams.first.url == first);

    // 非加扰事件 / 过期地址的事件都不能触发换线。
    player.benign(player.loads.first);
    player.fault('http://other/old.m3u8');
    await Future<void>.delayed(const Duration(milliseconds: 120));
    check('非加扰事件不换线', player.loads.length == 1);
    check('过期地址事件不换线', player.loads.length == 1);

    // 当前线路报加扰 → 拉黑 + 换到下一条。
    player.fault(player.loads.first);
    await _waitFor(() => player.loads.length >= 2);
    check('加扰触发换线', player.loads.length >= 2, '${player.loads.length} 次 load');
    check('换到备用线路', player.loads.contains(second));
    check('按身份键记住花屏线路', board.isKnownBad(first));
    check('花屏线路不再排第一', c.currentStreams.first.url != first);
    await _waitFor(() => c.isPlaying);
    check('换线后仍能出画面', c.isPlaying, c.message);

    // 解析失败必须退回原地址，而不是让整台失败。
    final p2 = _FakePlayer();
    final c2 = LiveController(
      player: p2,
      catalogService: _FakeCatalog(),
      startTimeout: const Duration(seconds: 2),
      resolver: resolver.actual,
    );
    final channel2 = LiveChannel(
      id: 't2',
      name: '测试台',
      group: '卫视频道',
      badge: '测',
      streams: <LiveStream>[
        LiveStream(
          url: first,
          label: '官方解析',
          qualityRank: 100,
          resolverUrl: '$base/dead',
        ),
        const LiveStream(url: second, label: '备用'),
      ],
    );
    c2.loadChannelsForTest(<LiveChannel>[channel2]);
    final deadBefore = deadHits;
    await c2.tune(channel2);
    await _waitFor(() => c2.isPlaying);
    check('解析失败不导致整台失败', c2.isPlaying, c2.message);
    check('解析失败退回原地址', p2.loads.contains(first), p2.loads.join(','));
    final deadAfterFirst = deadHits;
    check('解析失败会真的请求一次解析器', deadAfterFirst > deadBefore,
        '${deadAfterFirst - deadBefore} 次');

    // 负缓存：解析器刚失败过，紧接着再切这台不该再打解析器（省 150~300ms 白等）。
    p2.loads.clear();
    await c2.tune(channel2);
    await _waitFor(() => c2.isPlaying);
    check('解析失败后走负缓存（不再请求解析器）',
        deadHits == deadAfterFirst, '${deadHits - deadAfterFirst} 次');
    check('负缓存下仍退回原地址并出画面',
        p2.loads.contains(first) && c2.isPlaying, p2.loads.join(','));
    c2.dispose();
    c.dispose();
    c2.dispose();

    // 解析缓存：回切不重复换 token；失败后必须作废重解析。
    await testResolveCache(base, () => hopHits);
  } finally {
    await server.close(force: true);
  }
  print('');
  print('回归通过：$_pass/${_pass + _fail} 断言通过');
  if (_fail > 0) exit(1);
}

/// 官方源解析缓存：换台/回切不该每次都重新换 token（实测 150~300ms 黑屏），
/// 但**起播失败后必须作废**——复用坏地址会让下一次尝试白等一次超时。
Future<void> testResolveCache(String base, int Function() hopHits) async {
  print('\n== 官方源解析缓存 ==');
  final player = _FakePlayer();
  final c = LiveController(
    player: player,
    catalogService: _FakeCatalog(),
    startTimeout: const Duration(seconds: 2),
    stallTimeout: const Duration(seconds: 2),
    resolver: OfficialSourceResolverForTest().actual,
  );
  const identity = 'http://relay.example/live.php?id=cache';
  final channel = LiveChannel(
    id: 'tc',
    name: '缓存台',
    group: '卫视频道',
    badge: '缓存',
    streams: <LiveStream>[
      LiveStream(
        url: identity,
        label: '官方解析',
        qualityRank: 100,
        decodeVerified: true,
        resolverUrl: '$base/hop',
      ),
    ],
  );
  c.loadChannelsForTest(<LiveChannel>[channel]);

  final before = hopHits();
  await c.tune(channel);
  await _waitFor(() => c.isPlaying);
  check('首次起播解析一次', hopHits() == before + 1, '${hopHits() - before} 次');

  // 回切同一台：应命中缓存，不再请求解析器。
  await c.tune(channel);
  await _waitFor(() => c.isPlaying);
  check('回切命中解析缓存', hopHits() == before + 1, '${hopHits() - before} 次');
  check('回切后仍能出画面', c.isPlaying, c.message);

  // 下一次 load 失败 → 这一次仍是命中缓存（所以只解析过 1 次），但缓存要被作废。
  player.failNextLoad = true;
  await c.tune(channel);
  await Future<void>.delayed(const Duration(milliseconds: 400));
  check('失败那一次仍走缓存（没有多余解析）', hopHits() == before + 1,
      '${hopHits() - before} 次');

  // 再切回来：缓存已作废 → 必须重新解析，否则会继续拿坏地址撞超时。
  await c.tune(channel);
  await _waitFor(() => c.isPlaying);
  check('失败后再起播重新解析', hopHits() == before + 2, '${hopHits() - before} 次');
  check('重新解析后仍能出画面', c.isPlaying, c.message);

  c.dispose();
  await Future<void>.delayed(const Duration(milliseconds: 200));
}

/// 包一层只是为了在测试里显式构造解析器并复用同一个实例。
class OfficialSourceResolverForTest {
  final actual = OfficialSourceResolver(
    allowedHostSuffixes: const <String>{'localhost'},
    timeout: const Duration(seconds: 3),
  );
}
