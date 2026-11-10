// 频道线路丰度诊断：统计每个频道有几条可用线路、来自哪些主机。
//
// 背景：`load()` 原先拉到第一份索引就 break，导致「每个台只有一条线路」，
// 「源挂自动切换」在多数台上等于没有备用源。改完之后用它核对分布。
//
// 运行：dart run tooling/diag_live_streams.dart
import 'dart:io';

import 'package:shunbo/features/live/live_catalog.dart';

Future<void> main() async {
  final service = LiveCatalogService(
    builtIn: BuiltInLiveChannels.all,
    remotePlaylistUrls: kDefaultLiveIndexUrls,
  );
  final sw = Stopwatch()..start();
  final snap = await service.load(remote: true);
  sw.stop();

  final counts = <int, int>{};
  var multi = 0;
  var hostVariety = 0;
  for (final c in snap.channels) {
    final n = c.streams.length;
    counts[n] = (counts[n] ?? 0) + 1;
    if (n >= 2) multi++;
    final hosts = c.streams.map((s) => Uri.tryParse(s.url)?.host ?? '').toSet();
    if (hosts.length >= 2) hostVariety++;
  }

  print('装载：${snap.sourceLabel}  耗时 ${sw.elapsedMilliseconds}ms');
  print('提示：${snap.warnings.isEmpty ? '无' : snap.warnings.join(' / ')}');
  print('线路数分布（线路数 → 频道数）：${counts.entries.map((e) => '${e.key}:${e.value}').join('  ')}');
  print('有 ≥2 条线路的频道：$multi / ${snap.channels.length}');
  print('线路跨 ≥2 个主机的频道：$hostVariety / ${snap.channels.length}');

  final cctv = snap.channels.where((c) => c.group == '央视频道').take(6);
  print('\n央视样例：');
  for (final c in cctv) {
    print('  ${c.name}（${c.streams.length} 线）');
    for (final s in c.orderedStreams) {
      final host = Uri.tryParse(s.url)?.host ?? '?';
      print('    rank=${s.qualityRank} $host  ${s.label}');
    }
  }
  exit(0);
}
