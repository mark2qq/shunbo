// 把「官方源 + 解码实测」结果生成成 App 内置的 Dart 常量。
//
// 与 gen_verified_channels.dart 的差别：官方源线路带 `resolverUrl`
// （起播前解析 302 换时效令牌）和 `decodeVerified`（libmpv 零解码错误），
// 这两种语义 M3U 表达不了，所以只借用 `parseM3U` 算 id / 台标 / 分类，
// 线路字段最终由这份 JSON 决定。
//
// 用法：
//   dart run tooling/gen_official_satellite.dart \
//        --in ../.apk_analysis/official_final.json \
//        --out lib/features/live/official_satellite.g.dart
library;

import 'dart:convert';
import 'dart:io';

import 'package:shunbo/features/live/live_catalog.dart';
import 'package:shunbo/features/live/live_channel.dart';

String _lit(String s) =>
    "'${s.replaceAll(r'\', r'\\').replaceAll("'", r"\'").replaceAll(r'$', r'\$')}'";

String _mapLit(Map<String, String> m) {
  if (m.isEmpty) return 'const <String, String>{}';
  return '<String, String>{${m.entries.map((e) => '${_lit(e.key)}: ${_lit(e.value)}').join(', ')}}';
}

Future<void> main(List<String> args) async {
  var inPath = '';
  var outPath = '';
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--in':
        inPath = args[++i];
      case '--out':
        outPath = args[++i];
    }
  }
  if (inPath.isEmpty || outPath.isEmpty) {
    stderr.writeln('用法: --in <official_final.json> --out <xxx.g.dart>');
    exit(2);
  }

  final raw = (jsonDecode(File(inPath).readAsStringSync()) as List).cast<Map>();
  if (raw.isEmpty) {
    stderr.writeln('输入为空，拒绝生成空清单');
    exit(1);
  }

  // 先把所有线路拼成一份 M3U，交给线上同一套解析器算频道身份。
  // 同名台会被引擎合并成一个频道，id / 台标 / 分类不会与运行时漂移。
  final m3u = StringBuffer('#EXTM3U\n');
  final byUrl = <String, Map>{};
  for (final ch in raw) {
    final group = '${ch['group'] ?? '卫视频道'}';
    final name = '${ch['name']}';
    for (final s in (ch['streams'] as List).cast<Map>()) {
      final url = '${s['url']}';
      byUrl[url] = <String, Object?>{
        'name': name,
        'group': group,
        ...s,
      };
      m3u.writeln('#EXTINF:-1 group-title="$group",$name');
      m3u.writeln(url);
    }
  }
  final parsed = LiveCatalogService.parseM3U(
    m3u.toString(),
    channelLimit: 4000,
    scanLines: 40000,
  );
  final merged = LiveCatalogService.mergeChannels(
    builtIn: const <LiveChannel>[],
    remote: parsed,
  );
  final channels = merged.where((c) => c.streams.isNotEmpty).toList()
    ..sort((a, b) {
      final g = LiveChannel.groupRank(a.group) - LiveChannel.groupRank(b.group);
      return g != 0 ? g : a.name.compareTo(b.name);
    });

  var streamCount = 0;
  var verifiedCount = 0;
  var resolverCount = 0;
  final now = DateTime.now().toUtc();
  final day = '${now.year}-${now.month.toString().padLeft(2, '0')}-'
      '${now.day.toString().padLeft(2, '0')}';

  final buf = StringBuffer()
    ..writeln('// GENERATED FILE — 由 tooling/gen_official_satellite.dart 生成，勿手改。')
    ..writeln('//')
    ..writeln('// 官方源 = 广电 / 持牌平台自有 CDN 的直连流（非境外中转、非第三方转播）。')
    ..writeln('// 每条都经过 libmpv 解码验证：建起解码链 + 解码器零报错。')
    ..writeln('// 带 `resolverUrl` 的线路在起播前会重新解析 302，换取当次有效的 CDN 令牌；')
    ..writeln('// 解析失败退回原地址，由既有换线链路兜底。')
    ..writeln('//')
    ..writeln('// 生成时间：$day（${channels.length} 个台）')
    ..writeln('library;')
    ..writeln()
    ..writeln("import 'live_channel.dart';")
    ..writeln()
    ..writeln('/// 生成时间戳（ISO8601，UTC）。公开 CDN 令牌以小时计过期，')
    ..writeln('/// 这份清单本身也应按月重新验证。')
    ..writeln("const String kOfficialSatelliteAt = "
        "'${now.toIso8601String().split('.').first}Z';")
    ..writeln()
    ..writeln('/// 内置官方源频道（解码实测通过）。')
    ..writeln('const List<LiveChannel> kOfficialSatelliteChannels = <LiveChannel>[');

  for (final c in channels) {
    buf.writeln('  LiveChannel(');
    buf.writeln('    id: ${_lit(c.id)},');
    buf.writeln('    name: ${_lit(c.name)},');
    buf.writeln('    group: ${_lit(c.group)},');
    buf.writeln('    badge: ${_lit(c.badge)},');
    if (c.categories.isNotEmpty) {
      buf.writeln('    categories: <String>['
          '${c.categories.map(_lit).join(', ')}],');
    }
    buf.writeln('    streams: <LiveStream>[');
    for (final parsedStream in c.streams) {
      final s = byUrl[parsedStream.url];
      if (s == null) continue;
      streamCount++;
      final verified = s['verified'] == true;
      final resolver = s['resolverUrl'] as String?;
      if (verified) verifiedCount++;
      if (resolver != null) resolverCount++;
      final headers = (s['headers'] as Map?)?.map(
            (k, v) => MapEntry<String, String>('$k', '$v'),
          ) ??
          const <String, String>{};
      buf.writeln('      LiveStream(');
      buf.writeln('        url: ${_lit(parsedStream.url)},');
      buf.writeln('        label: ${_lit('${s['label'] ?? '官方源'}')},');
      buf.writeln('        qualityRank: ${s['rank'] ?? 0},');
      if (headers.isNotEmpty) buf.writeln('        headers: ${_mapLit(headers)},');
      if (verified) buf.writeln('        decodeVerified: true,');
      if (resolver != null) buf.writeln('        resolverUrl: ${_lit(resolver)},');
      buf.writeln('      ),');
    }
    buf.writeln('    ],');
    buf.writeln('  ),');
  }
  buf.writeln('];');

  File(outPath).writeAsStringSync(buf.toString());
  stdout.writeln('写出 $outPath：${channels.length} 个台 / $streamCount 条线路 '
      '（解码实测 $verifiedCount 条、运行时解析 $resolverCount 条）');
}
