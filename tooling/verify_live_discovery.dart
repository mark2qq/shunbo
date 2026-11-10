// 全网检索 / 高清优先 / 全线路失败自动切台 / 失败流程不崩溃 回归。
//
// 这一轮直接对应用户反馈的四条硬要求，裸 dart run 可验证：
//   ① 在保留 iptv-org 的基础上扩到全网：多格式源、中国收窄、高清专表、
//      请求头保留、线路数与高清线路数提升、苏州台多来源稳定收录；
//   ② 加载频道时首先加载高清线路（目录收口 + 选源排序双保险）；
//   ③ 当前台全部线路失败 → 按现有频道顺序自动切下一个台，不回原台、
//      不重复重试、不卡加载态，一轮扫完进入明确终态；
//   ④ 线路切换/加载失败/自动切台不崩溃：原生调用串行化、异常不外溢、
//      Timer 回调有守卫、dispose 后不再通知。
//
// 运行：dart run tooling/verify_live_discovery.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shunbo/features/live/async_gate.dart';
import 'package:shunbo/features/live/live_auto_advance.dart';
import 'package:shunbo/features/live/live_catalog.dart';
import 'package:shunbo/features/live/live_channel.dart';
import 'package:shunbo/features/live/live_health.dart';
import 'package:shunbo/features/live/live_region.dart';
import 'package:shunbo/features/live/live_selection.dart';
import 'package:shunbo/features/live/live_source_descriptor.dart';

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

LiveStream _s(String url, int rank) =>
    LiveStream(url: url, label: '线路', qualityRank: rank);

// ── ① 源描述与常量 ──────────────────────────────────────────

void testDescriptors() {
  print('\n== 全网检索源描述 ==');
  check('https 无凭据源合法',
      const LiveSourceDescriptor('https://a.example/x.m3u').isWellFormed);
  check('http 源在正式装配里视为不合法',
      !const LiveSourceDescriptor('http://a.example/x.m3u').isWellFormed);
  check('带凭据的源不合法',
      !const LiveSourceDescriptor('https://u:p@a.example/x.m3u').isWellFormed);
  check('非 http(s) 源不合法',
      !const LiveSourceDescriptor('file:///etc/passwd').isWellFormed);

  check('主索引只保留 iptv-org 两份目录（小快直连，不含大体积代理源）',
      kDefaultLiveIndexUrls.length == 2 &&
          kDefaultLiveIndexUrls.every((u) => u.contains('iptv-org.github.io')),
      kDefaultLiveIndexUrls.join(' | '));
  check('IPv6 直连表已移入增强源（不阻塞/不告警首屏）',
      kDefaultDiscoverySources.any((d) => d.label.startsWith('IPv6 直连表')),
      '${kDefaultDiscoverySources.map((d) => d.label).join(',')}');
  check('全网发现源至少 9 份（含镜像对）', kDefaultDiscoverySources.length >= 9,
      '${kDefaultDiscoverySources.length}');
  check('发现源全部 https 且地址合法',
      kDefaultDiscoverySources.every((s) => s.isWellFormed));
  check('发现源含 iptv-org 中国全线路表',
      kDefaultDiscoverySources.any((s) => s.url.contains('streams/cn.m3u')));
  check('发现源含全球总索引且做 chinaOnly 收窄',
      kDefaultDiscoverySources.any((s) =>
          s.url.contains('index.m3u') &&
          s.scope == LiveSourceScope.chinaOnly));
  check('发现源含 4K 高清聚合表',
      kDefaultDiscoverySources.any((s) => s.label.contains('4K')));
  // 央视补强：聚合表按 nationalOnly 收窄后并入，专门补上「CCTV-1..17
  // 全挂在同一批境外中转 IP 上」这个单点故障。
  check('发现源含央视/卫视线路补强（nationalOnly）',
      kDefaultDiscoverySources.any((s) =>
          s.scope == LiveSourceScope.nationalOnly &&
          s.url.contains('Guovin/iptv-api')));
  check('央视补强有两条不同主机镜像',
      kDefaultDiscoverySources
              .where((s) => s.scope == LiveSourceScope.nationalOnly)
              .map((s) => Uri.parse(s.url).host)
              .toSet()
              .length >=
          2);
  check('发现源含 nameUrl 格式的苏州来源',
      kDefaultDiscoverySources.any((s) =>
          s.format == LiveSourceFormat.nameUrl &&
          s.scope == LiveSourceScope.cityOnly));
  check('全球总索引放大体积上限',
      kDefaultDiscoverySources
          .where((s) => s.url.contains('index.m3u'))
          .every((s) => (s.maxBytes ?? 0) > LiveCatalogService.maxPlaylistBytes));
  check('全球总索引放大扫描行数',
      kDefaultDiscoverySources
          .where((s) => s.url.contains('index.m3u'))
          .every((s) => (s.scanLines ?? 0) > LiveCatalogService.maxLines));

  // 苏州「稳定检索」：两份不同镜像 + 第二种格式的独立来源。
  check('苏州 M3U 有两条不同主机镜像',
      kDefaultCitySupplementUrls.length >= 2 &&
          kDefaultCitySupplementUrls
                  .map((u) => Uri.parse(u).host)
                  .toSet()
                  .length >=
              2);
  check('苏州另有独立 txt 格式来源',
      kDefaultDiscoverySources.any((s) =>
          s.format == LiveSourceFormat.nameUrl &&
          s.scope == LiveSourceScope.cityOnly &&
          s.url.contains('result.txt')));
  check('单台线路上限已扩大到 10',
      LiveCatalogService.maxStreamsPerChannel == 10,
      '${LiveCatalogService.maxStreamsPerChannel}');
  check('高清阈值与线路模型一致',
      LiveCatalogService.hdQualityThreshold == LiveStream.hdQualityThreshold);
}

