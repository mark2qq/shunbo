// 内置索引（第 1 项）回归：打包产物 ↔ Dart 解析器的双向一致性。
//
// 为什么必须交叉校验：索引由 Python 打包、由 Dart 读取。两侧的词表、
// 前端编码的截取口径、分片归属只要有一处不同，就会出现「App 里搜不到」
// 或「搜到了点不开」，而且症状极隐蔽（只是少几条）。这里用**真实的
// 打包产物**（assets/vod_index/*.tsv.gz）跑断言，不是造样本。
//
// 运行：dart run tooling/verify_vod_builtin_index.dart
import 'dart:convert';
import 'dart:io';

import 'package:shunbo/features/vod/vod_builtin_index.dart';
import 'package:shunbo/features/vod/vod_catalog.dart';
import 'package:shunbo/features/vod/vod_facets.dart';

int _pass = 0;
int _fail = 0;
final List<String> _failures = <String>[];

void check(String name, bool ok, [String detail = '']) {
  if (ok) {
    _pass++;
  } else {
    _fail++;
    _failures.add(detail.isEmpty ? name : '$name —— $detail');
    stdout.writeln('  FAIL $name${detail.isEmpty ? '' : ' —— $detail'}');
  }
}

String readText(String p) => File(p).readAsStringSync();

