// 多源与选源回归：tvg-id 关联、备用源合并、健康度排序、换线跳过探测。
//
// 为什么单独一套：这些逻辑决定「源慢/源挂时能不能无感切走」，
// 但它们出错时**没有任何异常**——界面只是「还是那条慢源」或「一直黑屏」。
// 三个直接对应线上事故的断言：
//   ① M3U 的 tvg-id 带 `@SD` 后缀，而 streams.json 的 key 没有后缀，
//      不剥离就一条都对不上 → 备用源永远补不进来（表现：每个台还是 1 条线路）；
//   ② streams.json 是不可信输入（3.8 MB、1.8 万条），必须逐条过滤 scheme，
//      否则一条 `javascript:` 或 `rtsp://user:pass@` 会直接把脏地址交给播放内核；
//   ③ 健康度排序必须让「实测快且稳」压过「画质高但总失败」，
//      否则换线永远回到那条烂源（用户体感：换了等于没换）。
//
// 运行：dart run tooling/verify_live_sources.dart
import 'dart:io';

import 'package:shunbo/features/live/live_catalog.dart';
import 'package:shunbo/features/live/live_channel.dart';
import 'package:shunbo/features/live/live_health.dart';
import 'package:shunbo/features/live/live_selection.dart';

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

class _Clock {
  DateTime now = DateTime(2026, 11, 6, 12);
  DateTime call() => now;
  void advance(Duration d) => now = now.add(d);
}

LiveChannel _ch(String id, {String? tvgId, List<LiveStream>? streams}) => LiveChannel(
      id: id,
      name: id,
      group: '央视频道',
      badge: id,
      tvgId: tvgId,
      streams: streams ??
          <LiveStream>[LiveStream(url: 'http://origin.example/$id.m3u8', qualityRank: 60)],
    );

void testTvgId() {
  print('\n== tvg-id 关联键 ==');
  final parsed = LiveCatalogService.parseM3U('''
#EXTINF:-1 tvg-id="CCTV1.cn@SD" group-title="General",CCTV-1 HD (1080p)
http://a.example/1.m3u8
#EXTINF:-1 tvg-id="CCTV2.cn" group-title="General",CCTV-2 (720p)
http://a.example/2.m3u8
#EXTINF:-1 group-title="General",无标识台
http://a.example/3.m3u8
''');
  check('读取 tvg-id', parsed[0].tvgId == 'CCTV1.cn', parsed[0].tvgId);
  check('剥离 @feed 后缀', !parsed[0].tvgId!.contains('@'), parsed[0].tvgId);
  check('无后缀时保持原值', parsed[1].tvgId == 'CCTV2.cn', parsed[1].tvgId);
  check('没有 tvg-id 时为 null', parsed[2].tvgId == null, '${parsed[2].tvgId}');

  check('normalizeTvgId 处理空串', LiveCatalogService.normalizeTvgId('  ') == null);
  check('normalizeTvgId 处理 @ 开头',
      LiveCatalogService.normalizeTvgId('@HD') == null,
      LiveCatalogService.normalizeTvgId('@HD'));

  // 合并内置与远端时不能把 tvgId 丢掉：内置台没有 id，靠远端补。
  final merged = LiveCatalogService.mergeChannels(
    builtIn: <LiveChannel>[_ch('CCTV-1')],
    remote: <LiveChannel>[
      _ch('CCTV-1', tvgId: 'CCTV1.cn', streams: <LiveStream>[
        LiveStream(url: 'http://b.example/1.m3u8'),
      ]),
    ],
  );
  check('合并时继承 tvgId', merged.single.tvgId == 'CCTV1.cn', merged.single.tvgId);
  check('合并时保留两条线路', merged.single.streams.length == 2,
      '${merged.single.streams.length}');
}

