// 直播频道目录回归：M3U 自动获取与解析的边界。
//
// 为什么单独一套：频道表是「打开即用」的唯一入口，它出问题不会有异常栈——
// 表现只是「频道少了」「某个台点了没反应」「公司网络下整页空白」。
// 而远端 M3U 是**不可信输入**，解析层必须逐条钉住：
//   ① URL 白名单（禁 rtsp/脚本/userinfo）  ② 体积与条数上限
//   ③ 属性解析（group-title / tvg-name）   ④ 内置优先与线路去重
//   ⑤ 远端失败必须静默退回内置清单，而不是把页面变空
//   ⑥ 同一台的多条线路必须合并成一个频道（否则「画质/线路切换」不成立）
//   ⑦ 分组必须中文化且按归属分类（央视不能被 iptv-org 的 Education/Documentary 拆散）
//
// 运行：dart run tooling/verify_live_catalog.dart
import 'dart:async';
import 'dart:io';

import 'package:shunbo/features/live/channel_numbering.dart';
import 'package:shunbo/features/live/live_catalog.dart';
import 'package:shunbo/features/live/live_channel.dart';
import 'package:shunbo/features/live/stream_policy.dart';
import 'package:shunbo/features/live/verified_channels.g.dart';

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

/// 探测与播放必须用**同一套**请求头。
///
/// 这条不是理论洁癖：探测只带 `shunbo/1.0` 时，需要防盗链的源站会回 403，
/// 调用方据此 `markDead + return false`，`player.load` 根本不会被调用。
/// 同时远端 M3U 是**不可信输入**，它声明的头不能顺手改掉传输层语义。
Future<void> testProbeHeaders() async {
  print('\n== 探测请求头 ==');
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final seen = <String, String?>{};
  var hits = 0;
  server.listen((req) async {
    hits++;
    seen['ua'] = req.headers.value('user-agent');
    seen['referer'] = req.headers.value('referer');
    seen['origin'] = req.headers.value('origin');
    seen['host'] = req.headers.value('host');
    seen['x-extra'] = req.headers.value('x-extra');
    seen['x-injected'] = req.headers.value('x-injected');
    seen['range'] = req.headers.value('range');
    req.response.write('#EXTM3U\n');
    await req.response.close();
  });

  final service = LiveCatalogService(builtIn: const <LiveChannel>[]);
  final url = 'http://127.0.0.1:${server.port}/live.m3u8';

  final ok = await service.probe(url, headers: <String, String>{
    'Referer': 'http://ref.example/play',
    'user-agent': 'custom-ua/2.0',
    'Origin': 'http://ref.example',
  });
  check('带线路声明头的探测能成功', ok);
  check('Referer 真的到达源站', seen['referer'] == 'http://ref.example/play',
      '${seen['referer']}');
  check('线路 UA 覆盖默认 UA', seen['ua'] == 'custom-ua/2.0', '${seen['ua']}');
  check('Origin 真的到达源站', seen['origin'] == 'http://ref.example',
      '${seen['origin']}');

  // 危险头必须被过滤：改 Host 等于把请求打到别的虚拟主机，
  // 探测结果与播放结果的差异会变成无法解释的谜；CRLF 则是请求头注入。
  final ok2 = await service.probe(url, headers: <String, String>{
    'Host': 'evil.example',
    'X-Extra': '1',
    'Range': 'bytes=9-9',
    'Referer': 'http://ref.example/\r\nX-Injected: 1',
  });
  check('过滤后仍能探测', ok2);
  check('Host 不被线路改写',
      (seen['host'] ?? '').contains('127.0.0.1'), '${seen['host']}');
  check('未知头不转发', seen['x-extra'] == null, '${seen['x-extra']}');
  check('Range 不被线路改写', seen['range'] == null, '${seen['range']}');
  check('含 CRLF 的头整条丢弃（不发出去）', seen['referer'] == null,
      '${seen['referer']}');
  check('没有被注入新请求头', seen['x-injected'] == null, '${seen['x-injected']}');
  check('两次探测真的到达源站', hits == 2, 'hits=$hits');

  await server.close(force: true);
}

/// 内置「实测已验证」清单的守护。
///
/// 这份清单是生成产物（`verified_channels.g.dart`），手改会悄悄破坏它；
/// 而它一旦坏掉，表现是「首屏 CCTV 又一个台都放不出来」——不会有异常栈、
/// 不会有告警，只是列表里那几个台点了没反应。
///
/// 所以这里只钉**结构上必须成立**的性质，不钉具体线路数（那会随验证批次变化，
/// 钉死数字等于让每次重新生成都要改一条断言）。
void testVerifiedChannels() {
  print('\n== 内置已验证清单 ==');
  final all = kVerifiedLiveChannels;
  check('清单非空', all.isNotEmpty);
  check('台数不少于 300', all.length >= 300, '实际 ${all.length}');

  final ids = all.map((c) => c.id).toSet();
  check('频道 id 无重复', ids.length == all.length, '${all.length - ids.length} 个重复');

  final cctv = all.where((c) => c.group == '央视频道').toList();
  check('央视台不少于 10 个', cctv.length >= 10, '实际 ${cctv.length}');

  var badUrl = 0;
  var emptyStreams = 0;
  var badRank = 0;
  var badHeader = 0;
  for (final c in all) {
    if (c.streams.isEmpty) emptyStreams++;
    for (final s in c.streams) {
      final u = Uri.tryParse(s.url);
      if (u == null || !(u.scheme == 'http' || u.scheme == 'https')) badUrl++;
      if (s.qualityRank <= 0) badRank++;
      if (s.headers.keys.any((k) => const <String>{'host', 'range'}.contains(k.toLowerCase()))) {
        badHeader++;
      }
    }
  }
  check('线路地址只允许 http/https', badUrl == 0, '$badUrl 条越界');
  check('每个台至少一条线路', emptyStreams == 0, '$emptyStreams 个空台');
  check('线路画质分已设置', badRank == 0, '$badRank 条为 0');
  check('线路头不改传输语义', badHeader == 0, '$badHeader 条带 host/range');

  // 这份清单的准入条件就是「libmpv 建起解码链且解码器零报错」，
  // 所以每条线路都必须带 decodeVerified。少这个标记的后果不是少一条断言：
  // `orderedStreams` 的「实测优先」与 `_tryStream` 的 trusted 免探测快路径
  // 会同时失效——排序退化成画质优先，首次起播还要白等 3.5s 探测。
  var notVerified = 0;
  for (final c in all) {
    for (final s in c.streams) {
      if (!s.decodeVerified) notVerified++;
    }
  }
  check('实测清单每条线路带 decodeVerified', notVerified == 0,
      '$notVerified 条缺标记');

  // 与演示信号合并后 id 不能撞：撞了会让「演示信号」和真实台互相覆盖。
  final merged = <LiveChannel>[...BuiltInLiveChannels.all, ...all];
  check('与内置演示信号 id 不冲突', merged.map((c) => c.id).toSet().length == merged.length);

  // 央视必须落在第一栏：分组错了用户翻不到，「能播」等于白搭。
  check('央视全部归入央视频道', cctv.every((c) => c.categories.contains('央视频道')));
  final satellite = all.where((c) => c.group == '卫视频道').length;
  check('卫视有独立分组', satellite >= 3, '实际 $satellite');

  // 清单是有保质期的：时间戳必须存在且可解析，否则「过期」无从判断。
  final stamp = DateTime.tryParse(kVerifiedLiveAt);
  check('验证时间戳可解析', stamp != null, kVerifiedLiveAt);
  check('验证时间戳不是占位值', stamp != null && stamp.year >= 2026);
}

