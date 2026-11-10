// 生成《频道分类与数字编号对照表》文档。
//
// 用法：
//   dart run tooling/gen_channel_numbering_doc.dart            # 联网取真实频道表
//   dart run tooling/gen_channel_numbering_doc.dart --offline  # 只出配置部分
//
// 文档里的「实际频道清单」来自真实公开索引，因此每次生成的结果会随
// 索引内容变化；**配置本身**（号段、固定编号、来源策略）是写死在代码里的，
// 见 `lib/features/live/channel_numbering.dart` 与 `channel_taxonomy.dart`。
import 'dart:io';

import 'package:shunbo/features/live/channel_numbering.dart';
import 'package:shunbo/features/live/channel_taxonomy.dart';
import 'package:shunbo/features/live/live_catalog.dart';
import 'package:shunbo/features/live/live_channel.dart';

const String outPath = 'docs/channel-numbering.md';

String _srcOf(LiveChannel c) =>
    ChannelTaxonomy.sourceOf(c.name, tvgId: c.tvgId).label;

String _buildDoc(List<LiveChannel>? channels) {
  final b = StringBuffer();
  b.writeln('# 频道分类与数字编号对照表');
  b.writeln('');
  b.writeln('> 本表由 `dart run tooling/gen_channel_numbering_doc.dart` 生成，');
  b.writeln('> 配置源头是 `lib/features/live/channel_taxonomy.dart`（来源与分类策略）');
  b.writeln('> 与 `lib/features/live/channel_numbering.dart`（号段与固定编号）。');
  b.writeln('');

  // ── 一、号段 ────────────────────────────────────────────
  b.writeln('## 一、数字号段');
  b.writeln('');
  b.writeln('| 号段 | 内容来源 | 覆盖范围 |');
  b.writeln('| --- | --- | --- |');
  for (final band in kChannelBands) {
    b.writeln('| ${band.start} – ${band.end} | ${band.source.label} | '
        '${band.source == ChannelSource.cctv ? 'CCTV / CGTN / 中国教育' : ''}'
        '${band.source == ChannelSource.satellite ? '省级卫视' : ''}'
        '${band.source == ChannelSource.local ? '省市地方台' : ''}'
        '${band.source == ChannelSource.web ? '全网其它视频源' : ''} |');
  }
  b.writeln('| $kProgramBandStart – $kProgramBandEnd | 节目 | 点播条目（电影 / 剧集 / 纪录片） |');
  b.writeln('| $kEpisodeBandStart – $kEpisodeBandEnd | 节目分集 | 1100 + 节目序号 × 10 + 集号 |');
  b.writeln('');
  b.writeln('**央视一套 = 数字编号 1**（需求硬性要求）。'
      '央视 1–17 依次对应 1–17；`CCTV-5+`（体育赛事）= 18；'
      '`CCTV 4K`（超高清）= 19；`CGTN` = 20；`CGTN 纪录` = 21；'
      '`中国教育 1–4` = 22–25；`CCTV-8K`（8K 超高清）= $kCctv8kNumber。');
  b.writeln('');

  // ── 二、分类来源策略 ────────────────────────────────────
  b.writeln('## 二、频道分类与内容来源的对应关系');
  b.writeln('');
  b.writeln('分类是**可叠加**的：一个台有「主分类」（按来源归属）与'
      '「内容分类」（按节目类型）。频道栏的分类过滤用的是两者的并集。');
  b.writeln('');
  b.writeln('| 分类 | 收录的内容来源 | 说明 |');
  b.writeln('| --- | --- | --- |');
  b.writeln('| 全部 | 全部 | 默认视图 |');
  b.writeln('| 央视频道 | 央视 | CCTV / CGTN / 中国教育 1–4 |');
  b.writeln('| 卫视频道 | 卫视 | 省级卫视 |');
  b.writeln('| 地方频道 | 地方 | 省市地方台（按 IP 定位城市过滤） |');
  for (final g in ChannelTaxonomy.thematicGroups) {
    final sources = ChannelTaxonomy.categorySources[g]!;
    final names = sources.map((s) => s.label).join(' + ');
    b.writeln('| $g | $names | 内容分类，与主分类叠加 |');
  }
  b.writeln('');
  b.writeln('> 需求原文：「新闻、少儿、体育三个分类频道的内容来源覆盖央视、卫视、地方三类频道；'
      '纪实分类频道的内容来源为央视及全网其它视频源；'
      '除上述已列来源之外的其它来源视频统一归入『其它』频道。」');
  b.writeln('');

  // ── 三、固定编号表 ──────────────────────────────────────
  b.writeln('## 三、固定编号表');
  b.writeln('');
  // 直接从配置常量生成，避免改了固定表却忘了同步文档（实测曾留下 109 重复）。
  final cctvFixed = <String, int>{
    for (final e in kCctvNumbers.entries) 'CCTV-${e.key}': e.value,
    'CCTV-5+ 体育赛事': kCctvSportsPlusNumber,
    'CCTV 4K 超高清': kCctv4kNumber,
    'CCTV-8K 超高清': kCctv8kNumber,
    'CGTN 综合': kCgtnNumber,
    'CGTN 纪录': kCgtnDocumentaryNumber,
    for (final e in kEducationNumbers.entries) '中国教育${e.key}台': e.value,
  };
  final cctvEntries = cctvFixed.entries.toList()
    ..sort((a, b) => a.value.compareTo(b.value));
  b.writeln('### 3.1 央视（1–${cctvEntries.last.value}）');
  b.writeln('');
  b.writeln('| 编号 | 频道 | 编号 | 频道 |');
  b.writeln('| --- | --- | --- | --- |');
  for (var i = 0; i < cctvEntries.length; i += 2) {
    final a = <String>['${cctvEntries[i].value}', cctvEntries[i].key];
    final bb = i + 1 < cctvEntries.length
        ? <String>['${cctvEntries[i + 1].value}', cctvEntries[i + 1].key]
        : <String>['—', '—'];
    b.writeln('| ${a[0]} | ${a[1]} | ${bb[0]} | ${bb[1]} |');
  }
  b.writeln('');
  b.writeln('> 中国教育电视台（CETV）是**国家级教育台**，属于央视体系，'
      '索引里挂在「卫视频道」下的 `中国教育1台`–`中国教育4台` 已改归央视频道，'
      '并与 iptv-org 目录里的 `CETV-1`–`CETV-4` 合并成同四个台。');
  b.writeln('> `CCTV 4K`(=19) 与 `CCTV-8K`(=$kCctv8kNumber) 是**两个不同的台**：'
      '旧实现把任何 `cctvNk` 都当成 4K 台返回 19，导致二者抢号。');
  b.writeln('> CGTN 各语种子频道（英语 / 俄语 / 法语 / 西语 / 阿语 / Global Biz…）'
      '也是**不同的台**，只有「综合」= 20、「纪录」= 21 有固定号，'
      '其余走央视号段稳定分配（首次分配即落盘）。');
  b.writeln('');

  b.writeln('### 3.2 省级卫视与特殊卫视（101–160）');
  b.writeln('');
  b.writeln('| 编号 | 频道 | 编号 | 频道 |');
  b.writeln('| --- | --- | --- | --- |');
  final satEntries = kSatelliteNumbers.entries.toList()
    ..sort((a, b) => a.value.compareTo(b.value));
  final satRows = <List<String>>[
    for (final e in satEntries) <String>['${e.value}', e.key],
  ];
  for (var i = 0; i < satRows.length; i += 2) {
    final a = satRows[i];
    final bb = i + 1 < satRows.length ? satRows[i + 1] : <String>['—', '—'];
    b.writeln('| ${a[0]} | ${a[1]} | ${bb[0]} | ${bb[1]} |');
  }
  b.writeln('');
  b.writeln('> 101–135 按 GB/T 2260 省级行政区划顺序；旧名「上海卫视」'
      '在 `canonicalName` 阶段归一成「东方卫视」，只保留一个 109，不再双列。');
  b.writeln('> 136–140 与 160 是真实公开索引里出现、但不属于省级序列的卫视'
      '（兵团 / 延边 / 东南 / 大湾区 / 康巴 / 蒙语）。它们原先走自动分配，'
      '实测号码会随索引刷新漂移（134 / 135 / 138 / 139 / 140），现统一给固定号。');
  b.writeln('> 聚合表里的 `BRTV 北京卫视`、`黑龙卫视` 分别是「北京卫视」'
      '「黑龙江卫视」的同一台写法，已归一合并，不另给号。');
  b.writeln('');

  b.writeln('### 3.3 卫视 4K / 8K 画质变体（141–159）');
  b.writeln('');
  b.writeln('| 编号 | 频道 |');
  b.writeln('| --- | --- |');
  final qEntries = kSatelliteQualityNumbers.entries.toList()
    ..sort((a, b) => a.value.compareTo(b.value));
  for (final e in qEntries) {
    b.writeln('| ${e.value} | ${e.key} |');
  }
  b.writeln('');
  b.writeln('> 4K / 8K 后缀是**独立频道身份**（刻意不削），与基础台不同号。'
      '结尾带「超清 / 高清」的写法则会被 `canonicalName` 归一进基础台，'
      '不在此列。这些变体原先无固定号、号码会漂移，现固定并预留 141–159。');
  b.writeln('');

  b.writeln('### 3.4 地方台固定编号（201 起）');
  b.writeln('');
  b.writeln('| 编号 | 频道 |');
  b.writeln('| --- | --- |');
  final localEntries = kLocalNumbers.entries.toList()
    ..sort((a, b) => a.value.compareTo(b.value));
  for (final e in localEntries) {
    b.writeln('| ${e.value} | ${e.key} |');
  }
  b.writeln('');
  b.writeln('> 其余地方台在 215–899 区间内按台名**稳定分配**：'
      '首次分配即落盘（`channel-numbers.json`），同一个台永远同一个号，'
      '索引新增或镜像变动都不会挤掉老台的号码。');
  b.writeln('');

  b.writeln('### 3.5 节目（点播条目）');
  b.writeln('');
  b.writeln('| 编号 | 节目 |');
  b.writeln('| --- | --- |');
  final progEntries = kProgramNumbers.entries.toList()
    ..sort((a, b) => a.value.compareTo(b.value));
  for (final e in progEntries) {
    b.writeln('| ${e.value} | ${e.key} |');
  }
  b.writeln('');

  // ── 四、遥控器 ──────────────────────────────────────────
  b.writeln('## 四、遥控器数字输入（Android TV）');
  b.writeln('');
  b.writeln('* **逐位累积**：按 `1` 立刻切到 CCTV-1；继续按 `0` 会在 1.5 秒内'
      '等成 `10`；超时未继续按就把已输入的数字当成完整编号提交。');
  b.writeln('* **确认键立即提交**：按「确认 / OK」不用等超时。');
  b.writeln('* **返回键取消**：按「返回 / ESC」放弃本次输入。');
  b.writeln('* 界面上给出「**编号 + 台名**」浮层，逐字确认输到了哪一步、跳到了哪个台。');
  b.writeln('* 数字输入走的是与点台**完全相同**的调台流程'
      '（`LiveController.tuneByNumber` → `tune`），不另开一条播放路径。');
  b.writeln('* 安卓清单已声明 `leanback` / `touchscreen` 非必需并注册 '
      '`LEANBACK_LAUNCHER`，电视端可安装、可被启动器检索。');
  b.writeln('');

  // ── 五、实际频道清单 ────────────────────────────────────
  if (channels == null || channels.isEmpty) {
    b.writeln('## 五、实际频道清单');
    b.writeln('');
    b.writeln('> 本次以离线模式生成，未拉取远端索引，故不含实际清单。');
    b.writeln('');
    return b.toString();
  }

  final book = ChannelNumberBook();
  book.rebuild(channels);

  final byCategory = <String, List<LiveChannel>>{};
  for (final c in channels) {
    final cats = c.categories.isEmpty ? <String>[c.group] : c.categories;
    for (final g in cats) {
      byCategory.putIfAbsent(g, () => <LiveChannel>[]).add(c);
    }
  }

  b.writeln('## 五、实际频道清单');
  b.writeln('');
  final numbered = channels.where((c) => book.numberOf(c.id) != null).length;
  b.writeln('共 **${channels.length}** 个频道，其中 **$numbered** 个已分配数字编号。');
  b.writeln('');
  for (final group in <String>[
    '央视频道',
    '卫视频道',
    '地方频道',
    ...ChannelTaxonomy.thematicGroups,
    '其它频道',
  ]) {
    final list = byCategory[group];
    if (list == null || list.isEmpty) continue;
    final sorted = list.toList()
      ..sort((a, b) {
        final na = book.numberOf(a.id) ?? 99999;
        final nb = book.numberOf(b.id) ?? 99999;
        return na != nb ? na.compareTo(nb) : a.name.compareTo(b.name);
      });
    b.writeln('### $group（${sorted.length} 个台）');
    b.writeln('');
    b.writeln('| 编号 | 频道 | 来源 | 其它分类 | 线路数 |');
    b.writeln('| --- | --- | --- | --- | --- |');
    for (final c in sorted) {
      final others = (c.categories.isEmpty ? <String>[c.group] : c.categories)
          .where((g) => g != group)
          .join(' / ');
      b.writeln('| ${book.numberOf(c.id) ?? '-'} | ${c.name} | ${_srcOf(c)} | '
          '${others.isEmpty ? '—' : others} | ${c.streams.length} |');
    }
    b.writeln('');
  }
  return b.toString();
}

Future<void> main(List<String> args) async {
  final offline = args.contains('--offline');
  List<LiveChannel>? channels;
  if (!offline) {
    try {
      final service = LiveCatalogService(
        builtIn: BuiltInLiveChannels.all,
        remotePlaylistUrls: kDefaultLiveIndexUrls,
        streamIndexUrl: kDefaultStreamIndexUrl,
        streamIndexUrls: kDefaultStreamIndexUrls,
        citySupplementUrls: kDefaultCitySupplementUrls,
        discoverySources: kDefaultDiscoverySources,
      );
      final snap = await service.load(remote: true);
      channels = snap.channels;
      print('已拉取 ${channels.length} 个频道（${snap.sourceLabel}）');
    } catch (e) {
      print('拉取失败，退回离线模式：$e');
    }
  }

  final doc = _buildDoc(channels);
  final out = File(outPath);
  out.parent.createSync(recursive: true);
  out.writeAsStringSync(doc);
  print('已生成：${out.path}（${doc.length} 字符）');
}
