// 多索引合并收益测量：每份索引能给「已有频道」补多少条线路。
//
// 目的：决定默认索引清单该放哪几个。指标只有一个——
// 「有 ≥2 条线路（且跨 ≥2 个主机）的频道占比」，因为这才是「源挂了能换」的前提。
//
// 运行：dart run tooling/diag_index_yield.dart
import 'dart:io';

import 'package:shunbo/features/live/live_catalog.dart';
import 'package:shunbo/features/live/live_channel.dart';

const List<String> _urls = <String>[
  'https://iptv-org.github.io/iptv/countries/cn.m3u',
  'https://iptv-org.github.io/iptv/languages/zho.m3u',
  'https://iptv-org.github.io/iptv/index.m3u',
];

Future<String?> fetch(String url) async {
  final client = HttpClient()..findProxy = ((_) => 'DIRECT');
  client.connectionTimeout = const Duration(seconds: 20);
  try {
    final req = await client.getUrl(Uri.parse(url)).timeout(const Duration(seconds: 25));
    req.headers.set(HttpHeaders.userAgentHeader, 'shunbo/1.0');
    final resp = await req.close().timeout(const Duration(seconds: 25));
    if (resp.statusCode != 200) return null;
    final bytes = <int>[];
    await for (final chunk in resp) {
      bytes.addAll(chunk);
      if (bytes.length > 8 * 1024 * 1024) break;
    }
    return String.fromCharCodes(bytes);
  } catch (_) {
    return null;
  } finally {
    client.close(force: true);
  }
}

void report(String label, List<LiveChannel> channels) {
  var multi = 0;
  var multiHost = 0;
  var streams = 0;
  for (final c in channels) {
    streams += c.streams.length;
    if (c.streams.length >= 2) multi++;
    final hosts = c.streams.map((s) => Uri.tryParse(s.url)?.host ?? '').toSet();
    if (hosts.length >= 2) multiHost++;
  }
  print('$label：频道 ${channels.length} / 线路 $streams / '
      '≥2线 $multi / ≥2主机 $multiHost');
}

Future<void> main() async {
  final texts = <String, String>{};
  for (final u in _urls) {
    final sw = Stopwatch()..start();
    final t = await fetch(u);
    sw.stop();
    if (t == null) {
      print('不可达：$u');
      continue;
    }
    texts[u] = t;
    print('${u.split('/').last}  ${t.length} 字符  ${sw.elapsedMilliseconds}ms'
        '  EXTINF=${RegExp(r'#EXTINF').allMatches(t).length}');
  }

  final parts = <String, List<LiveChannel>>{};
  for (final e in texts.entries) {
    parts[e.key] = LiveCatalogService.parseM3U(e.value);
  }

  if (parts.isEmpty) {
    print('全部索引不可达');
    exit(1);
  }

  final cn = parts[_urls[0]];
  if (cn != null) report('仅 cn.m3u', LiveCatalogService.sortChannels(cn));

  if (cn != null && parts[_urls[1]] != null) {
    report('cn + zho',
        LiveCatalogService.mergeChannels(builtIn: cn, remote: parts[_urls[1]]!));
  }

  if (cn != null && parts[_urls[2]] != null) {
    // 全站索引只用来**补线路**：先按 cn 的频道 id 过滤，避免把全世界频道灌进来。
    final ids = cn.map((c) => c.id).toSet();
    final extra = parts[_urls[2]]!.where((c) => ids.contains(c.id)).toList();
    print('index.m3u 中与 cn 同 id 的条目：${extra.length}');
    report('cn + index(按 id 过滤)',
        LiveCatalogService.mergeChannels(builtIn: cn, remote: extra));
  }

  if (cn != null && parts[_urls[1]] != null && parts[_urls[2]] != null) {
    final ids = cn.map((c) => c.id).toSet();
    final extra = <LiveChannel>[
      ...parts[_urls[1]]!,
      ...parts[_urls[2]]!.where((c) => ids.contains(c.id)),
    ];
    report('cn + zho + index(按 id 过滤)',
        LiveCatalogService.mergeChannels(builtIn: cn, remote: extra));
  }
  exit(0);
}