// ── ② 多格式解析 / 收窄 / 请求头 ────────────────────────────

void testNameUrlParsing() {
  print('\n== nameUrl 纯文本源 ==');
  const text = '''
🕘️更新时间,#genre#
2026-08-27 14:06:22,http://meta.example/x.m3u8

☘️江苏频道,#genre#
苏州4k,https://live.example/sz1.m3u8
苏州新闻综合,https://live.example/sz2.m3u8
苏州社会经济,https://live.example/sz3.m3u8
CCTV-1,https://live.example/cctv1.m3u8
风尚购物,https://live.example/shop.m3u8
坏行没有逗号
另一坏行,ftp://bad.example/x
''';
  final all = LiveCatalogService.parseNameUrl(text);
  check('分节行与元信息行被丢弃',
      all.every((c) => c.name != '🕘️更新时间' && c.name != '2026-08-27 14:06:22'),
      all.map((c) => c.name).join(','));
  check('购物台被剔除', all.every((c) => !c.name.contains('购物')));
  check('非 http 地址被过滤',
      all.every((c) => c.streams.every((s) => s.url.startsWith('https://'))));
  check('苏州 3 个台被解析',
      all.where((c) => c.name.contains('苏州')).length == 3,
      all.map((c) => c.name).join(','));
  check('分节信息让苏州台归入地方频道',
      all.where((c) => c.name.contains('苏州'))
          .every((c) => c.group == LiveRegion.localGroup),
      all.map((c) => '${c.name}:${c.group}').join(','));
  check('苏州4k 被判为高清',
      all.firstWhere((c) => c.name == '苏州4k').streams.first.isHd);

  final cities = LiveCatalogService.parseNameUrl(text, cityOnly: true);
  check('cityOnly 只留城市台', cities.length == 3, '${cities.length}');
  check('cityOnly 丢掉央视', cities.every((c) => c.name.contains('苏州')));
  check('cityOnly 后默认城市是苏州',
      CityDirectory.defaultCity(cities, located: '苏州') == '苏州');
  check('cityOnly 后苏州过滤出 3 台',
      CityDirectory.filter(cities, '苏州').length == 3);

  // 过滤在计数之前：把上限压到 1，仍能扫到末尾那行苏州台。
  final late = StringBuffer('☘️江苏频道,#genre#\n');
  for (var i = 0; i < 40; i++) {
    late.writeln('CCTV-1,https://live.example/c$i.m3u8');
  }
  late.writeln('苏州新闻综合,https://live.example/suzhou.m3u8');
  final capped = LiveCatalogService.parseNameUrl(
    late.toString(),
    cityOnly: true,
    channelLimit: 1,
  );
  check('被过滤条目不占额度（末尾苏州台仍拿到）',
      capped.length == 1 && capped.single.name == '苏州新闻综合');

  check('空文本不抛异常', LiveCatalogService.parseNameUrl('').isEmpty);
  check('非法上限不抛异常',
      LiveCatalogService.parseNameUrl(text, channelLimit: 0).isEmpty);

  // nationalOnly：只留央视 + 卫视（聚合表用来补「央视全台无源」）。
  final national = LiveCatalogService.parseNameUrl(text, nationalOnly: true);
  check('nationalOnly 保留央视', national.any((c) => c.name == 'CCTV-1'),
      national.map((c) => c.name).join(','));
  check('nationalOnly 丢掉城市台',
      national.every((c) => !c.name.contains('苏州')));
  check('nationalOnly 不引入购物台',
      national.every((c) => !c.name.contains('购物')));
}

