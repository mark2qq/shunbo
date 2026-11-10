// 把「实测解码通过」的线路清单生成成 Dart 常量，供 App 内置装载。
//
// 为什么不直接塞 m3u 到 assets：
//   ① 纯 dart 回归（`dart run tooling/verify_*.dart`）没有 AssetBundle，读不到 assets，
//      内置清单就没法进回归；
//   ② 生成成常量后，`verify_live_catalog` 可以直接断言「央视有几个台、每条线路都带
//      实测分辨率」，不需要起 flutter 环境。
//
// 为什么这份清单可以硬编码（而 `BuiltInLiveChannels` 的注释反对硬编码）：
//   那条注释反对的是「没验证过就写死地址」——31 个台 × 2 条死链把首屏探测窗口占满。
//   这里每一条都过了 libmpv 解码（零解码错误 + 建起解码链），且文件头带验证时间；
//   清单会随时间腐烂，所以 `verifiedAt` 是必读字段，过期就该重跑工具重生成。
//
// 用法：
//   dart run tooling/gen_verified_channels.dart \
//        --in ../.apk_analysis/decode_pass1.json \
//        --out lib/features/live/verified_channels.g.dart
library;

import 'dart:convert';
import 'dart:io';

import 'package:shunbo/features/live/live_catalog.dart';
import 'package:shunbo/features/live/live_channel.dart';

/// 实测分辨率 → 台名后缀。借 `LiveCatalogService.qualityRankOf` 既有的识别规则
/// 把「实测出来的画质」写进 rank，而不是靠台名里原本吹的 HD 字样。
String _resTag(int w, int h) {
  if (w >= 1900 || h >= 1000) return '1080P';
  if (w >= 1200) return '720P';
  if (w >= 700) return '576P';
  return '480P';
}

/// 整理成 dart 字符串字面量（单引号 + 转义）。
String _lit(String s) =>
    "'${s.replaceAll(r'\', r'\\').replaceAll("'", r"\'").replaceAll(r'$', r'\$')}'";

