// dart run tooling/diag_tvg_coverage.dart
// 验证两个假设：
//  (1) 备用源丰富度低，是因为非 iptv-org 索引的条目 tvg-id 缺失/不匹配，导致
//      withBackupStreams 无法把它们关联到 streams.json 的多线路表。
//  (2) 那 6 个 IPv6-only 频道，是否本应有 IPv4 兄弟频道却因「台名归一不一致」
//      被拆成了两个频道对象（一个 IPv4、一个 IPv6）。

import 'dart:async';

import 'package:shunbo/features/live/live_catalog.dart';
import 'package:shunbo/features/live/live_channel.dart';

void main() async {
  final service = LiveCatalogService(
    builtIn: BuiltInLiveChannels.all,
    remotePlaylistUrls: kDefaultLiveIndexUrls,
    streamIndexUrl: kDefaultStreamIndexUrl,
    streamIndexUrls: kDefaultStreamIndexUrls,
    citySupplementUrls: kDefaultCitySupplementUrls,
    discoverySources: kDefaultDiscoverySources,
    remoteTimeout: const Duration(seconds: 8),
  );
  final snap = await service.load(remote: true).timeout(
    const Duration(seconds: 150),
    onTimeout: () => throw TimeoutException('load() 超时'),
  );
  final channels = snap.channels;

  // (1) tvg-id 覆盖
  final withTvg = channels.where((c) => c.tvgId != null && c.tvgId!.isNotEmpty).toList();
  final multi = channels.where((c) => c.streams.length >= 2).toList();
  print('频道总数            ：${channels.length}');
  print('有 tvg-id 的频道    ：${withTvg.length}  (${(withTvg.length*100/channels.length).toStringAsFixed(0)}%)');
  print('≥2 路（拿到的备用） ：${multi.length}  (${(multi.length*100/channels.length).toStringAsFixed(0)}%)');
  // 有 tvg-id 但仍是单点 → 说明即便有 tvg-id，也没匹配上 streams.json（或本身只有1条）
  final withTvgSingle = withTvg.where((c) => c.streams.length == 1).toList();
  print('有 tvg-id 却仍单点  ：${withTvgSingle.length}');

  // (2) IPv6-only 频道：列出 id / tvgId / group / 全部 URL（host 形态）
  print('\n── 6 个 IPv6-only 频道详情 ──');
  final ipv6 = channels.where((c) {
    if (c.streams.isEmpty) return false;
    final host = Uri.tryParse(c.streams.first.url)?.host ?? '';
    return host.contains('[') || host.contains(':');
  }).toList();
  for (final c in ipv6) {
    print('  name=${c.name}  id=${c.id}  tvgId=${c.tvgId}  group=${c.group}');
    for (final s in c.streams) {
      print('     ${s.url.substring(0, s.url.length.clamp(0, 90))}');
    }
  }

  // (3) 同一「站点」被拆成多个频道对象（台名归一不一致）？
  //     用更激进的归一：去空格、去常见后缀，看有多少 stations 对应多个 channel 对象。
  String loose(String name) => name
      .replaceAll(RegExp(r'\s+'), '')
      .replaceAll(RegExp(r'(高清|超清|标清|蓝光|HD|UHD|SD|\d{3,4}[Pp]|\(.*?\)|\[.*?\])'), '');
  final byLoose = <String, List<LiveChannel>>{};
  for (final c in channels) {
    byLoose.putIfAbsent(loose(c.name), () => <LiveChannel>[]).add(c);
  }
  final split = byLoose.entries.where((e) => e.value.length > 1).toList();
  print('\n── 同一站点被拆成多个频道对象（疑似台名归一不一致）：${split.length} 组 ──');
  for (final e in split.take(30)) {
    final urls = e.value.map((c) {
      final h = Uri.tryParse(c.streams.first.url)?.host ?? '';
      final v6 = h.contains('[') || h.contains(':') ? 'IPv6' : 'IPv4';
      return '${c.name}[$v6×${c.streams.length}]';
    }).join('  ');
    print('  ${e.key}  =>  $urls');
  }

  print('\n诊断完成。');
}
