// 为「只有 HTTPS 线路、没有任何明文兜底」的频道，实测同路径 HTTP 孪生线路。
//
// 背景（2026-11-09 真机反馈）：乐视 S50 Air / API 18 上，苏州 7 个地方台
// 全部报「全部 1 条线路不可用」。清单里这些台只有
//   https://live-auth.51kandianshi.com/szgd/csztvN.m3u8
//   https://tylive.kan0512.com/norecord/csztv4k_*.m3u8
// PC 实测：51kandianshi 的 https 是 TLS 1.3 + TrustAsia 2024 新链，
// ijkplayer 0.8.8 自带的旧 OpenSSL 很可能协商不了；而 kan0512 的 https
// 在本机就握手失败（curl code 000），**同路径 http 却是 200 且分片可下**。
// 而 PlaybackController 一旦连续 3 条 https 失败就把剩余 https 全跳过，
// 于是「只有 https 的频道」永远拿不到任何可试线路。
//
// 本工具不猜测、不硬编码白名单：逐条把 scheme 换成 http，实测
//   ① 播放列表 HTTP 2xx 且内容含 #EXTM3U；
//   ② 列表里第一条分片（或一级变体后的分片）HTTP 2xx 且有字节。
// 只有两条都过才写进 legacy/assets/plaintext_mirrors.json，
// 由 gen_legacy_catalog.dart 作为「明文镜像线路」注入清单。
//
// 用法：dart run tooling/probe_plaintext_mirrors.dart [--conc=8] [--timeout=8] [--limit=N]
// 注意：与 probe_legacy_streams.dart 一样必须 findProxy DIRECT（本机系统代理
// 会把 127.0.0.1:1 接管成 502，否则结果全是假死）。

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

const String kCatalogPath = 'legacy/assets/channels.json';
const String kOutputPath = 'legacy/assets/plaintext_mirrors.json';

class _Mirror {
  final String httpsUrl;
  final String httpUrl;
  final int ms;
  final int segmentBytes;
  const _Mirror(this.httpsUrl, this.httpUrl, this.ms, this.segmentBytes);

  Map<String, Object?> toJson() => <String, Object?>{
        'httpsUrl': httpsUrl,
        'httpUrl': httpUrl,
        'probeMs': ms,
        'segmentBytes': segmentBytes,
      };
}

class _Response {
  final int status;
  final String text;
  final int bytes;
  const _Response(this.status, this.text, this.bytes);
}

Future<void> main(List<String> args) async {
  final int conc = _intArg(args, 'conc', 8);
  final int timeoutSec = _intArg(args, 'timeout', 8);
  final int? limit = _intArgOrNull(args, 'limit');
  final timeout = Duration(seconds: timeoutSec);

  final file = File(kCatalogPath);
  if (!file.existsSync()) {
    stderr.writeln('缺少 $kCatalogPath，请先跑 gen_legacy_catalog.dart');
    exitCode = 2;
    return;
  }
  final root = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
  final channels = (root['channels'] as List).cast<Map<String, Object?>>();

  final urls = <String>{};
  var candidateChannels = 0;
  for (final c in channels) {
    final ss = (c['streams'] as List).cast<Map<String, Object?>>();
    if (ss.isEmpty) continue;
    // 已经有明文线路的频道不需要镜像：明文优先本来就是排序规则之一。
    if (ss.any((s) => s['https'] != true)) continue;
    candidateChannels++;
    for (final s in ss) {
      final url = '${s['url']}';
      if (url.toLowerCase().startsWith('https://')) urls.add(url);
    }
  }
  final targets = urls.toList()..sort();
  final use = limit == null ? targets : targets.take(limit).toList();
  stdout.writeln('无明文兜底频道 $candidateChannels 台，待探唯一 HTTPS 线路 '
      '${targets.length} 条，本次 ${use.length} 条；并发 $conc / 超时 ${timeoutSec}s');

  final mirrors = <_Mirror>[];
  var done = 0;
  var cursor = 0;
  Future<void> worker() async {
    while (true) {
      final i = cursor++;
      if (i >= use.length) return;
      final m = await _probeOne(use[i], timeout);
      if (m != null) mirrors.add(m);
      done++;
      if (done % 25 == 0 || done == use.length) {
        stdout.writeln('[明文镜像 $done/${use.length}] 通过 ${mirrors.length}');
      }
    }
  }

  await Future.wait(List.generate(conc, (_) => worker()));
  mirrors.sort((a, b) => a.httpsUrl.compareTo(b.httpsUrl));

  final payload = <String, Object?>{
    'format': 'shunbo-plaintext-mirrors/1',
    'probedAt': DateTime.now().toUtc().toIso8601String(),
    'source': kCatalogPath,
    'method': 'same-path https->http, m3u8 2xx + first segment 2xx (PC side)',
    'params': <String, Object?>{
      'concurrency': conc,
      'timeoutSeconds': timeoutSec,
      'limit': limit,
    },
    'candidateChannels': candidateChannels,
    'candidateUrls': targets.length,
    'probedUrls': use.length,
    'verifiedCount': mirrors.length,
    'mirrors': <Map<String, Object?>>[
      for (final m in mirrors) m.toJson(),
    ],
  };
  final out = File(kOutputPath);
  out.parent.createSync(recursive: true);
  out.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(payload),
      flush: true);
  stdout.writeln('输出: ${out.absolute.path} (${out.lengthSync()} B)');
  stdout.writeln('通过 ${mirrors.length} / ${use.length}；'
      '苏州相关：${mirrors.where((m) => m.httpsUrl.contains('51kandianshi') || m.httpsUrl.contains('kan0512')).length} 条');
}