void testM3uEnrichment() {
  print('\n== M3U 收窄 / 高清 / 请求头 ==');
  const m3u = '''
#EXTM3U
#EXTINF:-1 tvg-id="AnhuiTV.cn@SD" group-title="Undefined",Anhui TV (1080p)
https://a.example/anhui.m3u8
#EXTINF:-1 tvg-id="FooTV.us" group-title="News",Foreign Channel
https://b.example/foreign.m3u8
#EXTINF:-1 group-title="Undefined",湖南新闻
https://c.example/hunan.m3u8
''';
  final cn = LiveCatalogService.parseM3U(m3u, chinaOnly: true);
  check('chinaOnly 保留 .cn 台', cn.any((c) => c.urlOf().contains('a.example')));
  check('chinaOnly 保留中文台名条目',
      cn.any((c) => c.name == '湖南新闻'));
  check('chinaOnly 丢掉境外台',
      cn.every((c) => !c.urlOf().contains('b.example')),
      cn.map((c) => c.urlOf()).join(','));
  check('isChineseEntry 认 .cn / 汉字 / 中文分组',
      LiveCatalogService.isChineseEntry('Anhui TV', 'AnhuiTV.cn', null) &&
          LiveCatalogService.isChineseEntry('湖南新闻', null, null) &&
          LiveCatalogService.isChineseEntry('X', null, '央视频道'));
  check('isChineseEntry 不误收纯英文境外台',
      !LiveCatalogService.isChineseEntry('Foreign Channel', 'FooTV.us', 'News'));

  const hd = '''
#EXTM3U
#EXTINF:-1 group-title="General",CCTV-1 (480p)
https://a.example/sd.m3u8
#EXTINF:-1 group-title="高清频道",CCTV-2
https://a.example/hd.m3u8
#EXTINF:-1 group-title="4K8K频道",江苏卫视4K
https://a.example/4k.m3u8
''';
  final hdOnly = LiveCatalogService.parseM3U(hd, hdOnly: true);
  check('hdOnly 只留高清条目', hdOnly.length == 2,
      hdOnly.map((c) => c.name).join(','));
  check('hdOnly 分组标注「高清频道」被识别',
      hdOnly.any((c) => c.name == 'CCTV-2' && c.streams.first.qualityRank == 90));
  check('hdOnly 分组标注 4K8K 被识别为最高档',
      hdOnly.any((c) => c.name.contains('江苏卫视') &&
          c.streams.first.qualityRank == 100));

  const withHeaders = '''
#EXTM3U
#EXTINF:-1 tvg-id="JiangsuTV.cn" http-user-agent="AptvPlayer-UA" http-referer="http://live.jstv.com/" group-title="4K8K频道",江苏卫视4K
https://a.example/4k.m3u8
''';
  final channels = LiveCatalogService.parseM3U(withHeaders);
  final h = channels.single.streams.single.headers;
  check('EXTINF 的 http-user-agent 转成请求头', h['User-Agent'] == 'AptvPlayer-UA',
      h.toString());
  check('EXTINF 的 http-referer 转成请求头',
      h['Referer'] == 'http://live.jstv.com/');
  check('带高清分组的线路被判为高清',
      channels.single.streams.single.isHd);

  // scanLines 与 channelLimit 是两件不同的事。
  final many = StringBuffer('#EXTM3U\n');
  for (var i = 0; i < 20; i++) {
    many.writeln('#EXTINF:-1 group-title="General",频道$i');
    many.writeln('https://a.example/$i.m3u8');
  }
  check('scanLines 限制扫描行数',
      LiveCatalogService.parseM3U(many.toString(), scanLines: 4).length == 1,
      '${LiveCatalogService.parseM3U(many.toString(), scanLines: 4).length}');
  check('scanLines 不合法时不抛异常',
      LiveCatalogService.parseM3U(many.toString(), scanLines: 0).isEmpty);

  // nationalOnly：聚合表（Guovin）并入央视/卫视线路时用的收窄档。
  // 事故背景：iptv-org 目录里 CCTV-1..17 几乎全挂在同一批境外中转 IP 上，
  // 那批 IP 一抽风就一个央视台都放不出来，且没有任何备份线路。
  const national = '''
#EXTM3U
#EXTINF:-1 group-title="📺央视频道",CCTV-1
https://a.example/cctv1.m3u8
#EXTINF:-1 group-title="📺央视频道",CETV-1
https://a.example/cetv1.m3u8
#EXTINF:-1 group-title="📺卫视频道",湖南卫视
https://a.example/hunan.m3u8
#EXTINF:-1 group-title="☘️江苏频道",苏州新闻综合
https://a.example/suzhou.m3u8
#EXTINF:-1 group-title="☘️浙江频道",绍兴公共
https://a.example/shaoxing.m3u8
''';
  final nat = LiveCatalogService.parseM3U(national, nationalOnly: true);
  final natNames = nat.map((c) => c.name).join(',');
  check('nationalOnly 收央视', nat.any((c) => c.name == 'CCTV-1'), natNames);
  check('nationalOnly 收教育台（央视体系）',
      nat.any((c) => c.name == '中国教育1台'), natNames);
  check('nationalOnly 收卫视', nat.any((c) => c.name == '湖南卫视'), natNames);
  check('nationalOnly 丢省市台',
      nat.every((c) => !c.name.contains('苏州') && !c.name.contains('绍兴')),
      natNames);
  check('nationalOnly 判定只看台名、不信分组',
      // 分组写成「央视频道」但台名是地方台 → 不收（分组是展示用的，会骗人）。
      LiveCatalogService.parseM3U(
        '#EXTM3U\n#EXTINF:-1 group-title="央视频道",苏州新闻综合\n'
        'https://a.example/x.m3u8\n',
        nationalOnly: true,
      ).isEmpty);
}

