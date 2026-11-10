// 投屏双模式（R12b）与投屏指标（R12d）的回归。
//
// 为什么这一块的回归必须做厚：投屏的失败是**静默**的 —— DLNA 的 Play 指令
// 回 200，电视屏幕却是黑的。任何一处判断写反，用户看到的是「投屏成功了」
// 但画面一直不出来，且没有任何错误提示。所以这里既钉纯逻辑（模式判定、
// 记忆、播放列表改写），也钉真实 socket（中继真的会补鉴权头、真的改写分片）。
//
// 运行：dart run tooling/verify_cast_dual_mode.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shunbo/core/cast/cast_fallback.dart';
import 'package:shunbo/core/cast/cast_metrics.dart';
import 'package:shunbo/core/cast/cast_mode.dart';
import 'package:shunbo/core/cast/relay/cast_relay_server.dart';
import 'package:shunbo/core/cast/relay/relay_session.dart';
import 'package:shunbo/core/player/kernel_error.dart';
import 'package:shunbo/data/cast_mode_store.dart';

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

// ---------------------------------------------------------------------------
// 1. 记忆键
// ---------------------------------------------------------------------------

void testCastModeKey() {
  check('记忆键按源站归并（同 host 不同路径 → 同一个键）',
      castModeKey(sourceId: 'src-a', url: 'https://cdn.example.com/a/1.m3u8') ==
          castModeKey(sourceId: 'src-a', url: 'https://cdn.example.com/b/2.m3u8'),
      castModeKey(sourceId: 'src-a', url: 'https://cdn.example.com/a/1.m3u8'));

  check('记忆键含源 id（不同源共用一个 CDN 不串味）',
      castModeKey(sourceId: 'src-a', url: 'https://cdn.example.com/x.m3u8') !=
          castModeKey(sourceId: 'src-b', url: 'https://cdn.example.com/x.m3u8'));

  check('记忆键区分端口',
      castModeKey(sourceId: 's', url: 'http://nas:8080/a.m3u8') ==
          's|nas:8080',
      castModeKey(sourceId: 's', url: 'http://nas:8080/a.m3u8'));

  check('主机名统一小写',
      castModeKey(sourceId: 's', url: 'https://CDN.Example.COM/a.m3u8') ==
          's|cdn.example.com');

  check('地址解析不出主机时退回源 id',
      castModeKey(sourceId: 'src-a', url: '不是地址') == 'src-a');

  check('源 id 为空时退回主机',
      castModeKey(sourceId: '', url: 'https://cdn.example.com/a.m3u8') ==
          'cdn.example.com');
}

// ---------------------------------------------------------------------------
// 2. 模式判定策略
// ---------------------------------------------------------------------------

void testCastModePolicy() {
  const p = CastModePolicy();

  final memRelay = p.decideInitial(remembered: CastMode.relay, probeStatus: 200);
  check('记住串流的源直接走串流，不再看探测结果',
      memRelay.mode == CastMode.relay &&
          memRelay.reason == CastModeReason.rememberedRelay,
      memRelay.toString());

  final memDirect = p.decideInitial(remembered: CastMode.direct, probeStatus: 200);
  check('记住直推的源仍走直推',
      memDirect.mode == CastMode.direct &&
          memDirect.reason == CastModeReason.rememberedDirect,
      memDirect.toString());

  for (final code in <int>[401, 403, 407]) {
    final d = p.decideInitial(probeStatus: code);
    check('无头探测 $code → 直接串流（电视补不了鉴权头）',
        d.mode == CastMode.relay &&
            d.reason == CastModeReason.requiresAuthHeaders,
        d.toString());
  }

  for (final code in <int>[200, 404, 500]) {
    final d = p.decideInitial(probeStatus: code);
    check('无头探测 $code → 仍先直推（不是鉴权拒绝）', d.mode == CastMode.direct,
        d.toString());
  }

  final unknown = p.decideInitial();
  check('没有任何信息时先直推', unknown.mode == CastMode.direct &&
      unknown.reason == CastModeReason.probeOk, unknown.toString());

  final probeFailed = p.decideInitial(probeStatus: null);
  check('探测本身失败不据此判串流（网络抖动不该污染记忆）',
      probeFailed.mode == CastMode.direct, probeFailed.toString());

  check('直推未确认出图 → 允许改串流',
      p.shouldFallbackToRelay(CastMode.direct, firstFrameConfirmed: false));
  check('直推已确认出图 → 不改串流',
      !p.shouldFallbackToRelay(CastMode.direct, firstFrameConfirmed: true));
  check('已经是串流就不再无限套娃',
      !p.shouldFallbackToRelay(CastMode.relay, firstFrameConfirmed: false));

  check('直推确认 → 记 direct',
      p.rememberAfter(attempted: CastMode.direct, firstFrameConfirmed: true) ==
          CastMode.direct);
  check('都没确认 → 不记（避免把真因归错成模式问题）',
      p.rememberAfter(attempted: CastMode.relay, firstFrameConfirmed: false) ==
          null);
}

