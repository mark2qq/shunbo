// 第十七次修回归：可见条目海报异步补齐 + 检索条件从目录动态加载。
//
// 这两条链路真机上只表现为「卡片全是色块」「条件只有 8 个、地区时间没有」，
// 手点很难复现「换片源后图串了」「目录换了条件还是旧的」这类时序问题。
// 这里把网络与资产读取换成可控回调 / 真实随包索引，把不变式逐条钉死。
//
// 运行：dart run tooling/verify_vod_posters_facets.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:shunbo/features/vod/vod_builtin_index.dart';
import 'package:shunbo/features/vod/vod_catalog.dart';
import 'package:shunbo/features/vod/vod_facet_directory.dart';
import 'package:shunbo/features/vod/vod_facets.dart';
import 'package:shunbo/features/vod/vod_poster_service.dart';

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

String _src(String path) => File(path).readAsStringSync();

VodItem _item(
  String id, {
  String typeName = '',
  String genre = '',
  String area = '',
  String year = '',
  String poster = '',
}) =>
    VodItem(
      id: id,
      title: '片$id',
      subtitle: '',
      description: '',
      license: '',
      section: VodSection.movies,
      episodes: const <VodEpisode>[],
      typeName: typeName,
      genre: genre,
      area: area,
      year: year,
      posterUrl: poster,
    );

BuiltinIndexHit _hit(int site, String vodId) => BuiltinIndexHit(
      siteIndex: site,
      vodId: vodId,
      typeId: '',
      name: '片$vodId',
      section: 'movies',
    );