extension on LiveChannel {
  String urlOf() => streams.first.url;
}

void testQualityRank() {
  print('\n== 高清画质判定 ==');
  bool hd(String raw) => LiveCatalogService.qualityRankOf(raw) >=
      LiveStream.hdQualityThreshold;
  check('1080p 是高清', hd('CCTV-1 (1080p)'));
  check('720p 是高清', hd('CCTV-1 (720p)'));
  check('4K 标注是高清', hd('CCTV-1 4K'));
  check('2160p 是高清', hd('CCTV-1 (2160p)'));
  check('中文「高清」是高清', hd('CCTV-1 高清'));
  check('中文「超清」是高清', hd('CCTV-1 超清'));
  check('蓝光是高清', hd('CCTV-1 蓝光'));
  check('FHD 是高清', hd('CCTV-1 FHD'));
  check('1080i 是高清', hd('CCTV-1 1080i'));
  check('标清不是高清', !hd('CCTV-1 标清'));
  check('480p 不是高清', !hd('CCTV-1 (480p)'));
  check('未标注落到中档 60',
      LiveCatalogService.qualityRankOf('CCTV-1') == 60);
  check('分组标 4K 也算高清',
      LiveCatalogService.qualityRankOf('CCTV-1', remoteGroup: '4K8K频道') == 100);
  check('分组标高清也算高清',
      LiveCatalogService.qualityRankOf('CCTV-1', remoteGroup: '高清频道') == 90);
  check('2160p 仍最高',
      LiveCatalogService.qualityRankOf('X (2160p)') == 100);
  check('576i 仍是 50',
      LiveCatalogService.qualityRankOf('X (576i)') == 50);

  // 中文画质词必须削成同一台，否则高清线路被拆成独立频道。
  check('「CCTV-1 高清」归一为 CCTV-1',
      LiveCatalogService.canonicalName('CCTV-1 高清') == 'CCTV-1',
      LiveCatalogService.canonicalName('CCTV-1 高清'));
  check('「湖南卫视 超清」归一为湖南卫视',
      LiveCatalogService.canonicalName('湖南卫视 超清') == '湖南卫视');
  check('「CCTV-1 标清」归一为 CCTV-1',
      LiveCatalogService.canonicalName('CCTV-1 标清') == 'CCTV-1');
  check('4K 台名仍保留（独立频道身份）',
      LiveCatalogService.canonicalName('CCTV 4K') == 'CCTV-4K',
      LiveCatalogService.canonicalName('CCTV 4K'));
  check('以画质词开头的台名不被削',
      LiveCatalogService.canonicalName('高清频道') == '高清频道');
}