void main() {
  const dir = 'assets/vod_index';
  final manifestFile = File('$dir/manifest.json');
  if (!manifestFile.existsSync()) {
    stdout.writeln('缺 $dir/manifest.json —— 先跑 python tooling/pack_vod_index.py');
    exit(2);
  }

  // ── A. manifest 结构与自洽 ──
  final manifest = BuiltinIndexManifest.decode(readText(manifestFile.path));
  check('A01 manifest 可解析且版本匹配', manifest != null);
  if (manifest == null) {
    _report();
    return;
  }
  check('A02 非空索引（total>0 且至少一片）', !manifest.isEmpty,
      'total=${manifest.total} shards=${manifest.shards.length}');
  check('A03 sourceUrl 非空', manifest.sourceUrl.trim().isNotEmpty,
      manifest.sourceUrl);
  check('A04 站点表非空', manifest.sites.isNotEmpty,
      '${manifest.sites.length} 站');
  check('A05 类目字典非空', manifest.types.isNotEmpty,
      '${manifest.types.length} 个');
  check('A06 generatedAt 是真实时间（晚于 2026-01-01）',
      manifest.generatedAt.isAfter(DateTime.utc(2026, 1, 1)),
      manifest.generatedAt.toIso8601String());

  final sumRecords =
      manifest.shards.fold<int>(0, (a, s) => a + s.records);
  check('A07 分片条数之和 == manifest.total', sumRecords == manifest.total,
      '$sumRecords vs ${manifest.total}');
  check('A08 每个分片都有 sha256 与非零条数',
      manifest.shards.every((s) => s.sha256.length == 64 && s.records > 0));

  // 分片 key 必须都是合法 VodSection 名（除 other 也合法）
  final sectionNames = {for (final s in VodSection.values) s.name};
  final badKeys =
      manifest.shards.where((s) => !sectionNames.contains(s.key)).toList();
  check('A09 分片 key 全部对应真实 VodSection', badKeys.isEmpty,
      badKeys.map((e) => e.key).join(','));
  // 六个栏目最多六片，且不能重复
  final keys = manifest.shards.map((s) => s.key).toList();
  check('A10 分片 key 无重复', keys.toSet().length == keys.length,
      keys.join(','));
  check('A11 片数不超过栏目数', manifest.shards.length <= 6,
      '${manifest.shards.length}');

  // 每个片名最多留 N 条（`--keep-per-title`，默认 2）：留多条是为了
  // 主站回源失败时换源，留太多只是白占安装包体积。
  final rawJson = jsonDecode(readText(manifestFile.path));
  final titleCount = rawJson is Map ? (rawJson['titleCount'] as num?)?.toInt() : null;
  final keepN = rawJson is Map ? (rawJson['keepPerTitle'] as num?)?.toInt() : null;
  check('A12 manifest 记录了唯一片名数与每名上限',
      titleCount != null && keepN != null,
      'titleCount=$titleCount keepPerTitle=$keepN');
  if (titleCount != null && keepN != null) {
    check('A13 唯一片名数不超过总条数', titleCount <= manifest.total,
        '$titleCount vs ${manifest.total}');
    check('A14 总条数不超过「片名数 × 每名上限」',
        manifest.total <= titleCount * keepN,
        '${manifest.total} > $titleCount × $keepN');
  }

  // ── 类目名字表（1.0.5 第十五次修）──
  //
  // 背景：分片每行只有类目**下标**，manifest 原来只写 `types`（id 数组）。
  // App 回填 `VodItem.typeName` 时手上只有 id，界面上就出现「25」这种
  // 数字类型。现在多写两条平行表：`typeNames`（显示名）与
  // `typeSites`（该项属于哪个站）。
  check('A15 类目名字表与 id 表等长',
      manifest.typeNames.length == manifest.types.length,
      '${manifest.typeNames.length} vs ${manifest.types.length}');
  check('A16 类目站点表与 id 表等长',
      manifest.typeSites.length == manifest.types.length,
      '${manifest.typeSites.length} vs ${manifest.types.length}');
  final unnamed = manifest.typeNames.where((n) => n.isEmpty).length;
  check('A17 无名字的类目占比 < 10%（其余都能显示中文名）',
      manifest.types.isNotEmpty && unnamed * 10 < manifest.types.length,
      '$unnamed / ${manifest.types.length}');
  // (站点, 类目) 必须唯一：重复会让 typeNameOf 命中错的那一项。
  final combos = <String>{};
  for (var i = 0; i < manifest.types.length; i++) {
    combos.add('${manifest.typeSites[i]}:${manifest.types[i]}');
  }
  check('A18 (站点, 类目 id) 组合唯一', combos.length == manifest.types.length,
      '${combos.length} vs ${manifest.types.length}');

  // 同一个 type_id 在不同站有不同名字 —— 这正是「按站点查」的理由。
  final byTypeId = <String, Map<int, String>>{};
  for (var i = 0; i < manifest.types.length; i++) {
    final name = i < manifest.typeNames.length ? manifest.typeNames[i] : '';
    if (name.isEmpty) continue;
    byTypeId
        .putIfAbsent(manifest.types[i], () => <int, String>{})[manifest.typeSites[i]] =
        name;
  }
  String? sharedId;
  for (final e in byTypeId.entries) {
    if (e.value.values.toSet().length > 1) {
      sharedId = e.key;
      break;
    }
  }
  check('A19 存在跨站同 id 不同名的类目（按站点查才有意义）',
      sharedId != null, '未找到（数据退化，断言失去意义）');
  if (sharedId != null) {
    final names = byTypeId[sharedId]!;
    var ok = true;
    for (final e in names.entries) {
      if (manifest.typeNameOf(e.key, sharedId) != e.value) {
        ok = false;
      }
    }
    check('A20 同 id 按站点查到各自的正确名字', ok,
        'id=$sharedId ${names.entries.map((e) => '${e.key}->${e.value}').join(' ')}');
  }
  check('A21 查不到的类目返回空串而不是数字 id',
      manifest.typeNameOf(0, 'definitely-not-a-type') == '');
  // v2 的地区词表：必须非空，且**只能**出现 Dart 侧认识的规范词。
  // 打包侧自创一个词（比如把 `中国大陆` 原样落盘），App 里就会多出一行
  // 点下去筛不到任何东西的地区 —— 这类错不报错，只是白点。
  final vocab = kVodAreaVocabulary.toSet();
  check('A22 manifest 地区词表非空且都在 Dart 规范词表内',
      manifest.areas.isNotEmpty && manifest.areas.every(vocab.contains),
      manifest.areas.join('/'));
  check('A23 地区词表没有重复项',
      manifest.areas.toSet().length == manifest.areas.length,
      manifest.areas.join('/'));

  // ── B. 逐片解压 + 前端编码还原 ──
  var totalLines = 0;
  var totalHits = 0;
  final namesSample = <String>[];
  for (final shard in manifest.shards) {
    final f = File('$dir/${shard.file}');
    check('B01[${shard.key}] 分片文件存在', f.existsSync(), f.path);
    if (!f.existsSync()) continue;
    final gzBytes = f.readAsBytesSync();
    check('B02[${shard.key}] gz 字节数与 manifest 一致',
        gzBytes.length == shard.gzBytes,
        '${gzBytes.length} vs ${shard.gzBytes}');

    final body = decodeShardBody(gzBytes);
    final scanner = BuiltinIndexScanner(manifest: manifest, sectionKey: shard.key);
    // 「全命中」= 逐行还原但不做片名过滤，用来核对行数与还原正确性
    final all = scanner.scan(body, match: (_, __) => true).hits;
    check('B03[${shard.key}] 行数 == manifest.records', all.length == shard.records,
        '${all.length} vs ${shard.records}');
    totalLines += all.length;

    // 片名非空、无 tab、不含控制字符
    var badName = 0;
    for (final h in all) {
      if (h.name.trim().isEmpty) badName++;
      if (h.name.contains('\t')) badName++;
      if (h.name.codeUnits.any((c) => c < 0x20)) badName++;
    }
    check('B04[${shard.key}] 还原后的片名全部干净', badName == 0,
        '$badName 条异常');

    // 站点下标必须在范围内
    final badSite =
        all.where((h) => h.siteIndex < 0 || h.siteIndex >= manifest.sites.length);
    check('B05[${shard.key}] 站点下标全部有效', badSite.isEmpty,
        '${badSite.length} 条越界');

    // 片名递增（前端编码要求按片名排序，这是解码正确的前提）
    var outOfOrder = 0;
    for (var i = 1; i < all.length; i++) {
      if (all[i - 1].name.compareTo(all[i].name) > 0) outOfOrder++;
    }
    check('B06[${shard.key}] 片名按字典序排列（前端编码前提）',
        outOfOrder == 0, '$outOfOrder 处逆序');

    if (namesSample.length < 8 && all.isNotEmpty) {
      namesSample.addAll(all.take(3).map((h) => h.name));
    }

    // 抽样：按片名前两字检索必须能命中自己
    if (all.isNotEmpty) {
      final probe = all[all.length ~/ 2];
      final prefix = probe.name.length >= 2
          ? probe.name.substring(0, 2).toLowerCase()
          : probe.name.toLowerCase();
      final found = scanner.scan(body, match: (n, _) => n.contains(prefix)).hits;
      totalHits += found.length;
      check('B07[${shard.key}] 抽样检索「$prefix」能命中自身',
          found.any((h) => h.vodId == probe.vodId),
          '命中 ${found.length} 条');
    }
  }
  check('B08 全部分片行数之和 == manifest.total', totalLines == manifest.total,
      '$totalLines vs ${manifest.total}');
  check('B09 抽样检索整体有结果', totalHits > 0, '$totalHits');
  // 年份 / 地区是「时间 / 地区」两行筛选的前提。覆盖率低不代表崩溃，
  // 代表筛下去会大面积漏片 —— 那是条件在骗人，必须在门禁里挡住。
  //
  // 分档而不是一刀切，因为实测覆盖率天然分层（2026-11-12 全量重抓）：
  //  * 电影/电视剧/纪录片/动漫 98–99.7%（这些站给得齐）；
  //  * 短视频 92.4% / 75.4%（短剧站一半不给地区）；
  //  * 其他 57.4% / 33.9%（综艺、赛事混在一起，很多站整列为空）。
  // 给「其他」放宽不是放水：那个桶本来就没有地区语义，硬要求 90% 只会
  // 让门禁永远红。四个主栏目仍按 90% 卡死。
  const strict = <String>{'movies', 'series', 'documentaries', 'anime'};
  for (final shard in manifest.shards) {
    if (shard.records <= 0) continue;
    final isStrict = strict.contains(shard.key);
    final needYear = isStrict ? 9 : (shard.key == 'shortVideo' ? 9 : 5);
    // 动漫地区 86.9%（部分动画站整列空），主栏目地区统一按 80% 卡；
    // 年份仍按 90% —— 年份是「时间」行唯一来源，缺得多就整行不准。
    final needArea = isStrict ? 8 : (shard.key == 'shortVideo' ? 7 : 3);
    check('B10[${shard.key}] 年份覆盖率 >= ${needYear}0% / 地区 >= ${needArea}0%',
        shard.withYear * 10 >= shard.records * needYear &&
            shard.withArea * 10 >= shard.records * needArea,
        'year ${shard.withYear}/${shard.records}'
        ' area ${shard.withArea}/${shard.records}');
  }
  // 逐行验证：分片里确实存在带年份 / 地区的行（不是只在 manifest 里报数）。
  final moviesText = decodeShardBody(
      File('$dir/movies.tsv.gz').readAsBytesSync());
  var v2Rows = 0;
  for (final line in moviesText.split('\n').take(500)) {
    final parsed = BuiltinIndexLine.parse(line, format: manifest.version);
    if (parsed != null && parsed.year.isNotEmpty && parsed.areas.isNotEmpty) {
      v2Rows++;
    }
  }
  check('B11 movies 分片前 500 行里确实带年份与地区', v2Rows > 400,
      '$v2Rows/500');

  // ── C. 前端编码函数本身的边界 ──
  check('C01 前缀 0 时直接返回后缀', applyFrontCode('任意', 0, '新片') == '新片');
  check('C02 正常拼接', applyFrontCode('斗罗大陆', 2, '神界传说') == '斗罗神界传说');
  check('C03 前缀超长时退回后缀（容错）',
      applyFrontCode('短', 99, '完整名') == '完整名');
  check('C04 空上一条 + 非零前缀退回后缀',
      applyFrontCode('', 3, '独立片名') == '独立片名');
  check('C05 前缀等于全长时得到上一条本身',
      applyFrontCode('完全一致', 4, '') == '完全一致');

  // ── D. 一致性判定（第 2 项的核心判据）──
  final now = DateTime.utc(2026, 11, 12, 12);
  final fresh = BuiltinIndexManifest(
    version: kBuiltinIndexVersion,
    generatedAt: now.subtract(const Duration(days: 1)),
    sourceUrl: 'http://example/a.json',
    sites: const [BuiltinIndexSite(key: 'k', name: 'n', api: 'a', total: 1)],
    types: const ['1'],
    shards: <BuiltinIndexShard>[
      BuiltinIndexShard(
          key: 'movies',
          label: '电影',
          file: 'movies.tsv.gz',
          records: 1,
          gzBytes: 10,
          sha256: 'x' * 64),
    ],
    total: 1,
  );
  check('D01 地址一致 + 新鲜 ⇒ 匹配',
      builtinIndexMatches(
          manifest: fresh, selectedUrl: 'http://example/a.json', now: now));
  check('D02 地址不一致 ⇒ 不匹配',
      !builtinIndexMatches(
          manifest: fresh, selectedUrl: 'http://other/a.json', now: now));
  check('D03 地址末尾空格不影响判定',
      builtinIndexMatches(
          manifest: fresh, selectedUrl: ' http://example/a.json ', now: now));
  check('D04 超过 7 天 ⇒ 不匹配',
      !builtinIndexMatches(
          manifest: fresh,
          selectedUrl: 'http://example/a.json',
          now: now.add(const Duration(days: 8))));
  check('D05 恰好 7 天内 ⇒ 匹配',
      builtinIndexMatches(
          manifest: fresh,
          selectedUrl: 'http://example/a.json',
          now: now.add(const Duration(days: 6))));
  check('D06 manifest 为空 ⇒ 不匹配',
      !builtinIndexMatches(
          manifest: null, selectedUrl: 'http://example/a.json', now: now));
  final emptyManifest = BuiltinIndexManifest(
    version: kBuiltinIndexVersion,
    generatedAt: now,
    sourceUrl: 'http://example/a.json',
    sites: const [],
    types: const [],
    shards: const [],
    total: 0,
  );
  check('D07 total=0 的空索引 ⇒ 不匹配',
      !builtinIndexMatches(
          manifest: emptyManifest,
          selectedUrl: 'http://example/a.json',
          now: now));

  // ── E. 坏数据不炸 ──
  check('E01 缺字段的行被跳过', BuiltinIndexLine.parse('1\t2\t3') == null);
  check('E02 非数字站点下标被跳过', BuiltinIndexLine.parse('x\t2\t3\t0\tn') == null);
  check('E03 空 vod_id 被跳过', BuiltinIndexLine.parse('0\t\t3\t0\tn') == null);
  check('E04 空行被跳过', BuiltinIndexLine.parse('') == null);
  final scanner2 = BuiltinIndexScanner(
      manifest: manifest, sectionKey: 'movies');
  check('E05 全是坏行时返回空而不是抛异常',
      scanner2.scan('bad\nworse\n', match: (_, __) => true).hits.isEmpty);
  check('E06 空正文返回空',
      scanner2.scan('', match: (_, __) => true).hits.isEmpty);
  check('E07 limit 生效',
      scanner2
              .scan('0\t1\t0\t0\t甲\n0\t2\t0\t0\t乙\n0\t3\t0\t0\t丙\n',
                  match: (_, __) => true, limit: 2)
              .hits
              .length ==
          2);
  // v2 列式：数值列在前、后缀永远在最后
  final v2 = BuiltinIndexLine.parse('3\t42\t7\t2\t2020\t0,2\t后缀片', format: 2);
  check('E09 v2 行解析出年份与地区下标',
      v2 != null && v2.year == '2020' && v2.areas.join(',') == '0,2' &&
          v2.suffix == '后缀片', v2 == null ? 'null' : '\${v2.year}/\${v2.areas}');
  final v1 = BuiltinIndexLine.parse('3\t42\t7\t2\t老片', format: 1);
  check('E10 v1 行仍可解析（年份 / 地区为空，兼容旧资产）',
      v1 != null && v1.year.isEmpty && v1.areas.isEmpty && v1.suffix == '老片');
  // 后缀含 tab 时要拼回去
  final tabLine = BuiltinIndexLine.parse('0\t9\t0\t0\t片\t名');
  check('E08 后缀含 tab 时拼回完整后缀', tabLine?.suffix == '片\t名',
      tabLine?.suffix ?? 'null');

  // ── F. 源码静态护栏 ──
  final pack = readText('tooling/pack_vod_index.py');
  check('F01 打包脚本声明格式版本 2（行内带年份 + 地区下标）',
      pack.contains('"version": 2'));
  check('F02 打包脚本按 VodSection 六片', pack.contains('SECTION_KEYS') &&
      pack.contains('"shortVideo"') &&
      pack.contains('"anime"'));
  // 词表必须与 Dart 侧逐字一致：任一侧改了另一侧不改，分类就会分叉。
  final catalogSrc = readText('lib/features/vod/vod_catalog.dart');
  for (final marker in kVodAnimeMarkers) {
    check('F03 动漫词「$marker」两侧一致',
        pack.contains('"$marker"') && catalogSrc.contains("'$marker'"));
  }
  for (final marker in kVodDocumentaryMarkers) {
    check('F04 纪录片词「$marker」两侧一致',
        pack.contains('"$marker"') && catalogSrc.contains("'$marker'"));
  }
  check('F05 打包脚本不读 genre（与 Dart 同口径）',
      !pack.contains('vod_class') && !pack.contains('genre'));
  check('F06 pubspec 已声明 assets/vod_index',
      readText('pubspec.yaml').contains('assets/vod_index/'));
  // 「类型」显示成中文名而不是数字 id —— 两条回填路径都不许退回旧写法。
  check('F07 回填类型不许回退成 typeId',
      !readText('lib/main.dart').contains('typeName: hit.typeId') &&
          !readText('lib/features/vod/vod_builtin_service.dart')
              .contains('typeName: hit.typeId'));
  check('F08 类目名查询必须带站点下标（否则跨站串名）',
      readText('lib/features/vod/vod_builtin_index.dart')
          .contains('String typeNameOf(int siteIndex, String typeId)'));
  // v2：地区词表两侧必须一致。打包侧把 `中国大陆/内地/大陆` 都映射到规范词，
  // Dart 侧按同一张表统计与过滤；任一侧加了词而另一侧没加，那个地区的
  // 条目就会「筛得到但显示不出来」（或反过来）。
  final missingVocab =
      kVodAreaVocabulary.where((w) => !pack.contains('"${w}"')).toList();
  check('F09 地区词表两侧一致（每个规范词都在打包脚本里）',
      missingVocab.isEmpty, missingVocab.join('/'));
  check('F10 打包脚本按 split 处理多值地区',
      pack.contains('_AREA_SPLIT') && pack.contains('AREA_ALIASES'));

  _report();
}

void _report() {
  stdout.writeln('');
  if (_fail == 0) {
    stdout.writeln('回归通过：$_pass/$_pass 断言通过');
  } else {
    stdout.writeln('回归失败：$_pass 通过 / $_fail 失败');
    for (final f in _failures) {
      stdout.writeln('  - $f');
    }
    exit(1);
  }
}
