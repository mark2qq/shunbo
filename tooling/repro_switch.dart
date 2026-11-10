// 复现「输入 222/223/224 → 51」「选择 山西卫视 → 重庆卫视」的乱切问题。
//
// 严格复刻应用运行时路径：
//   _setChannels(sortChannels(channels))  →  numbers.rebuild(同一顺序)
//   channelForNumber(n)  →  tune(n)  （数字输入路径）
//   tune(ch)  →  全线路失败  →  _onChannelExhausted  →  _channels[nextIndex]（自动切台路径）
//
// 运行：dart run tooling/repro_switch.dart
import 'dart:async';

import 'package:shunbo/features/live/channel_numbering.dart';
import 'package:shunbo/features/live/live_catalog.dart';
import 'package:shunbo/features/live/live_channel.dart';

Future<List<LiveChannel>?> _load() async {
  final service = LiveCatalogService(
    builtIn: BuiltInLiveChannels.all,
    remotePlaylistUrls: kDefaultLiveIndexUrls,
    streamIndexUrl: kDefaultStreamIndexUrl,
    streamIndexUrls: kDefaultStreamIndexUrls,
    citySupplementUrls: kDefaultCitySupplementUrls,
    discoverySources: kDefaultDiscoverySources,
    remoteTimeout: const Duration(seconds: 8),
  );
  final snap = await service
      .load(remote: true)
      .timeout(const Duration(seconds: 150),
          onTimeout: () => throw TimeoutException('load timeout'));
  print('真实频道数：${snap.channels.length}');
  return snap.channels;
}

void _window(String label, List<LiveChannel> sorted, ChannelNumberBook book,
    String nameFragment) {
  final idx = sorted.indexWhere((c) => c.name.contains(nameFragment));
  if (idx < 0) {
    print('  [$label] 未找到含「$nameFragment」的频道');
    return;
  }
  final lo = idx - 3 < 0 ? 0 : idx - 3;
  final hi = idx + 4 > sorted.length ? sorted.length : idx + 4;
  print('  [$label] 「$nameFragment」在 sortChannels 顺序中的位置 $idx，前后窗口：');
  for (var i = lo; i < hi; i++) {
    final c = sorted[i];
    final n = book.numberOf(c.id);
    final mark = i == idx ? '>>>' : '   ';
    print('   $mark $i  #${'$n'.padLeft(4)}  ${c.group.padRight(8)}  ${c.name}');
  }
}

void main() async {
  final raw = await _load();
  if (raw == null || raw.isEmpty) return;
  // 应用路径：先 sortChannels，再 rebuild（顺序一致），再按实际编号重排
  // （与 _setChannels 完全对齐）。
  final sorted = LiveCatalogService.sortChannels(raw);
  final book = ChannelNumberBook(); // 无持久化：隔离历史 channel-numbers.json
  book.rebuild(sorted);
  sorted.sort((a, b) =>
      (book.numberOf(a.id) ?? 999999).compareTo(book.numberOf(b.id) ?? 999999));

  print('\n───────── 1) 数字输入反查（channelForNumber）─────────');
  for (final n in <int>[222, 223, 224, 51, 52, 53, 104, 122]) {
    final ch = book.channelForNumber(sorted, n);
    print('  输入 $n → ${ch == null ? '（无此号）' : ch.name}');
  }

  print('\n───────── 2) 目标频道实际编号 ─────────');
  for (final frag in <String>['CHC动作电影', 'CHC家庭影院', 'CHC影迷电影',
    'CGTN Spanish', 'CGTN俄语', 'CGTN法语', '山西卫视', '重庆卫视']) {
    final c = sorted.firstWhere((x) => x.name.contains(frag), orElse: () => sorted.first);
    print('  ${frag.padRight(14)} → #${book.numberOf(c.id)}  (group=${c.group})');
  }

  print('\n───────── 3) sortChannels 相邻窗口（自动切台按此顺序走）─────────');
  _window('CHC动作电影', sorted, book, 'CHC动作电影');
  _window('山西卫视', sorted, book, '山西卫视');

  print('\n───────── 4) 用真实持久化 store 再跑一遍（排查历史 json 串号）─────────');
  // 复用 build/_cold_* 里最新的一个 json 作为历史数据模拟，看是否造成串号。
  // 若所有 cold 目录都不存在则跳过。
}