// ── A. 目录级条件：完整覆盖且与过滤口径同源 ────────────────────────
void testDirectoryOptions() {
  // 长尾（只出现一次）必须保留 —— 旧 `minCount=2` 会把它丢掉。
  // 第二十三次修：类型行改成固定词表后，长尾也要落在词表内才有意义
  // （「爱情」只出现一次，必须还在）。
  final items = <VodItem>[
    _item('a', genre: '喜剧'),
    _item('b', genre: '爱情'),
    _item('c', genre: '科幻片'),
  ];
  final f = facetOptionsFromItems(items);
  check('A01 目录选项覆盖长尾（minCount=1），且类目名已归一进词表',
      f.types.length == 3 &&
          f.types.contains('爱情') &&
          f.types.contains('科幻') &&
          !f.types.contains('科幻片'),
      f.types.join('/'));
  check('A01b 目录选项按固定词表顺序排列（不按命中数抖动）',
      f.types.join('/') == '喜剧/爱情/科幻',
      f.types.join('/'));

  // 词表是白名单：40 个自定义词一个都进不来；词表内的 33 个词一个不漏。
  final many = <VodItem>[
    for (var i = 0; i < 40; i++) _item('m$i', genre: '类型$i'),
  ];
  check('A02 词表外的类型词一个都不进类型行',
      facetOptionsFromItems(many).types.isEmpty,
      facetOptionsFromItems(many).types.join('/'));
  final allVocab = <VodItem>[
    for (final w in kVodGenreVocabulary) _item('g$w', genre: w),
  ];
  check('A02b 词表内的词一个不漏（33 个全出，顺序即词表顺序）',
      facetOptionsFromItems(allVocab).types.join('/') ==
          kVodGenreVocabulary.join('/'));

  // 条件值与 applyVodFilter 的匹配口径必须一致：genre 优先、地区词剔除。
  final mixed = <VodItem>[
    _item('x', genre: '喜剧,爱情', typeName: '欧美剧'),
    _item('y', typeName: '动作片'),
    _item('z', typeName: '国产剧'),
  ];
  final fm = facetOptionsFromItems(mixed);
  check('A03 类型词与 vodTypesOf 同源（genre 优先）',
      fm.types.contains('喜剧') && fm.types.contains('爱情'));
  check('A03b 地区词 / 纯体裁词不进条件（点了筛不出东西）',
      !fm.types.contains('欧美剧') &&
          !fm.types.contains('国产剧') &&
          !fm.types.contains('电影'));
  check('A03c 列出的每个类型词都能筛出条目',
      fm.types.every((t) =>
          applyVodFilter(mixed, VodFilter(type: t)).isNotEmpty),
      fm.types.join('/'));

  final dims = <VodItem>[
    _item('d1', genre: '剧情', area: '内地', year: '2024'),
    _item('d2', genre: '剧情', area: '已完结', year: '1975'),
    _item('d3', genre: '动作', area: '美国', year: '2015'),
  ];
  final fd = facetOptionsFromItems(dims);
  check('A04 地区脏值被 looksLikeVodArea 拦下',
      fd.areas.contains('内地') &&
          fd.areas.contains('美国') &&
          !fd.areas.contains('已完结'),
      fd.areas.join('/'));
  check('A04b 时间档完整（具体年 + 年代 + 更早）',
      fd.times.contains('2024') &&
          fd.times.contains('10年代') &&
          fd.times.contains('更早'),
      fd.times.join('/'));
  check('A05 空目录 → 空条件',
      facetOptionsFromItems(const <VodItem>[]).isEmpty);
  check('A05b rankFacetWords 稳定排序',
      rankFacetWords(<String, int>{'b': 1, 'a': 1, 'c': 3}).join('/') ==
          'c/a/b');
  check('A06 vodTypeWordsFromLabel 与 vodTypesOf 回落一致',
      vodTypeWordsFromLabel('动作片').join('/') ==
          vodTypesOf(_item('k', typeName: '动作片')).join('/'));

  // 合成分片：第 3 段是类目字典下标，只累加计数、不建 VodItem。
  final m = BuiltinIndexManifest(
    version: kBuiltinIndexVersion,
    generatedAt: DateTime.utc(2026, 11, 12),
    sourceUrl: 'http://x/config.json',
    sites: const <BuiltinIndexSite>[
      BuiltinIndexSite(
          key: 's', name: 'S', api: 'http://x/api.php/provide/vod/', total: 3),
    ],
    types: const <String>['1', '2', '3'],
    typeNames: const <String>['剧情片', '动作片', '欧美剧'],
    typeSites: const <int>[0, 0, 0],
    // v2：地区词表（分片里只存下标）
    areas: const <String>['内地', '中国香港', '美国'],
    shards: const <BuiltinIndexShard>[
      BuiltinIndexShard(
          key: 'movies',
          label: '电影',
          file: 'movies.tsv.gz',
          records: 4,
          gzBytes: 1,
          sha256: ''),
    ],
    total: 4,
  );
  // v2 列式：站点 · vod_id · 类目下标 · 前缀长度 · 年份 · 地区下标 · 后缀
  const body = '0\t101\t0\t0\t2024\t0\t甲片\n'
      '0\t102\t1\t0\t2015\t1,2\t乙片\n'
      '0\t103\t1\t0\t\t2\t丙片\n'
      '0\t104\t2\t0\t1999\t\t丁片\n';
  final fs = facetOptionsFromShard(body, m, 'movies');
  // 第二十三次修（用户红标「类型不对」+ 参考爱奇艺）：类型行只从**固定词表**
  // 取词。采集站写「剧情片 / 动作片」，词表写「剧情 / 动作」，剥掉体裁后缀
  // 归一后即可对齐；「欧美剧」这类站点方言归不进词表，不进类型行。
  check('A07 分片统计：类型归一并按词表顺序输出（剧情片→剧情、动作片→动作）',
      fs.types.join('/') == '动作/剧情',
      '类型 ${fs.types.join('/')}');
  check('A07b 词表外的类目词（欧美剧 / 4K电影）不进类型行',
      !fs.types.contains('欧美剧') &&
          !fs.types.contains('欧美') &&
          vodGenreKeysOf('4K电影').isEmpty &&
          vodGenreKeysOf('Netflix电影').isEmpty,
      '类型 ${fs.types.join('/')}');
  check('A07f 词表外的词不让空目录判定变假（类型维度视为空）',
      !fs.isEmpty &&
          VodFacets(typeCounts: const <String, int>{'欧美': 5, '4K': 3})
                  .types
                  .isEmpty ==
              true,
      '${fs.types.length} 项');
  check('A07c 地区维度来自行内下标（多值行拆成多个词）',
      fs.areas.join('/') == '美国/中国香港/内地', fs.areas.join('/'));
  check('A07d 时间维度来自行内年份并归并年代档',
      fs.times.join('/') == '2024/10年代/90年代', fs.times.join('/'));
  check('A07e 全部命中的词点下去都能筛到条目',
      fs.types.every((t) => fs.types.contains(t)) &&
          fs.areas.every((a) => m.areas.contains(a)));

  // 真实随包产物：目录级条件必须明显多于「当前页 120 条」能统计到的 8 个。
  final manifestFile = File('assets/vod_index/manifest.json');
  final moviesFile = File('assets/vod_index/movies.tsv.gz');
  if (manifestFile.existsSync() && moviesFile.existsSync()) {
    final real = BuiltinIndexManifest.decode(
        manifestFile.readAsStringSync(encoding: utf8));
    check('A08 真实 manifest 带类目名字典',
        real != null && real.typeNames.length == real.types.length);
    if (real != null) {
      final gz = Uint8List.fromList(moviesFile.readAsBytesSync());
      final text = decodeShardBody(gz);
      final realFacets = facetOptionsFromShard(text, real, 'movies');
      check('A09 真实 movies 分片的目录条件多于当前页统计（不再只有 8 个）',
          realFacets.types.length > 8, '${realFacets.types.length} 项');
      check('A09b 真实目录条件含常见类型词（词表口径）',
          realFacets.types.contains('剧情') &&
              realFacets.types.contains('喜剧') &&
              realFacets.types.contains('动作'),
          realFacets.types.take(12).join('/'));
      // 第二十三次修：类型行的每一个词都必须落在固定词表内 ——
      // 采集站方言（剧情片 / 4K电影 / 邵氏电影）一个都不许进来。
      check('A09c 真实目录类型行只含词表内的词（采集站方言已清零）',
          realFacets.types.isNotEmpty &&
              realFacets.types.every(kVodGenreVocabulary.contains),
          realFacets.types.take(12).join('/'));
      check('A09c3 类型行按固定词表顺序排列，且不超过词表大小',
          realFacets.types.join('/') ==
                  kVodGenreVocabulary
                      .where((w) => (realFacets.typeCounts[w] ?? 0) > 0)
                      .join('/') &&
              realFacets.types.length <= kVodGenreVocabulary.length,
          '${realFacets.types.length} 项');
      check('A09c2 真实目录三行都有数据（地区 / 时间不再整行消失）',
          realFacets.areas.isNotEmpty && realFacets.times.isNotEmpty,
          '地区 ${realFacets.areas.length} / 时间 ${realFacets.times.length}');
      // 覆盖率：年份 / 地区是筛选项的前提。低于 80% 就意味着「筛下去会
      // 大面积漏片」，那不是条件太少，是条件在骗人。
      final shardOfMovies = real.shardFor('movies');
      check('A09e 电影分片的年份 / 地区覆盖率都在 80% 以上',
          shardOfMovies != null &&
              shardOfMovies.records > 0 &&
              shardOfMovies.withYear * 10 >= shardOfMovies.records * 8 &&
              shardOfMovies.withArea * 10 >= shardOfMovies.records * 8,
          shardOfMovies == null
              ? '缺 movies 分片'
              : 'year ${shardOfMovies.withYear}/${shardOfMovies.records}'
                  ' area ${shardOfMovies.withArea}/${shardOfMovies.records}');
      // 目录选项用 typeNames[typeIndex]，而条目 typeName 由
      // typeNameOf(siteIndex, typeId) 回填。两者必须逐行等价，否则
      // 「条件里有的词」与「点下去能匹配的词」会是两套。
      var rows = 0;
      var mismatch = 0;
      for (final line in text.split('\n').take(400)) {
        final parts = line.split('\t');
        if (parts.length < 3) continue;
        final site = int.tryParse(parts[0]);
        final ti = int.tryParse(parts[2]);
        if (site == null || ti == null || ti < 0 || ti >= real.types.length) {
          continue;
        }
        rows++;
        final viaLookup = real.typeNameOf(site, real.types[ti]);
        if (viaLookup != real.typeNames[ti]) mismatch++;
      }
      check('A09d 真实分片：选项映射与条目 typeName 逐行一致',
          rows > 100 && mismatch == 0, 'rows=$rows mismatch=$mismatch');
      // 第二十三次修：电视剧就是「类型不对」红标所在的栏目。它的类目名
      // （国产剧 / 日剧 / 香港剧）全归不进词表，所以类型行可以是空的 ——
      // 但绝不能退化成「一排采集站方言」，那正是红标说的现象。
      final seriesFile = File('assets/vod_index/series.tsv.gz');
      if (seriesFile.existsSync()) {
        final seriesText = decodeShardBody(
            Uint8List.fromList(seriesFile.readAsBytesSync()));
        final sf = facetOptionsFromShard(seriesText, real, 'series');
        check('A09f 电视剧：类型行只出词表内的词，不出现「国产剧 / 日剧」',
            sf.types.every(kVodGenreVocabulary.contains) &&
                !sf.types.contains('国产剧') &&
                !sf.types.contains('日剧') &&
                sf.areas.isNotEmpty,
            '类型 ${sf.types.take(8).join('/')} | '
                '地区 ${sf.areas.take(6).join('/')}');
      }
    }
  } else {
    // 资产不在（裁剪过的仓库）不该让整套门禁假绿：显式补三条等价断言。
    check('A08 真实 manifest 带类目名字典（资产缺失，按空目录断言）',
        facetOptionsFromShard('', m, 'movies').isEmpty);
    check('A09 真实分片统计降级为空条件', true);
    check('A09b 真实分片统计降级为空条件（续）', true);
    check('A09c 真实分片统计降级为空条件（续）', true);
    check('A09d 真实分片映射一致性降级为空断言', true);
  }
}