void testStreamIndex() {
  print('\n== 备用源索引解析 ==');
  final json = '''
[
  {"channel":"CCTV1.cn","url":"http://h1.example/a.m3u8","quality":"1080p","user_agent":"UA1","referrer":"http://ref.example"},
  {"channel":"CCTV1.cn@SD","url":"http://h2.example/b.m3u8","quality":"720p"},
  {"channel":"CCTV1.cn","url":"http://h1.example/a.m3u8","quality":"1080p"},
  {"channel":"CCTV1.cn","url":"rtsp://h3.example/c","quality":null},
  {"channel":"CCTV1.cn","url":"javascript:alert(1)"},
  {"channel":"CCTV1.cn","url":"http://user:pass@h4.example/d.m3u8"},
  {"channel":null,"url":"http://h5.example/e.m3u8"},
  {"channel":"CCTV2.cn","url":"http://h6.example/f.m3u8","quality":"2160p"}
]''';
  final index = LiveCatalogService.parseStreamIndex(json);
  final cctv1 = index['CCTV1.cn'] ?? const <LiveStream>[];
  check('解析出频道条目', index.containsKey('CCTV1.cn'));
  check('同一频道去重后 2 条', cctv1.length == 2, '${cctv1.length}');
  check('@feed 条目并入同一频道',
      cctv1.any((s) => s.url.contains('h2.example')));
  check('rtsp 被过滤', cctv1.every((s) => !s.url.startsWith('rtsp')));
  check('javascript 被过滤', cctv1.every((s) => !s.url.startsWith('javascript')));
  check('带凭据的地址被过滤', cctv1.every((s) => !s.url.contains('user:pass')));
  check('user-agent / referer 转为请求头',
      cctv1.first.headers['User-Agent'] == 'UA1' &&
          cctv1.first.headers['Referer'] == 'http://ref.example',
      cctv1.first.headers.toString());
  check('quality 转成画质分', cctv1.first.qualityRank == 90, '${cctv1.first.qualityRank}');
  check('2160p 画质分最高', index['CCTV2.cn']!.single.qualityRank == 100);

  check('坏 JSON 不抛异常', LiveCatalogService.parseStreamIndex('{oops').isEmpty);
  check('非数组返回空', LiveCatalogService.parseStreamIndex('{"a":1}').isEmpty);

  // 每台上限：防止恶意/异常数据让单台线路无限增长（换线是逐条试的）。
  final many = <String>[
    for (var i = 0; i < 20; i++) '{"channel":"X.cn","url":"http://h.example/$i.m3u8"}',
  ].join(',');
  final capped = LiveCatalogService.parseStreamIndex('[$many]');
  check('单台线路数有上限',
      capped['X.cn']!.length <= LiveCatalogService.maxStreamsPerChannel,
      '${capped['X.cn']!.length}');
}

void testBackupMerge() {
  print('\n== 备用源合并 ==');
  final channels = <LiveChannel>[
    _ch('CCTV-1', tvgId: 'CCTV1.cn'),
    _ch('CCTV-2', tvgId: 'CCTV2.cn'),
    _ch('无标识台'),
  ];
  final index = <String, List<LiveStream>>{
    'CCTV1.cn': <LiveStream>[
      LiveStream(url: 'http://origin.example/CCTV-1.m3u8'), // 与原有重复
      LiveStream(url: 'http://backup.example/cctv1.m3u8', qualityRank: 90),
    ],
    'CCTV2.cn': <LiveStream>[
      LiveStream(url: 'http://backup.example/cctv2.m3u8', qualityRank: 70),
    ],
  };
  final merged = LiveCatalogService.withBackupStreams(channels, index);

  check('补进备用源', merged[0].streams.length == 2, '${merged[0].streams.length}');
  check('原有线路仍在且排第一',
      merged[0].streams.first.url.contains('origin.example'),
      merged[0].streams.first.url);
  check('重复地址不重复添加',
      merged[0].streams.where((s) => s.url.contains('origin.example')).length == 1);
  check('无标识台原样保留', identical(merged[2], channels[2]));
  check('其它台也被补上', merged[1].streams.length == 2);

  // 上限：备源再多也不超过 maxStreamsPerChannel。
  final greedy = LiveCatalogService.withBackupStreams(
    <LiveChannel>[_ch('多源台', tvgId: 'X.cn')],
    <String, List<LiveStream>>{
      'X.cn': <LiveStream>[
        for (var i = 0; i < 30; i++) LiveStream(url: 'http://x.example/$i.m3u8'),
      ],
    },
  );
  check('合并后不超过上限',
      greedy.single.streams.length <= LiveCatalogService.maxStreamsPerChannel,
      '${greedy.single.streams.length}');
}

