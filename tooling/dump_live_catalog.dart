// 把主程序「运行时实际看到的那份频道表」导出成静态 JSON，供兼容版/单包使用。
//
// 为什么要导出而不是让两边各读一套：用户在电视上看到的 657 台是**运行时**把
// 内置清单（441 台实测解码通过 + 12 台官方卫星源）与网络增强（城市补充、全网发现、
// streams.json 备用线路）合并、过滤购物台之后的结果。兼容版如果只吃内置的 441 台，
// 就会出现「手机上能看的台，电视上没有」——这正是本轮要消掉的差异。
//
// 导出是**一次性固化**：清单里的地址会随周腐坏，所以同时记录导出来源与时间，
// 由 probe_legacy_streams.dart 重新跑可播台账来兜底。
//
// 用法：dart run tooling/dump_live_catalog.dart [--out legacy/assets/unified_channels.json]
import 'dart:convert';
import 'dart:io';

import '../lib/features/live/live_catalog.dart';
import '../lib/features/live/live_channel.dart';
import '../lib/features/live/official_satellite.g.dart';
import '../lib/features/live/verified_channels.g.dart';

Future<void> main(List<String> args) async {
  var outPath = 'legacy/assets/unified_channels.json';
  for (var i = 0; i < args.length - 1; i++) {
    if (args[i] == '--out') outPath = args[i + 1];
  }

  final service = LiveCatalogService(
    builtIn: <LiveChannel>[
      ...kVerifiedLiveChannels,
      ...kOfficialSatelliteChannels,
    ],
    remotePlaylistUrls: kDefaultLiveIndexUrls,
    streamIndexUrl: kDefaultStreamIndexUrl,
    streamIndexUrls: kDefaultStreamIndexUrls,
    citySupplementUrls: kDefaultCitySupplementUrls,
    discoverySources: kDefaultDiscoverySources,
    // 系统代理会把 127.0.0.1:1 接管成 502，本机跑工具必须直连。
    remoteTimeout: const Duration(seconds: 10),
    enhancedTimeout: const Duration(seconds: 20),
  );

  stdout.writeln('[dump] 开始装载（内置 + 主索引 + 增强源）…');
  final sw = Stopwatch()..start();
  final snapshot = await service.load();
  sw.stop();

  stdout.writeln('[dump] 装载完成：${snapshot.channels.length} 台，耗时 '
      '${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)}s');
  stdout.writeln('[dump] 来源：${snapshot.sourceLabel}');
  for (final w in snapshot.warnings) {
    stdout.writeln('[dump] 降级说明：$w');
  }

  final channels = <Map<String, Object?>>[];
  var streamTotal = 0;
  for (final c in snapshot.channels) {
    final streams = <Map<String, Object?>>[];
    for (final s in c.streams) {
      streamTotal++;
      streams.add(<String, Object?>{
        'url': s.url,
        'label': s.label,
        if (s.qualityRank != 0) 'rank': s.qualityRank,
        if (s.decodeVerified) 'verified': true,
        if (s.headers.isNotEmpty) 'headers': s.headers,
        if (s.resolverUrl != null) 'resolver': s.resolverUrl,
});

    }
    channels.add(<String, Object?>{
      'id': c.id,
      'name': c.name,
      'group': c.group,
      if (c.badge.isNotEmpty) 'badge': c.badge,
      'streams': streams,
    });
  }

  final payload = <String, Object?>{
    'format': 'shunbo-unified-catalog/1',
    'exportedAt': DateTime.now().toUtc().toIso8601String(),
    'sourceLabel': snapshot.sourceLabel,
    'channelCount': channels.length,
    'streamCount': streamTotal,
    'warnings': snapshot.warnings,
    'builtInVerifiedAt': kVerifiedLiveAt,
    'builtInOfficialAt': kOfficialSatelliteAt,
    'channels': channels,
  };

  final file = File(outPath);
  file.parent.createSync(recursive: true);
  const encoder = JsonEncoder.withIndent('  ');
  file.writeAsStringSync(encoder.convert(payload));

  final withMulti = channels
      .where((c) => (c['streams'] as List).length >= 2)
      .length;
  stdout.writeln('[dump] 写出 $outPath（${file.lengthSync()} B）');
  stdout.writeln('[dump] 频道 ${channels.length} / 线路 $streamTotal / '
      '多线路台 $withMulti');
  stdout.writeln('[dump] 内置实测时间 ${kVerifiedLiveAt}，'
      '官方源时间 $kOfficialSatelliteAt');
}