void testNormalizeStreams() {
  print('\n== 线路收口（高清在前） ==');
  final c = LiveChannel(
    id: 'c',
    name: 'CCTV-1',
    group: '央视频道',
    badge: 'CCTV',
    streams: <LiveStream>[
      _s('http://a/sd.m3u8', 40),
      _s('http://a/hd.m3u8', 90),
      _s('http://a/sd.m3u8', 40), // 重复地址
      _s('http://a/4k.m3u8', 100),
    ],
  );
  final out = LiveCatalogService.normalizeStreams(<LiveChannel>[c]).single;
  check('重复地址被去重', out.streams.length == 3, '${out.streams.length}');
  check('4K 排第一', out.streams[0].qualityRank == 100);
  check('1080p 排第二', out.streams[1].qualityRank == 90);
  check('标清排最后', out.streams[2].qualityRank == 40);

  final many = LiveChannel(
    id: 'm',
    name: '多源台',
    group: '央视频道',
    badge: '多源',
    streams: <LiveStream>[
      for (var i = 0; i < 15; i++) _s('http://a/$i.m3u8', i * 5),
    ],
  );
  check('单台线路数封顶 10',
      LiveCatalogService.normalizeStreams(<LiveChannel>[many])
              .single
              .streams
              .length ==
          LiveCatalogService.maxStreamsPerChannel);
  check('封顶后保留的是最高画质档',
      LiveCatalogService.normalizeStreams(<LiveChannel>[many])
              .single
              .streams
              .first
              .qualityRank ==
          70);
  check('空输入不抛异常',
      LiveCatalogService.normalizeStreams(const <LiveChannel>[]).isEmpty);

  // 备用源索引：标清先到、高清后到时，高清仍要进前 10。
  final items = <Map<String, Object>>[
    for (var i = 0; i < 10; i++)
      <String, Object>{'channel': 'X.cn', 'url': 'http://a/sd$i.m3u8', 'quality': '480p'},
    <String, Object>{'channel': 'X.cn', 'url': 'http://a/4k.m3u8', 'quality': '2160p'},
    <String, Object>{'channel': 'X.cn', 'url': 'http://a/hd.m3u8', 'quality': '1080p'},
  ];
  final idx = LiveCatalogService.parseStreamIndex(jsonEncode(items));
  final lines = idx['X.cn']!;
  check('备用源索引封顶 10', lines.length == 10, '${lines.length}');
  check('后到的 4K 备用源排第一', lines.first.qualityRank == 100,
      lines.map((s) => s.qualityRank).join(','));
  check('后到的 1080p 备用源排第二', lines[1].qualityRank == 90);
}

// ── ③ 高清优先播放 / 自动切台 / 不崩溃 ──────────────────────

void testHdFirstRanking() {
  print('\n== 高清线路优先加载 ==');
  final dead = DeadStreamRegistry();
  final board = StreamHealthBoard();
  final channel = LiveChannel(
    id: 'c',
    name: 'CCTV-1',
    group: '央视频道',
    badge: 'CCTV',
    streams: <LiveStream>[
      _s('http://hd.example/1080.m3u8', 90),
      _s('http://sd.example/480.m3u8', 40),
    ],
  );
  // 标清线路「实测又快又稳」，高清线路没测过。
  board.recordOk('http://sd.example/480.m3u8', const Duration(milliseconds: 60));
  board.recordStartup('http://sd.example/480.m3u8',
      const Duration(milliseconds: 800));
  final ranked = LiveSelection.rankStreams(channel, dead, health: board);
  check('有健康数据时仍先加载高清',
      ranked.first.url.contains('hd.example'), ranked.map((s) => s.url).join(','));
  final legacy = LiveSelection.rankStreams(channel, dead,
      health: board, preferHd: false);
  check('关闭高清优先后退回健康度排序',
      legacy.first.url.contains('sd.example'));
  dead.mark('http://hd.example/1080.m3u8');
  final afterDead = LiveSelection.rankStreams(channel, dead, health: board);
  check('高清线路已失效时不硬撑，改用可用标清',
      afterDead.first.url.contains('sd.example'));
  check('失效线路只是降级不删除', afterDead.length == 2);
  check('无健康数据时按画质降序（高清自然在前）',
      LiveSelection.rankStreams(channel, DeadStreamRegistry())
          .first
          .url
          .contains('hd.example'));
}

