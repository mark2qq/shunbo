// 运行：dart run tooling/diag_tvg_mismatch.dart
//
// 目的：定位「明明带了 tvg-id，却没从 streams.json 拿到备用源」的根因。
// 量化 cn.m3u 的 tvg-id 与 streams.json 的 channel 键的重合度，并抽样不匹配项，
// 判断是不是归一化/大小写/命名空间差异导致匹配失败（可修复的代码问题）。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shunbo/features/live/live_catalog.dart';

Future<String?> get(String url, {Duration timeout = const Duration(seconds: 20)}) async {
  final uri = Uri.tryParse(url);
  if (uri == null) return null;
  final client = HttpClient()..findProxy = ((_) => 'DIRECT');
  client.connectionTimeout = timeout;
  try {
    final req = await client.getUrl(uri).timeout(timeout);
    req.headers.set(HttpHeaders.userAgentHeader, 'shunbo/1.0');
    final resp = await req.close().timeout(timeout);
    if (resp.statusCode != HttpStatus.ok) return null;
    final bytes = <int>[];
    await for (final c in resp.timeout(timeout)) {
      bytes.addAll(c);
      if (bytes.length > 8 * 1024 * 1024) break;
    }
    return utf8.decode(bytes, allowMalformed: true);
  } catch (_) {
    return null;
  } finally {
    client.close(force: true);
  }
}

Future<void> main() async {
  print('═══ tvg-id ↔ streams.json 匹配诊断 ═══');

  final cn = await get('https://iptv-org.github.io/iptv/countries/cn.m3u');
  final streams = await get('https://iptv-org.github.io/api/streams.json');
  if (cn == null || streams == null) {
    print('拉取失败：cn=${cn != null} streams=${streams != null}');
    return;
  }

  // cn.m3u 的 tvg-id 集合（按应用同样的归一化）。
  final cnIds = <String>{};
  for (final line in const LineSplitter().convert(cn)) {
    if (!line.toUpperCase().startsWith('#EXTINF')) continue;
    final m = RegExp(r'tvg-id="([^"]*)"').firstMatch(line);
    if (m == null) continue;
    final id = LiveCatalogService.normalizeTvgId(m.group(1));
    if (id != null && id.isNotEmpty) cnIds.add(id);
  }

  // streams.json 的 channel 键集合（同样归一化）。
  final streamIds = <String>{};
  final decoded = jsonDecode(streams) as List<dynamic>;
  for (final item in decoded) {
    if (item is! Map) continue;
    final ch = LiveCatalogService.normalizeTvgId(
        item['channel'] is String ? item['channel'] as String : null);
    if (ch != null && ch.isNotEmpty) streamIds.add(ch);
  }

  print('cn.m3u 去重 tvg-id 数：${cnIds.length}');
  print('streams.json channel 键数：${streamIds.length}');

  final intersection = cnIds.intersection(streamIds);
  final missing = cnIds.difference(streamIds);
  print('直接归一化后能匹配：${intersection.length}');
  print('有 tvg-id 但匹配不上：${missing.length}');

  // 再试「小写」归一化，看是不是大小写差异。
  final missingLower = missing.where((id) => streamIds.contains(id.toLowerCase())).toList();
  print('其中仅因大小写差异可救：${missingLower.length}');

  print('');
  print('── 匹配不上的 tvg-id 抽样（前 25，看命名空间差异）──');
  for (final id in missing.take(25)) {
    print('  $id');
  }

  // 这些匹配不上的，在 streams.json 里是否有「同名不同写法」能近似命中？
  // 例如 cn.m3u 用 "CCTV1.cn"，streams.json 用 "cctv1cn"。
  final stripped = <String, String>{};
  for (final id in missing) {
    stripped[id] = id.replaceAll(RegExp(r'[^a-z0-9]'), '').toLowerCase();
  }
  final streamStripped = streamIds.map((s) => s.replaceAll(RegExp(r'[^a-z0-9]'), '').toLowerCase()).toSet();
  final recoverable = stripped.values.where(streamStripped.contains).toList();
  print('');
  print('若按「去非字母数字+小写」再匹配，可救回：${recoverable.length}');
  for (final id in missing.where((i) => streamStripped.contains(stripped[i]!)).take(15)) {
    final hit = streamIds.firstWhere(
        (s) => s.replaceAll(RegExp(r'[^a-z0-9]'), '').toLowerCase() == stripped[id]);
    print('  $id  →  可命中 $hit');
  }

  print('诊断完成。');
}
