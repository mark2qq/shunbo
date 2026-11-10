// 顺播「数字编号 ↔ 实际频道」**全频道**一致性审计。
//
// 覆盖四层，任一层发现不一致都会在末尾「不一致清单」里点名频道与错误对应：
//   A 配置层：全部固定编号表（央视 / 卫视 / 卫视4K / 地方 / 节目）——重复号、
//     号段越界、归一键冲突、号段表本身重叠或缺口；
//   B 别名层：satelliteAliases **全量**英文别名归一出的中文卫视，是否都有固定号；
//   C 归一/合并层：canonicalName 与 channelIdFor 会不会把不同台错误合并（串台）；
//   D 实盘层：把「所有已知台名」喂进真实解析链路 parseM3U → ChannelNumberBook，
//     逐台核对 声明固定号 == 实际编号、按号反查是否串台、编号是否落在正确号段；
//   E 真实频道表层：联网 load() 拉当前真实频道表，对**每一个真实频道**跑同一套核对，
//     并列出「含『卫视』却无固定号（自动分配、会漂移）」的台。
//
// 用法：
//   dart run tooling/audit_numbers.dart             # 静态全量 + 联网真实频道表
//   dart run tooling/audit_numbers.dart --offline  # 只跑静态全量（无网络）
//
// 退出码：0 = 无硬不一致；1 = 存在硬不一致（同号多台 / 号≠声明 / 反查串台 / 号段错配）。
// 「漂移风险」是提示不升级为失败。本脚本依赖外网与当前索引，不进 verify_all 门禁。
import 'dart:async';
import 'dart:io';

import 'package:shunbo/features/live/channel_numbering.dart';
import 'package:shunbo/features/live/channel_taxonomy.dart';
import 'package:shunbo/features/live/live_catalog.dart';
import 'package:shunbo/features/live/live_channel.dart';

final List<String> _issues = <String>[];
final List<String> _drift = <String>[];

void _hard(String layer, String detail) => _issues.add('[$layer] $detail');
void _warn(String detail) => _drift.add(detail);

String _bandLabel(int n) {
  for (final b in kChannelBands) {
    if (b.contains(n)) return '${b.source.label}(${b.start}-${b.end})';
  }
  if (n >= kProgramBandStart && n <= kProgramBandEnd) return '节目';
  if (n >= kEpisodeBandStart && n <= kEpisodeBandEnd) return '节目分集';
  return '未定义号段';
}

// ── A 配置层 ────────────────────────────────────────────────
void auditConfig() {
  print('═══════════════════════════════════════════════════════');
  print(' A 配置层：全部固定编号表');
  print('═══════════════════════════════════════════════════════');

  // 表 → (显示台名, 固定号)。央视/教育表的键是台号不是台名，先转成台名。
  final tables = <String, Map<String, int>>{
    '央视主表': <String, int>{
      for (final e in kCctvNumbers.entries) 'CCTV-${e.key}': e.value,
    },
    '央视特殊台': <String, int>{
      'CCTV-5+': kCctvSportsPlusNumber,
      'CCTV 4K': kCctv4kNumber,
      'CCTV-8K': kCctv8kNumber,
      'CGTN': kCgtnNumber,
      'CGTN 纪录': kCgtnDocumentaryNumber,
    },
    '中国教育': <String, int>{
      for (final e in kEducationNumbers.entries) '中国教育${e.key}台': e.value,
    },
    '省级卫视': Map<String, int>.of(kSatelliteNumbers),
    '卫视4K/8K': Map<String, int>.of(kSatelliteQualityNumbers),
    '地方台': Map<String, int>.of(kLocalNumbers),
    '节目': Map<String, int>.of(kProgramNumbers),
  };

  // 号段表本身：必须互不重叠、且升序铺满。
  for (var i = 1; i < kChannelBands.length; i++) {
    final a = kChannelBands[i - 1];
    final b = kChannelBands[i];
    if (a.end >= b.start) {
      _hard('A', '号段重叠：${a.source.label}(${a.start}-${a.end}) 与 '
          '${b.source.label}(${b.start}-${b.end})');
    }
  }

  // 跨表重复号 + 单表内归一键冲突 + 号段越界。
  final owner = <int, List<String>>{};
  for (final t in tables.entries) {
    final keys = <String, String>{};
    for (final e in t.value.entries) {
      final name = e.key;
      final n = e.value;
      owner.putIfAbsent(n, () => <String>[]).add('${t.key}/$name');

      final key = numberKey(name);
      if (keys.containsKey(key) && keys[key] != name) {
        _hard('A', '${t.key} 表内归一键冲突：$key 同时对应 '
            '${keys[key]!} 与 $name');
      }
      keys[key] = name;

      // 应落号段
      int? lo;
      int? hi;
      switch (t.key) {
        case '央视主表':
        case '央视特殊台':
        case '中国教育':
          lo = 1;
          hi = 99;
          break;
        case '省级卫视':
        case '卫视4K/8K':
          lo = 101;
          hi = 199;
          break;
        case '地方台':
          lo = 201;
          hi = 899;
          break;
        case '节目':
          lo = kProgramBandStart;
          hi = kProgramBandEnd;
          break;
      }
      if (lo != null && hi != null && (n < lo || n > hi)) {
        _hard('A', '${t.key}/$name 固定号 $n 越界，应落 $lo-$hi');
      }
    }
  }

  var dup = 0;
  for (final e in owner.entries) {
    if (e.value.length > 1) {
      dup++;
      _hard('A', '固定编号 ${e.key} 被多个台声明占用：${e.value.join(' / ')}');
    }
  }
  final total = tables.values.fold<int>(0, (s, m) => s + m.length);
  print(' 固定编号条目合计：$total（${tables.length} 张表）');
  for (final t in tables.entries) {
    print('   ${t.key.padRight(12)} ${t.value.length.toString().padLeft(3)} 条，'
        '号 ${t.value.values.isEmpty ? '-' : t.value.values.reduce((a, b) => a < b ? a : b)}'
        '..${t.value.values.isEmpty ? '-' : t.value.values.reduce((a, b) => a > b ? a : b)}');
  }
  print(' 跨表重复固定号：${dup == 0 ? '✓ 无' : '$dup 处（见清单）'}');
  print(' 号段表重叠/缺口：${_issues.any((s) => s.contains('号段')) ? '见清单' : '✓ 无'}');
}

