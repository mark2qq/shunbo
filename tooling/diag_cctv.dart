/// 央视频道可播性诊断（一次性排查工具，不进门禁）。
///
/// 用法：`dart run tooling/diag_cctv.dart [--probe]`
///  默认只装载频道表并打印央视各台的线路清单（快）；
///  `--probe` 逐条线路真实探测，输出失败阶段。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shunbo/features/live/live_catalog.dart';
import 'package:shunbo/features/live/live_channel.dart';

class P {
  final bool ok;
  final String stage;
  final String detail;
  final int ms;
  const P(this.ok, this.stage, this.detail, this.ms);
}

Future<P> probe(String url, {Map<String, String> headers = const {}, Duration timeout = const Duration(seconds: 6)}) async {
  final sw = Stopwatch()..start();
  final client = HttpClient()
    ..connectionTimeout = timeout
    ..findProxy = ((_) => 'DIRECT');
  try {
    final uri = Uri.parse(url);
    final req = await client.getUrl(uri).timeout(timeout);
    req.headers.set(HttpHeaders.userAgentHeader, headers['User-Agent'] ?? headers['user-agent'] ?? 'shunbo/1.0');
    final ref = headers['Referer'] ?? headers['referer'];
    if (ref != null && ref.isNotEmpty) req.headers.set(HttpHeaders.refererHeader, ref);
    req.headers.set(HttpHeaders.rangeHeader, 'bytes=0-2047');
    final resp = await req.close().timeout(timeout);
    final code = resp.statusCode;
    if (code < 200 || code >= 400) return P(false, 'HTTP', 'HTTP $code', sw.elapsedMilliseconds);
    final first = await resp.timeout(timeout).first;
    if (first.isEmpty) return P(false, 'NODATA', '首块为空', sw.elapsedMilliseconds);
    return P(true, 'OK', '${code} ${first.length}B', sw.elapsedMilliseconds);
  } on HandshakeException catch (e) {
    return P(false, 'TLS', e.message.isEmpty ? '握手失败' : e.message, sw.elapsedMilliseconds);
  } on SocketException catch (e) {
    final msg = e.message;
    if (e.osError?.errorCode == 11001 || msg.contains('Failed host lookup')) return P(false, 'DNS', msg, sw.elapsedMilliseconds);
    return P(false, 'TCP', e.osError == null ? msg : 'errno ${e.osError!.errorCode}', sw.elapsedMilliseconds);
  } on TimeoutException {
    return P(false, 'TIMEOUT', '超时', sw.elapsedMilliseconds);
  } catch (e) {
    return P(false, 'OTHER', '$e', sw.elapsedMilliseconds);
  } finally {
    client.close(force: true);
  }
}

bool isCctv(LiveChannel c) =>
    c.group.contains('央视') || RegExp(r'CCTV|CGTN|央视').hasMatch(c.name);

Future<void> main(List<String> args) async {
  final doProbe = args.contains('--probe');
  final service = LiveCatalogService(
    builtIn: BuiltInLiveChannels.all,
    remotePlaylistUrls: kDefaultLiveIndexUrls,
    streamIndexUrl: kDefaultStreamIndexUrl,
    streamIndexUrls: kDefaultStreamIndexUrls,
    citySupplementUrls: kDefaultCitySupplementUrls,
    discoverySources: kDefaultDiscoverySources,
    remoteTimeout: const Duration(seconds: 8),
  );
  stdout.writeln('装载频道表…');
  final snap = await service.load(remote: true).timeout(const Duration(seconds: 180));
  stdout.writeln('频道 ${snap.channels.length} · ${snap.sourceLabel}');
  for (final w in snap.warnings) stdout.writeln('warn: $w');
  final cctv = snap.channels.where(isCctv).toList()
    ..sort((a, b) => LiveCatalogService.sortKeyOf(a.name).compareTo(LiveCatalogService.sortKeyOf(b.name)));
  stdout.writeln('央视类频道 ${cctv.length} 个，线路合计 ${cctv.fold<int>(0, (s, c) => s + c.streams.length)} 条\n');
  final hosts = <String, int>{};
  for (final c in cctv) {
    stdout.writeln('${c.name}  [${c.streams.length} 路]');
    for (final s in c.orderedStreams) {
      final h = Uri.tryParse(s.url)?.host ?? '?';
      hosts[h] = (hosts[h] ?? 0) + 1;
      stdout.writeln('   - ${s.label} | q=${s.qualityRank} | $h | ${s.url}');
      if (s.headers.isNotEmpty) stdout.writeln('     headers=${jsonEncode(s.headers)}');
    }
  }
  stdout.writeln('\n主机分布（top 15）：');
  final ranked = hosts.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
  for (final e in ranked.take(15)) stdout.writeln('  ${e.value} × ${e.key}');

  if (!doProbe) return;
  stdout.writeln('\n=== 逐条线路探测（裸探两次，带头再兜一次） ===');
  final results = <String, List<String>>{};
  for (final c in cctv) {
    final rows = <String>[];
    var anyOk = false;
    for (final s in c.orderedStreams) {
      var r = await probe(s.url);
      if (!r.ok) r = await probe(s.url);
      var viaHeader = false;
      if (!r.ok && s.headers.isNotEmpty) {
        final h = await probe(s.url, headers: s.headers);
        if (h.ok) { r = h; viaHeader = true; }
      }
      if (r.ok) anyOk = true;
      rows.add('   ${r.ok ? "OK  " : "FAIL"} ${r.stage.padRight(7)} ${r.ms}ms '
          '${viaHeader ? "[需头] " : ""}${Uri.tryParse(s.url)?.host ?? "?"}');
    }
    results[c.name] = rows;
    stdout.writeln('${anyOk ? "✅" : "❌"} ${c.name}');
    for (final r in rows) stdout.writeln(r);
  }
  final dead = results.entries.where((e) => e.value.every((r) => r.contains('FAIL'))).map((e) => e.key).toList();
  stdout.writeln('\n整台不可播 ${dead.length}/${results.length}：${dead.join("、")}');
}