void testAutoAdvancePlanner() {
  print('\n== 全线路失败自动切台 ==');
  final p = AutoAdvancePlanner();
  check('下一个台是列表顺序的下一条', p.nextIndex(0, 4, (_) => false) == 1);
  check('末尾回绕到第一个台', p.nextIndex(3, 4, (_) => false) == 0);
  check('中间下标正确推进', p.nextIndex(1, 5, (_) => false) == 2);
  check('跳过已失效的台', p.nextIndex(0, 4, (i) => i == 1) == 2);
  check('跳过多个已失效的台', p.nextIndex(0, 5, (i) => i == 1 || i == 2) == 3);
  check('只有一台时不原地重试', p.nextIndex(0, 1, (_) => false) == null);
  check('零台时返回 null', p.nextIndex(0, 0, (_) => false) == null);
  check('全部候选都跳过时返回 null（进入明确终态）',
      p.nextIndex(0, 4, (_) => true) == null);
  check('单台表直接判定一轮走完', p.sweepComplete(1));
  check('初始未走完', !p.sweepComplete(4));

  p.recordFailure('A');
  check('记录失败后 hops=1', p.hops == 1);
  check('记录失败后可查询', p.hasAttempted('A') && !p.hasAttempted('B'));
  p.recordFailure('B');
  p.recordFailure('C');
  p.recordFailure('D');
  check('覆盖全部 4 台后一轮走完', p.sweepComplete(4));
  check('已试台集合不可被外部修改', () {
    try {
      p.attempted.add('Z');
      return false;
    } catch (_) {
      return true;
    }
  }());
  p.reset();
  check('重置后 hops 归零', p.hops == 0 && p.attemptedCount == 0);
  check('重置后可重新切台', p.nextIndex(0, 4, (_) => false) == 1);

  final capped = AutoAdvancePlanner(maxHops: 2);
  capped.recordFailure('A');
  capped.recordFailure('B');
  check('跳跃上限兜住整网故障时的紧循环', capped.sweepComplete(100));
}

void testSkipDeadChannels() {
  print('\n== 自动切台跳过整台死链 ==');
  final dead = DeadStreamRegistry();
  final channels = <LiveChannel>[
    for (var i = 0; i < 4; i++)
      LiveChannel(
        id: 'ch$i',
        name: '台$i',
        group: '央视频道',
        badge: '台$i',
        streams: <LiveStream>[_s('http://host$i.example/1.m3u8', 90)],
      ),
  ];
  check('初始四个台都有可用线路',
      channels.every((c) => LiveSelection.hasLiveStream(c, dead)));
  dead.mark('http://host1.example/1.m3u8');
  dead.mark('http://host2.example/1.m3u8');
  final p = AutoAdvancePlanner();
  p.recordFailure('ch0');
  dead.mark('http://host0.example/1.m3u8');
  final next = p.nextIndex(0, channels.length,
      (i) => p.hasAttempted(channels[i].id) ||
          !LiveSelection.hasLiveStream(channels[i], dead));
  check('跳过本轮失败台与两台整台死链，落到第 4 台', next == 3, '$next');
  p.recordFailure('ch3');
  dead.mark('http://host3.example/1.m3u8');
  check('全表死链时 nextIndex 返回 null 而非回到原台',
      p.nextIndex(3, channels.length,
              (i) => p.hasAttempted(channels[i].id) ||
                  !LiveSelection.hasLiveStream(channels[i], dead)) ==
          null);
  // 一轮里其余两台也试过后，明确判定「扫完了」→ 进入终态并低频重扫。
  p.recordFailure('ch1');
  p.recordFailure('ch2');
  check('全表死链时 sweepComplete 为真', p.sweepComplete(channels.length));
}

Future<void> testAsyncGate() async {
  print('\n== 原生调用串行化（防闪退） ==');
  final gate = AsyncSerialGate();
  final log = <String>[];
  Future<void> op(String name, {bool fail = false}) => gate.run(() async {
        log.add('start-$name');
        await Future<void>.delayed(const Duration(milliseconds: 15));
        log.add('end-$name');
        if (fail) throw StateError('boom-$name');
      });

  final a = op('A');
  final b = op('B');
  final c = op('C');
  check('并发操作进入队列', gate.pending >= 2, '${gate.pending}');
  await Future.wait(<Future<void>>[a, b, c]);
  check('三个操作严格串行，没有交错',
      log.join(',') == 'start-A,end-A,start-B,end-B,start-C,end-C', log.join(','));
  check('队列清空', gate.pending == 0, '${gate.pending}');

  var caught = false;
  try {
    await gate.run(() async => throw StateError('boom'));
  } catch (_) {
    caught = true;
  }
  check('异常原样交给调用方', caught);
  var ranAfterError = false;
  await gate.run(() async {
    ranAfterError = true;
  });
  check('前一个操作抛异常不会卡死队列', ranAfterError);

  final closed = AsyncSerialGate();
  final first = closed.run(() async {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  });
  var skipped = true;
  final second = closed.run(() async {
    skipped = false;
  });
  closed.close();
  await Future.wait(<Future<void>>[first, second]);
  check('close 后排队操作被跳过', skipped);
  check('close 后门闩标记为已关闭', closed.isClosed);
}

