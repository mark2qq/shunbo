// 直播选台策略回归：失效登记簿 TTL、线路排序、探测分批、内核错误分类。
//
// 为什么必须有这一套：这段逻辑错了，界面**只表现为黑屏**，没有任何异常栈。
// 三个直接对应真机事故的断言：
//   ① 一个镜像整站挂掉（31 个台共用一个域名）→ 死主机必须连带整批失效，
//      否则用户要连着看十几个「正在连接」才等到一个能播的台；
//   ② 死链占满「并发探测 8 个」的窗口 → 必须能换下一批，否则首屏必然黑屏；
//   ③ 内核重试中的 `tcp: Connection ... failed` 不能当终态 → 否则会把一条
//      二十秒后才出画面的线路踢掉，界面显示「暂无信号」而声音已经在放。
//
// 运行：dart run tooling/verify_live_selection.dart
import 'dart:io';

import 'package:shunbo/core/player/kernel_error.dart';
import 'package:shunbo/features/live/live_channel.dart';
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

/// 可控时钟：TTL 相关断言不能靠 `sleep` 等 10 分钟。
class _FakeClock {
  DateTime now = DateTime(2026, 11, 6, 12);
  DateTime call() => now;
  void advance(Duration d) => now = now.add(d);
}

LiveChannel _ch(String id, String group, List<String> urls) => LiveChannel(
      id: id,
      name: id,
      group: group,
      badge: id,
      streams: <LiveStream>[
        for (var i = 0; i < urls.length; i++)
          LiveStream(url: urls[i], label: '线路 ${i + 1}', qualityRank: 10 - i),
      ],
    );