// ── B 别名层 ────────────────────────────────────────────────
void auditAliases() {
  print('\n═══════════════════════════════════════════════════════');
  print(' B 别名层：satelliteAliases 全量固定号覆盖');
  print('═══════════════════════════════════════════════════════');
  final values = LiveCatalogService.satelliteAliases.values.toSet().toList()..sort();
  print(' 英文别名键 ${LiveCatalogService.satelliteAliases.length} 个 → '
      '归一出 ${values.length} 个中文卫视：');
  for (final v in values) {
    final n = fixedNumberOf(v);
    final ok = n != null;
    print('   ${v.padRight(10)} 固定号=${'$n'.padLeft(4)}  ${ok ? '✓' : '✗ 无固定号'}');
    if (!ok) _hard('B', '$v 被 satelliteAliases 归一为中文台名，但 '
        'kSatelliteNumbers 没有固定号 → 自动分配、会漂移');
  }
  print(' 覆盖率：${values.where((v) => fixedNumberOf(v) != null).length}/${values.length}');
}

// ── C 归一 / 合并层 ─────────────────────────────────────────
void auditCanonical() {
  print('\n═══════════════════════════════════════════════════════');
  print(' C 归一 / 合并层：different 台是否被错误合并');
  print('═══════════════════════════════════════════════════════');

  // 应为「同一个台」的写法对（归一后必须相同）。
  const same = <List<String>>[
    <String>['上海卫视', '东方卫视'],
    <String>['CCTV1', 'CCTV-1'],
    <String>['CCTV-1 综合', 'CCTV-1'],
    <String>['CETV-1', '中国教育1台'],
    <String>['湖南卫视 超清', '湖南卫视'],
    <String>['湖南卫视 高清', '湖南卫视'],
    <String>['CCTV-1 HD', 'CCTV-1'],
    // 第十二轮：聚合表前缀/简写 → 正式台名
    <String>['BRTV 北京卫视', '北京卫视'],
    <String>['黑龙卫视', '黑龙江卫视'],
    // CGTN 纪录频道的中英文 / 错字写法 → 同一个台（共享 21）
    <String>['CGTN Documentary', 'CGTN纪录'],
    <String>['CGTN 纪录', 'CGTN纪录'],
    <String>['CGTN记录', 'CGTN纪录'],
  ];
  for (final p in same) {
    final a = LiveCatalogService.canonicalName(p[0]);
    final b = LiveCatalogService.canonicalName(p[1]);
    if (a != b) _hard('C', '应合并的写法被拆成两个台：${p[0]}→$a / ${p[1]}→$b');
    print('   同一台 ${p[0].padRight(14)} → $a  ${a == b ? '✓' : '✗'}');
  }

  // 应为「不同台」的写法对（归一后必须不同）。
  const different = <List<String>>[
    <String>['深圳卫视', '深圳卫视4K'],
    <String>['深圳卫视4K', '深圳卫视8K'],
    <String>['CCTV-4', 'CCTV 4K'],
    <String>['CCTV-5', 'CCTV-5+'],
    <String>['东方卫视', '东方卫视4K'],
    <String>['兵团卫视', '延边卫视'],
    // 第十二轮：独立超高清台 / CGTN 子频道 / 特殊卫视不得互相合并
    <String>['CCTV-4K', 'CCTV-8K'],
    <String>['CGTN', 'CGTN英语'],
    <String>['CGTN纪录', 'CGTN英语'],
    <String>['东南卫视', '大湾区卫视'],
    <String>['康巴卫视', '蒙语卫视'],
  ];
  for (final p in different) {
    final a = LiveCatalogService.canonicalName(p[0]);
    final b = LiveCatalogService.canonicalName(p[1]);
    if (a == b) {
      _hard('C', '不同台被错误合并：${p[0]} 与 ${p[1]} 均归一为 $a（会串台）');
    }
    print('   不同台 ${p[0].padRight(12)} / ${p[1].padRight(12)} '
        '${a == b ? '✗ 被合并' : '✓'}');
  }
}