int _intArg(List<String> args, String name, int fallback) =>
    _intArgOrNull(args, name) ?? fallback;

int? _intArgOrNull(List<String> args, String name) {
  for (final a in args) {
    if (a.startsWith('--$name=')) {
      return int.tryParse(a.substring(name.length + 3));
    }
  }
  return null;
}

/// https → http，同 host / path / query。显式 :443 要去掉，否则会把明文
/// 请求发到只监听 TLS 的 443 端口上（:5443 / :4430 这类自定义端口保留，
/// 由实测结果决定它是否真的提供明文）。
String _toHttp(String url) {
  final u = Uri.parse(url);
  final drop443 = u.hasPort && u.port == 443;
  final port = drop443 || !u.hasPort ? '' : ':${u.port}';
  final auth = u.userInfo.isEmpty ? '' : '${u.userInfo}@';
  final query = u.query.isEmpty ? '' : '?${u.query}';
  return 'http://$auth${u.host}$port${u.path}$query';
}

Future<_Mirror?> _probeOne(String httpsUrl, Duration timeout) async {
  final httpUrl = _toHttp(httpsUrl);
  final sw = Stopwatch()..start();
  final client = HttpClient()
    ..connectionTimeout = timeout
    ..idleTimeout = const Duration(seconds: 5)
    ..autoUncompress = false
    ..findProxy = ((Uri uri) => 'DIRECT');
  try {
    final list = await _fetch(client, httpUrl, timeout, false);
    if (list.status < 200 || list.status >= 300) return null;
    if (!list.text.contains('#EXTM3U')) return null;
    var next = _firstUri(list.text, httpUrl);
    if (next == null) return null;
    // 主列表（#EXT-X-STREAM-INF）后面还跟着一层变体列表，再下钻一级。
    var seg = await _fetch(client, next, timeout, true);
    if (seg.status >= 200 && seg.status < 300 && seg.bytes > 0) {
      return _Mirror(httpsUrl, httpUrl, sw.elapsedMilliseconds, seg.bytes);
    }
    if (seg.text.contains('#EXT-X-STREAM-INF')) {
      next = _firstUri(seg.text, next);
      if (next == null) return null;
      seg = await _fetch(client, next, timeout, true);
      if (seg.status >= 200 && seg.status < 300 && seg.bytes > 0) {
        return _Mirror(httpsUrl, httpUrl, sw.elapsedMilliseconds, seg.bytes);
      }
    }
    return null;
  } catch (_) {
    return null;
  } finally {
    client.close(force: true);
  }
}

Future<_Response> _fetch(HttpClient client, String url, Duration timeout,
    bool range) async {
  final req = await client
      .getUrl(Uri.parse(url))
      .timeout(timeout, onTimeout: () => throw TimeoutException('connect'));
  req.followRedirects = true;
  req.maxRedirects = 3;
  req.headers.set('user-agent',
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Shunbo-Probe');
  if (range) req.headers.set('range', 'bytes=0-65535');
  final resp = await req.close().timeout(timeout,
      onTimeout: () => throw TimeoutException('response'));
  final builder = BytesBuilder(copy: false);
  await for (final chunk in resp.timeout(timeout)) {
    builder.add(chunk);
    if (builder.length >= 65536) break;
  }
  final bytes = builder.takeBytes();
  return _Response(
      resp.statusCode, utf8.decode(bytes, allowMalformed: true), bytes.length);
}

String? _firstUri(String body, String base) {
  for (final raw in const LineSplitter().convert(body)) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    final abs = Uri.tryParse(base)?.resolve(line);
    if (abs == null) continue;
    final s = abs.toString();
    if (s.startsWith('http://') || s.startsWith('https://')) return s;
  }
  return null;
}
