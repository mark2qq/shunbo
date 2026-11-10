// 直播信号源现场诊断：把「应用内真实会走的那条路」跑一遍。
//
// 为什么需要它：直播首屏黑屏时，UI 上只显示「正在连接」，而链路上有四段完全不同的
// 失败可能——
//   ① 远端索引拉不到（DNS/代理/超时）→ 频道表退化成内置清单；
//   ② 索引拉到了但解析空了（属性变了、URL 被白名单拒）；
//   ③ 频道表正常但线路整站失效（镜像关停）→ 探测全灭；
//   ④ 线路能连但拉不出流（返回 200 后挂住）。
// 只对着界面猜会一直绕着「解码器坏了」打转（本项目已经踩过一次：
// 真因是 libmpv 走了系统代理拿到 502）。所以把每段的判断结果直接打出来。
//
// 与 `verify_live_catalog.dart` 的分工：那套是**离线门禁**（注入 HttpServer，
// 断言可复现）；本脚本是**联网探针**（说清「此刻这台机器上哪条线路能用」），
// 不进 verify_all，因为它依赖外网、结果天然会变。
//
// 运行：dart run tooling/diag_live_catalog.dart [--no-proxy]
import 'dart:async';

import 'package:shunbo/features/live/live_catalog.dart';
import 'package:shunbo/features/live/live_channel.dart';

/// 探测前多少个台（与 `LiveController._selectProbed(limit: 8)` 对齐）。
const int _probeLimit = 8;

/// 采样打印多少个台的线路明细。
const int _sampleSize = 12;

Future<void> main(List<String> args) async {
  final sw = Stopwatch()..start();
  final service = LiveCatalogService(
    builtIn: BuiltInLiveChannels.all,
    remotePlaylistUrls: kDefaultLiveIndexUrls,
  );

  print('== 1. 内置清单 ==');
  final builtIn = service.builtIn;
  print('内置频道数：${builtIn.length}');
  final hosts = <String>{};
  for (final c in builtIn) {
    for (final s in c.streams) {
      hosts.add(Uri.tryParse(s.url)?.host ?? '?');
    }
  }
  print('内置线路涉及主机：$hosts');

  print('\n== 2. 装载（内置 + 公开索引）==');
  final snap = await service.load(remote: true);
  print('来源：${snap.sourceLabel}');
  print('频道数：${snap.channelCount}');
  print('耗时：${sw.elapsedMilliseconds} ms');
  if (snap.warnings.isEmpty) {
    print('降级说明：无');
  } else {
    for (final w in snap.warnings) {
      print('降级说明：$w');
    }
  }

  final byGroup = <String, int>{};
  for (final c in snap.channels) {
    byGroup[c.group] = (byGroup[c.group] ?? 0) + 1;
  }
  print('分组分布：$byGroup');
  print('前 5 个台：${snap.channels.take(5).map((c) => c.name).toList()}');

  print('\n== 3. 线路明细抽样（前 $_sampleSize 个台）==');
  for (final c in snap.channels.take(_sampleSize)) {
    final first = c.orderedStreams.first;
    print('  ${c.group} / ${c.name} ×${c.streams.length} → ${first.url}');
  }

  print('\n== 4. 并发探测（分批，与首屏选台逻辑一致）==');
  final sw2 = Stopwatch()..start();
  final deadUrls = <String>{};
  final deadHosts = <String>{};
  String hostOf(String u) => Uri.tryParse(u)?.host ?? '';
  LiveChannel? hit;
  String? hitUrl;
  for (var round = 0; round < 4 && hit == null; round++) {
    final batch = <(LiveChannel, String)>[];
    for (final c in snap.channels) {
      if (batch.length >= _probeLimit) break;
      for (final s in c.orderedStreams) {
        if (deadUrls.contains(s.url) || deadHosts.contains(hostOf(s.url))) continue;
        batch.add((c, s.url));
        break;
      }
    }
    if (batch.isEmpty) break;
    final results = await Future.wait(batch.map((e) async {
      final ok = await service.probe(e.$2, timeout: const Duration(seconds: 4));
      if (!ok) {
        deadUrls.add(e.$2);
        deadHosts.add(hostOf(e.$2));
      }
      return (e.$1, e.$2, ok);
    }));
    for (final r in results) {
      print('  [第 ${round + 1} 轮] ${r.$3 ? 'OK  ' : 'FAIL'} ${r.$1.name} → ${r.$2}');
      if (r.$3 && hit == null) {
        hit = r.$1;
        hitUrl = r.$2;
      }
    }
  }
  print('探测耗时：${sw2.elapsedMilliseconds} ms');

  print('\n== 5. 首屏会选哪个台 ==');
  if (hit != null) {
    print('命中：${hit.name}（${hit.group}）→ $hitUrl');
  } else {
    print('四轮探测全灭 → 会退到「第一个线路未被标记失效的台」，用户看到的是暂无信号。');
  }

  print('\n== 6. 失效主机清单 ==');
  print(deadHosts.isEmpty ? '无' : deadHosts.join('\n'));
  print('\n总耗时：${sw.elapsedMilliseconds} ms');
}