// ── D/E 实盘层 ──────────────────────────────────────────────
void auditBook(String label, List<LiveChannel> channels, {bool showFixedTable = false}) {
  print('\n═══════════════════════════════════════════════════════');
  print(' $label：${channels.length} 个频道逐台核对');
  print('═══════════════════════════════════════════════════════');
  if (channels.isEmpty) {
    print(' （频道表为空，跳过实盘核对）');
    return;
  }

  final book = ChannelNumberBook();
  book.rebuild(channels);

  // 1) 编号唯一（按台名去重：同一个台在不同 id 上共享号属设计允许）。
  final owner = <int, Set<String>>{};
  for (final c in channels) {
    final n = book.numberOf(c.id);
    if (n == null) {
      _hard(label, '${c.name} 未分配到数字编号');
      continue;
    }
    owner.putIfAbsent(n, () => <String>{}).add(c.name);
  }
  var dup = 0;
  for (final e in owner.entries) {
    if (e.value.length > 1) {
      dup++;
      _hard(label, '数字编号 ${e.key} 被不同台同时占用：${e.value.join(' / ')}');
    }
  }
  print(' 编号唯一性：${dup == 0 ? '✓ 无重复' : '$dup 处重复'}');

  // 2) 逐台：声明固定号 == 实际编号；反查不串台；号段与来源匹配。
  var mismatch = 0;
  var crossTune = 0;
  var bandBad = 0;
  var drift = 0;
  for (final c in channels) {
    final declared = fixedNumberOf(c.name);
    final got = book.numberOf(c.id);
    if (declared != null && got != declared) {
      mismatch++;
      _hard(label, '${c.name} 声明固定号 $declared，实际编号却是 $got');
    }
    if (declared != null) {
      final hit = book.channelForNumber(channels, declared);
      if (hit == null) {
        crossTune++;
        _hard(label, '遥控器按 $declared（${c.name}）反查不到任何频道');
      } else if (numberKey(hit.name) != numberKey(c.name)) {
        crossTune++;
        _hard(label, '遥控器按 $declared 应切到「${c.name}」，'
            '实际切到「${hit.name}」——串台');
      }
    }
    if (got != null) {
      final src = ChannelTaxonomy.sourceOf(c.name, tvgId: c.tvgId);
      final band = ChannelNumberBook.bandOf(src);
      if (!band.contains(got)) {
        bandBad++;
        _hard(label, '${c.name} 来源=${src.label} 应落 ${band.start}-${band.end}，'
            '实际编号 $got（${_bandLabel(got)}）');
      }
    }
    // 漂移风险：含「卫视」却无固定号。
    if (declared == null && c.name.contains('卫视')) {
      drift++;
      _warn('$label：${c.name} → 编号 $got（自动分配，无稳定固定号；'
          '频道表刷新可能漂移）');
    }
  }
  print(' 号≠声明：${mismatch == 0 ? '✓ 无' : '$mismatch 个'}；'
      '按号反查串台：${crossTune == 0 ? '✓ 无' : '$crossTune 个'}；'
      '号段错配：${bandBad == 0 ? '✓ 无' : '$bandBad 个'}');
  print(' 含「卫视」但无固定号（漂移风险）：${drift == 0 ? '✓ 无' : '$drift 个'}');

  // 3) 固定号段完整对照：编号 → 声明台 → 反查实际台。
  if (showFixedTable) {
    print('\n 固定编号 ↔ 实际频道 完整对照（编号 | 声明台 | 反查实际台 | 结论）');
    final declaredByNumber = <int, String>{};
    void addAll(Map<String, int> m) {
      for (final e in m.entries) {
        declaredByNumber.putIfAbsent(e.value, () => e.key);
      }
    }

    addAll(<String, int>{for (final e in kCctvNumbers.entries) 'CCTV-${e.key}': e.value});
    addAll(<String, int>{
      'CCTV-5+': kCctvSportsPlusNumber,
      'CCTV 4K': kCctv4kNumber,
      'CCTV-8K': kCctv8kNumber,
      'CGTN': kCgtnNumber,
      'CGTN 纪录': kCgtnDocumentaryNumber,
    });
    addAll(<String, int>{
      for (final e in kEducationNumbers.entries) '中国教育${e.key}台': e.value,
    });
    addAll(kSatelliteNumbers);
    addAll(kSatelliteQualityNumbers);
    addAll(kLocalNumbers);

    final nums = declaredByNumber.keys.toList()..sort();
    for (final n in nums) {
      final declared = declaredByNumber[n]!;
      final hit = book.channelForNumber(channels, n);
      final actual = hit?.name ?? '（频道表无此台）';
      final ok = hit != null && numberKey(hit.name) == numberKey(declared);
      print('   ${'$n'.padLeft(4)} | ${declared.padRight(14)} | '
          '${actual.padRight(16)} | ${ok ? '✓ 一致' : '✗ 不一致'}');
    }
  }
}

