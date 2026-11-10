// 官方源解码门禁回归：日志分类、判决状态机、短期记忆、解析器边界、选源排序。
//
// 这一套存在的理由：加扰流在 HTTP 200 / EXTINF / TS 同步字节 / SPS 四层上
// 全部「看起来能播」，甚至 `picture=yes`；用户看到的是满屏色块，而系统里
// 没有任何异常栈。唯一能钉住它的是解码器日志，所以每个环节都要有断言。
//
// 运行：dart run tooling/verify_decode_gate.dart
library;

import 'dart:async';
import 'dart:io';

import 'package:shunbo/features/live/decode_gate.dart';
import 'package:shunbo/features/live/live_catalog.dart';
import 'package:shunbo/features/live/live_channel.dart';
import 'package:shunbo/features/live/live_selection.dart';
import 'package:shunbo/features/live/official_satellite.g.dart';
import 'package:shunbo/features/live/official_sources.dart';
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

void testClassifier() {
  print('\n== 解码日志分类 ==');
  const scrambled = <String>[
    '[ffmpeg/video] h264: error while decoding MB 24 0, bytestream 13923',
    '[ffmpeg/video] h264: Reference 3 >= 3',
    'h264: decode_slice_header error',
    'h264: no frame!',
    'mpegts: corrupted PES packet',
    'h264: Invalid NAL unit size',
  ];
  for (final s in scrambled) {
    final cut = s.length > 22 ? 22 : s.length;
    check('判加扰：${s.substring(0, cut)}…',
        classifyDecodeLog(s) == DecodeFaultKind.scrambled);
  }
  check('大小写不敏感',
      classifyDecodeLog('ERROR WHILE DECODING MB 1 0') == DecodeFaultKind.scrambled);
  check('网络错误不算加扰',
      classifyDecodeLog('ffmpeg: HTTP error 403 Forbidden') == DecodeFaultKind.network);
  check('打不开不算加扰',
      classifyDecodeLog('cplayer: Failed to open http://x/y.m3u8') ==
          DecodeFaultKind.network);
  check('普通信息日志放行',
      classifyDecodeLog('cplayer: (+) Video --vid=1 (h264 1920x1080)') ==
          DecodeFaultKind.none);
  check('空串放行', classifyDecodeLog('') == DecodeFaultKind.none);
  check('网络+加扰同现时归网络',
      classifyDecodeLog('http error 502 / corrupted stream') ==
          DecodeFaultKind.network);
}

void testGate() {
  print('\n== 判决规则 ==');
  const gate = DecodeGate(window: Duration(seconds: 3));
  check('零错误 + 有链 + 满窗 → 通过',
      gate
          .evaluate(
            chainBuilt: true,
            errorCount: 0,
            observed: const Duration(seconds: 4),
            width: 3840,
            height: 2160,
          )
          .ok);
  check('错误达阈值 → 花屏（不要求等满窗）',
      gate
          .evaluate(
            chainBuilt: true,
            errorCount: 3,
            observed: const Duration(milliseconds: 900),
          )
          .scrambled);
  check('未建链 → 没画面',
      gate
          .evaluate(
            chainBuilt: false,
            errorCount: 0,
            observed: const Duration(seconds: 5),
          )
          .reason ==
          DecodeVerdict.kReasonNoPicture);
  check('1~2 条瞬态错误不误判',
      !(gate
          .evaluate(
            chainBuilt: true,
            errorCount: 2,
            observed: const Duration(seconds: 5),
          )
          .scrambled));
  check('有链但窗口未满不提前宣布成功',
      !gate
          .evaluate(
            chainBuilt: true,
            errorCount: 0,
            observed: const Duration(seconds: 1),
          )
          .ok);
  check('通过时带出实测分辨率',
      gate
              .evaluate(
                chainBuilt: true,
                errorCount: 0,
                observed: const Duration(seconds: 3),
                width: 1920,
                height: 1080,
              )
              .width ==
          1920);
}