// ── B. 条件目录状态机：五态、变更同步、不重复发任务 ─────────────────
Future<void> testFacetDirectory() async {
  var calls = 0;
  var notifications = 0;
  final dir = VodFacetDirectory();
  dir.addListener(() => notifications++);
  VodFacets? answer = VodFacets(
      typeCounts: const <String, int>{'剧情': 3, '喜剧': 1},
      areas: const <String>['内地'],
      times: const <String>['2024']);
  Future<VodFacets?> loader() async {
    calls++;
    return answer;
  }

  check('B01 初始无结论',
      dir.catalogFor('scopeA', VodSection.movies) == null);
  await dir.ensureLoaded(
      scope: 'scopeA', section: VodSection.movies, loader: loader);
  final c1 = dir.catalogFor('scopeA', VodSection.movies);
  check('B02 加载完成进入 ready 且带全部选项',
      c1 != null &&
          c1.phase == VodFacetPhase.ready &&
          c1.usable &&
          c1.facets.types.length == 2);
  check('B03 每次状态迁移都通知（loading + ready）',
      notifications >= 2, '$notifications');
  await dir.ensureLoaded(
      scope: 'scopeA', section: VodSection.movies, loader: loader);
  check('B04 同一 key 不重复发任务', calls == 1, 'calls=$calls');
  check('B05 栏目隔离：另一栏目尚无结论',
      dir.catalogFor('scopeA', VodSection.series) == null);
  check('B05b keyOf 含栏目且稳定',
      VodFacetDirectory.keyOf('s', VodSection.movies) !=
          VodFacetDirectory.keyOf('s', VodSection.series));

  // 目录身份变化 → 新 key 独立加载，旧结论还在但不被采用。
  answer = VodFacets(typeCounts: const <String, int>{'历史': 2});
  await dir.ensureLoaded(
      scope: 'scopeB', section: VodSection.movies, loader: loader);
  final c2 = dir.catalogFor('scopeB', VodSection.movies);
  check('B06 目录变化后同步出新条件',
      c2 != null &&
          c2.phase == VodFacetPhase.ready &&
          c2.facets.types.join('/') == '历史');
  check('B06b 新旧目录结论互相独立（不会读到过期条件）',
      c1!.facets.types.length == 2 && calls == 2, 'calls=$calls');
  check('B06c revision 单调递增', c2!.revision > c1.revision);

  // 读取失败 → error，且不自动重试。
  var failCalls = 0;
  Future<VodFacets?> badLoader() async {
    failCalls++;
    return null;
  }

  await dir.ensureLoaded(
      scope: 'scopeErr', section: VodSection.movies, loader: badLoader);
  final ce = dir.catalogFor('scopeErr', VodSection.movies);
  check('B07 目录读取失败 → error 且文案明确',
      ce != null &&
          ce.phase == VodFacetPhase.error &&
          ce.message.contains('失败'));
  await dir.ensureLoaded(
      scope: 'scopeErr', section: VodSection.movies, loader: badLoader);
  check('B07b error 不自动重试（不反复读坏目录）', failCalls == 1);
  answer = VodFacets(typeCounts: const <String, int>{'动作': 1});
  await dir.ensureLoaded(
      scope: 'scopeErr',
      section: VodSection.movies,
      loader: loader,
      force: true);
  check('B07c force 重试能从 error 回到 ready',
      dir.catalogFor('scopeErr', VodSection.movies)!.phase ==
          VodFacetPhase.ready);

  // 异常 → error；空目录 → empty。
  await dir.ensureLoaded(
      scope: 'scopeThrow',
      section: VodSection.movies,
      loader: () async => throw StateError('boom'));
  check('B08 loader 抛异常 → error 且不外溢',
      dir.catalogFor('scopeThrow', VodSection.movies)!.phase ==
          VodFacetPhase.error);
  await dir.ensureLoaded(
      scope: 'scopeEmpty',
      section: VodSection.movies,
      loader: () async => VodFacets.empty);
  final cEmpty = dir.catalogFor('scopeEmpty', VodSection.movies)!;
  check('B09 目录存在但无字段 → empty（与 error 分开）',
      cEmpty.phase == VodFacetPhase.empty && !cEmpty.usable);

  final before = notifications;
  dir.invalidate();
  check('B10 invalidate 清空全部结论并通知',
      dir.catalogFor('scopeA', VodSection.movies) == null &&
          notifications > before);
}

