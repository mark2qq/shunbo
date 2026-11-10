// 运行：dart run tooling/diag_stream_coverage.dart
//
// 目的：用应用真实的装载链路（LiveCatalogService.load + 默认索引）拉取当前公开索引，
// 量化「每个频道有几个数据源（线路）」，定位「大量频道缺少数据源」的根因。
//
// 输出：
//  - 总数 / 0 路 / 1 路 / ≥2 路 / 含高清 的分布
//  - 0 路频道的完整清单（若有）
//  - 仅 1 路且为 IPv6 直连（纯 IPv4 网络下必死）的频道清单
//  - 按分组统计缺源占比，定位受影响频道范围

import 'dart:async';
import 'dart:io';

import 'package:shunbo/features/live/live_catalog.dart';
import 'package:shunbo/features/live/live_channel.dart';

void main() async {
  print('═══════════════════════════════════════════════════════');
  print('  直播数据源覆盖率诊断（应用真实装载链路）');
  print('═══════════════════════════════════════════════════════');

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
    onTimeout: () => throw TimeoutException('load() 超过 150s'),
  );

  final channels = snap.channels;
  print('来源：${snap.sourceLabel}');
  print('频道总数：${channels.length}');
  if (snap.warnings.isNotEmpty) {
    print('降级提示：');
    for (final w in snap.warnings) print('  - $w');
  }

  final zero = channels.where((c) => c.streams.isEmpty).toList();
  final one = channels.where((c) => c.streams.length == 1).toList();
  final multi = channels.where((c) => c.streams.length >= 2).toList();
  final withHd = channels.where((c) => c.streams.any((s) => s.isHd)).toList();

  print('');
  print('── 数据源（线路）数量分布 ──');
  print('  0 路（完全无源，必不能播）：${zero.length}');
  print('  1 路（单点，源挂即死）    ：${one.length}');
  print('  ≥2 路（有备用）            ：${multi.length}');
  print('  含高清线路                ：${withHd.length}');

  if (zero.isNotEmpty) {
    print('');
    print('── 0 路频道清单（${zero.length} 个）──');
    for (final c in zero) {
      print('  # ${c.id}  ${c.name}  [${c.group}]');
    }
  }

  // 仅 1 路且地址为 IPv6 直连（纯 IPv4 网络下必死）：地址含冒号且非 http://host:port 的常见形态。
  final ipv6Only = one.where((c) {
    final u = c.streams.first.url.toLowerCase();
    if (!u.startsWith('http')) return false;
    final host = Uri.tryParse(u)?.host ?? '';
    // IPv6 字面量 host 含冒号且被 [] 包裹；也兜底检测裸 IPv6。
    return host.contains(':') || host.isEmpty;
  }).toList();
  print('');
  print('── 仅 1 路且疑似 IPv6/非常规 host（纯 IPv4 下必死）：${ipv6Only.length} 个 ──');
  for (final c in ipv6Only.take(40)) {
    print('  ${c.name.padRight(16)} ${c.streams.first.url}');
  }

  // 按分组统计：哪些分组的缺源（0 路或仅 1 路）最严重。
  final byGroup = <String, List<LiveChannel>>{};
  for (final c in channels) {
    byGroup.putIfAbsent(c.group, () => <LiveChannel>[]).add(c);
  }
  print('');
  print('── 各分组「缺源/单点」占比（按频道数降序）──');
  final groups = byGroup.entries.toList()
    ..sort((a, b) => b.value.length.compareTo(a.value.length));
  for (final e in groups) {
    final list = e.value;
    final weak = list.where((c) => c.streams.length <= 1).length;
    print('  ${e.key.padRight(12)} 共 ${list.length} 个 · '
        '弱源(≤1路) $weak 个 · '
        '占比 ${(weak * 100 / list.length).toStringAsFixed(0)}%');
  }

  // 抽样可达性：对「仅 1 路」频道随机抽 30 个做 HEAD 探测，看多大比例实际死链。
  print('');
  print('── 单点源可达性抽样（HTTP HEAD，最多 30 个，每源 6s 超时）──');
  final sample = one.take(30).toList();
  var dead = 0;
  var alive = 0;
  for (final c in sample) {
    final url = c.streams.first.url;
    try {
      final uri = Uri.parse(url);
      final req = await HttpClient()
          .headUrl(uri)
          .timeout(const Duration(seconds: 6));
      final resp = await req.close().timeout(const Duration(seconds: 6));
      resp.drain();
      if (resp.statusCode >= 200 && resp.statusCode < 400) {
        alive++;
        print('  可达  ${c.name}  [$resp.statusCode]');
      } else {
        dead++;
        print('  不可达(${resp.statusCode})  ${c.name}');
      }
    } catch (e) {
      dead++;
      print('  死链   ${c.name}  (${e.runtimeType})');
    }
  }
  print('  抽样结果：可达 $alive / 死链 $dead（样本 ${sample.length}）');

  print('');
  print('诊断完成。');
}