void testWatch() {
  print('\n== 运行时观察窗 ==');
  final w = DecodeWatch();
  w.begin('http://a/1.m3u8');
  check('begin 后计数归零', w.errorCount == 0 && w.url.endsWith('1.m3u8'));
  check('一条瞬态错误不判',
      w.onLog('h264: no frame!') == null && w.errorCount == 1);
  check('无关日志不计数',
      w.onLog('cplayer: AO: wasapi') == null && w.errorCount == 1);
  check('网络日志不计数',
      w.onLog('HTTP error 502') == null && w.errorCount == 1);
  final v = w.onLog('h264: error while decoding MB 1 0');
  check('第三条前仍不判', v == null, '$v');
  final verdict = w.onLog('h264: Reference 3 >= 3');
  check('第 3 条判定花屏', verdict != null && verdict.scrambled);
  check('只判一次', w.onLog('h264: error while decoding MB 2 0') == null);

  final w2 = DecodeWatch();
  final t0 = DateTime.now();
  w2.begin('http://a/2.m3u8', now: t0);
  check('窗口内 tick 不收口',
      w2.tick(hasPicture: true, now: t0.add(const Duration(seconds: 1))) == null);
  final clean = w2.tick(
    hasPicture: true,
    now: t0.add(const Duration(seconds: 4)),
  );
  check('满窗且无错 → 健康', clean != null && clean.ok);
  check('健康后不再重复判定', w2.tick(hasPicture: true) == null);
  w2.end();
  check('end 后迟到日志被忽略', w2.onLog('h264: no frame!') == null);
}

void testBoard() {
  print('\n== 判决记忆 ==');
  var now = DateTime(2026, 11, 7, 9);
  final b = DecodeGateBoard(clock: () => now);
  check('初始为空', b.length == 0 && !b.isKnownBad('http://a'));
  b.record('http://a', DecodeVerdict.scrambledFault(errorCount: 9, sample: 'x'),
      now: now);
  b.record('http://b', DecodeVerdict.pass(), now: now);
  check('花屏地址被记住', b.isKnownBad('http://a'));
  check('健康地址不算坏', !b.isKnownBad('http://b'));
  check('knownBadUrls 只含坏地址',
      b.knownBadUrls().length == 1 && b.knownBadUrls().contains('http://a'));
  now = now.add(const Duration(minutes: 9));
  check('9 分钟后仍有效', b.isKnownBad('http://a'));
  now = now.add(const Duration(minutes: 2));
  final expiredA = !b.isKnownBad('http://a');
  final expiredB = !b.isKnownBad('http://b');
  check('超 TTL 自动失效', expiredA && expiredB && b.length == 0,
      '${b.length} 条残留');
  b.record('http://c', DecodeVerdict.pass(), now: now);
  b.noteGood('http://c');
  check('noteGood 清除记录', b.verdictOf('http://c') == null);
  final tiny = DecodeGateBoard(maxEntries: 2, clock: () => now);
  tiny.record('u1', DecodeVerdict.pass(), now: now);
  tiny.record('u2', DecodeVerdict.pass(), now: now);
  tiny.record('u3', DecodeVerdict.pass(), now: now);
  check('容量上限生效', tiny.length <= 2, '${tiny.length}');
  tiny.clear();
  check('clear 清空', tiny.length == 0);

  // 限容时最旧的先被淘汰，新结果不能被挤掉。
  final limited = DecodeGateBoard(maxEntries: 2, clock: () => now);
  limited.record('old', DecodeVerdict.pass(), now: now);
  limited.record('keep', DecodeVerdict.pass(), now: now);
  limited.record('new', DecodeVerdict.pass(), now: now);
  check('新判决未被容量淘汰', limited.verdictOf('new') != null);
}

