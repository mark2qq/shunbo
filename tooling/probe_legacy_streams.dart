// 兼容版线路可播台账探测（离线工具，不参与打包）。
//
// 用法：
//   dart run tooling/probe_legacy_streams.dart            # 全量（两轮）
//   dart run tooling/probe_legacy_streams.dart 1 19       # 只探台号 1–19
//   dart run tooling/probe_legacy_streams.dart --skip-fail
//
// 判据（分三段，任一失败即判不可达）：
//   1. m3u8 本身 HTTP 200 且正文含 #EXTM3U；
//   2. 若是 master playlist，取一条变体再拉一次，同样要求 200 + #EXTM3U；
//   3. 取播放列表里第一个分片，带 Range 请求，要求 200/206 且实收 ≥ 4 KB。
//
// 这是「网络可达性 + 分片可下载」的台账，**不等于解码成功**：
// 编码格式、分辨率、容器异常仍要靠播放判定（主程序侧是 libmpv 解码门禁，
// 本文件只做保质期复核与死线剔除）。探测从本机网络发起，与电视所在网络
// 可能有差异，结论按「可达 / 不可达 / 待复核」三态记录，不写成绝对可播。
//
// 两轮策略：第一轮 8 并发 / 8s，失败项第二轮降并发到 2 / 15s 复检，
// 避免慢源被并发窗口误杀（历史教训：8s/6 并发会把慢而可用的源判死）。
//
// 全量清单涨到 1000+ 台 / 1900+ 线路之后，第二轮的耗时不可控（失败项越多越慢），
// 因此加了可调参数，并把实际用的参数写进台账的 method 字段，便于复核：
//   --conc1/--timeout1  第一轮并发与超时（默认 8 / 8s）
//   --conc2/--timeout2  第二轮复检（默认 2 / 15s）
//   --recheck-max=N     第二轮最多复检 N 条（默认 0 = 不限）
// 复检按台号升序挑，即央视 → 卫视 → 地方，先保最常看的。

import 'dart:async';
import 'dart:convert';
import 'dart:io';
// BytesBuilder 由 dart:io 间接导出已被标记弃用，显式从 typed_data 引入。
import 'dart:typed_data';

const String kCatalogPath = 'legacy/assets/channels.json';
const String kLedgerPath = 'legacy/assets/probe_ledger.json';
const int kMinSegmentBytes = 4096;

class StreamProbe {
  final int num;
  final String channelName;
  final String label;
  final String url;
  final bool https;

  StreamProbe(this.num, this.channelName, this.label, this.url, this.https);

  bool ok = false;
  String stage = 'init'; // playlist / variant / segment / done
  int httpStatus = 0;
  int ms = 0;
  int bytes = 0;
  String? resolution;
  int segments = 0;
  String? error;
  int attempts = 0;

  Map<String, Object?> toJson() => <String, Object?>{
        'num': num,
        'name': channelName,
        'label': label,
        'url': url,
        'https': https,
        'ok': ok,
        'stage': stage,
        'status': httpStatus,
        'ms': ms,
        'bytes': bytes,
        if (resolution != null) 'resolution': resolution,
        'segments': segments,
        'attempts': attempts,
        if (error != null) 'error': error,
      };
}