// ---------------------------------------------------------------------------
// 3. 记忆落盘
// ---------------------------------------------------------------------------

Future<void> testCastModeStore() async {
  final dir = await Directory.systemTemp.createTemp('shunbo-castmode-');
  try {
    final path = '${dir.path}${Platform.pathSeparator}cast-mode.json';
    final store = CastModeStore.at(path);

    check('文件不存在时读到空表', (await store.load()).isEmpty);

    check('写入 relay 成功', await store.put('s1|cdn.example.com', CastMode.relay));
    check('写入 direct 成功', await store.put('s2|cdn.example.com', CastMode.direct));
    final all = await store.load();
    check('读回两条记忆', all.length == 2, '${all.length}');
    check('读回 relay 正确', all['s1|cdn.example.com'] == CastMode.relay);
    check('读回 direct 正确', all['s2|cdn.example.com'] == CastMode.direct);

    // 覆盖写同一键：不应产生重复条目。
    await store.put('s1|cdn.example.com', CastMode.direct);
    final again = await store.load();
    check('同键覆盖不产生重复', again.length == 2, '${again.length}');
    check('同键覆盖后值更新', again['s1|cdn.example.com'] == CastMode.direct);

    // 坏文件：整块非法 JSON。
    await File(path).writeAsString('{这不是 json');
    final broken = CastModeStore.at(path);
    check('坏 JSON 读成空表而不是抛异常', (await broken.load()).isEmpty);
    check('坏 JSON 会置 degraded', broken.degraded);

    // 非法枚举值：必须被过滤，不能塞进内存。
    await File(path).writeAsString('{"k1":"relay","k2":"hack","k3":123}');
    final filtered = await CastModeStore.at(path).load();
    check('非法值被过滤，只留合法项', filtered.length == 1 && filtered['k1'] == CastMode.relay,
        filtered.toString());

    // 超长键：拒绝写入。
    final longKey = 'x' * (CastModeStore.maxKeyLength + 1);
    check('超长键拒绝写入', !await CastModeStore.at(path).put(longKey, CastMode.relay));

    // 超大文件：直接判无效，不做无界解析。
    await File(path).writeAsString('{"a":"relay"}');
    final huge = CastModeStore.at(path);
    await File(path).writeAsString('a' * (CastModeStore.maxBytes + 10));
    check('超大文件读成空表', (await huge.load()).isEmpty);
    check('超大文件会置 degraded', huge.degraded);

    // 原子写：写完不应残留 .tmp。
    final store2 = CastModeStore.at(path);
    await store2.put('s3|h', CastMode.relay);
    check('原子写不残留 .tmp', !await File('$path.tmp').exists());
  } finally {
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  }
}

// ---------------------------------------------------------------------------
// 4. 播放列表改写（纯逻辑）
// ---------------------------------------------------------------------------