/// 内置实测线路必须排在远端线路**之前**。
///
/// 起播是按线路顺序逐条探测的（`LiveSelection`），所以「排在后面」等于「大概率轮不到」——
/// 那份清单花了 20 分钟解码验证，排到远端 HD 线路后面就等于白做。
/// 同时台名、分组不能被远端改名：内置的台名是干净的「CCTV-1」，
/// 远端常见「CCTV1 综合 HD 备用」这类噪音，谁覆盖谁决定了首屏长什么样。
void testVerifiedPrecedence() {
  print('\n== 内置实测线路优先 ==');
  final base = kVerifiedLiveChannels.firstWhere((c) => c.group == '央视频道');
  final remote = LiveChannel(
    id: base.id,
    name: '${base.name} 远端镜像',
    group: base.group,
    badge: base.badge,
    streams: const <LiveStream>[
      LiveStream(url: 'http://remote.example.test/x.m3u8', label: '远端', qualityRank: 99),
    ],
  );
  final merged = LiveCatalogService.mergeChannels(
    builtIn: <LiveChannel>[base],
    remote: <LiveChannel>[remote],
  );
  check('同 id 合并成一个台', merged.length == 1, '实际 ${merged.length}');
  final m = merged.first;
  check('内置实测线路排在最前', m.streams.first.url == base.streams.first.url, m.streams.first.url);
  check('远端线路被并入而非覆盖', m.streams.length == base.streams.length + 1,
      '${base.streams.length} → ${m.streams.length}');
  check('台名与分组不被远端改写', m.name == base.name && m.group == base.group, m.name);
}

/// 候选层线路准入：占位线路拦截 + 站点强制请求头。
///
/// 两个实测事故钉在这里：
///  ① 贵州卫视首条候选 302 到 `error_account_pirated.mp4`——解码零报错、有 1080p
///     视频轨，解码门禁判「可播」，用户看到的却是反盗链提示片；
///  ② 河南卫视唯一可解码线路缺 `Referer` 直接 403，补上站点 Referer 就 200。
///
/// 两类都不能只靠运行时兜底：占位线路会先占掉「单台线路封顶」的名额，
/// 缺头的线路则会把一个本来能播的台整台判死。
void testStreamPolicy() {
  print('\n== 线路准入（占位拦截 / 站点请求头） ==');
  const placeholder =
      'https://live.264788.xyz/channel/guizhouweishi?streamid=x';
  const normal = 'http://ok.example.test/a.m3u8';

  check('占位/反盗链主机被拦',
      StreamPolicy.isBlocked(const LiveStream(url: placeholder)));
  check(
      '解析器落在占位主机也被拦',
      StreamPolicy.isBlocked(const LiveStream(
          url: normal, resolverUrl: placeholder)));
  check('普通地址不拦', !StreamPolicy.isBlocked(const LiveStream(url: normal)));

  const henan = 'http://media.hndyjyfw.gov.cn/live/jz-hnweishi/live.m3u8';
  final fixed = StreamPolicy.withSiteHeaders(
      const LiveStream(url: henan, label: '河南卫视', qualityRank: 50));
  check('站点强制头被补齐',
      fixed.headers['Referer'] == 'http://media.hndyjyfw.gov.cn/',
      '${fixed.headers}');
  check('补齐不改画质与标签', fixed.qualityRank == 50 && fixed.label == '河南卫视');

  final declared = StreamPolicy.withSiteHeaders(const LiveStream(
    url: henan,
    headers: <String, String>{'referer': 'http://custom.test/'},
  ));
  check(
      '线路自带 Referer 不被覆盖',
      declared.headers.length == 1 &&
          declared.headers['referer'] == 'http://custom.test/',
      '${declared.headers}');

  final mixed = LiveChannel(
    id: 't:mixed',
    name: '混合台',
    group: '卫视频道',
    badge: '混合',
    streams: const <LiveStream>[
      LiveStream(url: placeholder, label: '提示片', qualityRank: 99),
      LiveStream(url: normal, label: '正常', qualityRank: 50),
    ],
  );
  final applied = StreamPolicy.apply(<LiveChannel>[mixed]);
  check('占位线路从候选里删掉', applied.single.streams.length == 1,
      '${applied.single.streams.length}');
  check('保留下来的不是占位线路',
      applied.single.streams.single.url == normal);

  final onlyPlaceholder = LiveChannel(
    id: 't:bad',
    name: '只有提示片',
    group: '卫视频道',
    badge: '提示',
    streams: const <LiveStream>[
      LiveStream(url: placeholder, qualityRank: 99),
    ],
  );
  check('全部线路被拦时整台消失',
      StreamPolicy.apply(<LiveChannel>[onlyPlaceholder]).isEmpty);

  final untouched = LiveChannel(
    id: 't:ok',
    name: '正常台',
    group: '央视频道',
    badge: '正常',
    streams: const <LiveStream>[
      LiveStream(url: normal, qualityRank: 50),
    ],
  );
  check('无需处理时返回原引用',
      identical(StreamPolicy.apply(<LiveChannel>[untouched]).single, untouched));

  // 端到端：内置清单里的河南卫视经准入层之后必须带 Referer，
  // 否则装载完仍然 403（这正是本轮实测到的「打不开」）。
  final henanChannels = StreamPolicy.apply(kVerifiedLiveChannels)
      .where((c) => c.name == '河南卫视')
      .toList();
  check('内置清单含河南卫视', henanChannels.isNotEmpty);
  final henanStreams = henanChannels.expand((c) => c.streams).toList();
  check(
      '河南卫视线路经准入层后带 Referer',
      henanStreams.isNotEmpty &&
          henanStreams.every((s) =>
              s.headers.keys.any((k) => k.toLowerCase() == 'referer')),
      '${henanStreams.map((s) => s.headers).toList()}');
}