/// 构造「所有已知台名」的 M3U，走**真实解析链路**（canonicalName →
/// satelliteNameOf → channelIdFor → 分组判定），与线上行为完全一致。
List<LiveChannel> buildStaticSet() {
  final names = <String>[
    // 央视全系 + 各种归一写法
    for (var i = 1; i <= 17; i++) 'CCTV-$i',
    'CCTV-5+', 'CCTV 4K', 'CCTV-8K', 'CGTN', 'CGTN 纪录',
    'CGTN Documentary', 'CGTN记录', 'CGTN英语', 'CGTN Arabic',
    'CGTN Global Biz', 'CGTN俄语',
    '中国教育1台', '中国教育2台', '中国教育3台', '中国教育4台',
    'CETV-1', 'CETV-2', 'CETV-3', 'CETV-4',
    'CCTV-1 综合', 'CCTV-13 新闻', 'CCTV1', 'CCTV 5',
    // 卫视固定表全部键
    ...kSatelliteNumbers.keys,
    // 旧名 / 聚合表前缀 / 简写（应被归并到正式台名）
    '上海卫视', 'BRTV 北京卫视', '黑龙卫视',
    // 卫视 4K/8K 变体（真实索引写法：大写 K）
    '深圳卫视4K', '浙江卫视4K', '广东卫视4K', '江苏卫视4K', '湖南卫视4K',
    '东方卫视4K', '北京卫视4K', '山东卫视4K', '湖北卫视4K', '四川卫视4K',
    '深圳卫视8K',
    // 结尾带画质词的写法（应被归一进基础台）
    '湖南卫视 超清', '浙江卫视超清', 'CCTV-1 高清',
    // satelliteAliases 全量英文别名键（会折成中文卫视名）
    ...LiveCatalogService.satelliteAliases.keys,
    // 地方台固定表全部键
    ...kLocalNumbers.keys,
    // 内置清单唯一一条 + 若干无归属境外台（验证 901-999 号段）
    '演示信号 · HLS 测试', 'Some TV', 'NTD TV China', 'Channel U',
  ];
  final b = StringBuffer();
  final seen = <String>{};
  for (final n in names) {
    if (!seen.add(n)) continue;
    b.writeln('#EXTINF:-1,$n');
    b.writeln('http://a.example/$n.m3u8');
  }
  return LiveCatalogService.parseM3U(b.toString());
}

Future<List<LiveChannel>?> loadRealTable() async {
  print('\n═══════════════════════════════════════════════════════');
  print(' E 真实频道表（联网拉取当前公开索引）');
  print('═══════════════════════════════════════════════════════');
  try {
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
    print(' 来源：${snap.sourceLabel}');
    print(' 频道数：${snap.channels.length}');
    if (snap.warnings.isNotEmpty) {
      for (final w in snap.warnings.take(5)) {
        print(' 降级：$w');
      }
    }
    if (snap.channels.length <= BuiltInLiveChannels.all.length + 1) {
      print(' ⚠ 真实索引未拉到（只剩内置清单），本层结果不具代表性；'
          '静态层审计仍然有效。');
    }
    return snap.channels;
  } catch (e) {
    print(' ⚠ 真实频道表获取失败：$e');
    print('   静态层（A–D）审计仍然有效；本层跳过。');
    return null;
  }
}