void testPlaylistRewrite() {
  const playlist = '#EXTM3U\n'
      '#EXT-X-VERSION:3\n'
      '#EXT-X-KEY:METHOD=AES-128,URI="key.bin"\n'
      '#EXT-X-MAP:URI="init.mp4"\n'
      '#EXTINF:10,\n'
      'seg1.ts\n'
      '#EXTINF:10,\n'
      'https://cdn.example.com/abs/seg2.ts\n'
      '#EXT-X-ENDLIST\n';
  final base = Uri.parse('https://cdn.example.com/live/index.m3u8');
  final rewritten = rewritePlaylist(
    playlist,
    baseUrl: base,
    resolve: (raw) {
      final abs = resolveUri(base, raw);
      return abs == null ? null : 'R(${abs.toString()})';
    },
  );
  final lines = const LineSplitter().convert(rewritten);

  check('保留 #EXTM3U 头', lines.first == '#EXTM3U');
  check('保留普通标签（VERSION 不该被动）',
      lines.contains('#EXT-X-VERSION:3'));
  check('密钥 URI 也改写成中继地址（否则照样 403）',
      lines.any((l) => l.contains('URI="R(https://cdn.example.com/live/key.bin)"')), rewritten);
  check('初始化段 URI 改写',
      lines.any((l) => l.contains('URI="R(https://cdn.example.com/live/init.mp4)"')), rewritten);
  check('相对分片被解析成绝对地址后改写',
      lines.any((l) => l == 'R(https://cdn.example.com/live/seg1.ts)'), rewritten);
  check('绝对分片直接改写',
      lines.any((l) => l == 'R(https://cdn.example.com/abs/seg2.ts)'), rewritten);
  check('结尾换行保持', rewritten.endsWith('\n'));
  check('解析失败的行原样保留',
      rewritePlaylist('bad://x', baseUrl: base, resolve: (_) => null) == 'bad://x');

  check('相对地址在无基准时返回 null',
      resolveUri(null, 'seg1.ts') == null);
  check('绝对地址不受基准影响',
      resolveUri(Uri.parse('https://a.com/x.m3u8'), 'https://b.com/y.ts').toString() ==
          'https://b.com/y.ts');
}

// ---------------------------------------------------------------------------
// 5. 私网判定
// ---------------------------------------------------------------------------

Future<void> testAddressRules() async {
  // 只用构造器，不做反查：`InternetAddress.reverse()` 会触发真实 DNS 查询，
  // 一条 8.8.8.8 就能把这个回归拖慢几十秒。
  bool priv(String ip) => isPrivateAddress(InternetAddress(ip));

  check('10.0.0.1 是私网', priv('10.0.0.1'));
  check('172.16.0.1 是私网', priv('172.16.0.1'));
  check('172.31.255.254 是私网', priv('172.31.255.254'));
  check('172.32.0.1 不是私网', !priv('172.32.0.1'));
  check('192.168.1.10 是私网', priv('192.168.1.10'));
  check('169.254.1.1 是链路本地（允许）', priv('169.254.1.1'));
  check('127.0.0.1 是回环（允许）', priv('127.0.0.1'));
  check('8.8.8.8 不是私网（不得当开放代理）', !priv('8.8.8.8'));
  check('::1 是回环', isPrivateAddress(InternetAddress.loopbackIPv6));
  check('fc00::1 是唯一本地地址', isPrivateAddress(InternetAddress('fc00::1')));
  check('fe80::1 是链路本地', isPrivateAddress(InternetAddress('fe80::1')));
  check('2001:4860::1 不是私网', !isPrivateAddress(InternetAddress('2001:4860::1')));

  final picked = await pickLanAddress();
  check('挑出的局域网地址（若有）必须是私网',
      picked == null || isPrivateAddress(InternetAddress(picked)), picked);
}

// ---------------------------------------------------------------------------
// 6. 中继真实 socket
// ---------------------------------------------------------------------------

/// 一台「带防盗链的源站」：没有 Referer 就 403，有就发 m3u8 / 分片。
class _GuardedOrigin {
  late HttpServer _server;
  int plainHits = 0;
  int guardedHits = 0;