/// 本地 HttpServer 模拟「解析器 302 → 官方 CDN」以及各类恶意 Location。
Future<void> testResolver() async {
  print('\n== 官方源解析边界 ==');
  final seen = <String, Map<String, String>>{};
  final seenCdn = <String, Map<String, String>>{};
  late HttpServer server;
  late HttpServer cdnServer;
  server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  // 第二个端口 = 另一个 origin：用来验证「302 跨 origin 时凭据不跟随」。
  cdnServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final base = 'http://localhost:${server.port}';
  final cdnBase = 'http://localhost:${cdnServer.port}';
  cdnServer.listen((req) async {
    final hdrs = <String, String>{};
    req.headers.forEach((name, values) {
      hdrs[name.toLowerCase()] = values.join(',');
    });
    seenCdn[req.uri.path] = hdrs;
    req.response.headers.contentType =
        ContentType('application', 'vnd.apple.mpegurl');
    req.response.write('#EXTM3U\n');
    await req.response.close();
  });
  server.listen((req) async {
    final path = req.uri.path;
    final hdrs = <String, String>{};
    req.headers.forEach((name, values) {
      hdrs[name.toLowerCase()] = values.join(',');
    });
    seen[path] = hdrs;
    final res = req.response;
    void redirect(String to, {bool omitLocation = false}) {
      res.statusCode = HttpStatus.found;
      if (!omitLocation) res.headers.set(HttpHeaders.locationHeader, to);
      res.close();
    }

    switch (path) {
      case '/hop':
        redirect('$base/cdn/live.m3u8');
      case '/cross':
        redirect('$cdnBase/cdn/live.m3u8');
      case '/cdn/live.m3u8':
        res.headers.contentType = ContentType('application', 'vnd.apple.mpegurl');
        res.write('#EXTM3U\n#EXTINF:-1,\nseg.ts\n');
        res.close();
      case '/direct':
        res.write('#EXTM3U\n');
        res.close();
      case '/twohops':
        redirect('$base/hop');
      case '/loop':
        redirect('$base/loop');
      case '/ip':
        redirect('http://127.0.0.1:${server.port}/cdn/live.m3u8');
      case '/userinfo':
        redirect('http://u:p@localhost:${server.port}/cdn/live.m3u8');
      case '/evil-scheme':
        redirect('file:///C:/Windows/win.ini');
      case '/non-official':
        redirect('http://not-allowed.example/x.m3u8');
      case '/no-location':
        redirect('', omitLocation: true);
      case '/placeholder-one':
        redirect('1');
      case '/placeholder-pirated':
        redirect('https://static.tv.darwinchow.com/status/'
            'error_account_pirated.mp4');
      case '/404':
        res.statusCode = HttpStatus.notFound;
        res.close();
      case '/same-origin':
        redirect('$base/cdn/live.m3u8');
      default:
        res.statusCode = HttpStatus.notFound;
        res.close();
    }
  });

  final r = OfficialSourceResolver(
    allowedHostSuffixes: const <String>{'localhost'},
    timeout: const Duration(seconds: 4),
  );
  try {
    final defaults = OfficialSourceResolver();
    check('白名单识别官方域',
        defaults.isOfficialHost('ali-xwl.cztv.com') &&
            defaults.isOfficialHost('hlsal-ldvt.qing.mgtv.com'));
    check('IP 字面量一律拒绝', !defaults.isOfficialHost('101.35.240.114'));
    check('未知域拒绝', !defaults.isOfficialHost('evil.test'));
    check('空主机拒绝', !defaults.isOfficialHost(''));

    check('占位 Location 识别：1', isPlaceholderLocation('1'));
    check('占位 Location 识别：空', isPlaceholderLocation('  '));
    check('占位 Location 识别：反盗链提示片',
        isPlaceholderLocation(
            'https://static.tv.darwinchow.com/status/error_account_pirated.mp4'));
    check('正常 m3u8 Location 不误判',
        !isPlaceholderLocation('http://ali-xwl.cztv.com/live/4k.m3u8'));
    check('占位主机识别',
        isPlaceholderMediaUrl(
            'https://live.264788.xyz/channel/sichuanweishi4k?x=1'));
    check('官方 CDN 不误判为占位',
        !isPlaceholderMediaUrl('http://ali-xwl.cztv.com/live/4k.m3u8'));

    final ok = await r.resolve('$base/hop',
        headers: const <String, String>{
          'User-Agent': 'AptvPlayer-UA',
          'Cookie': 'session=SECRET',
          'Referer': 'https://live.example/',
        });
    check('302 → 官方直连成功', ok.ok, ok.reason);
    check('返回终点地址', ok.url == '$base/cdn/live.m3u8', ok.url);
    check('跳数正确', ok.hops == 1, '${ok.hops}');
    check('同 origin 保留凭据',
        (seen['/cdn/live.m3u8']?['cookie'] ?? '').contains('SECRET'));

    final cross = await r.resolve('$base/cross',
        headers: const <String, String>{
          'User-Agent': 'AptvPlayer-UA',
          'Cookie': 'session=SECRET',
          'Referer': 'https://live.example/',
        });
    check('跨 origin 302 解析成功', cross.ok, cross.reason);
    check('跨 origin 不转发 Cookie',
        !(seenCdn['/cdn/live.m3u8']?['cookie'] ?? '').contains('SECRET'));
    check('跨 origin 保留 UA',
        seenCdn['/cdn/live.m3u8']?['user-agent'] == 'AptvPlayer-UA');
    check('跨 origin 保留 Referer',
        seenCdn['/cdn/live.m3u8']?['referer'] == 'https://live.example/');

    final two = await r.resolve('$base/twohops');
    check('两跳内可解析', two.ok, two.reason);
    final direct = await r.resolve('$base/direct');
    check('直连 200 也可作为终点', direct.ok && direct.hops == 0);
    final same = await r.resolve('$base/same-origin',
        headers: const <String, String>{'Cookie': 'k=v'});
    check('同 origin 允许带凭据',
        same.ok && (seen['/cdn/live.m3u8']?['cookie'] ?? '').contains('k=v'));

    final cases = <String, String>{
      '/loop': '重定向超限',
      '/ip': 'IP 终点',
      '/userinfo': 'userinfo',
      '/evil-scheme': '非 http scheme',
      '/non-official': '非白名单域',
      '/no-location': '缺 Location',
      '/placeholder-one': '占位 Location=1',
      '/placeholder-pirated': '反盗链提示片 Location',
      '/404': 'HTTP 404',
    };
    for (final e in cases.entries) {
      final v = await r.resolve('$base${e.key}');
      check('拒绝${e.value}', !v.ok, '${v.reason}');
      check('${e.value} 退回原地址', v.url == '$base${e.key}');
    }
    final bad = await r.resolve('ftp://localhost/x');
    check('入口 scheme 拒绝', !bad.ok && bad.reason == '地址不合法');
    final injected = await r.resolve('$base/hop',
        headers: const <String, String>{'X-Test': 'a\r\nX-Evil: 1'});
    check('CRLF 注入头被丢弃',
        injected.ok && !(seen['/hop']?['x-test'] ?? '').contains('X-Evil'));
  } finally {
    await server.close(force: true);
    await cdnServer.close(force: true);
  }
}