Future<void> main(List<String> args) async {
  final bool skipFail = args.contains('--skip-fail');
  final int conc1 = _optInt(args, '--conc1', kConcurrency1);
  final int to1 = _optInt(args, '--timeout1', 8);
  final int conc2 = _optInt(args, '--conc2', kConcurrency2);
  final int to2 = _optInt(args, '--timeout2', 15);
  final int recheckMax = _optInt(args, '--recheck-max', 0);
  final ints = args.where((a) => int.tryParse(a) != null).map(int.parse).toList();
  final int? from = ints.isNotEmpty ? ints[0] : null;
  final int? to = ints.length > 1 ? ints[1] : from;

  final catalog = jsonDecode(File(kCatalogPath).readAsStringSync())
      as Map<String, Object?>;
  final channels = (catalog['channels'] as List).cast<Map<String, Object?>>();

  final targets = <StreamProbe>[];
  for (final c in channels) {
    final num = c['num'] as int;
    if (from != null && (num < from || num > to!)) continue;
    for (final s in (c['streams'] as List).cast<Map<String, Object?>>()) {
      targets.add(StreamProbe(
        num,
        '${c['name']}',
        '${s['label'] ?? ''}',
        '${s['url']}',
        s['https'] == true,
      ));
    }
  }
  stdout.writeln('目标：${targets.length} 条线路'
      '${from == null ? '（全量）' : '（台号 $from–$to）'}');

  // 第一轮：默认 8 并发 / 8s
  await _runPool(targets, conc1, Duration(seconds: to1), '第一轮');
  var rechecked = 0;
  final failed = targets.where((t) => !t.ok).toList();
  if (!skipFail && failed.isNotEmpty) {
    // 第二轮：降并发 + 拉窗口复检（慢源）。按台号升序 = 央视/卫视优先。
    failed.sort((a, b) => a.num.compareTo(b.num));
    final sample = recheckMax > 0 && failed.length > recheckMax
        ? failed.sublist(0, recheckMax)
        : failed;
    rechecked = sample.length;
    await _runPool(sample, conc2, Duration(seconds: to2), '第二轮');
  }

  _report(targets);
  _write(targets, channels, from, to, <String, Object?>{
    'conc1': conc1,
    'timeout1': to1,
    'conc2': conc2,
    'timeout2': to2,
    'recheckMax': recheckMax,
    'recheckApplied': rechecked,
    'firstRoundFailures': failed.length,
  });
}

int _optInt(List<String> args, String name, int fallback) {
  for (final a in args) {
    if (a.startsWith('$name=')) {
      final v = int.tryParse(a.substring(name.length + 1));
      if (v != null && v > 0) return v;
    }
  }
  return fallback;
}

const int kConcurrency1 = 8;
const int kConcurrency2 = 2;

Future<void> _runPool(List<StreamProbe> items, int concurrency,
    Duration timeout, String label) async {
  var cursor = 0;
  var done = 0;
  final workers = <Future<void>>[];
  final sw = Stopwatch()..start();
  for (var w = 0; w < concurrency; w++) {
    workers.add(() async {
      while (true) {
        final i = cursor++;
        if (i >= items.length) return;
        final t = items[i];
        t.attempts += 1;
        await probeOne(t, timeout);
        done++;
        final mark = t.ok ? 'OK  ' : 'DEAD';
        stdout.writeln('[$label $done/${items.length}] $mark '
            '${t.num.toString().padLeft(3)} ${t.channelName} '
            '| ${t.label} | ${t.ms}ms ${t.stage}'
            '${t.error == null ? '' : ' | ${t.error}'}');
      }
    }());
  }
  await Future.wait(workers);
  stdout.writeln('[$label] 完成，耗时 ${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)}s');
}