  Uri get url => Uri.parse('http://127.0.0.1:${_server.port}');

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    unawaited(_serve());
  }

  Future<void> _serve() async {
    await for (final req in _server) {
      final referer = req.headers.value('referer');
      if (referer == null) {
        plainHits++;
        req.response.statusCode = HttpStatus.forbidden;
        await req.response.close();
        continue;
      }
      guardedHits++;
      final path = req.uri.path;
      if (path.endsWith('.m3u8')) {
        req.response.headers.contentType =
            ContentType('application', 'vnd.apple.mpegurl');
        req.response.write('#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="key.bin"\n'
            '#EXTINF:5,\nseg1.ts\n#EXT-X-ENDLIST\n');
        await req.response.close();
      } else if (path.endsWith('.ts')) {
        req.response.headers.contentType = ContentType('video', 'mp2t');
        req.response.add(const <int>[0x47, 0x40, 0x11, 0x10]);
        await req.response.close();
      } else if (path.endsWith('.bin')) {
        req.response.add(const <int>[1, 2, 3, 4, 5]);
        await req.response.close();
      } else {
        req.response.statusCode = HttpStatus.notFound;
        await req.response.close();
      }
    }
  }

  Future<void> stop() async {
    try {
      await _server.close(force: true);
    } catch (_) {}
  }
}

Future<void> testRelayReal() async {
  final origin = _GuardedOrigin();
  await origin.start();
  final relay = CastRelayServer(overrideHost: '127.0.0.1');
  final client = HttpClient()..findProxy = ((_) => 'DIRECT');
  try {
    final base = await relay.start(headers: <String, String>{
      'referer': 'https://example.com/',
      'user-agent': 'shunbo-test',
    });
    check('中继启动并给出基地址', base.host == '127.0.0.1' && base.port > 0,
        base.toString());

    final playlistUrl = '${origin.url}/live/index.m3u8';

    // 先证明「不带头确实拉不到」：这是本功能存在的理由。
    final plainReq = await client.getUrl(Uri.parse(playlistUrl));
    final plainResp = await plainReq.close();
    await plainResp.drain<void>();
    check('源站确实做了防盗链（无 Referer 403）',
        plainResp.statusCode == HttpStatus.forbidden, '${plainResp.statusCode}');

    final relayed = relay.relayUrlFor(playlistUrl);
    check('中继地址可生成', relayed != null && relayed.contains('/r/'), relayed);
    if (relayed == null) return;

    final req = await client.getUrl(Uri.parse(relayed));
    final resp = await req.close();
    final body = await utf8.decodeStream(resp);
    check('经中继拉播放列表成功（中继替设备补了 Referer）',
        resp.statusCode == HttpStatus.ok, '${resp.statusCode}');
    check('播放列表按 HLS 类型返回',
        (resp.headers.contentType?.mimeType ?? '').contains('mpegurl'),
        resp.headers.contentType?.toString());
    check('播放列表内容被改写：分片指向中继',
        body.contains('/r/') && !body.contains('seg1.ts\n'), body);
    check('密钥 URI 也被改写',
        body.contains('URI="') && body.contains('/r/'), body);

    // 取第一条被改写出来的分片地址，验证分片也能拉到。
    final segLine = const LineSplitter()
        .convert(body)
        .firstWhere((l) => l.trim().isNotEmpty && !l.startsWith('#'),
            orElse: () => '');
    check('改写后的分片行非空', segLine.isNotEmpty, body);
    if (segLine.isNotEmpty) {
      final segReq = await client.getUrl(Uri.parse(segLine));
      final segResp = await segReq.close();
      final segBytes = await segResp.fold<List<int>>(<int>[], (a, b) => a..addAll(b));
      check('经中继拉分片成功', segResp.statusCode == HttpStatus.ok,
          '${segResp.statusCode}');
      check('分片字节原样透传', segBytes.length == 4 && segBytes.first == 0x47,
          '$segBytes');
    }

    check('中继统计到真实请求', relay.requestCount >= 2, '${relay.requestCount}');

    // token 不对 → 404（不暴露「这里有中继」）。
    final wrong = await client.getUrl(Uri.parse('http://127.0.0.1:${base.port}/t/deadbeef/r/abc'));
    final wrongResp = await wrong.close();
    await wrongResp.drain<void>();
    check('token 不对返回 404', wrongResp.statusCode == HttpStatus.notFound,
        '${wrongResp.statusCode}');

    check('非法上游地址（file://）不生成中继地址',
        relay.relayUrlFor('file:///etc/passwd') == null);
    check('带 userinfo 的地址不生成中继地址',
        relay.relayUrlFor('http://user:pass@a.com/x.m3u8') == null);
    check('超长上游地址被拒绝',
        relay.relayUrlFor('https://a.com/${'x' * 5000}') == null);

    await relay.stop();
    check('中继停止后不再生成地址', relay.relayUrlFor(playlistUrl) == null);
  } finally {
    client.close(force: true);
    await relay.stop();
    await origin.stop();
  }
}