void testRegistry() {
  print('\n== 失效登记簿 ==');
  final clock = _FakeClock();
  final reg = DeadStreamRegistry(clock: clock.call);

  check('未记录时不算失效', !reg.isDead('http://a.example/1.m3u8'));

  reg.mark('http://a.example/1.m3u8');
  check('记录后地址失效', reg.isDeadUrl('http://a.example/1.m3u8'));

  // 单条线路失败**不能**连坐整台主机：公开镜像普遍有约 10% 的瞬时抖动
  // （实测 119 条央视/卫视线路里 12 条「首次超时、重试 2~4.7s 成功」）。
  // 按「一条失败 = 整站拉黑 10 分钟」，同一镜像上本来能播的台会被一起拖下水。
  check('单条失败不连坐整站', !reg.isDeadHost('http://a.example/2.m3u8'));
  check('首条失败计数为 1', reg.hostFailuresOf('http://a.example/2.m3u8') == 1,
      '${reg.hostFailuresOf('http://a.example/2.m3u8')}');

  // 同一主机上第三条**独立线路**也失败 → 判定整站不可用，
  // 换台时才能整批跳过、不用把超时重走一遍。
  //
  // 阈值是 3 而不是 2：一个主机常承载十几个台（实测 74.91.26.218 一家承载
  // 13 个央视台）。2 次抖动就整站封禁 10 分钟 → 这 13 个台同时没有候选线路，
  // 用户看到的就是「央视频道全都不能播」。
  reg.mark('http://a.example/2.m3u8');
  check('同主机第二条失败不连坐',
      !reg.isDeadHost('http://a.example/3.m3u8'),
      'hostFailures=${reg.hostFailuresOf('http://a.example/3.m3u8')}');
  reg.mark('http://a.example/3.m3u8');
  check('阈值常量是 3', DeadStreamRegistry.hostFailureThreshold == 3);
  check('同主机第三条失败后连坐',
      reg.isDeadHost('http://a.example/4.m3u8'),
      'hostFailures=${reg.hostFailuresOf('http://a.example/4.m3u8')}');
  check('同主机其它线路连带失效', reg.isDead('http://a.example/4.m3u8'));
  check('不同主机不受牵连', !reg.isDead('http://b.example/1.m3u8'));

  // 成功必须能**解除**连坐：只记失败不记成功的话，一次抖动留下的封禁
  // 会在 10 分钟里继续压住同一主机上已经恢复的台。
  reg.noteSuccess('http://a.example/4.m3u8');
  check('成功后解除主机连坐', !reg.isDeadHost('http://a.example/4.m3u8'));
  check('成功后该地址失效记录被撤销',
      !reg.isDeadUrl('http://a.example/4.m3u8'));
  reg.mark('http://a.example/3.m3u8');

  clock.advance(const Duration(minutes: 9));
  check('TTL 内仍算失效', reg.isDead('http://a.example/1.m3u8'));

  clock.advance(const Duration(minutes: 2));
  check('TTL 过期后解封（地址）', !reg.isDeadUrl('http://a.example/1.m3u8'));
  check('TTL 过期后解封（主机）', !reg.isDeadHost('http://a.example/2.m3u8'));

  // 上限不能「整表清空」：清空等于把已经学到的失效信息全丢掉，
  // 首屏会立刻退回「挨个试死链」。
  final small = DeadStreamRegistry(clock: clock.call, maxEntries: 3);
  for (var i = 0; i < 3; i++) {
    small.mark('http://h$i.example/$i.m3u8');
    clock.advance(const Duration(seconds: 1));
  }
  small.mark('http://h9.example/9.m3u8');
  check('超上限时保留最近记录', small.isDead('http://h9.example/9.m3u8'),
      'count=${small.streamCount}');
  check('超上限时记录数不超限', small.streamCount <= 3, 'count=${small.streamCount}');
  check('超上限时最旧记录被淘汰', !small.isDeadUrl('http://h0.example/0.m3u8'));

  small.clear();
  check('clear 后清空', small.streamCount == 0 && small.hostCount == 0);
}

void testRanking() {
  print('\n== 线路排序 ==');
  final reg = DeadStreamRegistry();
  // 两条线路刻意放在**不同主机**上：主机级失效是连带整批的（见登记簿回归），
  // 要验证「单条线路降级」就必须避开连带效应。
  final c = _ch('CCTV-1', '央视频道', <String>[
    'http://cdn1.example/hd.m3u8',
    'http://cdn2.example/sd.m3u8',
  ]);

  final clean = LiveSelection.rankStreams(c, reg);
  check('无失效记录时保持画质顺序', clean.first.url.endsWith('hd.m3u8'),
      clean.map((s) => s.url).join(','));

  reg.mark('http://cdn1.example/hd.m3u8');
  final ranked = LiveSelection.rankStreams(c, reg);
  check('失效线路排到最后', ranked.last.url.endsWith('hd.m3u8'),
      ranked.map((s) => s.url).join(','));
  check('失效线路不被删除（只是降级）', ranked.length == 2, '${ranked.length}');
  check('可用线路被提到首位', ranked.first.url.endsWith('sd.m3u8'));

  // 同一主机累计**三条独立线路**失败后才连带降级：单条抖动不拉黑整站
  // （见登记簿用例的说明），整站真死时同一轮并发就会累积到阈值。
  final sameHost = _ch('CCTV-2', '央视频道', <String>[
    'http://cdn1.example/1.m3u8',
    'http://cdn1.example/2.m3u8',
  ]);
  final beforeThreshold = LiveSelection.rankStreams(sameHost, reg);
  check('同主机只失败过一条时不连带',
      beforeThreshold.any((s) => !reg.isDead(s.url)),
      beforeThreshold.map((s) => s.url).join(','));

  // reg 里 cdn1.example 已因上面 hd.m3u8 记过 1 次，补到 3 次触发连坐。
  reg.mark('http://cdn1.example/other1.m3u8');
  reg.mark('http://cdn1.example/other2.m3u8');
  final ranked2 = LiveSelection.rankStreams(sameHost, reg);
  check('同主机线路一起降级',
      ranked2.every((s) => reg.isDead(s.url)), ranked2.map((s) => s.url).join(','));
}

void testPickPlayable() {
  print('\n== 挑台 ==');
  final reg = DeadStreamRegistry();
  check('空表返回 null', LiveSelection.pickPlayable(const <LiveChannel>[], reg) == null);

  final channels = <LiveChannel>[
    _ch('失效台', '央视频道', <String>['http://dead.example/1.m3u8']),
    _ch('可用台', '卫视频道', <String>['http://ok.example/1.m3u8']),
  ];
  reg.mark('http://dead.example/1.m3u8');
  final picked = LiveSelection.pickPlayable(channels, reg);
  check('跳过整台失效的台', picked?.id == '可用台', picked?.id);

  final allDead = <LiveChannel>[
    _ch('A', '央视频道', <String>['http://d1.example/1.m3u8']),
    _ch('B', '卫视频道', <String>['http://d2.example/1.m3u8']),
  ];
  reg.mark('http://d1.example/1.m3u8');
  reg.mark('http://d2.example/1.m3u8');
  check('全部可疑时退回第一个台',
      LiveSelection.pickPlayable(allDead, reg)?.id == 'A');

  // 首条线路死了、备用线路还能用：这个台**必须仍被判为可播**。
  // 早期实现只看 `streams.first`，结果一条备用线路能用的台被整台跳过。
  final reg2 = DeadStreamRegistry();
  final crossHost = <LiveChannel>[
    _ch('跨主机台', '央视频道', <String>[
      'http://t1.example/hd.m3u8',
      'http://t2.example/sd.m3u8',
    ]),
  ];
  reg2.mark('http://t1.example/hd.m3u8');
  check('首条线路失效但备用可用时仍可播',
      LiveSelection.pickPlayable(crossHost, reg2)?.id == '跨主机台');

  // 所有主机都失效 → 跳过这个台，选后面能播的。
  final reg3 = DeadStreamRegistry();
  final fullyDead = <LiveChannel>[
    _ch('全死台', '央视频道', <String>[
      'http://u1.example/1.m3u8',
      'http://u2.example/2.m3u8',
    ]),
    _ch('活台', '卫视频道', <String>['http://u9.example/1.m3u8']),
  ];
  reg3.mark('http://u1.example/1.m3u8');
  reg3.mark('http://u2.example/2.m3u8');
  check('所有主机都失效时跳过整台',
      LiveSelection.pickPlayable(fullyDead, reg3)?.id == '活台');

  // ★ 事故回归钉子：**主机连坐不能让整台频道变成「无候选」**。
  //
  // 真机事故：主索引给 CCTV-1..17 的 13 条线路落在同一个主机上
  // （74.91.26.218）。用户在其中任意两个台各撞一次超时 → 主机被判死 →
  // 其余 11 个台的 `_firstCandidate` 全返回 null → `hasLiveStream` 为 false
  // → 自动切台把整组央视跳过去 → 用户看到「央视频道都不能播放」。
  //
  // 语义拆分后：地址级失效（这条地址刚真的打不开）才取消候选资格；
  // 主机连坐只是「这个镜像不稳」的推测，只影响尝试顺序。
  final reg4 = DeadStreamRegistry();
  for (var i = 0; i < 3; i++) {
    reg4.mark('http://shared.example/dead$i.m3u8');
  }
  final sharedHost = <LiveChannel>[
    _ch('共用主机台', '央视频道', <String>['http://shared.example/fresh.m3u8']),
  ];
  check('触发主机连坐的前提成立', reg4.isDeadHost('http://shared.example/x.m3u8'));
  check('主机连坐后该台仍被视为可播（候选不为空）',
      LiveSelection.pickPlayable(sharedHost, reg4)?.id == '共用主机台');
  check('主机连坐后 hasLiveStream 仍为真（自动切台不会整组跳过）',
      LiveSelection.hasLiveStream(sharedHost.first, reg4));
  reg4.mark('http://shared.example/fresh.m3u8');
  check('地址级失效后该台才真正没有候选',
      !LiveSelection.hasLiveStream(sharedHost.first, reg4));
}

Future<void> testPickProbed() async {
  print('\n== 探测分批 ==');
  final reg = DeadStreamRegistry();
  var probes = 0;

  // 第 ① 场景：前 8 个台共用一个死主机，第 9 个台在另一台主机上。
  // 这正是真机事故的复刻：死链占满探测窗口，能播的台一条都轮不到。
  final channels = <LiveChannel>[
    for (var i = 0; i < 8; i++)
      _ch('死台$i', '央视频道', <String>['http://mirror.example/$i.m3u8']),
    _ch('能播台', '卫视频道', <String>['http://alive.example/1.m3u8']),
  ];
  Future<bool> probe(LiveStream stream) async {
    probes++;
    return stream.url.contains('alive.example');
  }

  final picked = await LiveSelection.pickProbed(
    channels: channels,
    dead: reg,
    probe: probe,
    batch: 8,
  );
  check('死链占满首轮后仍能找到能播的台', picked?.id == '能播台', picked?.id);
  check('首轮探测条数不超过 batch', probes >= 8, 'probes=$probes');
  check('死主机已记录', reg.isDead('http://mirror.example/0.m3u8'));

  // 第 ② 场景：全部失效 → 返回 null（由调用方报「暂无信号」）。
  final reg2 = DeadStreamRegistry();
  final allDead = <LiveChannel>[
    for (var i = 0; i < 3; i++)
      _ch('X$i', '央视频道', <String>['http://none.example/$i.m3u8']),
  ];
  final none = await LiveSelection.pickProbed(
    channels: allDead,
    dead: reg2,
    probe: (stream) async => false,
    batch: 8,
    rounds: 2,
  );
  check('全部失效返回 null', none == null);

  // 第 ③ 场景：一轮只探 batch 条，不会把整表都探一遍。
  final reg3 = DeadStreamRegistry();
  var calls = 0;
  final many = <LiveChannel>[
    for (var i = 0; i < 20; i++)
      _ch('M$i', '卫视频道', <String>['http://host$i.example/1.m3u8']),
  ];
  await LiveSelection.pickProbed(
    channels: many,
    dead: reg3,
    probe: (stream) async {
      calls++;
      return false;
    },
    batch: 8,
    rounds: 1,
  );
  check('单轮最多探 batch 条', calls == 8, 'calls=$calls');

  // 第 ④ 场景：命中第一个可播台就停，不再白探后面的。
  final reg4 = DeadStreamRegistry();
  var calls4 = 0;
  final mixed = <LiveChannel>[
    _ch('先死', '央视频道', <String>['http://no1.example/1.m3u8']),
    _ch('后活', '卫视频道', <String>['http://yes.example/1.m3u8']),
    _ch('更多', '卫视频道', <String>['http://more.example/1.m3u8']),
  ];
  final hit = await LiveSelection.pickProbed(
    channels: mixed,
    dead: reg4,
    probe: (stream) async {
      calls4++;
      await Future<void>.delayed(const Duration(milliseconds: 10));
      return stream.url.contains('yes.example');
    },
    batch: 8,
  );
  check('命中即止并返回对应台', hit?.id == '后活', hit?.id);
  check('同轮并发探测所有候选', calls4 == 3, 'calls=$calls4');
}

void testKernelErrors() {
  print('\n== 内核错误分类 ==');
  check('Failed to open 是终态',
      KernelErrorClassifier.isFatal('Failed to open http://a/b.m3u8.'));
  check('HTTP 502 是终态',
      KernelErrorClassifier.isFatal('http error 502 bad gateway'));
  check('HTTP 404 是终态', KernelErrorClassifier.isFatal('HTTP error 404 Not Found'));
  check('DNS 失败是终态',
      KernelErrorClassifier.isFatal('Failed to resolve hostname example.com'));
  check('格式不可识别是终态',
      KernelErrorClassifier.isFatal('Failed to recognize file format.'));

  // 关键：重试中的中间态**不能**判死，否则会踢掉一条其实能播的线路。
  check('tcp 连接失败不是终态',
      !KernelErrorClassifier.isFatal('tcp: Connection to 1.2.3.4:80 failed'));
  check('空文本不是终态', !KernelErrorClassifier.isFatal(''));
  check('只有 http error 前缀不算终态',
      !KernelErrorClassifier.isFatal('http error while reading header'));
  check('tcp 失败被识别为中间态',
      KernelErrorClassifier.isTransient('tcp: Connection to 1.2.3.4:80 failed'));
}

Future<void> main() async {
  testRegistry();
  testRanking();
  testPickPlayable();
  await testPickProbed();
  testKernelErrors();

  print('');
  // 汇总串格式与其余回归保持一致：门禁靠 "N/M 断言通过" 解析断言数，
  // 格式不对会被判成「静默跳过」。
  if (_fail == 0) {
    print('回归通过：$_pass/$_pass 断言通过');
    exit(0);
  }
  print('回归失败：$_pass/${_pass + _fail} 断言通过');
  exit(1);
}