String _mapLit(Map<String, String> m) {
  if (m.isEmpty) return 'const <String, String>{}';
  final entries = m.entries.map((e) => '${_lit(e.key)}: ${_lit(e.value)}').join(', ');
  return '<String, String>{$entries}';
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
    stderr.writeln('用法: --in <decode_result.json> --out <xxx.g.dart>');
    exit(2);
  }

  final raw = (jsonDecode(File(inPath).readAsStringSync()) as List).cast<Map>();
  final ok = raw.where((m) => m['ok'] == true).toList();
  if (ok.isEmpty) {
    stderr.writeln('没有任何通过项，拒绝生成空清单');
    exit(1);
  }

  // 先拼成 m3u 文本，交给线上同一套解析器：分组归类、台名归一、id 生成、
  // 台标取字全走 `parseM3U`，生成器里不重复实现一遍（重复实现必然与线上漂移）。
  final m3u = StringBuffer('#EXTM3U\n');
  for (final m in ok) {
    final w = (m['w'] as num?)?.toInt() ?? 0;
    final h = (m['h'] as num?)?.toInt() ?? 0;
    final tag = _resTag(w, h);
    final group = (m['group'] as String?) ?? '';
    final name = (m['name'] as String?) ?? '';
    m3u.writeln('#EXTINF:-1 group-title="$group",$name $tag');
    m3u.writeln(m['url']);
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

  // 每条线路带上「实测画质」标签，UI 的线路切换里能直接看出哪条是 1080p 实测。
  final channels = merged.where((c) => c.streams.isNotEmpty).toList()
    ..sort((a, b) => LiveChannel.groupRank(a.group) - LiveChannel.groupRank(b.group));

  // 头部数字必须由本次输入算出来，不能手写：手写的数字会和内容对不上，
  // 而这个文件唯一的价值就是「它说的是真的」。
  final streamCount = channels.fold<int>(0, (a, c) => a + c.streams.length);
  final now = DateTime.now().toUtc();
  final day = '${now.year}-${now.month.toString().padLeft(2, '0')}-'
      '${now.day.toString().padLeft(2, '0')}';

  final buf = StringBuffer()
    ..writeln('// GENERATED FILE — 由 tooling/gen_verified_channels.dart 生成，勿手改。')
    ..writeln('//')
    ..writeln('// 数据来源：昭昭TV(`cc.zztv.tvbox`) 的直播源总表 kds_common.txt（7270 条 / 3083 台）')
    ..writeln('// 筛法：① HTTP 层并发探测留下「返回合法 m3u8」的线路；② 逐条用 libmpv 播放，')
    ..writeln('//       判定「建起解码链 + 解码器零报错」。浅判据（HTTP 200 / 有 EXTINF /')
    ..writeln('//       分片首字节 0x47 / SPS 可解析）在央视加扰流上全部为真，但画面是满屏色块。')
    ..writeln('// 验证时间：$day（${ok.length} 条通过，去重后 $streamCount 条线路 / '
        '${channels.length} 个台）')
    ..writeln('//')
    ..writeln('// **这份清单有保质期。** 公开直播地址以周为单位腐烂，`verifiedAt` 超过一个月')
    ..writeln('// 就该重跑 tooling/scan_batch_decode.dart + 本工具重新生成，而不是继续信它。')
    ..writeln('library;')
    ..writeln()
    ..writeln("import 'live_channel.dart';")
    ..writeln()
    ..writeln('/// 生成时间戳（ISO8601，UTC）。')
    ..writeln("const String kVerifiedLiveAt = '${now.toIso8601String().split('.').first}Z';")
    ..writeln()
    ..writeln('/// 实测解码通过的频道清单。')
    ..writeln('///')
    ..writeln('/// 只放**真的出得了画面**的线路：判据是 libmpv 建起解码链且解码器零报错，')
    ..writeln('/// 不是 HTTP 200，也不是「有 EXTINF / 分片首字节是 0x47」——')
    ..writeln('/// 这两种浅判据在央视加扰流上全部为真，但画面是满屏色块。')
    ..writeln('const List<LiveChannel> kVerifiedLiveChannels = <LiveChannel>[');

  for (final c in channels) {
    buf.writeln('  LiveChannel(');
    buf.writeln('    id: ${_lit(c.id)},');
    buf.writeln('    name: ${_lit(c.name)},');
    buf.writeln('    group: ${_lit(c.group)},');
    buf.writeln('    badge: ${_lit(c.badge)},');
    if (c.tvgId != null) buf.writeln('    tvgId: ${_lit(c.tvgId!)},');
    if (c.categories.isNotEmpty) {
      buf.writeln('    categories: <String>[${c.categories.map(_lit).join(', ')}],');
    }
    buf.writeln('    streams: <LiveStream>[');
    for (final s in c.streams) {
      buf.writeln('      LiveStream(');
      buf.writeln('        url: ${_lit(s.url)},');
      buf.writeln('        label: ${_lit(s.label)},');
      buf.writeln('        qualityRank: ${s.qualityRank},');
      if (s.headers.isNotEmpty) buf.writeln('        headers: ${_mapLit(s.headers)},');
      // 这份清单的准入条件本身就是「libmpv 建起解码链且解码器零报错」，
      // 所以每条线路都必须带 decodeVerified。漏写这个字段会让
      // `LiveChannel.orderedStreams` 的「实测优先」和 `LiveController._tryStream`
      // 的 trusted 免探测快路径对这 440 个台全部失效——排序退化成画质优先，
      // 首次起播还要白等 3.5s 探测。
      buf.writeln('        decodeVerified: true,');
      buf.writeln('      ),');
    }
    buf.writeln('    ],');
    buf.writeln('  ),');
  }
  buf.writeln('];');

  File(outPath).writeAsStringSync(buf.toString());
  stdout.writeln('写出 $outPath：${channels.length} 个台 / '
      '${channels.fold<int>(0, (a, c) => a + c.streams.length)} 条线路');
}