// ---------------------------------------------------------------------------
// 7. 双模式状态机
// ---------------------------------------------------------------------------

class _FakeRelay implements CastRelaySession {
  _FakeRelay(this.baseUri);

  @override
  final Uri baseUri;

  int stops = 0;

  @override
  String? relayUrlFor(String upstreamUrl) =>
      upstreamUrl.startsWith('http') ? '$baseUri/r/${base64Url.encode(utf8.encode(upstreamUrl))}' : null;

  @override
  Future<void> stop() async {
    stops++;
  }
}

class _Memory {
  final Map<String, CastMode> modes = <String, CastMode>{};
  int probeCalls = 0;
  int? probeStatus;
  final List<String> probeUrls = <String>[];
  int relayStarts = 0;
  _FakeRelay? lastRelay;

  CastModeReader get read => (key) async => modes[key];
  CastModeWriter get write => (key, mode) async => modes[key] = mode;
  CastUrlStatusProbe get probe => (url) async {
        probeCalls++;
        probeUrls.add(url);
        return probeStatus;
      };
  CastRelayFactory get relay => (headers) async {
        relayStarts++;
        final r = _FakeRelay(Uri.parse('http://192.168.1.5:${8000 + relayStarts}'));
        lastRelay = r;
        return r;
      };
}