Future<void> probeOne(StreamProbe t, Duration timeout) async {
  final sw = Stopwatch()..start();
  // 复检时保留上一轮的最佳观测值，便于对照
  final prevMs = t.ms;
  HttpClient? client;
  try {
    client = _newClient(timeout);
    final playlist = await _fetch(client, t.url, const {}, timeout, 64 * 1024);
    t.httpStatus = playlist.status;
    if (playlist.status != 200) {
      t.stage = 'playlist';
      t.error = 'HTTP ${playlist.status}';
      return;
    }
    final body = playlist.text;
    if (!body.contains('#EXTM3U')) {
      t.stage = 'playlist';
      t.error = 'not m3u8';
      return;
    }
    var playlistText = body;
    // 302 之后相对分片必须按**最终 URL** 解析。旧实现这里用原始 t.url 作
    // base，重定向站点返回的相对分片会被拼回旧 host/路径，于是 123 条本来
    // 能播的线路被误判成「segment HTTP 404」，可播台账被系统性低估。
    var playlistBase = playlist.url;
    if (_isMaster(body)) {
      final variant = _firstUri(body, playlistBase);
      if (variant == null) {
        t.stage = 'variant';
        t.error = 'no variant uri';
        return;
      }
      t.stage = 'variant';
      final v = await _fetch(client, variant.url, const {}, timeout, 256 * 1024);
      t.httpStatus = v.status;
      if (v.status != 200 || !v.text.contains('#EXTM3U')) {
        t.error = 'variant HTTP ${v.status}';
        return;
      }
      playlistText = v.text;
      // 变体列表自身也可能重定向，base 同样要跟着走。
      playlistBase = v.url;
      _absorb(t, v.text);
    } else {
      _absorb(t, body);
    }
    final seg = _firstUri(playlistText, playlistBase);
    if (seg == null) {
      t.stage = 'segment';
      if (t.segments == 0) {
        // 空播放列表：源在播但当前无分片，按「待复核」处理，不判死
        t.ok = t.segments == 0 && body.contains('#EXTINF');
        t.error = t.ok ? null : 'empty playlist';
        t.stage = 'done';
      }
      return;
    }
    t.stage = 'segment';
    final chunk = await _fetch(client, seg.url, const {'range': 'bytes=0-65535'},
        timeout, 96 * 1024);
    t.bytes = chunk.bytes;
    if (chunk.status == 200 || chunk.status == 206) {
      if (chunk.bytes >= kMinSegmentBytes) {
        t.ok = true;
        t.stage = 'done';
        t.error = null;
      } else {
        t.error = 'segment too small (${chunk.bytes}B)';
      }
    } else {
      t.error = 'segment HTTP ${chunk.status}';
    }
  } catch (e) {
    t.error = _short(e);
  } finally {
    t.ms = sw.elapsedMilliseconds;
    if (!t.ok && prevMs > 0) t.ms = prevMs;
    client?.close(force: true);
  }
}

void _absorb(StreamProbe t, String body) {
  // 只累计本条线路的状态：并发池里任何全局可变字段都会串台。
  t.segments = body
      .split('\n')
      .where((l) => l.trim().isNotEmpty && !l.trim().startsWith('#'))
      .length;
  final res = RegExp(r'RESOLUTION=(\d+x\d+)').firstMatch(body);
  if (res != null) t.resolution = res.group(1);
}

bool _isMaster(String body) => body.contains('#EXT-X-STREAM-INF');

class _Uri {
  final String url;
  const _Uri(this.url);
}

/// 取播放列表里第一条非注释行（变体或分片），相对路径按 base 解析。
_Uri? _firstUri(String body, String base) {
  for (final raw in const LineSplitter().convert(body)) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    final abs = Uri.tryParse(base)?.resolve(line);
    if (abs == null) continue;
    return _Uri(abs.toString());
  }
  return null;
}

HttpClient _newClient(Duration timeout) {
  final c = HttpClient()
    ..connectionTimeout = timeout
    ..idleTimeout = const Duration(seconds: 5)
    ..autoUncompress = false
    // 本机系统代理会把 127.0.0.1:1 接管成 502，探测必须直连。
    ..findProxy = ((Uri uri) => 'DIRECT');
  return c;
}

class _Response {
  final int status;
  final String text;
  final int bytes;
  /** 跟随 302 后的最终 URL；播放列表里的相对分片必须按它解析。 */
  final String url;
  const _Response(this.status, this.text, this.bytes, this.url);
}