void testControllerHardening() {
  print('\n== 控制器硬编码防线（静态检查） ==');
  final src = File('lib/features/live/live_controller.dart').readAsStringSync();
  check('旧的「同一台反复重连」已移除',
      !src.contains('_scheduleAutoRetry') && !src.contains('_autoRetries'));
  check('自动切台链路存在', src.contains('_onChannelExhausted'));
  check('自动切台走与手动点台相同的 tune 流程',
      src.contains('tune(target, manual: false)'));
  check('全线路失败进入明确 failed 终态而非停在 tuning',
      src.contains('_phase = LiveTuning.failed'));
  check('调台与换线都经串行门闩',
      src.contains('_gate.run(() => _tuneLocked') &&
          src.contains('_gate.run(() => _failoverLocked'));
  check('看门狗周期回调有防重入', src.contains('_failoverInFlight'));
  check('Timer 周期回调包了 try/catch',
      src.contains('_watchdogTick(attempt, timer)') &&
          src.contains('watchdog tick failed'));
  check('起播单条线路整体不向外抛异常',
      src.contains('stream attempt crashed'));
  check('dispose 后不再通知监听者',
      src.contains('void _notify()') &&
          src.contains('if (_disposed) return;') &&
          src.contains('_disposed = true;'));
  // 除 _notify 内部外，不允许直接调用 notifyListeners()。
  // 只统计「行首就是调用」的语句，避免把注释里的反引号文本算进去。
  final direct = RegExp(r'^\s*notifyListeners\(\);', multiLine: true)
      .allMatches(src)
      .length;
  check('notifyListeners 只在统一出口里出现一次', direct == 1, '$direct');
  check('失败切台有间隔而不是紧循环', src.contains('advanceDelay'));
  check('一轮全灭后低频重扫而不是无限重试', src.contains('fullRescanDelay'));
  check('播放成功后重置本轮失败轨迹', src.contains('_advance.reset()'));
}

// ── ④ 端到端：本地 HTTP 服务器跑完整 load() ────────────────