/// CCTV-5 必须在内置清单里，且按号 5 能切到它。
///
/// 背景：内置清单此前只筛到央视 11 个台、缺 CCTV-5，于是编号 5 被 `CCTV+1`
/// 付费台占走，用户按 5 切到的是付费台。本轮补入一条实测 **3 轮解码零错误**
/// 的公开源（`207.56.13.146` 中转，302 到带时效令牌的 CDN，需 UA=AptvPlayer-UA）。
void testCctv5Present() {
  print('\n== CCTV-5 补齐 ==');
  final c5 = kVerifiedLiveChannels.where((c) => c.name == 'CCTV-5').toList();
  check('内置清单含 CCTV-5', c5.length == 1, '${c5.length} 个');
  if (c5.isEmpty) return;
  final streams = c5.first.streams;
  check('CCTV-5 有解码验证过的线路',
      streams.any((x) => x.decodeVerified && x.qualityRank > 0),
      '${streams.length} 条');
  check(
      'CCTV-5 线路带 UA 头（公开源 302 需要）',
      streams.any((x) =>
          (x.headers['User-Agent'] ?? x.headers['user-agent'] ?? '').isNotEmpty),
      '无 UA');

  final book = ChannelNumberBook();
  final byId = book.rebuild(kVerifiedLiveChannels);
  check('按号 5 = CCTV-5', byId[c5.first.id] == 5, '${byId[c5.first.id]}');
  final hit = book.channelForNumber(kVerifiedLiveChannels, 5);
  check('channelForNumber(5) 返回 CCTV-5', hit?.name == 'CCTV-5', hit?.name);
}