void testHealth() {
  print('\n== 线路健康度 ==');
  final clock = _Clock();
  final board = StreamHealthBoard(clock: clock.call);

  check('未知线路给中性分', board.scoreOf('http://a/1') == 55);
  check('未知线路不算「近期可用」', !board.isFreshOk('http://a/1'));

  board.recordOk('http://fast/1', const Duration(milliseconds: 80));
  board.recordStartup('http://fast/1', const Duration(milliseconds: 1200));
  board.recordOk('http://slow/1', const Duration(milliseconds: 1800));
  board.recordStartup('http://slow/1', const Duration(milliseconds: 9000));

  check('快的分高于慢的',
      board.scoreOf('http://fast/1') > board.scoreOf('http://slow/1'),
      '${board.scoreOf('http://fast/1')} vs ${board.scoreOf('http://slow/1')}');
  check('实测可用高于未知',
      board.scoreOf('http://fast/1') > board.scoreOf('http://never/1'));

  // 起播慢必须被压下去：用户对「点下去多久出画面」最敏感。
  // 同样探测 80ms，一个起播 1.2 秒、一个 9 秒，分差要明显。
  board.recordOk('http://slowstart/1', const Duration(milliseconds: 80));
  board.recordStartup('http://slowstart/1', const Duration(milliseconds: 9000));
  check('起播慢显著扣分',
      board.scoreOf('http://fast/1') - board.scoreOf('http://slowstart/1') > 20,
      '${board.scoreOf('http://fast/1')} vs ${board.scoreOf('http://slowstart/1')}');

  // 只探测过、没起播记录的线路不能压过已验证线路。
  // 真机事故：某备用源探测 138ms、起播 17.3 秒，凭探测数据被排到了第一位。
  final probeOnly = StreamHealthBoard(clock: clock.call);
  probeOnly.recordOk('http://probe-only/1', const Duration(milliseconds: 60));
  probeOnly.recordOk('http://probe-only/1', const Duration(milliseconds: 60));
  probeOnly.recordOk('http://probe-only/1', const Duration(milliseconds: 60));
  final proven = StreamHealthBoard(clock: clock.call);
  proven.recordOk('http://proven/1', const Duration(milliseconds: 600));
  proven.recordStartup('http://proven/1', const Duration(milliseconds: 2500));
  check('未验证起播的线路分数有上限', probeOnly.scoreOf('http://probe-only/1') <= 78,
      '${probeOnly.scoreOf('http://probe-only/1')}');
  check('已验证起播的线路优先于未验证的',
      proven.scoreOf('http://proven/1') > probeOnly.scoreOf('http://probe-only/1'),
      '${proven.scoreOf('http://proven/1')} vs ${probeOnly.scoreOf('http://probe-only/1')}');

  check('近期可用被识别', board.isFreshOk('http://fast/1'));
  // 先取快照再推进时钟：落盘/恢复要验证的是「同一时刻的数据能还原」，
  // 不是「11 分钟前的记录还算新鲜」——后者本来就该过期。
  final encoded = board.encode();
  // 恢复用的时钟必须停在**同一时刻**：写死 `DateTime.now()` 会让这条断言
  // 随墙上时间漂移（快照时刻一旦离真实时间超过 5 分钟就必然失败），
  // 回归脚本不该有这种「定时炸弹」。
  final restoreClock = _Clock()..now = clock.now;
  clock.advance(const Duration(minutes: 11));
  check('超过有效期不再算「近期可用」', !board.isFreshOk('http://fast/1'));

  final flaky = StreamHealthBoard(clock: clock.call);
  flaky.recordFail('http://flaky/1');
  flaky.recordFail('http://flaky/1');
  check('连续失败判为可疑', flaky.healthOf('http://flaky/1')!.isFlaky);
  check('可疑线路分低于未知', flaky.scoreOf('http://flaky/1') < 55,
      '${flaky.scoreOf('http://flaky/1')}');
  check('可疑线路不算近期可用', !flaky.isFreshOk('http://flaky/1'));

  // 落盘往返：跨会话保留是这套机制的价值所在。
  // 用「同一时刻」的时钟恢复，避免把 TTL 过期误判成恢复失败。
  final restored = StreamHealthBoard(clock: restoreClock.call)
    ..loadEncoded(encoded);
  check('编码后可完整恢复',
      (restored.scoreOf('http://fast/1') - board.scoreOf('http://fast/1')).abs() < 0.01,
      '${restored.scoreOf('http://fast/1')}');
  check('恢复后仍算近期可用', restored.isFreshOk('http://fast/1'));

  final broken = StreamHealthBoard()..loadEncoded('not json');
  check('损坏文件不抛异常且为空', broken.length == 0);
}

void testRanking() {
  print('\n== 按健康度选源 ==');
  final dead = DeadStreamRegistry();
  final board = StreamHealthBoard();
  final channel = _ch(
    'CCTV-1',
    streams: <LiveStream>[
      // 画质最高，但实测很慢
      LiveStream(url: 'http://slow.example/hd.m3u8', label: '高清', qualityRank: 90),
      // 画质一般，但实测最快
      LiveStream(url: 'http://fast.example/sd.m3u8', label: '标清', qualityRank: 70),
    ],
  );
  board.recordOk('http://slow.example/hd.m3u8', const Duration(milliseconds: 1500));
  board.recordStartup('http://slow.example/hd.m3u8', const Duration(seconds: 8));
  board.recordOk('http://fast.example/sd.m3u8', const Duration(milliseconds: 60));
  board.recordStartup('http://fast.example/sd.m3u8', const Duration(milliseconds: 900));

  final ranked = LiveSelection.rankStreams(channel, dead, health: board);
  check('快的源排第一（压过画质更高但慢的）',
      ranked.first.url.contains('fast.example'), ranked.map((s) => s.url).join(','));

  // 没有健康数据时退回画质优先——不能因为「没测过」就乱序。
  final clean = LiveSelection.rankStreams(channel, dead);
  check('无数据时按画质排序', clean.first.qualityRank == 90,
      clean.map((s) => s.qualityRank).join(','));

  // 失效线路无论多快都要排最后（它在 10 分钟内打不开）。
  board.recordOk('http://slow.example/hd.m3u8', const Duration(milliseconds: 1100));
  dead.mark('http://fast.example/sd.m3u8');
  final afterDead = LiveSelection.rankStreams(channel, dead, health: board);
  check('失效线路排最后', afterDead.last.url.contains('fast.example'),
      afterDead.map((s) => s.url).join(','));

  // 「首条线路失效但备用可用」时仍要挑得出这个台。
  final picked = LiveSelection.pickPlayable(<LiveChannel>[channel], dead, health: board);
  check('仍能选中该台', picked?.id == 'CCTV-1');
}

Future<void> main() async {
  testTvgId();
  testStreamIndex();
  testBackupMerge();
  testHealth();
  testRanking();

  print('');
  if (_fail == 0) {
    print('回归通过：$_pass/$_pass 断言通过');
    exit(0);
  }
  print('回归失败：$_pass/${_pass + _fail} 断言通过');
  exit(1);
}