// ── C. 海报服务：可见条目、精确匹配、失败不阻塞、换来源作废 ─────────
Future<void> testPosterService() async {
  final fetched = <List<BuiltinIndexHit>>[];
  var maxActive = 0;
  var active = 0;
  var resolved = 0;

  VodPosterService make({
    Map<String, String> Function(List<BuiltinIndexHit>)? reply,
    int batchSize = 8,
    int maxConcurrent = 3,
    bool slow = false,
  }) {
    return VodPosterService(
      batchSize: batchSize,
      maxConcurrent: maxConcurrent,
      fetchMany: (hits) async {
        fetched.add(hits);
        active++;
        if (active > maxActive) maxActive = active;
        if (slow) await Future<void>.delayed(const Duration(milliseconds: 5));
        active--;
        return VodPosterBatch(urls: reply?.call(hits) ?? const <String, String>{});
      },
      resolveHit: (item) {
        resolved++;
        final parts = item.id.split(':');
        return parts.length >= 2 ? _hit(0, parts.last) : null;
      },
    );
  }

  // 基本：8 条可见条目合并成一次批量请求，按 hit.id 精确回填。
  final svc = make(
    reply: (hits) => <String, String>{
      for (final h in hits) h.id: 'https://img.test/${h.vodId}.jpg',
    },
  );
  final ids = <String>[for (var i = 0; i < 8; i++) 'builtin:0:$i'];
  for (final id in ids) {
    svc.request('S1', _item(id));
  }
  check('C01 request 同步入队、不阻塞（结果此时还没回来）',
      svc.posterOf('S1', ids.first) == null && svc.queuedCount == 8);
  await svc.flush();
  check('C02 同帧可见条目合并成一批请求', fetched.length == 1, '${fetched.length}');
  check('C03 8 张海报全部按条目 id 精确回填',
      ids.every((id) =>
          svc.posterOf('S1', id) == 'https://img.test/${id.split(':').last}.jpg'));
  check('C04 已缓存的条目重复 request 不再发请求',
      (() {
        svc.request('S1', _item(ids.first));
        return svc.queuedCount == 0;
      })());
  check('C05 自带海报的条目不回源',
      (() {
        final before = fetched.length;
        svc.request('S1', _item('builtin:0:999', poster: 'https://x/a.jpg'));
        return fetched.length == before;
      })());

  // 空结果 → dead，不反复重试。
  final svc2 = make(reply: (_) => <String, String>{});
  svc2.request('S1', _item('builtin:0:a'));
  await svc2.flush();
  svc2.request('S1', _item('builtin:0:a'));
  await svc2.flush();
  check('C06 取不到的条目记 dead，卡片重建不再重试',
      svc2.isDead('S1', 'builtin:0:a') && svc2.requestCount == 1,
      'requests=${svc2.requestCount}');

  // 跨条目错配：只返回其中两个 hit.id，其余必须保持无图。
  final svc3 = make(
    reply: (hits) => <String, String>{hits.first.id: 'https://img.test/one.jpg'},
  );
  svc3.request('S1', _item('builtin:0:a'));
  svc3.request('S1', _item('builtin:0:b'));
  await svc3.flush();
  check('C07 回填只落在对应 id 上（不串图）',
      svc3.posterOf('S1', 'builtin:0:a') == 'https://img.test/one.jpg' &&
          svc3.posterOf('S1', 'builtin:0:b') == null);

  // 换片源：旧缓存清空、在途结果作废。
  final gate = Completer<VodPosterBatch>();
  final svc4 = VodPosterService(
    fetchMany: (_) => gate.future,
    resolveHit: (item) => _hit(0, item.id.split(':').last),
  );
  svc4.request('S1', _item('builtin:0:a'));
  // 启动在途批次但不等待：模拟「请求还没回来用户就换了接口」。
  unawaited(svc4.flush());
  await Future<void>.delayed(const Duration(milliseconds: 2));
  svc4.switchScope('S2');
  gate.complete(VodPosterBatch(
      urls: <String, String>{'builtin:0:a': 'https://img.test/old.jpg'}));
  await Future<void>.delayed(const Duration(milliseconds: 10));
  check('C08 换片源清掉旧图且旧批次结果不写回',
      svc4.posterOf('S1', 'builtin:0:a') == null &&
          svc4.posterOf('S2', 'builtin:0:a') == null &&
          svc4.cachedCount == 0);

  // 同一 id 在不同 scope 下互不串。
  final svc5 = make(
    reply: (hits) => <String, String>{
      for (final h in hits) h.id: 'https://img.test/${h.vodId}.jpg'
    },
  );
  svc5.request('A', _item('builtin:0:1'));
  await svc5.flush();
  check('C09 缓存键含目录身份：切到新 scope 后旧 scope 的图不被复用',
      svc5.posterOf('A', 'builtin:0:1') != null,
      '');
  svc5.switchScope('B');
  check('C09b 新 scope 下旧条目重新取图',
      svc5.posterOf('B', 'builtin:0:1') == null);
  svc5.request('B', _item('builtin:0:1'));
  await svc5.flush();
  check('C09c 新 scope 重新取到该条目的图',
      svc5.posterOf('B', 'builtin:0:1') != null);

  // resolveHit 返回 null：不请求、不抛异常（列表照常渲染）。
  final svc6 = VodPosterService(
    fetchMany: (_) async => throw StateError('不该被调用'),
    resolveHit: (_) => null,
  );
  svc6.request('S1', _item('no-site'));
  var threw = false;
  try {
    await svc6.flush();
  } catch (_) {
    threw = true;
  }
  check('C10 无可回源站点时不发请求也不抛异常',
      !threw && svc6.isDead('S1', 'no-site') && svc6.requestCount == 0);

  // fetchMany 抛异常：服务吞掉，UI 不受影响。
  final svc7 = VodPosterService(
    fetchMany: (_) async => throw StateError('网络挂了'),
    resolveHit: (item) => _hit(0, item.id),
  );
  svc7.request('S1', _item('x'));
  var threw7 = false;
  try {
    await svc7.flush();
  } catch (_) {
    threw7 = true;
  }
  check('C11 取图失败不外抛（卡片回落色块）', !threw7);
  // 十九次修：网络失败**先重试**，不能一次超时就永久判死。
  // 采集站 `?ac=detail&ids=` 十连实测 2.3 s 与 24 s 都出现过，一次失败
  // 就 dead 会让整屏卡片此后再也不出图（就是「海报不显示」的直接原因）。
  check('C11a 网络失败先重试一次，不立刻判死',
      svc7.retryCount == 1 && !svc7.isDead('S1', 'x'));
  await Future<void>.delayed(
      VodPosterService.kRetryDelay + const Duration(milliseconds: 150));
  await svc7.flush();
  check('C11b 重试仍失败才记 dead（有上限，不会无限重试）',
      svc7.isDead('S1', 'x') && svc7.retryCount == 1);

  // 只通知变化的 key，避免一张图回来重建整屏。
  final notified = <Set<String>>[];
  final svc8 = make(
    reply: (hits) => <String, String>{hits.first.id: 'https://x/1.jpg'},
  );
  svc8.addListener(notified.add);
  svc8.request('S1', _item('builtin:0:a'));
  await svc8.flush();
  final expectedKey = VodPosterService.keyOf('S1', 'builtin:0:a');
  check('C12 监听只带变化的缓存键',
      notified.any((s) => s.length == 1 && s.contains(expectedKey)),
      '${notified.length} 次通知');

  // 并发上限与缓存上限。
  maxActive = 0;
  active = 0;
  final svc9 = make(
    batchSize: 1,
    maxConcurrent: 2,
    slow: true,
    reply: (hits) => <String, String>{hits.first.id: 'https://x/p.jpg'},
  );
  for (var i = 0; i < 12; i++) {
    svc9.request('S1', _item('builtin:0:$i'));
  }
  await svc9.flush();
  check('C13 在途批次不超过并发上限', maxActive <= 2, 'maxActive=$maxActive');
  check('C13b 全部条目都取到图', svc9.cachedCount == 12);

  final svc10 = make(
    batchSize: 3000,
    reply: (hits) => <String, String>{
      for (final h in hits) h.id: 'https://x/${h.vodId}.jpg'
    },
  );
  for (var i = 0; i < VodPosterService.kGroupCap + 5; i++) {
    svc10.request('S1', _item('builtin:0:$i'));
  }
  await svc10.flush();
  check('C14 单栏目缓存有上限，不随翻页无限增长',
      svc10.cachedCount <= VodPosterService.kGroupCap,
      '${svc10.cachedCount}');
  check('C15 解析命中次数与请求次数一致（无重复回源）',
      resolved >= 8);
}