Future<void> testEndToEnd() async {
  print('\n== 端到端全网检索 ==');
  const mainM3U = '''
#EXTM3U
#EXTINF:-1 tvg-id="CCTV1.cn" group-title="央视频道",CCTV-1 (720p)
http://main.example/cctv1.m3u8
#EXTINF:-1 tvg-id="HunanTV.cn" group-title="卫视频道",湖南卫视
http://main.example/hunan.m3u8
''';
  const cityM3U = '''
#EXTM3U
#EXTINF:-1 group-title="☘️江苏频道",苏州新闻综合
http://city.example/sz1.m3u8
#EXTINF:-1 group-title="☘️江苏频道",苏州社会经济
http://city.example/sz2.m3u8
#EXTINF:-1 group-title="Shop",风尚购物
http://city.example/shop.m3u8
''';
  const suzhouTxt = '''
☘️江苏频道,#genre#
苏州4k,https://live.example/sz4k.m3u8
苏州新闻综合,http://txt.example/sz1.m3u8
''';
  const hdM3U = '''
#EXTM3U
#EXTINF:-1 tvg-id="CCTV1.cn" http-user-agent="AptvPlayer-UA" group-title="4K8K频道",CCTV-1 超清
http://hd.example/cctv1-4k.m3u8
#EXTINF:-1 tvg-id="CCTV1.cn" group-title="高清频道",CCTV-1 高清
http://hd.example/cctv1-hd.m3u8
''';
  const streamsJson = '''
[
  {"channel":"CCTV1.cn","url":"http://backup.example/cctv1-sd.m3u8","quality":"480p"},
  {"channel":"CCTV1.cn","url":"http://backup.example/cctv1-1080.m3u8","quality":"1080p"}
]
''';
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final base = 'http://127.0.0.1:${server.port}';
  unawaited(() async {
    await for (final req in server) {
      switch (req.uri.path) {
        case '/main.m3u':
          req.response.write(mainM3U);
        case '/city.m3u':
          req.response.write(cityM3U);
        case '/suzhou.txt':
          req.response.write(suzhouTxt);
        case '/hd.m3u':
          req.response.write(hdM3U);
        case '/streams.json':
          req.response.write(streamsJson);
        default:
          req.response.statusCode = HttpStatus.notFound;
      }
      await req.response.close();
    }
  }());

  HttpClient directClient() => HttpClient()..findProxy = ((_) => 'DIRECT');
  final svc = LiveCatalogService(
    builtIn: const <LiveChannel>[],
    remotePlaylistUrls: <String>['$base/main.m3u'],
    citySupplementUrls: <String>['$base/city.m3u'],
    streamIndexUrl: '$base/streams.json',
    httpClientFactory: directClient,
    discoverySources: <LiveSourceDescriptor>[
      LiveSourceDescriptor('$base/suzhou.txt',
          format: LiveSourceFormat.nameUrl,
          scope: LiveSourceScope.cityOnly),
      LiveSourceDescriptor('$base/hd.m3u'),
      // 故意挂掉一份：必须静默，不影响主链路。
      LiveSourceDescriptor('$base/missing.m3u'),
    ],
  );
  final snap = await svc.load();

  check('端到端无降级告警（含挂掉的发现源静默）', snap.warnings.isEmpty,
      snap.warnings.join(';'));
  check('来源说明包含高清覆盖信息', snap.sourceLabel.contains('高清'),
      snap.sourceLabel);
  check('苏州 3 个台全部稳定收录',
      snap.channels.where((c) => c.name.contains('苏州')).length == 3,
      snap.channels.where((c) => c.name.contains('苏州')).map((c) => c.name).join(','));
  final local = snap.channels
      .where((c) => c.group == LiveRegion.localGroup)
      .toList(growable: false);
  check('苏州台归地方频道',
      snap.channels.where((c) => c.name.contains('苏州'))
          .every((c) => c.group == LiveRegion.localGroup));
  check('端到端默认城市仍是苏州',
      CityDirectory.defaultCity(local, located: '苏州') == '苏州');
  check('txt 格式来源给出了额外苏州线路',
      snap.channels.any((c) => c.name.contains('苏州') &&
          c.streams.any((s) => s.url.contains('txt.example'))));
  check('购物台在最终频道表里彻底消失',
      snap.channels.every((c) => !c.name.contains('购物')));

  final cctv = snap.channels.where((c) => c.name == 'CCTV-1').toList();
  check('CCTV-1 合并成一个台', cctv.length == 1, '${cctv.length}');
  final lines = cctv.single.streams;
  check('CCTV-1 拥有 5 条线路',
      lines.length == 5, lines.map((s) => s.url).join(','));
  check('CCTV-1 第一条是 4K 高清线路',
      lines.first.isHd && lines.first.qualityRank == 100,
      lines.map((s) => s.qualityRank).join(','));
  check('CCTV-1 所有高清线路都在标清备份之前',
      lines.indexWhere((s) => !s.isHd) >
          lines.lastIndexWhere((s) => s.isHd),
      lines.map((s) => s.qualityRank).join(','));
  check('EXTINF 请求头在合并后仍保留',
      lines.any((s) => s.headers['User-Agent'] == 'AptvPlayer-UA'));
  check('streams.json 的 1080p 备份没被标清挤掉',
      lines.any((s) => s.url.contains('cctv1-1080.m3u8')));

  // 发现源全挂 + 主索引仍可用：频道表照常出，不能变成空表。
  final degraded = LiveCatalogService(
    builtIn: const <LiveChannel>[],
    remotePlaylistUrls: <String>['$base/main.m3u'],
    streamIndexUrl: '$base/streams.json',
    httpClientFactory: directClient,
    discoverySources: <LiveSourceDescriptor>[
      LiveSourceDescriptor('$base/missing.m3u'),
    ],
  );
  final dSnap = await degraded.load();
  check('发现源全挂不影响主频道表',
      dSnap.channelCount >= 2 && dSnap.warnings.isEmpty,
      '${dSnap.channelCount} / ${dSnap.warnings}');

  await server.close(force: true);
}

Future<void> main() async {
  testDescriptors();
  testNameUrlParsing();
  testM3uEnrichment();
  testQualityRank();
  testNormalizeStreams();
  testHdFirstRanking();
  testAutoAdvancePlanner();
  testSkipDeadChannels();
  await testAsyncGate();
  testControllerHardening();
  await testEndToEnd();

  print('');
  if (_fail == 0) {
    print('回归通过：$_pass/$_pass 断言通过');
    exit(0);
  }
  print('回归失败：$_pass/${_pass + _fail} 断言通过');
  exit(1);
}
