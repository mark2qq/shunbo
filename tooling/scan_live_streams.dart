// 直播线路全量扫描：找出「此刻真能出流」的台与主机。
//
// 用途：内置清单的镜像会整站关停（本项目已踩过：ivi.bupt.edu.cn 全站不通），
// 而「哪个镜像今天还活着」只能实测。本脚本把频道表里每个台的首条线路并发探一遍，
// 输出可用清单与主机统计，用来校准内置清单与选台顺序。
//
// 运行：dart run tooling/scan_live_streams.dart [并发数]
import 'dart:io';

import 'package:shunbo/features/live/live_catalog.dart';
import 'package:shunbo/features/live/live_channel.dart';

Future<void> main(List<String> args) async {
  final concurrency = args.isEmpty ? 16 : (int.tryParse(args.first) ?? 16);
  final service = LiveCatalogService(
    builtIn: BuiltInLiveChannels.all,
    remotePlaylistUrls: kDefaultLiveIndexUrls,
  );
  final snap = await service.load(remote: true);
  print('频道数：${snap.channelCount}，来源：${snap.sourceLabel}');

  final alive = <LiveChannel>[];
  final okHosts = <String, int>{};
  final badHosts = <String, int>{};
  final sw = Stopwatch()..start();

  final queue = List<LiveChannel>.from(snap.channels);
  final total = queue.length;
  var done = 0;

  Future<void> worker() async {
    while (queue.isNotEmpty) {
      final c = queue.removeAt(0);
      if (!c.isPlayable) continue;
      final s = c.orderedStreams.first;
      final host = Uri.tryParse(s.url)?.host ?? '?';
      final ok = await service.probe(s.url, timeout: const Duration(seconds: 5));
      done++;
      if (ok) {
        alive.add(c);
        okHosts[host] = (okHosts[host] ?? 0) + 1;
        print('OK   [${c.group}] ${c.name} → ${s.url}');
      } else {
        badHosts[host] = (badHosts[host] ?? 0) + 1;
      }
      if (done % 20 == 0) print('... $done/$total');
    }
  }

  await Future.wait(List.generate(concurrency, (_) => worker()));

  print('\n== 总结 ==');
  print('可用台：${alive.length}/${total}，耗时 ${sw.elapsedMilliseconds} ms');
  print('可用主机：$okHosts');
  print('失效主机（前 10）：'
      '${(badHosts.entries.toList()..sort((a, b) => b.value.compareTo(a.value))).take(10).map((e) => '${e.key}×${e.value}').join(', ')}');
  print('\n可用台分组分布：');
  final groups = <String, List<String>>{};
  for (final c in alive) {
    groups.putIfAbsent(c.group, () => <String>[]).add(c.name);
  }
  for (final e in groups.entries) {
    print('  ${e.key}（${e.value.length}）：${e.value.take(8).join('、')}');
  }
  exit(0);
}
