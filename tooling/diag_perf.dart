// 运行：dart run tooling/diag_perf.dart
//
// 目的：量化「初始加载」与「换台探测」两处性能瓶颈的真实数值，验证本轮优化：
//  1) 新首屏路径 = 只等基线（loadBase，小目录）；
//     旧路径     = 基线 + 增强（城市/发现源 + streams.json），即旧实现首帧要多等的部分。
//  2) 采样若干首线路做短探测（1.2s），看换台时探测的平均占用。
//
// 说明：数值依网络而变，但「基线明显短于完整装载」这个结构性结论稳定。

import 'package:shunbo/features/live/live_catalog.dart';

Future<void> main() async {
  final service = LiveCatalogService(
    builtIn: BuiltInLiveChannels.all,
    remotePlaylistUrls: kDefaultLiveIndexUrls,
    streamIndexUrl: kDefaultStreamIndexUrl,
    streamIndexUrls: kDefaultStreamIndexUrls,
    citySupplementUrls: kDefaultCitySupplementUrls,
    discoverySources: kDefaultDiscoverySources,
    remoteTimeout: const Duration(seconds: 8),
    enhancedTimeout: const Duration(seconds: 15),
  );

  print('═══ 首屏装载耗时（真实索引）═══');
  final swBase = Stopwatch()..start();
  final base = await service.loadBase(remote: true);
  swBase.stop();
  final baseMark = swBase.elapsedMilliseconds;
  print('基线（新首屏关键路径）: ${baseMark}ms · ${base.channelCount} 频道 · 降级=${base.warnings.length}');

  // 旧实现首帧要等「基线 + 增强」全部完成；这里量增量，再相加即为旧等待。
  final swEnh = Stopwatch()..start();
  final enhanced = await service.enhanceSnapshot(base);
  swEnh.stop();
  final enhMark = swEnh.elapsedMilliseconds;
  print('增强（后台补齐，旧首屏要多等这部分）: ${enhMark}ms · ${enhanced.channelCount} 频道');

  final oldTotal = baseMark + enhMark;
  final saved = oldTotal - baseMark;
  final pct = oldTotal == 0 ? 0 : (saved * 100 / oldTotal).round();
  print('—— 旧首屏等待 ≈ ${oldTotal}ms → 新首屏等待 ≈ ${baseMark}ms（省 $saved ms，约 $pct%）');

  print('');
  print('═══ 换台探测耗时抽样（短探测 1.2s，最多 12 条首线路）═══');
  final sample = base.channels
      .where((c) => c.streams.isNotEmpty)
      .take(12)
      .toList(growable: false);
  if (sample.isEmpty) {
    print('基线条目为空，跳过探测抽样。');
  } else {
    var total = 0;
    var ok = 0;
    for (final c in sample) {
      final sw = Stopwatch()..start();
      final reachable = await service.probe(
        c.streams.first.url,
        timeout: const Duration(milliseconds: 1200),
      );
      sw.stop();
      total += sw.elapsedMilliseconds;
      if (reachable) ok++;
    }
    final avg = total ~/ sample.length;
    print('样本 ${sample.length} 条 · 可达 $ok · 平均单调探测 ${avg}ms');
    print('（旧实现每次换台先跑 4s 探测；本轮改为「有历史即跳过 / 未知才 1.2s 短探测」）');
  }

  print('');
  print('诊断完成。');
}