void testRanking() {
  print('\n== 解码实测参与选源 ==');
  const ch = LiveChannel(
    id: 't',
    name: '测试台',
    group: '卫视频道',
    badge: '测',
    streams: <LiveStream>[
      LiveStream(url: 'http://a/4k.m3u8', label: '标注4K', qualityRank: 100),
      LiveStream(
        url: 'http://b/sd.m3u8',
        label: '标清实测',
        qualityRank: 30,
        decodeVerified: true,
      ),
      LiveStream(url: 'http://c/hd.m3u8', label: '高清', qualityRank: 80),
    ],
  );
  check('实测线路排最前（无失效）',
      ch.orderedStreams.first.url == 'http://b/sd.m3u8');
  final dead = DeadStreamRegistry();
  final ranked = LiveSelection.rankStreams(ch, dead);
  check('实测线路排最前（rankStreams）',
      ranked.first.url == 'http://b/sd.m3u8');
  final ranked2 = LiveSelection.rankStreams(ch, dead,
      decodeBad: const <String>{'http://b/sd.m3u8'});
  check('花屏线路被挪到最后',
      ranked2.last.url == 'http://b/sd.m3u8', ranked2.map((e) => e.url).join(','));
  check('花屏不取消候选资格', ranked2.length == 3);
  dead.mark('http://b/sd.m3u8');
  final ranked3 = LiveSelection.rankStreams(ch, dead,
      decodeBad: const <String>{'http://b/sd.m3u8'});
  check('失效 + 花屏叠加仍只排一次序',
      ranked3.length == 3 && ranked3.last.url == 'http://b/sd.m3u8');
  check('解析器字段可构造',
      const LiveStream(url: 'u', resolverUrl: 'http://resolve/').resolverUrl ==
          'http://resolve/');
}