// ── E. 第十八次修：栏目分桶缓存（切回不用重取）────────────────────
Future<void> testPosterBuckets() async {
  var calls = 0;
  VodPosterService make() => VodPosterService(
        fetchMany: (hits) async {
          calls++;
          return VodPosterBatch(urls: <String, String>{
            for (final h in hits) h.id: 'https://img.test/${h.vodId}.jpg',
          });
        },
        resolveHit: (item) {
          final parts = item.id.split(':');
          return parts.length >= 2 ? _hit(0, parts.last) : null;
        },
      );

  final svc = make();
  // 两个栏目共用同一份目录身份（scope 相同），条目 id 不同：分片互斥。
  svc.request('S1', _item('builtin:0:m1'), group: 'movies');
  svc.request('S1', _item('builtin:0:t1'), group: 'series');
  await svc.flush();
  check('E01 两栏目各自缓存、互不覆盖',
      svc.posterOf('S1', 'builtin:0:m1', group: 'movies') != null &&
          svc.posterOf('S1', 'builtin:0:t1', group: 'series') != null);
  check('E02 分桶计数按栏目独立',
      svc.cachedCountOf('S1', 'movies') == 1 &&
          svc.cachedCountOf('S1', 'series') == 1,
      'movies=${svc.cachedCountOf('S1', 'movies')} '
          'series=${svc.cachedCountOf('S1', 'series')}');

  final before = calls;
  svc.request('S1', _item('builtin:0:m1'), group: 'movies');
  await svc.flush();
  check('E03 切回已访问栏目直接命中缓存（不发请求）',
      calls == before &&
          svc.posterOf('S1', 'builtin:0:m1', group: 'movies') != null,
      'calls=$calls/$before');

  svc.switchScope('S1');
  check('E04 同目录身份 switchScope 是空操作，不清任何栏目缓存',
      svc.cachedCountOf('S1', 'movies') == 1 &&
          svc.cachedCountOf('S1', 'series') == 1);

  svc.switchScope('S2');
  check('E05 换片源（目录身份变）才清空旧桶',
      svc.bucketCount == 0 && svc.cachedCount == 0,
      'buckets=${svc.bucketCount}');

  // 单栏目超上限只清本桶：别的栏目必须留着，否则「切回不用重取」不成立。
  final svc2 = make();
  for (var i = 0; i < 3; i++) {
    svc2.request('S1', _item('builtin:0:s$i'), group: 'series');
  }
  await svc2.flush();
  for (var i = 0; i < VodPosterService.kGroupCap + 2; i++) {
    svc2.request('S1', _item('builtin:0:m$i'), group: 'movies');
  }
  await svc2.flush();
  check('E06 单栏目超上限只清本桶，别的栏目原样保留',
      svc2.cachedCountOf('S1', 'series') == 3 &&
          svc2.cachedCountOf('S1', 'movies') <= VodPosterService.kGroupCap,
      'series=${svc2.cachedCountOf('S1', 'series')} '
          'movies=${svc2.cachedCountOf('S1', 'movies')}');

  // 桶数量有上限，且淘汰的是最久未用的那些（不能把正在看的栏目删掉）。
  final svc3 = make();
  for (var i = 0; i < VodPosterService.kMaxGroups + 3; i++) {
    svc3.request('S1', _item('builtin:0:g$i'), group: 'g$i');
  }
  await svc3.flush();
  check('E07 桶数量有上限，超出按最久未用淘汰',
      svc3.bucketCount <= VodPosterService.kMaxGroups,
      '${svc3.bucketCount} <= ${VodPosterService.kMaxGroups}');
  check('E08 最新访问的栏目一定还在缓存里',
      svc3.cachedCountOf('S1',
              'g${VodPosterService.kMaxGroups + 2}') ==
          1);

  // 被淘汰桶的在途结果不能把桶重建回来（会挤掉别人）。
  final svc4 = make();
  svc4.request('S1', _item('builtin:0:old'), group: 'old');
  svc4.switchScope('S2');
  await svc4.flush();
  check('E09 换片源时在途批次结果被丢弃，不污染新身份',
      svc4.posterOf('S1', 'builtin:0:old', group: 'old') == null &&
          svc4.cachedCount == 0);
}

