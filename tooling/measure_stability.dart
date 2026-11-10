// 稳定性测量：同一批线路重复解 N 轮，量化「官方源是否比现有源稳」。
//
// 为什么不能只测一遍：公开直播源的失效主要是**抖动与令牌过期**，一次 200
// 说明不了任何问题。本工具按轮次重复调用与 `scan_batch_decode` 完全相同的
// libmpv 判据（解码链建成 + 零解码错误），并额外记录首帧时延与分辨率，
// 输出逐轮原始数据和聚合结论。
//
// 用法：
//   dart run tooling/measure_stability.dart --in <candidates.json> \
//        --out <prefix> [--rounds 3] [--concurrency 4] [--seconds 6] [--gap 20]
//
// 输入：[{"group":"卫视","name":"浙江卫视","kind":"official",
//          "url":"...","headers":{"User-Agent":"..."}}]
// 输出：<prefix>_raw.json / <prefix>_summary.json / <prefix>_report.md
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'scan_batch_decode.dart' as scan;

Future<void> main(List<String> args) async {
  var inPath = '';
  var outPrefix = '';
  var rounds = 3;
  var concurrency = 4;
  var seconds = 6;
  var gap = 20;
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--in':
        inPath = args[++i];
      case '--out':
        outPrefix = args[++i];
      case '--rounds':
        rounds = int.parse(args[++i]);
      case '--concurrency':
        concurrency = int.parse(args[++i]);
      case '--seconds':
        seconds = int.parse(args[++i]);
      case '--gap':
        gap = int.parse(args[++i]);
    }
  }
  if (inPath.isEmpty || outPrefix.isEmpty || rounds < 1) {
    stderr.writeln('用法: --in <json> --out <prefix> [--rounds 3] '
        '[--concurrency 4] [--seconds 6] [--gap 20]');
    exit(2);
  }
  final libPath = File('build/windows/x64/runner/Release/libmpv-2.dll').path;
  if (!File(libPath).existsSync()) {
    stderr.writeln('缺少 $libPath：先执行 flutter build windows --release');
    exit(2);
  }

  final raw = jsonDecode(File(inPath).readAsStringSync()) as List;
  final items = raw.cast<Map>().map((m) {
    final s = scan.splitHeaders('${m['url']}');
    final declared = (m['headers'] as Map?)?.map(
          (k, v) => MapEntry<String, String>('$k', '$v'),
        ) ??
        const <String, String>{};
    return <String, Object?>{
      'group': m['group'] ?? '',
      'name': m['name'] ?? '',
      'kind': m['kind'] ?? 'unknown',
      'url': s.url,
      'headers': <String, String>{...declared, ...s.headers},
    };
  }).toList();

  final all = <Map<String, Object?>>[];
  final swAll = Stopwatch()..start();
  for (var round = 1; round <= rounds; round++) {
    final sw = Stopwatch()..start();
    for (var i = 0; i < items.length; i += concurrency) {
      final batch = items.sublist(i, (i + concurrency).clamp(0, items.length));
      final results = await Future.wait(batch.map((it) async {
        final job = <String, Object?>{
          'url': it['url'],
          'headers': it['headers'],
          'seconds': seconds,
          'lib': libPath,
        };
        Map<String, Object?> r;
        try {
          r = await Isolate.run(() => scan.probeDecode(job));
        } catch (e) {
          r = <String, Object?>{
            'ok': false,
            'detail': 'isolate 异常: $e',
            'w': 0,
            'h': 0,
            'firstFrameMs': 0,
          };
        }
        return <String, Object?>{
          'round': round,
          'group': it['group'],
          'name': it['name'],
          'kind': it['kind'],
          'url': it['url'],
          ...r,
        };
      }));
      all.addAll(results);
    }
    final ok = all.where((r) => r['round'] == round && r['ok'] == true).length;
    stdout.writeln('第 $round/$rounds 轮：$ok/${items.length} 通过，'
        '耗时 ${sw.elapsed.inSeconds}s');
    if (round < rounds && gap > 0) {
      await Future<void>.delayed(Duration(seconds: gap));
    }
  }

  // ---- 聚合 ----------------------------------------------------------------
  final byKey = <String, List<Map<String, Object?>>>{};
  for (final r in all) {
    final k = '${r['kind']}|${r['name']}';
    byKey.putIfAbsent(k, () => <Map<String, Object?>>[]).add(r);
  }
  final channels = <Map<String, Object?>>[];
  for (final e in byKey.entries) {
    final parts = e.key.split('|');
    final rows = e.value;
    final okRows = rows.where((r) => r['ok'] == true).toList();
    final frames = okRows
        .map((r) => (r['firstFrameMs'] as num?)?.toInt() ?? 0)
        .where((v) => v > 0)
        .toList();
    final reasons = rows
        .where((r) => r['ok'] != true)
        .map((r) => '${r['detail']}')
        .toList();
    channels.add(<String, Object?>{
      'kind': parts[0],
      'name': parts[1],
      'tried': rows.length,
      'ok': okRows.length,
      'rate': rows.isEmpty ? 0 : okRows.length / rows.length,
      'avgFirstFrameMs': frames.isEmpty
          ? 0
          : frames.reduce((a, b) => a + b) ~/ frames.length,
      'maxFirstFrameMs': frames.isEmpty ? 0 : frames.reduce((a, b) => a > b ? a : b),
      'resolutions': okRows.map((r) => '${r['w']}x${r['h']}').toSet().toList(),
      'failures': reasons,
    });
  }
  channels.sort((a, b) {
    final c = '${a['kind']}'.compareTo('${b['kind']}');
    return c != 0 ? c : '${a['name']}'.compareTo('${b['name']}');
  });

  final kinds = <String, Map<String, Object?>>{};
  for (final k in <String>{for (final r in all) '${r['kind']}'}) {
    final rows = all.where((r) => r['kind'] == k).toList();
    final ok = rows.where((r) => r['ok'] == true).toList();
    final frames = ok
        .map((r) => (r['firstFrameMs'] as num?)?.toInt() ?? 0)
        .where((v) => v > 0)
        .toList();
    kinds[k] = <String, Object?>{
      'tried': rows.length,
      'ok': ok.length,
      'rate': rows.isEmpty ? 0 : ok.length / rows.length,
      'avgFirstFrameMs': frames.isEmpty
          ? 0
          : frames.reduce((a, b) => a + b) ~/ frames.length,
      'p95FirstFrameMs': _percentile(frames, 0.95),
      'uhd': ok.where((r) => (r['w'] as num? ?? 0) >= 3000).length,
      'scrambled': ok.length < rows.length
          ? rows.where((r) => '${r['detail']}'.contains('解码报错')).length
          : 0,
    };
  }

  File('${outPrefix}_raw.json')
      .writeAsStringSync(const JsonEncoder.withIndent(' ').convert(all));
  File('${outPrefix}_summary.json').writeAsStringSync(
    const JsonEncoder.withIndent(' ').convert(<String, Object?>{
      'at': DateTime.now().toUtc().toIso8601String(),
      'rounds': rounds,
      'secondsPerProbe': seconds,
      'gapSeconds': gap,
      'totalSeconds': swAll.elapsed.inSeconds,
      'items': items.length,
      'kinds': kinds,
      'channels': channels,
    }),
  );

  final md = StringBuffer()
    ..writeln('# 官方源稳定性测量')
    ..writeln()
    ..writeln('- 时间：${DateTime.now().toUtc().toIso8601String()}')
    ..writeln('- 轮次：$rounds，每轮每条解 $seconds 秒，轮间隔 $gap 秒')
    ..writeln('- 判据：libmpv 建起解码链 + 解码器零报错（不是 HTTP 200）')
    ..writeln('- 样本：${items.length} 条线路 / ${all.length} 次探测')
    ..writeln()
    ..writeln('## 按源族汇总')
    ..writeln()
    ..writeln('| 源族 | 探测 | 通过 | 成功率 | 平均首帧 | P95 首帧 | 4K 通过 | 加扰报错 |')
    ..writeln('|---|---:|---:|---:|---:|---:|---:|---:|');
  for (final e in kinds.entries) {
    final v = e.value;
    md.writeln('| ${e.key} | ${v['tried']} | ${v['ok']} | '
        '${_pct(v['rate'] as double)} | ${v['avgFirstFrameMs']}ms | '
        '${v['p95FirstFrameMs']}ms | ${v['uhd']} | ${v['scrambled']} |');
  }
  md
    ..writeln()
    ..writeln('## 逐台逐族')
    ..writeln()
    ..writeln('| 源族 | 频道 | 成功/轮次 | 成功率 | 首帧均值/最大 | 分辨率 | 失败原因 |')
    ..writeln('|---|---|---:|---:|---|---|---|');
  for (final c in channels) {
    final fails = (c['failures'] as List).join('；');
    md.writeln('| ${c['kind']} | ${c['name']} | ${c['ok']}/${c['tried']} | '
        '${_pct(c['rate'] as double)} | ${c['avgFirstFrameMs']}/'
        '${c['maxFirstFrameMs']}ms | ${(c['resolutions'] as List).join(',')} | '
        '${fails.isEmpty ? '—' : fails.replaceAll('|', '/')} |');
  }
  File('${outPrefix}_report.md').writeAsStringSync(md.toString());
  stdout.writeln('写出 ${outPrefix}_raw.json / _summary.json / _report.md');
}

String _pct(double v) => '${(v * 100).toStringAsFixed(1)}%';

int _percentile(List<int> xs, double p) {
  if (xs.isEmpty) return 0;
  final s = List<int>.of(xs)..sort();
  final i = ((s.length - 1) * p).round();
  return s[i];
}