void testOfficialCatalog() {
  print('\n== 内置官方源清单 ==');
  final all = kOfficialSatelliteChannels;
  check('清单非空且不少于 10 个台', all.length >= 10, '${all.length}');
  check('频道 id 无重复', all.map((c) => c.id).toSet().length == all.length);
  check('时间戳可解析', DateTime.tryParse(kOfficialSatelliteAt) != null);
  check('时间戳不是占位值',
      (DateTime.tryParse(kOfficialSatelliteAt)?.year ?? 0) >= 2026);

  var unverified = 0;
  var badUrl = 0;
  var badHeader = 0;
  var uhd = 0;
  var resolvers = 0;
  var placeholder = 0;
  for (final c in all) {
    for (final s in c.streams) {
      if (!s.decodeVerified) unverified++;
      final u = Uri.tryParse(s.url);
      if (u == null || (u.scheme != 'http' && u.scheme != 'https')) badUrl++;
      if (isPlaceholderMediaUrl(s.url) ||
          (s.resolverUrl != null && isPlaceholderMediaUrl(s.resolverUrl!))) {
        placeholder++;
      }
      if (s.headers.keys.any(
          (k) => const <String>{'host', 'range'}.contains(k.toLowerCase()))) {
        badHeader++;
      }
      if (s.resolverUrl != null) resolvers++;
      if (s.qualityRank >= 90 && s.label.contains('2160P')) uhd++;
    }
  }
  check('每条线路都带解码实测标记', unverified == 0, '$unverified 条未验证');
  check('地址只允许 http/https', badUrl == 0, '$badUrl 条越界');
  check('请求头不改传输语义', badHeader == 0, '$badHeader 条带 host/range');
  check('不含已知占位/反盗链源', placeholder == 0, '$placeholder 条');
  check('至少 4 条实测 4K 线路', uhd >= 4, '$uhd 条');
  check('至少 6 条运行时解析线路', resolvers >= 6, '$resolvers 条');
  check('4K 变体归入卫视频道',
      all.where((c) => c.name.contains('4K') && c.group == '卫视频道').length >= 3);

  // 与既有内置清单合并后不能出现两个同 id 的台；同名台应当合并成一条
  // 并保留两边的线路（官方源 + 已验证源互为备用）。
  final merged = LiveCatalogService.mergeChannels(
    builtIn: <LiveChannel>[
      ...BuiltInLiveChannels.all,
      ...kVerifiedLiveChannels,
    ],
    remote: all,
  );
  check('合并后频道 id 唯一',
      merged.map((c) => c.id).toSet().length == merged.length);
  final officialUhd = merged.firstWhere(
    (c) => c.id == '卫视频道:浙江卫视4k',
    orElse: () => all.first,
  );
  check('4K 台合并后仍有实测线路',
      officialUhd.streams.any((s) => s.decodeVerified));
  check('合并未丢失频道',
      merged.length >= all.length, '${merged.length} < ${all.length}');
}

Future<void> main() async {
  testClassifier();
  testGate();
  testWatch();
  testBoard();
  await testResolver();
  testRanking();
  testOfficialCatalog();
  print('');
  print('回归通过：$_pass/${_pass + _fail} 断言通过');
  if (_fail > 0) exit(1);
}