Future<void> testDualMode() async {
  const url = 'https://cdn.example.com/live/1.m3u8';

  // A. 直推即确认：不走中继、记 direct。
  {
    final mem = _Memory();
    final t = FakeCastTransport(
      devices: const <CastDevice>[CastDevice(id: 'd1', name: '客厅')],
    );
    final r = await CastFallbackController(
      transport: t,
      readMode: mem.read,
      writeMode: mem.write,
      probeUrlStatus: mem.probe,
      relayFactory: mem.relay,
    ).startCast(
      mediaId: 'm',
      url: url,
      rawEpisode: 1,
      rawSeconds: 10,
      sourceId: 's',
    );
    check('直推确认 → 投屏成功', r.casting, r.userMessage);
    check('直推确认 → 模为 direct', r.mode == CastMode.direct, r.mode.name);
    check('直推确认 → 不起中继', mem.relayStarts == 0, '${mem.relayStarts}');
    check('直推确认 → 记住 direct',
        mem.modes['s|cdn.example.com'] == CastMode.direct,
        mem.modes.toString());
    check('直推确认 → 推的是原始地址', t.lastPlayUrl == url, t.lastPlayUrl);
    check('直推确认 → 报告标记为未中继', !r.report.relayed);
  }

  // B. 直推黑屏 → 自动改串流 → 确认 → 记住 relay。
  {
    final mem = _Memory();
    final t = FakeCastTransport(
      devices: const <CastDevice>[CastDevice(id: 'd1', name: '客厅')],
      signal: CastStartSignal.failed,
      signalFor: (u) =>
          u.contains('/r/') ? CastStartSignal.confirmed : CastStartSignal.failed,
    );
    final r = await CastFallbackController(
      transport: t,
      readMode: mem.read,
      writeMode: mem.write,
      probeUrlStatus: mem.probe,
      relayFactory: mem.relay,
    ).startCast(
      mediaId: 'm',
      url: url,
      rawEpisode: 1,
      rawSeconds: 10,
      sourceId: 's',
    );
    check('直推失败 → 改串流后仍然投屏', r.casting, r.userMessage);
    check('直推失败 → 模为 relay', r.mode == CastMode.relay, r.mode.name);
    check('直推失败 → 实际起了中继', mem.relayStarts >= 1);
    check('直推失败 → 第二次推的是中继地址',
        t.lastPlayUrl != null && t.lastPlayUrl!.contains('/r/'), t.lastPlayUrl);
    check('直推失败 → 判定依据为首帧超时/确认',
        r.modeReason == CastModeReason.firstFrameTimeout ||
            r.modeReason == CastModeReason.relayConfirmed,
        r.modeReason.name);
    check('直推失败 → 记住 relay',
        mem.modes['s|cdn.example.com'] == CastMode.relay, mem.modes.toString());
    check('直推失败 → 提示里说明已由本机转发',
        r.userMessage.contains('中继'), r.userMessage);
  }

  // C. 预探测 403 → 直接串流，不浪费 5 秒直推。
  {
    final mem = _Memory()..probeStatus = 403;
    final t = FakeCastTransport(
      devices: const <CastDevice>[CastDevice(id: 'd1', name: '客厅')],
    );
    final r = await CastFallbackController(
      transport: t,
      readMode: mem.read,
      writeMode: mem.write,
      probeUrlStatus: mem.probe,
      relayFactory: mem.relay,
    ).startCast(
      mediaId: 'm',
      url: url,
      rawEpisode: 1,
      rawSeconds: 0,
      sourceId: 's',
    );
    check('探测 403 → 直接串流', r.mode == CastMode.relay, r.mode.name);
    check('探测 403 → 判定依据可追溯',
        r.modeReason == CastModeReason.requiresAuthHeaders,
        r.modeReason.name);
    check('探测 403 → 只推了一次（没有先直推）', t.playCalls == 1, '${t.playCalls}');
    check('探测 403 → 首次推的就是中继地址',
        t.lastPlayUrl!.contains('/r/'), t.lastPlayUrl);
  }

  // D. 记住 relay 的源：不再探测、不再试直推。
  {
    final mem = _Memory();
    mem.modes['s|cdn.example.com'] = CastMode.relay;
    final t = FakeCastTransport(
      devices: const <CastDevice>[CastDevice(id: 'd1', name: '客厅')],
    );
    final r = await CastFallbackController(
      transport: t,
      readMode: mem.read,
      writeMode: mem.write,
      probeUrlStatus: mem.probe,
      relayFactory: mem.relay,
    ).startCast(
      mediaId: 'm',
      url: url,
      rawEpisode: 1,
      rawSeconds: 0,
      sourceId: 's',
    );
    check('记忆为 relay → 跳过探测（省掉 2 秒）', mem.probeCalls == 0,
        '${mem.probeCalls}');
    check('记忆为 relay → 一次推流即中继地址',
        t.playCalls == 1 && t.lastPlayUrl!.contains('/r/'), t.lastPlayUrl);
    check('记忆为 relay → 判定依据为记忆',
        r.modeReason == CastModeReason.rememberedRelay, r.modeReason.name);
  }

  // E. 串流也只「未确认」→ 保持投屏，不谎报失败、不写记忆。
  {
    final mem = _Memory();
    final t = FakeCastTransport(
      devices: const <CastDevice>[CastDevice(id: 'd1', name: '客厅')],
      signal: CastStartSignal.playingUnverified,
    );
    final r = await CastFallbackController(
      transport: t,
      readMode: mem.read,
      writeMode: mem.write,
      probeUrlStatus: mem.probe,
      relayFactory: mem.relay,
    ).startCast(
      mediaId: 'm',
      url: url,
      rawEpisode: 1,
      rawSeconds: 0,
      sourceId: 's',
    );
    check('未确认 ≠ 失败：仍然算投屏中', r.casting, r.userMessage);
    check('未确认 → 文案提示以电视画面为准',
        r.userMessage.contains('电视为准'), r.userMessage);
    check('未确认 → 不写记忆', mem.modes.isEmpty, mem.modes.toString());
  }

  // F. 串流也失败 → 老实地降级本机，并关掉中继。
  {
    final mem = _Memory();
    final t = FakeCastTransport(
      devices: const <CastDevice>[CastDevice(id: 'd1', name: '客厅')],
      signal: CastStartSignal.failed,
    );
    final r = await CastFallbackController(
      transport: t,
      readMode: mem.read,
      writeMode: mem.write,
      probeUrlStatus: mem.probe,
      relayFactory: mem.relay,
    ).startCast(
      mediaId: 'm',
      url: url,
      rawEpisode: 2,
      rawSeconds: 30,
      sourceId: 's',
    );
    check('全都失败 → 降级本机', !r.casting && r.reason == CastFailureReason.playbackError,
        r.reason?.name);
    check('全都失败 → 进度原样带回', r.rawSeconds == 30 && r.rawEpisode == 2,
        '${r.rawEpisode}/${r.rawSeconds}');
    check('全都失败 → 中继被关闭', mem.lastRelay == null || mem.lastRelay!.stops >= 1);
  }

  // G. 没有设备 → 明确报「未发现设备」，而不是笼统失败。
  {
    final r = await CastFallbackController(
      transport: FakeCastTransport(devices: const <CastDevice>[]),
    ).startCast(mediaId: 'm', url: url, rawEpisode: 1, rawSeconds: 0);
    check('无设备 → noDevice', r.reason == CastFailureReason.noDevice,
        r.reason?.name);
  }

  // H. 中继不可用（没有局域网地址）时退回直推，不能直接判死。
  {
    final t = FakeCastTransport(
      devices: const <CastDevice>[CastDevice(id: 'd1', name: '客厅')],
    );
    final r = await CastFallbackController(
      transport: t,
      relayFactory: (headers) async => null,
    ).startCast(mediaId: 'm', url: url, rawEpisode: 1, rawSeconds: 0, sourceId: 's');
    check('中继起不来 → 退回直推且成功', r.casting && r.mode == CastMode.direct,
        '${r.casting}/${r.mode.name}');
  }
}