Future<_Response> _fetch(HttpClient client, String url,
    Map<String, String> headers, Duration timeout, int maxBytes) async {
  final req = await client
      .getUrl(Uri.parse(url))
      .timeout(timeout, onTimeout: () => throw TimeoutException('connect'));
  req.followRedirects = true;
  req.maxRedirects = 3;
  req.headers.set('user-agent',
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Shunbo-Probe');
  headers.forEach(req.headers.set);
  final resp = await req.close().timeout(timeout,
      onTimeout: () => throw TimeoutException('response'));
  var finalUrl = url;
  if (resp.redirects.isNotEmpty) {
    finalUrl = resp.redirects.last.location.toString();
  }
  final builder = BytesBuilder(copy: false);
  await for (final chunk in resp.timeout(timeout)) {
    builder.add(chunk);
    if (builder.length >= maxBytes) break;
  }
  // 不能在这里 close：同一条线路还要用同一个 client 拉变体与分片。
  // client 的生命周期由 probeOne 的 finally 统一收口。
  final bytes = builder.takeBytes();
  final text = utf8.decode(bytes, allowMalformed: true);
  return _Response(resp.statusCode, text, bytes.length, finalUrl);
}

String _short(Object e) {
  final s = e.toString();
  if (s.contains('TimeoutException')) return 'timeout';
  if (s.contains('HandshakeException')) return 'tls handshake';
  if (s.contains('SocketException')) {
    final m = RegExp(r'message: ([^,)]+)').firstMatch(s);
    return 'socket: ${m?.group(1) ?? 'error'}';
  }
  return s.length > 90 ? s.substring(0, 90) : s;
}

void _report(List<StreamProbe> targets) {
  final ok = targets.where((t) => t.ok).length;
  stdout.writeln('\n=== 汇总 ===');
  stdout.writeln('线路 ${targets.length}：可播 $ok / 待复核 ${targets.length - ok} '
      '（${(100 * ok / targets.length).toStringAsFixed(1)}%）');
  final byChannel = <int, List<StreamProbe>>{};
  for (final t in targets) {
    (byChannel[t.num] ??= <StreamProbe>[]).add(t);
  }
  final nums = byChannel.keys.toList()..sort();
  for (final n in nums) {
    final list = byChannel[n]!;
    final good = list.where((t) => t.ok).length;
    final state = good == 0 ? '全失败' : (good == list.length ? '可播' : '部分');
    final res = list.firstWhere((t) => t.resolution != null,
        orElse: () => list.first).resolution;
    stdout.writeln('${n.toString().padLeft(3)} ${list.first.channelName}'
        '\t$state\t$good/${list.length}'
        '${res == null ? '' : '\t$res'}');
  }
}

void _write(List<StreamProbe> targets, List<Map<String, Object?>> channels,
    int? from, int? to, Map<String, Object?> params) {
  final byChannel = <int, List<StreamProbe>>{};
  for (final t in targets) {
    (byChannel[t.num] ??= <StreamProbe>[]).add(t);
  }
  final entries = <Map<String, Object?>>[];
  var chOk = 0;
  for (final c in channels) {
    final num = c['num'] as int;
    final list = byChannel[num];
    if (list == null) continue;
    final good = list.where((t) => t.ok).length;
    if (good > 0) chOk++;
    entries.add(<String, Object?>{
      'num': num,
      'name': c['name'],
      'group': c['group'],
      'streams': list.length,
      'reachable': good,
      'state': good == 0 ? 'dead' : (good == list.length ? 'ok' : 'partial'),
      'bestMs': list.where((t) => t.ok).isEmpty
          ? null
          : list
              .where((t) => t.ok)
              .map((t) => t.ms)
              .reduce((a, b) => a < b ? a : b),
    });
  }
  final payload = <String, Object?>{
    'format': 'shunbo-legacy-probe/1',
    'probedAt': DateTime.now().toUtc().toIso8601String(),
    'scope': from == null ? 'all' : 'num $from-$to',
    'method': 'm3u8 + first segment reachability (Range 0-65535, '
        '>= $kMinSegmentBytes B), 1st pass ${params['conc1']}x${params['timeout1']}s'
        '${params['recheckApplied'] == 0 ? ' only' : ', 2nd pass ${params['conc2']}x${params['timeout2']}s on ${params['recheckApplied']} of ${params['firstRoundFailures']} failures (by num asc)'}',
    'params': params,
    'caveat': '网络可达性台账，不等价于解码成功；结论以真机播放为准',
    'streamCount': targets.length,
    'reachableCount': targets.where((t) => t.ok).length,
    'channelCount': entries.length,
    'channelReachable': chOk,
    'channels': entries,
    'streams': targets.map((t) => t.toJson()).toList(),
  };
  final f = File(kLedgerPath);
  f.parent.createSync(recursive: true);
  f.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(payload),
      flush: true);
  stdout.writeln('\n台账: ${f.absolute.path} (${f.lengthSync()} B)');
}