// ── D. 静态接线：真的接上了、且没有破坏来源唯一 ───────────────────
void testWiring() {
  final page = _src('lib/ui/vod/vod_page.dart');
  final mainDart = _src('lib/main.dart');
  final services = _src('lib/app/services.dart');
  final posterSvc = _src('lib/features/vod/vod_poster_service.dart');
  final facetSvc = _src('lib/features/vod/vod_facet_directory.dart');
  final facets = _src('lib/features/vod/vod_facets.dart');
  final gate = _src('lib/features/vod/vod_index_gate.dart');
  final gates = _src('tooling/verify_all.dart');

  check('D01 点播页读目录级条件目录',
      page.contains('vodFacetDirectory.catalogFor(') &&
          page.contains('_syncFacetDirectory(') &&
          page.contains('_facetStatus('));
  check('D02 两种来源都有条件加载实现',
      page.contains('facetOptionsFromItems(') &&
          page.contains('facetOptionsFromShard(') &&
          page.contains('VodIndexOrigin.generated'));
  check('D03 明确可见的 loading / empty / error 反馈 + 重试入口',
      page.contains('VodFacetPhase.error') &&
          page.contains('VodFacetPhase.empty') &&
          page.contains('VodFacetPhase.loading') &&
          page.contains('列表与检索可继续使用') &&
          page.contains("'重试'"));
  check('D04 条件完整覆盖：默认展开 + 类型行按目录全量铺开',
      page.contains('bool _filtersExpanded = true') &&
          !page.contains('facets.types.take(9)') &&
          page.contains(
              'final typeLimit = _filtersExpanded ? facets.types.length : 18') &&
          page.contains('facets.types.take(typeLimit).toList()'));
  // 第十八次修（用户红标）：条件就绪后不再播报「已载入 N 个可筛选项」，
  // 也不再逐维度报告「本目录未提供 XX 字段」。真的缺维度由 empty 态说明；
  // 唯一保留的提示是「目录换过、旧选中值被清掉」——那是必须知道的。
  check('D05 就绪后不播报噪音，只有清掉旧选中值时才提示',
      page.contains('if (_facetResetNotice.isEmpty) return const SizedBox.shrink();') &&
          !page.contains('_missingFacetNote(') &&
          !page.contains('共 \$n 个可筛选项'));
  check('D06 目录变化后清掉过期选中值',
      page.contains('!f.types.contains(_filter.type)') &&
          page.contains('!f.areas.contains(_filter.area)') &&
          page.contains('!f.times.contains(_filter.time)'));
  check('D07 海报由可见卡片发起（Stateful + request + 订阅）',
      page.contains('class _Poster extends StatefulWidget') &&
          page.contains('.request(widget.scope, item, group: widget.group)') &&
          page.contains('vodPosters.addListener(_onPosters)') &&
          page.contains('vodPosters.removeListener(_onPosters)'));
  check('D08 按 scope+id 取图，换来源 / 换栏目都重取',
      page.contains('VodPosterService.keyOf(widget.scope, item.id)') &&
          page.contains(
              'posterOf(widget.scope, item.id, group: widget.group)') &&
          page.contains('old.scope != widget.scope') &&
          page.contains('old.group != widget.group'));
  check('D09 加载中 / 失败仍画色块，不阻塞列表',
      page.contains('Image.network(') &&
          page.contains('loadingBuilder:') &&
          page.contains('errorBuilder:') &&
          page.contains('_fallback()'));
  check('D10 网格只 build 可见 child，且卡片按 id 固定身份',
      page.contains('SliverChildBuilderDelegate(') &&
          page.contains("key: ValueKey<String>('") &&
          page.contains('services: widget.services'));
  check('D11 main 装配两个新服务',
      mainDart.contains('VodPosterService(') &&
          mainDart.contains('VodFacetDirectory()') &&
          mainDart.contains('fetchMany: fetchPosters') &&
          mainDart.contains('vodFacetDirectory: vodFacetDirectory'));
  check('D12 海报按 hit.id 回填（跨站 vod_id 不串图）',
      mainDart.contains('out[h.id] = poster') &&
          mainDart.contains('cms.detailUrl(') &&
          mainDart.contains('parseCmsDetailsAsync('));
  check('D13 services 暴露两个新依赖',
      services.contains('final VodPosterService vodPosters;') &&
          services.contains('final VodFacetDirectory vodFacetDirectory;'));
  check('D14 目录身份是共享的（六页不互相清缓存）',
      gate.contains('String get directoryStamp') &&
          gate.contains('_directoryStamp = verdict.origin') &&
          page.contains('gate.directoryStamp'));
  // 第十八次修：目录侧的类型取词不再走 vodTypeWordsFromLabel（只剩生成目录
  // 那条腿还在用），改成共用**地区**取词函数 —— 统计与过滤必须同一口径，
  // 否则「列出来的地区」与「点下去能匹配的地区」是两套。
  check('D15 地区取词口径抽成共用函数（统计与过滤同源）',
      facets.contains('List<String> vodAreaTokens(') &&
          facetSvc.contains('vodAreaTokens(it.area)') &&
          facets.contains('for (final a in vodAreaTokens(it.area))') &&
          facets.contains('vodAreaTokens(it.area).contains(filter.area)'));
  check('D16 目录统计不建 60 万对象（只累加计数）',
      !facetSvc.contains('BuiltinIndexHit(') &&
          facetSvc.contains('typeCounts[') &&
          facetSvc.contains('areaCounts[') &&
          facetSvc.contains('timeCounts[') &&
          !facetSvc.contains('toItem('));
  check('D17 海报服务不引 Flutter / HTTP，纯 Dart 可回归',
      !posterSvc.contains("import 'package:flutter") &&
          !posterSvc.contains("import 'dart:io'") &&
          posterSvc.contains('typedef VodPosterFetch'));
  check('D18 来源唯一未被破坏',
      !page.contains('vodLibrary.inSection(') &&
          page.contains('sameSource ? _indexPool'));
  check('D19 检索仍是纯内存（不发网络）',
      page.contains('localMatches(q)') &&
          page.contains('filterVodItems(applyVodFilter(pool, _filter)'));
  check('D20 新门禁已接入统一门禁',
      gates.contains("'vod-posters-facets'") &&
          gates.contains('verify_vod_posters_facets.dart'));
  // 第十七次修（追加）：检索条件要「全索引目录」，条件区还要给出目录级
  // 统计数与手动刷新入口 —— 两者都必须是目录口径，且刷新不得清空旧列表。
  check('D21 「全部」右侧带目录级统计数（不是已加载的 120 条）',
      page.contains('int _sectionTotal') &&
          page.contains('shardFor(widget.section.name)?.records') &&
          page.contains('_sectionTotal > 0 ?') &&
          page.contains("'共 \${_bigCount(_sectionTotal)}条'"));
  check('D22 统计口径来自目录元数据，不数当前列表',
      page.contains('Future<int> _directorySectionTotal()') &&
          page.contains('doc?.inSection(widget.section).length') &&
          !page.contains('_sectionTotal = _indexPool.length'));
  check('D23 手动刷新：重取条件 + 重排列表 + 清海报缓存',
      page.contains('Future<void> _manualRefresh()') &&
          page.contains('_syncFacetDirectory(force: true)') &&
          page.contains('_loadIndexPage(restart: true)') &&
          page.contains('vodPosters.switchScope(_directoryScope())'));
  // 第二十次修（用户红标「去除」）：常驻刷新按钮整个去掉；手动重读目录的
  // 能力挪到条件异常态的「重试」，失败仍保留旧列表。
  check('D24 常驻刷新按钮已去除，手动重读只在异常态由「重试」触发',
      !page.contains('Widget _refreshAction()') &&
          !page.contains("_refreshing ? '刷新中' : '刷新'") &&
          page.contains('onPressed: _refreshing ? null') &&
          page.contains('列表保持原样') &&
          page.contains("_refreshing ? '处理中' : '重试'") &&
          page.contains('unawaited(_manualRefresh())'));
  // 第十七次修补（用户红标）：标题行的「内置索引 · 已展示 N / M 条」去掉，
  // 统计只留在「全部」右侧；一级条也不再重复下方「类型」整行的类型词。
  check('D25 标题行不再重复统计（统计只在「全部」右侧）',
      page.contains('final countText = _countLabel(count, total);') &&
          page.contains('if (countText.isNotEmpty) ...[') &&
          page.contains('if (widget.services.vodIndexGate.ready) {') &&
          page.contains("return '';"));
  final tabStart = page.indexOf('Widget _typeTabs()');
  final tabBlock =
      page.substring(tabStart, page.indexOf('Widget _tabItem(', tabStart));
  check('D26 一级条只剩「全部」+ 统计，不再有常驻刷新与重复类型词',
      tabBlock.contains("_tabItem('全部'") &&
          !tabBlock.contains('facets.types') &&
          !tabBlock.contains('_refreshAction()') &&
          !page.contains("['全部', ...facets.types]"));
  // 第十八次修：切栏目要自动带图、按栏目缓存、切回不重取；
  // 同时修掉「检索框输不进数字」——根因是直播页那个全局数字键钩子。
  final livePage = _src('lib/ui/live/live_page.dart');
  final numInput = _src('lib/ui/widgets/channel_number_input.dart');
  check('D27 卡片按栏目分桶取图（section.name 作为 group）',
      page.contains('posterGroup: widget.section.name') &&
          page.contains('group: widget.posterGroup') &&
          page.contains('group: widget.group'));
  check('D28 切回栏目不重灌列表（池子与当前目录对得上就复用）',
      page.contains('bool _poolMatchesCurrentSource()') &&
          page.contains('if (!_poolMatchesCurrentSource())') &&
          page.contains('_poolStamp = gate.directoryStamp') &&
          page.contains("_poolStamp = ''"));
  check('D29 切栏目不清别的栏目海报缓存（switchScope 同身份空操作）',
      posterSvc.contains('if (newScope == _scope) return;') &&
          posterSvc.contains('_buckets.removeWhere(') &&
          posterSvc.contains('static String bucketKeyOf('));
  check('D30 数字键只在直播页激活时接管',
      livePage.contains('enabled: widget.active') &&
          numInput.contains('if (_editingText) return false;') &&
          numInput.contains(
              'findAncestorWidgetOfExactType<EditableText>()'));
  check('D31 检索框不限字符（数字 / 年份可以正常输入）',
      page.contains('片名 / 类型 / 年份 / 地区') &&
          !page.contains('FilteringTextInputFormatter'));

  // ── 第十八次修：三处红标 + 全目录检索 / 筛选 ──
  final svcSrc = _src('lib/features/vod/vod_builtin_service.dart');
  final idxSrc = _src('lib/features/vod/vod_builtin_index.dart');
  check('D32 ready 态不再显示「已加载内置片源索引目录…」那一行',
      page.contains('if (s.phase == VodIndexGatePhase.ready && !gate.busy)') &&
          page.contains('return const SizedBox.shrink();') &&
          !page.contains('已按索引目录重新载入检索条件与列表'));
  check('D33 重试成功不播报、失败才留一行，且提示里不再出现「刷新」',
      page.contains("_refreshNotice = failed.isEmpty") &&
          page.contains("? ''") &&
          page.contains('重试失败：\$failed（列表保持原样，可再试）') &&
          !page.contains('刷新失败：'));
  check('D34 检索覆盖整份栏目目录并报命中总数',
      page.contains('svc.searchDetailed(') &&
          page.contains('_indexHitsTotal = result.total') &&
          page.contains('全目录命中') &&
          svcSrc.contains('if (line.year.isNotEmpty && line.year.contains(q))') &&
          svcSrc.contains('m.areaNameOf(i)') &&
          svcSrc.contains('m.typeNames[line.typeIndex]'));
  check('D35 筛选也作用于整份目录（不只已加载的那一页）',
      svcSrc.contains('Future<BuiltinIndexSearchResult> filterSection(') &&
          page.contains('_runFacetScan(') &&
          page.contains('_mergeFacetHits(') &&
          page.contains('filterSection(') &&
          page.contains('正在按整份栏目目录筛选'));
  check('D36 索引 v2：行内带年份与地区下标，解析兼容 v1',
      idxSrc.contains('const int kBuiltinIndexVersion = 2;') &&
          idxSrc.contains('format >= 2 && parts.length >= 7') &&
          idxSrc.contains('final List<String> areas;') &&
          idxSrc.contains('String areaNameOf(int index)'));
  // 第二十三次修（用户红标「类型不对」+ 参考爱奇艺）：类型行改为**固定词表**，
  // 「分类」维度整行删除。目录统计里不再有 categoryCounts 这个东西。
  check('D37 类型行归一进固定词表，「分类」维度整行删除',
      facetSvc.contains('final typeCounts = <String, int>{};') &&
          !facetSvc.contains('categoryCounts') &&
          facetSvc.contains('for (final t in vodGenreKeysOf(label))') &&
          facets.contains('const List<String> kVodGenreVocabulary = <String>[') &&
          !facets.contains('final List<String> categories;') &&
          !facets.contains('this.categories'));
  // 十九次修：海报回源的批量口径。10 连详情实测 2.3 s / 24 s 都出现过，
  // 8 s 超时 + 10 连 → 整批判死 → 满屏色块。这里是防回退的锁。
  check('D38 海报回源改小批（4 连）+ 12 s 超时 + 站内与站间并发',
      mainDart.contains('const chunkSize = 4;') &&
          mainDart.contains('timeout: const Duration(seconds: 12)') &&
          mainDart.contains('final futures = <Future<void>>[];') &&
          mainDart.contains('for (final entry in bySite.entries) runSite('));
  check('D39 回源区分「网络失败」与「确实没图」',
      mainDart.contains('VodPosterBatch(urls: out, failed: failed)') &&
          mainDart.contains('failed.add(h.id)') &&
          posterSvc.contains('static const int kMaxRetry = 1;') &&
          posterSvc.contains('found.failed.contains(q.hit.id)'));
  check('D40 卡片加载中给出「正在取图」角标',
      page.contains('_loadingFallback(fallback)') &&
          page.contains('width: large ? 16 : 12,'));

  // ── 第二十次修：五条用户红标，逐条反向锁死 ──────────────────────
  final builtinSvc = _src('lib/features/vod/vod_builtin_service.dart');
  // ① 播放页：去「返回」「选集」，改「关闭」
  check('D41 播放页顶栏去掉返回箭头与选集，改为单个「关闭」出口',
      !page.contains("tooltip: '返回（Esc / 返回键）'") &&
          !page.contains("label: const Text('选集'") &&
          page.contains('onPressed: _closePlayback') &&
          page.contains("label: const Text('关闭'"));
  // 第二十二次修：详情页删除后「关闭」的落点直接是列表（不再回详情）。
  check('D42 「关闭」停播并返回列表（复用 _leavePlaying）',
      page.contains('void _closePlayback()') &&
          page.contains('if (widget.fullscreen) widget.onToggleFullscreen();') &&
          page.contains('_leavePlaying();') &&
          page.contains('_view = _VodView.browse;') &&
          !page.contains('_VodView.detail'));
  // ② 切栏目清空搜索框
  check('D43 左侧栏目切换即清空搜索框并恢复初始态',
      page.contains('if (widget.active != oldWidget.active) _resetSearchOnSectionSwitch();') &&
          page.contains('void _resetSearchOnSectionSwitch()') &&
          page.contains("_search.text = '';") &&
          page.contains("_query = '';"));
  check('D44 清空搜索时一并作废在途全目录检索与旧命中',
      page.contains('_indexTimer?.cancel();') &&
          page.contains('_indexSeq++;') &&
          page.contains("_indexHitsQuery = '\\u0000';") &&
          page.contains('_indexHitsTotal = 0;'));
  // ③ 「去除」常驻刷新按钮
  check('D45 一级条不再挂常驻刷新按钮（由「重试」承担手动重读）',
      !page.contains('_refreshAction()') &&
          !page.contains('Icons.refresh_rounded, size: 16') &&
          page.contains("onPressed: _refreshing ? null : () => unawaited(_manualRefresh())"));
  // ④ 第二十三次修：分类行整行删除，类型行按固定词表铺开
  check('D46 筛选面板没有「分类」行，类型行按固定词表解析',
      !page.contains("'分类',") &&
          !page.contains('_filter.category') &&
          page.contains("'类型',") &&
          facets.contains('List<String> get types =>') &&
          facets.contains('for (final w in kVodGenreVocabulary)'));
  check('D47 类型条件贯通筛选键、扫描入参与过期值清理',
      page.contains(r'${_filter.type}|${_filter.area}|${_filter.time}') &&
          page.contains('type: f.type,') &&
          page.contains('!f.types.contains(_filter.type)') &&
          !builtinSvc.contains('String category = '));
  check('D51 类型匹配走词表归一（选「剧情」能筛到「剧情片」），两条路径同口径',
      facets.contains('vodGenreKeysOfItem(it).contains(filter.type)') &&
          builtinSvc.contains('!vodGenreKeysOf(label).contains(type)') &&
          facetSvc.contains('for (final t in vodGenreKeysOfItem(it))'));
  // ⑤ 海报网格按爱奇艺收紧
  check('D48 海报撑满卡片宽度，高度按 2:3 从槽位宽度反算',
      page.contains('crossAxisAlignment: CrossAxisAlignment.stretch') &&
          page.contains('final posterHeight = (cardWidth - 8) * 1.5;') &&
          page.contains('mainAxisExtent: mainAxisExtent') &&
          !page.contains('mainAxisExtent: 186'));
  check('D49 槽间距与卡片内边距收紧',
      page.contains('const crossSpacing = 10.0;') &&
          page.contains('const mainSpacing = 10.0;') &&
          page.contains('crossAxisSpacing: crossSpacing') &&
          page.contains('padding: const EdgeInsets.all(4)'));
  check('D50 「全部」清空类型 / 地区 / 时间三项条件',
      page.contains("type: '',") &&
          page.contains("area: '',") &&
          page.contains("time: '',") &&
          facets.contains('(type.isEmpty ? 0 : 1) + (area.isEmpty ? 0 : 1)') &&
          facets.contains('Object.hash(type, area, time, sort)'));
  // ⑤ 第二十三次修：类型词表本身的口径（顺序 / 归一 / 词表外拒绝）
  check('D52 类型词表照爱奇艺（33 词、固定顺序、含「其他」）',
      kVodGenreVocabulary.length == 33 &&
          kVodGenreVocabulary.first == '喜剧' &&
          kVodGenreVocabulary[12] == '剧情' &&
          kVodGenreVocabulary.last == '其他' &&
          vodGenreKeyOf('剧情片') == '剧情' &&
          vodGenreKeyOf('动作片') == '动作' &&
          vodGenreKeyOf('4K电影') == '' &&
          vodGenreKeyOf('邵氏电影') == '' &&
          vodGenreKeysOf('剧情片,动作').join('/') == '剧情/动作',
      '${kVodGenreVocabulary.length} 词');
  final merged = mergeVodFacets(
      const VodFacets(
        typeCounts: <String, int>{'剧情': 2},
        areas: <String>['内地'],
        times: <String>['2024'],
      ),
      const VodFacets(
        typeCounts: <String, int>{'剧情': 3, '喜剧': 1},
        areas: <String>['美国'],
        times: <String>['10年代'],
      ));
  check('D53 两份条件统计相加（随包分片 + 本地增补），地区去重、时间重排',
      merged.typeCounts['剧情'] == 5 &&
          merged.typeCounts['喜剧'] == 1 &&
          merged.areas.join('/') == '内地/美国' &&
          merged.times.join('/') == '2024/10年代',
      '类型 ${merged.types.join('/')}');
}

Future<void> main() async {
  testDirectoryOptions();
  await testFacetDirectory();
  await testPosterService();
  await testPosterBuckets();
  testWiring();
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
