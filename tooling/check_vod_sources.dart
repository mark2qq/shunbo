// 点播片源可达性实测（联网探针，不进门禁）。
//
// 为什么单独一个工具：片库地址一旦指向解析不出来的域名，界面看起来是好的
// （卡片、简介、集数都在），只是点播放毫无反应——本项目踩过一次：
// 整库指向 `commondatastorage.googleapis.com`，该域名在部分网络下 DNS 直接失败，
// 三个片库栏目全部黑屏。所以换片源后必须实测每一个地址。
//
// 与 `verify_all` 的分工：那边是离线断言（不依赖外网），这里是**现场检查**
// 「此刻这台机器上片库能不能播」。结果天然会变，所以不能当门禁。
//
// 运行：dart run tooling/check_vod_sources.dart
import 'dart:io';

import 'package:shunbo/features/vod/vod_catalog.dart';

Future<void> main() async {
  var dead = 0;
  var ok = 0;
  for (final item in VodCatalog.all) {
    print('[${item.section.label}] ${item.title}（${item.episodeCount} 集）');
    for (final ep in item.episodes) {
      final uri = Uri.tryParse(ep.url);
      final reachable = uri == null ? false : await _probe(uri);
      if (reachable) {
        ok++;
      } else {
        dead++;
      }
      print('  ${reachable ? 'OK  ' : 'DEAD'} ${ep.title} → ${ep.url}');
    }
  }
  print('');
  print('可达 $ok 个 / 失效 $dead 个');
  exit(dead == 0 ? 0 : 1);
}

/// 只读前 1KB 就断开：既能证明确实有数据，又不浪费流量。
Future<bool> _probe(Uri uri) async {
  final client = HttpClient()..findProxy = ((_) => 'DIRECT');
  client.connectionTimeout = const Duration(seconds: 6);
  try {
    final req = await client.getUrl(uri).timeout(const Duration(seconds: 8));
    req.headers.set(HttpHeaders.userAgentHeader, 'shunbo/1.0');
    req.headers.set(HttpHeaders.rangeHeader, 'bytes=0-1023');
    final res = await req.close().timeout(const Duration(seconds: 8));
    final ok = res.statusCode >= 200 && res.statusCode < 400;
    await res.drain<void>();
    return ok;
  } catch (_) {
    return false;
  } finally {
    client.close(force: true);
  }
}