// ---------------------------------------------------------------------------
// 8. 指标与 TLS 提示
// ---------------------------------------------------------------------------

void testBudgetsAndHints() {
  check('发现超时为 5 秒', CastBudgets.discovery.inSeconds == 5);
  check('点按到起播 ≤ 8 秒', CastBudgets.tapToStart.inSeconds == 8);
  check('直推首帧窗口为 5 秒（R12b 原文）',
      CastBudgets.directFirstFrame.inSeconds == 5);
  check('直推 5 秒 + 串流 2.5 秒仍落在 8 秒内',
      CastBudgets.directFirstFrame + CastBudgets.relayFirstFrame <=
          CastBudgets.tapToStart,
      '${CastBudgets.directFirstFrame + CastBudgets.relayFirstFrame}');
  check('进度回传误差 ≤ 1 秒', CastBudgets.progressPoll.inMilliseconds <= 1000);
  check('断连恢复 3 秒', CastBudgets.reconnect.inSeconds == 3);

  const ok = CastReport(
    discoveryMillis: 900,
    startMillis: 4200,
    modeName: 'relay',
    reasonName: 'relayConfirmed',
    signalName: 'confirmed',
    relayed: true,
  );
  check('达标报告 withinAll', ok.withinAll && ok.summary.contains('串流中继'),
      ok.summary);

  const slow = CastReport(
    discoveryMillis: 6000,
    startMillis: 9000,
    modeName: 'direct',
    reasonName: 'probeOk',
    signalName: 'confirmed',
    relayed: false,
  );
  check('超预算报告被标出来', !slow.withinAll && slow.summary.contains('超出指标'),
      slow.summary);

  check('证书失败被识别', KernelErrorClassifier.isTlsFailure(
      'OpenSSL SSL_connect: SSL_ERROR_SYSCALL'));
  check('证书校验失败被识别',
      KernelErrorClassifier.isTlsFailure('Certificate verify failed'));
  check('普通网络失败不被误判为证书问题',
      !KernelErrorClassifier.isTlsFailure('tcp: Connection timed out'));
  check('空错误不误判', !KernelErrorClassifier.isTlsFailure(''));
  check('证书提示里含「该源需要较新证书」',
      KernelErrorClassifier.tlsUserHint.contains('该源需要较新证书'));
  check('证书提示里说明换网络无效',
      KernelErrorClassifier.tlsUserHint.contains('换网络'));
}

Future<void> main() async {
  testCastModeKey();
  testCastModePolicy();
  await testCastModeStore();
  testPlaylistRewrite();
  await testAddressRules();
  await testRelayReal();
  await testDualMode();
  testBudgetsAndHints();

  final total = _checkCount + _failCount;
  print('\n$_checkCount/$total 断言通过'
      '${_failCount == 0 ? '' : '（失败 $_failCount 项）'}');
  if (_failCount > 0) exitCode = 1;
  // 真实 socket 的残留连接会拖住进程。
  exit(exitCode);
}