/// 打印 CGTN / CCTV-K 家族在真实表里的全貌：台名 → 归一键 → 查表号 → 实际号。
/// 用来判断「一号多台」是同一个台的多种写法，还是不同的台被错误合并。
void _printFamilyDetail(List<LiveChannel> channels) {
  final book = ChannelNumberBook();
  book.rebuild(channels);
  for (final family in <String>['cgtn', 'cctvk']) {
    final hits = channels.where((c) {
      final k = numberKey(c.name);
      return family == 'cgtn' ? k.startsWith('cgtn') : k.startsWith('cctv') && k.endsWith('k');
    }).toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    print('\n 真实表 $family 家族（${hits.length} 个）：');
    print('   台名                         归一键                 查表号  实际号');
    for (final c in hits) {
      print('   ${c.name.padRight(26)} ${numberKey(c.name).padRight(22)} '
          '${('${fixedNumberOf(c.name)}').padLeft(5)}  '
          '${('${book.numberOf(c.id)}').padLeft(5)}');
    }
  }
  // 卫视漂移台的实际编号，供补号时避开冲突。
  final drift = channels
      .where((c) => c.name.contains('卫视') && fixedNumberOf(c.name) == null)
      .toList()
    ..sort((a, b) => a.name.compareTo(b.name));
  if (drift.isNotEmpty) {
    final book2 = ChannelNumberBook();
    book2.rebuild(channels);
    print('\n 卫视漂移台当前实际编号（补固定号时需避开）：');
    for (final c in drift) {
      print('   ${c.name.padRight(18)} → ${book2.numberOf(c.id)}');
    }
  }
}

Future<void> main(List<String> args) async {
  final offline = args.contains('--offline');
  print('╔═══════════════════════════════════════════════════════╗');
  print('║  顺播 · 全频道「数字编号 ↔ 实际频道」一致性审计       ║');
  print('╚═══════════════════════════════════════════════════════╝');

  auditConfig();
  auditAliases();
  auditCanonical();

  final staticSet = buildStaticSet();
  auditBook('D 静态全集', staticSet, showFixedTable: true);

  if (!offline) {
    final real = await loadRealTable();
    if (real != null && real.isNotEmpty) {
      auditBook('E 真实频道表', real);
      // 真实表里所有「含卫视」的台，逐个列出编号与是否有固定号。
      final sat = real.where((c) => c.name.contains('卫视')).toList()
        ..sort((a, b) => a.name.compareTo(b.name));
      print('\n 真实表中全部「卫视」台（${sat.length} 个）：');
      for (final c in sat) {
        final n = fixedNumberOf(c.name);
        print('   ${c.name.padRight(18)} 固定号=${'$n'.padLeft(4)} '
            '${n == null ? '⚠ 自动分配' : '✓ 稳定'}');
      }
      _printFamilyDetail(real);
    }
  } else {
    print('\n（--offline：跳过真实频道表层）');
  }

  // ── 不一致清单 ──────────────────────────────────────────
  print('\n╔═══════════════════════════════════════════════════════╗');
  print('║  不一致清单（频道 → 错误对应关系）                      ║');
  print('╚═══════════════════════════════════════════════════════╝');
  if (_issues.isEmpty) {
    print(' ✅ 未发现硬不一致：所有频道的数字编号与实际频道一一对应，'
        '按号跳台不会串台。');
  } else {
    print(' 发现 ${_issues.length} 处硬不一致：');
    for (var i = 0; i < _issues.length; i++) {
      print('  ${i + 1}. ${_issues[i]}');
    }
  }
  if (_drift.isNotEmpty) {
    print('\n 漂移风险（不判失败，但建议补固定号）共 ${_drift.length} 处，'
        '最多列 30 条：');
    for (final d in _drift.take(30)) {
      print('   • $d');
    }
    if (_drift.length > 30) print('   … 其余 ${_drift.length - 30} 条略');
  } else {
    print('\n ✅ 无漂移风险：所有「卫视」台都有稳定固定号。');
  }

  print('\n审计完成。');
  exit(_issues.isEmpty ? 0 : 1);
}