Future<void> main() async {
  testUrlWhitelist();
  await testProbeHeaders();
  testParse();
  testMergeDuplicateStations();
  testCanonicalName();
  testGroupInference();
  testQualityRank();
  testMerge();
  testSorting();
  testBuiltIn();
  testVerifiedChannels();
  testCctv5Present();
  testVerifiedPrecedence();
  testStreamPolicy();
  testSourceConfig();
  await testLoadSplit();
  await testServiceLoad();

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

void testUrlWhitelist() {
  check('https 地址可用', LiveCatalogService.isAcceptableStreamUrl('https://a.com/x.m3u8'));
  check('http 地址可用', LiveCatalogService.isAcceptableStreamUrl('http://a.com:8080/x.m3u8'));
  check('rtsp 被拒', !LiveCatalogService.isAcceptableStreamUrl('rtsp://a.com/x'));
  check('file 被拒', !LiveCatalogService.isAcceptableStreamUrl('file:///etc/passwd'));
  check('javascript 被拒', !LiveCatalogService.isAcceptableStreamUrl('javascript:alert(1)'));
  check('data 被拒', !LiveCatalogService.isAcceptableStreamUrl('data:text/plain,x'));
  check(
    '带 userinfo 被拒',
    !LiveCatalogService.isAcceptableStreamUrl('http://user:pass@a.com/x.m3u8'),
  );
  check('空 host 被拒', !LiveCatalogService.isAcceptableStreamUrl('http:///x.m3u8'));
  check('超长地址被拒', !LiveCatalogService.isAcceptableStreamUrl('https://a.com/${'x' * 2100}'));
  check('空串被拒', !LiveCatalogService.isAcceptableStreamUrl(''));
}

void testParse() {
  const sample = '''
#EXTM3U
#EXTINF:-1 tvg-id="cctv1.cn" tvg-name="CCTV-1" group-title="央视频道",CCTV-1 综合
http://ivi.example.com/cctv1.m3u8
#EXTINF:-1 group-title="卫视频道",湖南卫视
http://ivi.example.com/hunan.m3u8
#EXTVLCOPT:network-caching=1000
#EXTINF:-1,没有分组的台
https://a.com/nogroup.m3u8
http://orphan.example.com/no-extinf.m3u8
#EXTINF:-1,坏地址台
rtsp://a.com/x
#EXTINF:-1,超协议台
ftp://a.com/x.m3u8
''';

  final channels = LiveCatalogService.parseM3U(sample);
  check('解析出 3 个可用频道', channels.length == 3, '实际 ${channels.length}');
  check('第一个是 CCTV-1', channels[0].name == 'CCTV-1', channels[0].name);
  check('group-title 被采用', channels[0].group == '央视频道', channels[0].group);
  check('第二条是湖南卫视', channels[1].name == '湖南卫视');
  check('卫视分组正确', channels[1].group == '卫视频道');
  // 全网索引里大量中文地市台没有 group-title：这类台必须回「地方频道」，
  // 才能参与按城市过滤；否则「其它频道」会被几百个地方台冲爆。
  check('缺 group 的中文台归入地方频道', channels[2].group == '地方频道',
      channels[2].group);
  check('无 EXTINF 的裸地址被跳过', channels.every((c) => !c.streams.first.url.contains('orphan')));
  check('rtsp 条目被丢弃', channels.every((c) => !c.streams.first.url.startsWith('rtsp')));
  check('ftp 条目被丢弃', channels.every((c) => !c.streams.first.url.startsWith('ftp')));
  check('每条频道都有 1 条线路', channels.every((c) => c.streams.length == 1));

  // id 稳定性：同一份清单解析两次，id 必须一致（否则收藏与当前台会丢）。
  final again = LiveCatalogService.parseM3U(sample);
  check(
    '同源重复解析 id 稳定',
    List.generate(channels.length, (i) => channels[i].id == again[i].id).every((x) => x),
  );

  // 同名不同组不能合并成同一个 id。
  final sameName = LiveCatalogService.parseM3U('''
#EXTINF:-1 group-title="A组",同名台
http://a.com/1.m3u8
#EXTINF:-1 group-title="B组",同名台
http://a.com/2.m3u8
''');
  check('同名不同组保留两条', sameName.length == 2, '实际 ${sameName.length}');
  check('同名不同组 id 不同', sameName[0].id != sameName[1].id);

  check('空文本得到空清单', LiveCatalogService.parseM3U('').isEmpty);
  check('只有头标签得到空清单', LiveCatalogService.parseM3U('#EXTM3U\n').isEmpty);

  // 台标文字：去掉高清后缀、限长 4 字。
  final badge = LiveCatalogService.parseM3U('''
#EXTINF:-1,CCTV-1 综合高清
http://a.com/1.m3u8
#EXTINF:-1,湖南卫视
http://a.com/2.m3u8
''');
  check('台标去掉「高清」', !badge[0].badge.contains('高清'), badge[0].badge);
  check('台标不超过 4 字', badge.every((c) => c.badge.length <= 4));

  // 央视台标必须是频道号：否则整列都是「CCTV」，频道栏里分不出是哪个台。
  final cctvBadge = LiveCatalogService.parseM3U('''
#EXTINF:-1,CCTV-1 (720p)
http://a.com/1.m3u8
#EXTINF:-1,CCTV-13 HD
http://a.com/13.m3u8
#EXTINF:-1,CCTV-5+
http://a.com/5p.m3u8
''');
  check('CCTV-1 台标是 1', cctvBadge[0].badge == '1', cctvBadge[0].badge);
  check('CCTV-13 台标是 13', cctvBadge[1].badge == '13', cctvBadge[1].badge);
  check('CCTV-5+ 台标保留 +', cctvBadge[2].badge == '5+', cctvBadge[2].badge);

  // 条数上限：造 800 条，只保留前 600。
  final buf = StringBuffer('#EXTM3U\n');
  for (var i = 0; i < 800; i++) {
    buf.writeln('#EXTINF:-1,频道$i');
    buf.writeln('http://a.com/$i.m3u8');
  }
  final capped = LiveCatalogService.parseM3U(buf.toString());
  check('条数上限 600', capped.length == LiveCatalogService.maxChannels, '实际 ${capped.length}');
}

/// 同名站点跨索引拆分（不同 group-title 算出不同 id）必须合并回一个频道：
/// 既是去重，也是把弱重复行的线路补回强台。同时验证 IPv6 直连地址降权。
void testMergeDuplicateStations() {
  print('\n== 同名站点跨索引拆分 → 合并回一个频道（去重 + 补源） ==');
  final v4 = LiveStream(url: 'http://a.com/phx1.m3u8', label: 'l', qualityRank: 50);
  final s2 = LiveStream(url: 'http://a.com/phx2.m3u8', label: 'l', qualityRank: 80);
  final s3 = LiveStream(url: 'http://a.com/phx3.m3u8', label: 'l', qualityRank: 60);
  final s4 = LiveStream(url: 'http://a.com/phx4.m3u8', label: 'l', qualityRank: 70);
  final v6 = LiveStream(url: 'http://[2409:8087:8:21::18]:6610/x.m3u8', label: 'l', qualityRank: 50);
  final weak = LiveChannel(
      id: 'a:凤凰资讯', name: '凤凰资讯', group: '其它频道', badge: '凤凰资讯', streams: [v4]);
  final strong = LiveChannel(
      id: 'b:凤凰资讯', name: '凤凰资讯', group: '其它频道', badge: '凤凰资讯', streams: [s2, s3, s4]);
  final ipv6only = LiveChannel(
      id: 'c:凤凰资讯',
      name: '凤凰资讯',
      group: '其它频道',
      tvgId: 'phoenix.cn',
      badge: '凤凰资讯',
      streams: [v6]);
  final merged =
      LiveCatalogService.mergeDuplicateStations([weak, strong, ipv6only]);
  check('同名三行合并为 1 个频道', merged.length == 1, '实际 ${merged.length}');
  check('存活台是线路最多的强台', merged.first.id == 'b:凤凰资讯', merged.first.id);
  check('线路并集 = 5 条（不丢任何源）', merged.first.streams.length == 5,
      '实际 ${merged.first.streams.length}');
  check('弱台 tvg-id 被继承（可走备用源）', merged.first.tvgId == 'phoenix.cn',
      '${merged.first.tvgId}');
  // 不同站点仍分开，不会误并。
  final other = LiveChannel(
      id: 'x:别的台', name: '别的台', group: '其它频道', badge: '别的台', streams: [v4]);
  final two = LiveCatalogService.mergeDuplicateStations([weak, other]);
  check('不同名仍保留两条', two.length == 2, '实际 ${two.length}');

  // IPv6 直连地址必须降权（优先走 IPv4）。
  final v4s = LiveCatalogService.parseM3U('#EXTINF:-1,测试台\nhttp://a.com/x.m3u8');
  final v6s = LiveCatalogService.parseM3U(
      '#EXTINF:-1,测试台\nhttp://[2409:8087:8:21::18]:6610/x.m3u8');
  check('IPv4 与 IPv6 基础分相同', v4s.isNotEmpty && v6s.isNotEmpty);
  if (v4s.isNotEmpty && v6s.isNotEmpty) {
    final diff = v4s.first.streams.first.qualityRank -
        v6s.first.streams.first.qualityRank;
    check('IPv6 线路被降权 1000（排到本台最后）', diff == 1000, 'diff=$diff');
  }
}

void testCanonicalName() {
  // 这些形态都直接抄自 iptv-org 的 cn.m3u，不是假想的输入。
  check('去掉 (720p)', LiveCatalogService.canonicalName('CCTV-1 (720p)') == 'CCTV-1',
      LiveCatalogService.canonicalName('CCTV-1 (720p)'));
  check('去掉 HD (1080p)',
      LiveCatalogService.canonicalName('CCTV-1 HD (1080p)') == 'CCTV-1',
      LiveCatalogService.canonicalName('CCTV-1 HD (1080p)'));
  check('去掉 (2160p)', LiveCatalogService.canonicalName('Hunan TV (2160p)') == 'Hunan TV',
      LiveCatalogService.canonicalName('Hunan TV (2160p)'));
  check('去掉 [Not 24/7]',
      LiveCatalogService.canonicalName('Chuxiong News Channel [Not 24/7]') ==
          'Chuxiong News Channel',
      LiveCatalogService.canonicalName('Chuxiong News Channel [Not 24/7]'));
  // `+` 是台名的一部分：CCTV-5+（体育赛事）与 CCTV-5（体育）是两个台。
  check('保留 + 号', LiveCatalogService.canonicalName('CCTV-5+ (1080p)') == 'CCTV-5+',
      LiveCatalogService.canonicalName('CCTV-5+ (1080p)'));
  // 4K 是台名的一部分（CCTV 4K 是独立频道），不能当画质标注削掉。
  check('保留 4K 台名', LiveCatalogService.canonicalName('CCTV 4K (2160p)') == 'CCTV-4K',
      LiveCatalogService.canonicalName('CCTV 4K (2160p)'));
  // `CCTV4` 与 `CCTV-4` 是同一个台：写法不归一就会分裂成两个频道，
  // 数字编号也跟着分裂（两个台抢同一个号）。
  check('CCTV4 归一为 CCTV-4',
      LiveCatalogService.canonicalName('CCTV4') == 'CCTV-4',
      LiveCatalogService.canonicalName('CCTV4'));
  check('中文台名原样保留', LiveCatalogService.canonicalName('湖南卫视') == '湖南卫视');
  // 全角括号在中文索引里也常见。
  check('去掉全角括号',
      LiveCatalogService.canonicalName('CCTV-6 电影（1080p）') == 'CCTV-6',
      LiveCatalogService.canonicalName('CCTV-6 电影（1080p）'));
  // 央视的栏目后缀不是台名的一部分：`CCTV-1` 与 `CCTV-1综合` 是同一个台，
  // 不削掉就会分裂成两个台（数字编号也跟着分裂）。
  check('削掉央视栏目后缀',
      LiveCatalogService.canonicalName('CCTV-1综合') == 'CCTV-1',
      LiveCatalogService.canonicalName('CCTV-1综合'));
  check('海外版台名不被削',
      LiveCatalogService.canonicalName('CCTV-4 America') == 'CCTV-4 America',
      LiveCatalogService.canonicalName('CCTV-4 America'));

  // 规范化必须落到 id 上，否则「同一个台三条线路」不会合并。
  final three = LiveCatalogService.parseM3U('''
#EXTINF:-1 group-title="General",CCTV-1 (720p)
http://a.com/1.m3u8
#EXTINF:-1 group-title="General",CCTV-1 HD (1080p)
http://a.com/2.m3u8
#EXTINF:-1 group-title="General",CCTV-1
http://a.com/3.m3u8
''');
  check('三条同台条目 id 一致', three.map((c) => c.id).toSet().length == 1,
      three.map((c) => c.id).join(','));
}

void testGroupInference() {
  // 央视必须按归属分类，不能被 iptv-org 的内容分类拆散。
  check('CCTV-7 在 Education 组仍归央视',
      LiveCatalogService.inferGroup('CCTV-7', 'Education') == '央视频道',
      LiveCatalogService.inferGroup('CCTV-7', 'Education'));
  check('CCTV-9 在 Documentary 组仍归央视',
      LiveCatalogService.inferGroup('CCTV-9', 'Documentary') == '央视频道');
  check('CGTN 归央视', LiveCatalogService.inferGroup('CGTN', 'News') == '央视频道');
  check('卫视按台名判定', LiveCatalogService.inferGroup('湖南卫视', 'General') == '卫视频道');
  // **来源归属**看 tvg-id 的国家码：`QTV-1` 的 tvg-id 正是 `QTV1.cn`，
  // 它是青岛的地方台，不是「全网其它视频源」。
  check('General 归地方频道',
      LiveCatalogService.inferGroup('QTV-1', 'General', tvgId: 'QTV1.cn') ==
          '地方频道');
  // **内容分类是叠加的**：主分类按来源走，「新闻 / 少儿 / 体育」另算一份。
  check('News 归新闻',
      LiveCatalogService.categoriesOf('Harbin News', 'News',
              tvgId: 'HarbinNews.cn')
          .contains('新闻'),
      LiveCatalogService.categoriesOf('Harbin News', 'News',
              tvgId: 'HarbinNews.cn')
          .join(','));
  check('多标签取第一个可映射的',
      LiveCatalogService.categoriesOf('卡通频道', 'Animation;Kids')
          .contains('少儿'),
      LiveCatalogService.categoriesOf('卡通频道', 'Animation;Kids').join(','));
  // 境外来源的台不进「新闻 / 少儿 / 体育」——这三个分类只收央视、卫视、地方。
  check('境外台不进少儿分类',
      !LiveCatalogService.categoriesOf('Cartoon', 'Animation;Kids')
          .contains('少儿'),
      LiveCatalogService.categoriesOf('Cartoon', 'Animation;Kids').join(','));
  check('境外台归其它频道',
      LiveCatalogService.inferGroup('Cartoon', 'Animation;Kids') == '其它频道');
  check('未知分组归其它', LiveCatalogService.inferGroup('Some TV', 'Religious') == '其它频道');
  check('无分组归其它', LiveCatalogService.inferGroup('Some TV', null) == '其它频道');

  // 全网检索扩展后的归类兜底：中文台名 / tvg-id 国家码回地方频道，
  // 台名里的栏目词优先归到内容栏目，避免少儿、体育被地方台冲淡。
  check('中文台名兜底归地方频道',
      LiveCatalogService.inferGroup('徐州-1', null) == '地方频道');
  check('.cn 的 tvg-id 归地方频道',
      LiveCatalogService.inferGroup('Xinjiang TV 1', null, tvgId: 'XinjiangTV1.cn') ==
          '地方频道');
  check('.tw 的 tvg-id 归地方频道',
      LiveCatalogService.inferGroup('Good 2', null, tvgId: 'Good2.tw') == '地方频道');
  check('境外无中文台仍归其它',
      LiveCatalogService.inferGroup('Some TV', null, tvgId: 'SomeTV.us') == '其它频道');
  check('台名含体育归体育栏目',
      LiveCatalogService.categoriesOf('百事通体育1', null).contains('体育'),
      LiveCatalogService.categoriesOf('百事通体育1', null).join(','));
  check('台名含少儿归少儿栏目',
      LiveCatalogService.categoriesOf('卡通频道', null).contains('少儿'),
      LiveCatalogService.categoriesOf('卡通频道', null).join(','));
  // 中国教育电视台（CETV）是央视体系的四个台，不是卫视。
  check('中国教育台归央视频道',
      LiveCatalogService.inferGroup('中国教育1台', '卫视频道') == '央视频道');
  check('CETV 台名归一为中国教育',
      LiveCatalogService.canonicalName('CETV-1') == '中国教育1台',
      LiveCatalogService.canonicalName('CETV-1'));
  check('明确分组优先于台名栏目词',
      LiveCatalogService.inferGroup('浙江新闻', '浙江频道') == '地方频道');
  check('明确规则可识别央视',
      LiveCatalogService.explicitGroupOf('CCTV-7', 'Education') == '央视频道');
  check('未识别分组返回 null 以便身份保留原值',
      LiveCatalogService.explicitGroupOf('同名台', 'A组') == null);

  // 分组顺序决定频道列表顺序：央视最前，其它最后。
  check('央视排第一', LiveChannel.groupRank('央视频道') < LiveChannel.groupRank('地方频道'));
  check('其它频道排最后',
      LiveChannel.groupRank('其它频道') > LiveChannel.groupRank('购物'));

  // CCTV+ 1（付费外语频道）不能和 CCTV-1 合并。
  final plus = LiveCatalogService.parseM3U('''
#EXTINF:-1 group-title="General",CCTV+ 1 (600p)
http://a.com/plus.m3u8
#EXTINF:-1 group-title="General",CCTV-1 (720p)
http://a.com/one.m3u8
''');
  check('CCTV+ 1 与 CCTV-1 id 不同', plus[0].id != plus[1].id, plus.map((c) => c.id).join(' / '));
}

void testQualityRank() {
  check('2160p 最高', LiveCatalogService.qualityRankOf('X (2160p)') == 100);
  check('1080p 次之', LiveCatalogService.qualityRankOf('X (1080p)') == 90);
  check('720p', LiveCatalogService.qualityRankOf('X (720p)') == 70);
  check('576i', LiveCatalogService.qualityRankOf('X (576i)') == 50);
  check('未标注落到中档', LiveCatalogService.qualityRankOf('X') == 60);
  check('1080p 高于 720p',
      LiveCatalogService.qualityRankOf('X (1080p)') >
          LiveCatalogService.qualityRankOf('X (720p)'));

  // 合并后线路按画质排序：用户在 UI 里看到的第一条就是最清晰的那条。
  final parsed = LiveCatalogService.parseM3U('''
#EXTINF:-1 group-title="General",CCTV-1 (720p)
http://a.com/720.m3u8
#EXTINF:-1 group-title="General",CCTV-1 HD (1080p)
http://a.com/1080.m3u8
#EXTINF:-1 group-title="General",CCTV-1
http://a.com/unknown.m3u8
''');
  final merged = LiveCatalogService.mergeChannels(
      builtIn: const <LiveChannel>[], remote: parsed);
  check('同台三条线路合并成一个频道', merged.length == 1, '实际 ${merged.length}');
  check('线路数 3', merged.first.streams.length == 3, '实际 ${merged.first.streams.length}');
  check('最清晰线路排第一', merged.first.orderedStreams.first.url == 'http://a.com/1080.m3u8',
      merged.first.orderedStreams.first.url);
  check('线路名保留原始分辨率标注',
      merged.first.orderedStreams.first.label.contains('1080p'),
      merged.first.orderedStreams.first.label);
}

void testSorting() {
  LiveChannel ch(String name, String group) => LiveChannel(
        id: LiveCatalogService.channelIdFor(name, group),
        name: name,
        group: group,
        badge: name,
        streams: const <LiveStream>[LiveStream(url: 'http://a.com/x.m3u8')],
      );

  // 索引里 CCTV 的条目顺序是乱的，组内必须按号码重排。
  final sorted = LiveCatalogService.sortChannels(<LiveChannel>[
    ch('CCTV-6', '央视频道'),
    ch('CCTV+ 1', '央视频道'),
    ch('CCTV-1', '央视频道'),
    ch('CCTV-13', '央视频道'),
    ch('湖南卫视', '卫视频道'),
  ]);
  check('央视排在卫视前', sorted.first.group == '央视频道');
  check('组内按号码升序',
      sorted.take(4).map((c) => c.name).join(',') == 'CCTV-1,CCTV-6,CCTV-13,CCTV+ 1',
      sorted.take(4).map((c) => c.name).join(','));
  check('同组同号保持入库顺序', sorted.last.name == '湖南卫视');

  // 没有号码的台排在本组最后，但仍在本组内。
  final noNumber = LiveCatalogService.sortChannels(<LiveChannel>[
    ch('测试台', '央视频道'),
    ch('CCTV-1', '央视频道'),
  ]);
  check('无号码台排在本组末尾', noNumber.last.name == '测试台',
      noNumber.map((c) => c.name).join(','));
}

/// 数据源配置不变量：主链路只放小快直连、聚合源必须带可用镜像、增强超时宽于主超时。
///
/// 这是「70% 频道只有单点源」修复的护栏：一旦有人把大体积代理源塞回主链路、
/// 或删掉 gh-proxy.com 镜像，门禁立刻变红。
void testSourceConfig() {
  print('\n== 数据源配置不变量 ==');
  // 主链路：只放 iptv-org 官方目录（小、快、直连），不得含代理镜像或 IPv6 大表。
  check('主链路只有 2 份索引', kDefaultLiveIndexUrls.length == 2,
      '实际 ${kDefaultLiveIndexUrls.length}');
  check('主链路均为 iptv-org 直连', kDefaultLiveIndexUrls.every((u) => u.contains('iptv-org.github.io')),
      kDefaultLiveIndexUrls.join(' | '));
  check('主链路不含代理镜像', !kDefaultLiveIndexUrls.any((u) => u.contains('ghproxy')),
      kDefaultLiveIndexUrls.join(' | '));
  check('主链路不含 IPv6 大表', !kDefaultLiveIndexUrls.any((u) => u.contains('ipv6')), '');
  // 聚合增强源：每个核心多线路源都必须同时挂 gh-proxy.com 与 ghproxy.net 两条镜像。
  final discoveryLabels = kDefaultDiscoverySources.map((d) => d.label).toList();
  final hasProxyCom = kDefaultDiscoverySources.any((d) => d.url.contains('gh-proxy.com'));
  check('聚合源挂了 gh-proxy.com 镜像', hasProxyCom);
  check('聚合源均为 https', kDefaultDiscoverySources.every((d) => d.url.startsWith('https')));
  // 关键多线路源（4K/高清聚合、中文高清聚合、苏州补充）都应有镜像对。
  for (final key in <String>['4K/高清聚合', '中文高清聚合', '苏州补充']) {
    final prim = kDefaultDiscoverySources.where((d) => d.label.startsWith(key)).toList();
    check('「$key」至少 2 份镜像', prim.length >= 2, '实际 ${prim.length}');
  }
  // IPv6 直连表已从主链路移入增强源（不阻塞、不告警首屏）。
  check('IPv6 直连表在增强源中',
      kDefaultDiscoverySources.any((d) => d.label.startsWith('IPv6 直连表')));
  // 增强超时宽于主超时：loader 对可选源用 enhancedTimeout，避免慢镜像被静默掐掉。
  final svc = LiveCatalogService();
  check('增强超时宽于主超时', svc.enhancedTimeout > svc.remoteTimeout,
      '${svc.enhancedTimeout} !> ${svc.remoteTimeout}');
  check('增强超时 ≥ 12s', svc.enhancedTimeout.inSeconds >= 12,
      '${svc.enhancedTimeout.inSeconds}s');
  // 配置不被引用但未使用：确保诊断工具与装配用的是同一套常量。
  check('配置引用未被删除', discoveryLabels.isNotEmpty);
}

/// 增量装载：`loadBase` 必须只靠主索引就产出可播频道表（不等增强源/备用源索引），
/// `load` 再在其上补齐增强。这是「首屏不等 10s 网络」的实现护栏。
Future<void> testLoadSplit() async {
  print('\n== 增量装载：基线可独立出画面，完整装载再补增强 ==');
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final base = 'http://127.0.0.1:${server.port}';
  unawaited(() async {
    await for (final req in server) {
      if (req.uri.path == '/ok.m3u') {
        req.response.headers.contentType = ContentType.text;
        req.response.write('''#EXTM3U
#EXTINF:-1 group-title="央视频道",CCTV-1 综合
http://remote.example.com/cctv1.m3u8
#EXTINF:-1 group-title="卫视频道",湖南卫视
http://remote.example.com/hunan.m3u8
''');
      } else {
        req.response.statusCode = HttpStatus.notFound;
      }
      await req.response.close();
    }
  }());
  HttpClient direct() => HttpClient()..findProxy = ((_) => 'DIRECT');

  final svc = LiveCatalogService(
    remotePlaylistUrls: <String>['$base/ok.m3u'],
    // 增强源全指到 404：基线不该依赖它们。
    citySupplementUrls: <String>['$base/city.txt'],
    streamIndexUrl: '$base/missing-streams.json',
    httpClientFactory: direct,
    remoteTimeout: const Duration(seconds: 2),
    enhancedTimeout: const Duration(seconds: 2),
  );

  final sw = Stopwatch()..start();
  final b = await svc.loadBase(remote: true);
  sw.stop();
  check('基线只靠主索引即可出频道（不等增强源）', b.channelCount == 2, '实际 ${b.channelCount}');
  check('基线来源标注为公开索引', b.sourceLabel.startsWith('公开索引'), b.sourceLabel);
  check('基线装载耗时有上界(<2s)', sw.elapsedMilliseconds < 2000, '${sw.elapsedMilliseconds}ms');
  check('基线频道各只带主索引线路', b.channels.every((c) => c.streams.length == 1));

  final full = await svc.load(remote: true);
  check('完整装载包含基线全部频道', full.channelCount >= b.channelCount,
      '${full.channelCount} vs ${b.channelCount}');
  check('完整装载来源标注带备用/高清统计', full.sourceLabel.contains('有备用源'),
      full.sourceLabel);
  final ids = b.channels.map((c) => c.id).toSet();
  check('完整装载未丢失基线频道',
      full.channels.where((c) => ids.contains(c.id)).length == ids.length);

  await server.close(force: true);
}

void testBuiltIn() {
  final builtIn = BuiltInLiveChannels.all;
  // 内置清单刻意只保留演示信号：硬编码的央视镜像已经整站关停，
  // 留着只会占满首屏探测窗口（详见 live_catalog.dart 的说明）。
  check('内置清单只有演示信号', builtIn.length == 1, '实际 ${builtIn.length}');
  check('演示信号可播', builtIn.first.isPlayable);
  check('演示信号走 HLS',
      builtIn.first.streams.first.url.endsWith('.m3u8'), builtIn.first.streams.first.url);
  check('演示信号地址合法',
      LiveCatalogService.isAcceptableStreamUrl(BuiltInLiveChannels.demoUrl));
  check('演示信号排在其它频道', builtIn.first.group == '其它频道');
}

void testMerge() {
  const builtIn = <LiveChannel>[
    LiveChannel(
      id: 'cctv-1',
      name: 'CCTV-1 综合',
      group: '央视频道',
      badge: 'CCTV',
      streams: <LiveStream>[
        LiveStream(url: 'http://builtin/cctv1.m3u8', label: '内置线路', qualityRank: 20),
      ],
    ),
    LiveChannel(
      id: 'demo',
      name: '演示信号',
      group: '其它频道',
      badge: '演示',
      streams: <LiveStream>[LiveStream(url: 'http://builtin/demo.m3u8')],
    ),
  ];

  const remote = <LiveChannel>[
    LiveChannel(
      id: 'cctv-1',
      name: 'CCTV-1 综合',
      group: '央视频道',
      badge: 'CCTV',
      streams: <LiveStream>[
        LiveStream(url: 'http://builtin/cctv1.m3u8', label: '重复线路'),
        LiveStream(url: 'http://remote/cctv1-b.m3u8', label: '索引线路'),
      ],
    ),
    LiveChannel(
      id: 'sat-hunan',
      name: '湖南卫视',
      group: '卫视频道',
      badge: '湖南卫视',
      streams: <LiveStream>[LiveStream(url: 'http://remote/hunan.m3u8')],
    ),
  ];

  final merged = LiveCatalogService.mergeChannels(builtIn: builtIn, remote: remote);
  check('合并后 3 个频道', merged.length == 3, '实际 ${merged.length}');
  final cctv = merged.firstWhere((c) => c.id == 'cctv-1');
  check('内置线路保留', cctv.streams.any((s) => s.url == 'http://builtin/cctv1.m3u8'));
  check('远端新线路补入', cctv.streams.any((s) => s.url == 'http://remote/cctv1-b.m3u8'));
  check('重复线路被去重', cctv.streams.length == 2, '实际 ${cctv.streams.length}');
  check('央视频道排在最前', merged.first.group == '央视频道', merged.first.group);
  check('其它频道排在最后', merged.last.group == '其它频道', merged.last.group);

  // 线路排序：qualityRank 降序，同 rank 保持原序。
  final ordered = merged.first.orderedStreams;
  check('线路按画质降序', ordered.first.qualityRank >= ordered.last.qualityRank);
  check('内置高清线路排第一', ordered.first.url == 'http://builtin/cctv1.m3u8');
}

Future<void> testServiceLoad() async {
  const m3u = '''
#EXTM3U
#EXTINF:-1 group-title="央视频道",CCTV-1 综合
http://remote.example.com/cctv1.m3u8
#EXTINF:-1 group-title="卫视频道",湖南卫视
http://remote.example.com/hunan.m3u8
''';

  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final base = 'http://127.0.0.1:${server.port}';
  unawaited(() async {
    await for (final req in server) {
      switch (req.uri.path) {
        case '/ok.m3u':
          req.response.headers.contentType = ContentType.text;
          req.response.write(m3u);
        case '/empty.m3u':
          req.response.write('#EXTM3U\n');
        case '/streams.json':
          // 空索引：合法但没有任何备用线路。
          req.response.headers.contentType = ContentType.json;
          req.response.write('[]');
        default:
          req.response.statusCode = HttpStatus.notFound;
      }
      await req.response.close();
    }
  }());

  // 本机回环必须 DIRECT：项目所在机器有系统代理，不绕开就会把请求转成 502。
  HttpClient directClient() => HttpClient()..findProxy = ((_) => 'DIRECT');

  // 内置台必须用与解析同一套 id 规则，否则远端同名台会被当成新频道。
  // 台名用**归一后**的写法（`CCTV-1`，栏目后缀已被削掉）。
  final smallBuiltIn = <LiveChannel>[
    LiveChannel(
      id: LiveCatalogService.channelIdFor('CCTV-1', '央视频道'),
      name: 'CCTV-1',
      group: '央视频道',
      badge: '1',
      streams: const <LiveStream>[LiveStream(url: 'http://builtin/cctv1.m3u8')],
    ),
  ];

  // ① 关闭远端：只用内置
  final offline = LiveCatalogService(builtIn: smallBuiltIn);
  final offlineSnap = await offline.load(remote: false);
  check('remote=false 用内置清单', offlineSnap.channelCount == 1);
  check('remote=false 标注内置来源', offlineSnap.sourceLabel.contains('内置'));
  check('remote=false 无告警', offlineSnap.warnings.isEmpty);

  // ② 远端可用：合并
  //
  // `streamIndexUrl` 必须指到本机：默认值是 iptv-org 的 `streams.json`（3.8 MB，
  // 真实外网）。之前没传，于是「远端成功时无告警」这条断言实际在依赖外网速度——
  // 本机网络一慢，备用源索引超时就会往 warnings 里写一条，断言随机变红。
  // 这条用例要验证的是**主索引合并**，不该被增强源的可达性牵着走。
  final okService = LiveCatalogService(
    builtIn: smallBuiltIn,
    remotePlaylistUrls: <String>['$base/ok.m3u'],
    streamIndexUrl: '$base/streams.json',
    httpClientFactory: directClient,
  );
  final okSnap = await okService.load();
  check('远端可用时频道合并为 2', okSnap.channelCount == 2, '实际 ${okSnap.channelCount}');
  check('远端成功时无告警', okSnap.warnings.isEmpty, okSnap.warnings.join(';'));
  final cctv = okSnap.channels.firstWhere((c) => c.id == smallBuiltIn.first.id);
  check('内置台获得了远端线路', cctv.streams.length == 2, '实际 ${cctv.streams.length}');

  // ③ 远端 404：静默退回内置，但要留下降级说明
  final notFound = LiveCatalogService(
    builtIn: smallBuiltIn,
    remotePlaylistUrls: <String>['$base/missing.m3u'],
    httpClientFactory: directClient,
  );
  final nfSnap = await notFound.load();
  check('404 退回内置清单', nfSnap.channelCount == 1, '实际 ${nfSnap.channelCount}');
  check('404 留下告警', nfSnap.warnings.isNotEmpty);

  // ④ 远端内容为空（只有头标签）：同样退回内置
  final empty = LiveCatalogService(
    builtIn: smallBuiltIn,
    remotePlaylistUrls: <String>['$base/empty.m3u'],
    httpClientFactory: directClient,
  );
  final emptySnap = await empty.load();
  check('空清单退回内置', emptySnap.channelCount == 1);
  check('空清单留下告警', emptySnap.warnings.isNotEmpty);

  // ⑤ 端口不通：不能抛异常，必须走降级
  final dead = LiveCatalogService(
    builtIn: smallBuiltIn,
    remotePlaylistUrls: <String>['http://127.0.0.1:1/none.m3u'],
    remoteTimeout: const Duration(seconds: 1),
    httpClientFactory: directClient,
  );
  var threw = false;
  var deadSnap = await dead.load().catchError((Object _) {
    threw = true;
    return const LiveCatalogSnapshot(channels: <LiveChannel>[], sourceLabel: '');
  });
  check('不可达不抛异常', !threw);
  check('不可达退回内置', deadSnap.channelCount == 1);

  await server.close(force: true);
}
