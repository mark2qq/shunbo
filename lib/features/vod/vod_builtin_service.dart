/// 内置索引的运行期检索服务（纯 Dart，不依赖 Flutter）。
///
/// 职责只有三件，刻意不合并到 [VodLibrary]：
///
///  1. **按栏目懒加载分片** —— 用户进电影栏目只解 `movies.tsv.gz`，
///     其余五片一个字节都不读。全量 13 MB 一次性解开会占 40 MB 堆，
///     真机（API 18 / armv7a）撑不住。
///  2. **检索命中转成可展示条目** —— 命中只有「片名 + 站点 + vod_id」，
///     没有剧集。转 [VodItem] 时把 `episodes` 留空、并在 `id` 上保留
///     `builtin:` 前缀，UI 据此知道「点开要先回源取详情」。
///  3. **详情回源** —— 用户点开某部片时用 `?ac=detail&ids=<vod_id>`
///     取回播放地址，成功后写回 [VodLibrary]，之后走既有播放链路。
///
/// 为什么不在启动时把 13 MB 全部解成对象：135 万条 [VodItem] 至少 400 MB，
/// 解完就 OOM。这里只缓存**解压后的文本**（最大片约 6 MB）与**检索结果**。
library;

import 'dart:typed_data';

import 'vod_builtin_index.dart';
import 'vod_catalog.dart';
import 'vod_facets.dart';

/// 内置索引的运行期状态：分片文本缓存 + 检索入口 + 详情回源。
class BuiltinIndexService {
  BuiltinIndexService({
    required this.loadManifest,
    required this.loadShardBytes,
    required this.fetchDetail,
  });

  /// 读内置 manifest（读不到返回 null）。
  final Future<BuiltinIndexManifest?> Function() loadManifest;

  /// 读某个分片的 gzip 字节（读不到返回 null）。
  final Future<Uint8List?> Function(String file) loadShardBytes;

  /// 回源取详情。成功返回可播条目，失败返回 null。
  ///
  /// 参数是**整条命中**而不是 `(siteIndex, vodId)`：回源后要组装出可展示条目，
  /// 片名与栏目只有命中里才有（详情接口不保证回 `vod_name`），
  /// 只传两个 id 会让回源成功的条目变成「无标题、归错栏目」。
  ///
  /// 由装配层注入：内置索引层不关心 HTTP 细节，也不引 `dart:io`。
  final Future<VodItem?> Function(BuiltinIndexHit hit) fetchDetail;

  BuiltinIndexManifest? _manifest;

  /// 已解压的分片正文（按 sectionKey 缓存）。命中检索时才填充。
  final Map<String, String> _bodies = <String, String>{};

  /// 检索结果缓存：同一查询 + 同一分片集合直接复用。
  final Map<String, List<BuiltinIndexHit>> _hitCache =
      <String, List<BuiltinIndexHit>>{};

  /// 关键词检索缓存（带命中总数，与浏览缓存分开）。
  final Map<String, BuiltinIndexSearchResult> _searchCache =
      <String, BuiltinIndexSearchResult>{};

  /// 正在加载的分片（并发去重：用户连打两个字的间隙不要解两遍）。
  final Map<String, Future<String?>> _loading = <String, Future<String?>>{};

  /// 命中 id → 命中本身。UI 从卡片拿到的是 [VodItem]（只剩 id），
  /// 回源时需要站点下标 + vod_id + 片名，这里留一份索引把它们接回去。
  ///
  /// 上限 [kHitIndexCap]：检索缓存本身有上限，这里只做「最近搜过的」，
  /// 超出后整体清空重建 —— 回源只发生在用户刚搜完就点开的瞬间，
  /// 老条目被丢掉不影响任何路径。
  final Map<String, BuiltinIndexHit> _byId = <String, BuiltinIndexHit>{};

  /// 主命中 id → 同名的其他来源（备选）。
  ///
  /// 打包时每个片名最多保留两条**来自不同站**的记录（`--keep-per-title 2`）：
  /// 索引里的站一旦详情接口抽风，主记录就点不开，而另一个站明明有这部片。
  /// 检索时只把第一条当卡片展示（否则同一部片两张卡），其余存这里做换源。
  final Map<String, List<BuiltinIndexHit>> _alts =
      <String, List<BuiltinIndexHit>>{};

  static const int kHitIndexCap = 4000;

  /// 片名归一（去标点空白、小写）。与打包侧 `dedup_key` 同一口径 ——
  /// 两侧口径不一致的症状是「一部片两张卡」，很难从现象反推。
  static final RegExp _namePunct = RegExp(
      "[\\s\\u3000·・:：,，.。!！?？\"'（）()\\[\\]【】《》\\-—_/\\\\|~]+");

  static String nameKey(String name) =>
      name.toLowerCase().replaceAll(_namePunct, '');

  BuiltinIndexManifest? get manifest => _manifest;

  bool get ready => _manifest != null && !_manifest!.isEmpty;

  /// 已解压的片数（诊断页用）。
  int get loadedShards => _bodies.length;

  /// 已解压的总字符数（诊断页用；约等于堆占用的一半）。
  int get loadedChars =>
      _bodies.values.fold<int>(0, (sum, b) => sum + b.length);

  /// 载入 manifest。失败不抛：调用方据此回退网络同步。
  Future<BuiltinIndexManifest?> ensureManifest() async {
    if (_manifest != null) return _manifest;
    try {
      _manifest = await loadManifest();
    } catch (_) {
      _manifest = null;
    }
    return _manifest;
  }

  /// 清空分片缓存（内置索引更新后必须调用，否则还在用旧文本）。
  void clearCache() {
    _bodies.clear();
    _hitCache.clear();
    _searchCache.clear();
    _loading.clear();
    _byId.clear();
    _alts.clear();
    _manifest = null;
  }

  /// 读一个分片的正文（已解压）。同一片只解一次。
  Future<String?> body(String sectionKey) async {
    final cached = _bodies[sectionKey];
    if (cached != null) return cached;
    final inflight = _loading[sectionKey];
    if (inflight != null) return inflight;
    final task = _loadBody(sectionKey);
    _loading[sectionKey] = task;
    try {
      return await task;
    } finally {
      _loading.remove(sectionKey);
    }
  }

  Future<String?> _loadBody(String sectionKey) async {
    final m = _manifest;
    if (m == null) return null;
    final shard = m.shardFor(sectionKey);
    if (shard == null) return null;
    try {
      final gz = await loadShardBytes(shard.file);
      if (gz == null || gz.isEmpty) return null;
      final text = decodeShardBody(gz);
      _bodies[sectionKey] = text;
      return text;
    } catch (_) {
      return null;
    }
  }

  /// 关键词检索一个栏目分片（**整份目录**，不是已加载的那一页）。
  ///
  /// 匹配四个维度，任一命中即算：
  ///  1. 片名（`斗罗` / `复仇者`）；
  ///  2. 年份（`2020` / `2026`）—— 片名里几乎不出现年份，只匹配片名的话
  ///     「搜 2020 年的电视剧」永远为空，这是第十七次修最刺眼的一条；
  ///  3. 地区（`内地` / `日本`）；
  ///  4. 栏目类目名（`国产剧` / `动作片`）。
  ///
  /// [query] 为空时返回空结果：无关键词的浏览走 [browse]，两者采样口径不同
  /// （浏览要覆盖全片，检索要收敛到命中），混用会让首屏变成一整屏符号片名。
  Future<BuiltinIndexSearchResult> searchDetailed(
    String sectionKey,
    String query, {
    int limit = 200,
  }) async {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return BuiltinIndexSearchResult.empty;
    final cacheKey = '$sectionKey\u0000$q\u0000$limit';
    final cached = _searchCache[cacheKey];
    if (cached != null) return cached;
    final text = await body(sectionKey);
    if (text == null) return BuiltinIndexSearchResult.empty;
    final m = _manifest;
    if (m == null) return BuiltinIndexSearchResult.empty;
    final scanner = BuiltinIndexScanner(manifest: m, sectionKey: sectionKey);
    final raw = scanner.scan(
      text,
      limit: limit,
      match: (lowerName, line) {
        if (lowerName.contains(q)) return true;
        if (line.year.isNotEmpty && line.year.contains(q)) return true;
        for (final i in line.areas) {
          final w = m.areaNameOf(i);
          if (w.isNotEmpty && w.contains(q)) return true;
        }
        final label = line.typeIndex >= 0 && line.typeIndex < m.typeNames.length
            ? m.typeNames[line.typeIndex]
            : '';
        return label.isNotEmpty && label.contains(q);
      },
    );
    final result = BuiltinIndexSearchResult(_dedupe(raw.hits), raw.total);
    _searchCache[cacheKey] = result;
    return result;
  }

  /// 按**筛选条件**扫整份栏目目录（类型 / 地区 / 时间，三者与关系）。
  ///
  /// 为什么要有它：类型行写着「剧情」，目录里有几万条，而列表原来只对
  /// 已加载的 120 条做过滤 —— 点下去只剩几条，用户看到的就是「筛选没用 /
  /// 只筛当前页」。既然条件是从整份目录统计出来的，应用条件也必须作用于
  /// 整份目录，两边口径才能对上。
  ///
  /// 与关键词检索共用一次扫描：`type` 比**词表归一后的类型词**
  /// （类目名 `剧情片` → `剧情`，见 [vodGenreKeysOf]）、`area` 比地区词表
  /// 下标、`time` 比 [vodTimeBucket] 的时间档。全部为空时返回空结果（那是浏览）。
  ///
  /// 第二十三次修删掉了 `category` 入参：站点原始类目名那一行按用户红标
  /// 整行去掉了。
  Future<BuiltinIndexSearchResult> filterSection(
    String sectionKey, {
    String type = '',
    String area = '',
    String time = '',
    int limit = 400,
  }) async {
    if (type.isEmpty && area.isEmpty && time.isEmpty) {
      return BuiltinIndexSearchResult.empty;
    }
    final cacheKey = '$sectionKey\u0000f\u0000$type'
        '\u0000$area\u0000$time\u0000$limit';
    final cached = _searchCache[cacheKey];
    if (cached != null) return cached;
    final text = await body(sectionKey);
    if (text == null) return BuiltinIndexSearchResult.empty;
    final m = _manifest;
    if (m == null) return BuiltinIndexSearchResult.empty;
    final areaIndex = area.isEmpty ? -1 : m.areas.indexOf(area);
    // 条件里给了地区，但词表里没有这个下标 ⇒ 必然一条也匹配不到。
    if (area.isNotEmpty && areaIndex < 0) {
      const none = BuiltinIndexSearchResult(<BuiltinIndexHit>[], 0);
      _searchCache[cacheKey] = none;
      return none;
    }
    final scanner = BuiltinIndexScanner(manifest: m, sectionKey: sectionKey);
    final raw = scanner.scan(
      text,
      limit: limit,
      match: (_, line) {
        final label =
            line.typeIndex >= 0 && line.typeIndex < m.typeNames.length
                ? m.typeNames[line.typeIndex].trim()
                : '';
        if (type.isNotEmpty && !vodGenreKeysOf(label).contains(type)) {
          return false;
        }
        if (areaIndex >= 0 && !line.areas.contains(areaIndex)) return false;
        if (time.isNotEmpty && vodTimeBucket(line.year) != time) return false;
        return true;
      },
    );
    final result = BuiltinIndexSearchResult(_dedupe(raw.hits), raw.total);
    _searchCache[cacheKey] = result;
    return result;
  }

  /// 只要命中列表的版本（老调用方 / 门禁沿用）。
  ///
  /// 新增 [searchDetailed] 是为了同时拿到「全目录命中总数」——
  /// 卡片只铺前 N 张，但命中多少必须如实报，否则「全目录检索」不可见。
  Future<List<BuiltinIndexHit>> search(
    String sectionKey,
    String query, {
    int limit = 200,
  }) async =>
      (await searchDetailed(sectionKey, query, limit: limit)).hits;

  /// 浏览模式：不输入关键词，按栏目把索引片源直接铺进播放列表
  /// （1.0.5 第十六次修，需求「初始进入点播要把索引目录中的片源加载到播放列表」）。
  ///
  /// [page] 是续载序号，不是行偏移：分片按片名排序，顺序取前 N 行会得到
  /// 一整屏 `#` / `0.` 开头的符号片名。这里按 [BuiltinIndexScanner.collect]
  /// 等距采样，`page` 取「每段的第 page 张卡」，因此首屏就覆盖整个分片，
  /// 续载不重复；`page` 用尽后返回空列表。
  ///
  /// 仍然只解**当前栏目**那一片、只把命中的行建成对象：60 万条全建
  /// [VodItem] 在 API18 / armv7a 上必然 OOM。
  Future<List<BuiltinIndexHit>> browse(
    String sectionKey, {
    int page = 0,
    int limit = 120,
  }) async {
    final m = _manifest;
    if (m == null || m.isEmpty) return const <BuiltinIndexHit>[];
    final shard = m.shardFor(sectionKey);
    if (shard == null || shard.records <= 0) return const <BuiltinIndexHit>[];
    final cap = limit < 1 ? 1 : limit;
    var stride = (shard.records / cap).ceil();
    if (stride < 1) stride = 1;
    if (stride > shard.records) stride = shard.records;
    if (page < 0 || page >= stride) return const <BuiltinIndexHit>[];
    // 与关键词检索的缓存键分开，避免「搜过 X」和「浏览第 0 页」互相顶掉。
    final cacheKey = '$sectionKey\u0000browse\u0000$page\u0000$limit';
    final cached = _hitCache[cacheKey];
    if (cached != null) return cached;
    final text = await body(sectionKey);
    if (text == null) return const <BuiltinIndexHit>[];
    final scanner = BuiltinIndexScanner(manifest: m, sectionKey: sectionKey);
    final raw = scanner.collect(
      text,
      offset: page,
      stride: stride,
      limit: cap,
    );
    final hits = _dedupe(raw);
    _hitCache[cacheKey] = hits;
    return hits;
  }

  /// 同名归并：打包侧每个片名最多两条（不同站），这里只留第一条当卡片，
  /// 其余进 `_alts` 做回源换源。不归并的话用户会看到同一部片两张卡。
  /// 检索与浏览共用同一套口径，避免「搜出来一张、浏览出来两张」。
  List<BuiltinIndexHit> _dedupe(Iterable<BuiltinIndexHit> raw) {
    final hits = <BuiltinIndexHit>[];
    final byName = <String, BuiltinIndexHit>{};
    for (final h in raw) {
      final key = nameKey(h.name);
      final first = byName[key];
      if (first == null) {
        byName[key] = h;
        hits.add(h);
        continue;
      }
      final list = _alts[first.id];
      if (list == null) {
        // 与 `_byId` 同样的上限策略：回源只发生在「刚看到就点开」的瞬间，
        // 老条目整体丢掉不影响任何路径，但能挡住无限增长。
        if (_alts.length >= kHitIndexCap) _alts.clear();
        _alts[first.id] = <BuiltinIndexHit>[h];
      } else {
        list.add(h);
      }
    }
    return hits;
  }

  /// 把所有栏目都搜一遍（「全部」检索）。
  ///
  /// 顺序固定为 [VodSection] 的声明顺序，结果拼起来即可 —— 用户看到的是
  /// 「电影里 3 条、电视剧里 8 条」这种可预期的分组，不会因为哪片先加载
  /// 完就跑到前面。
  Future<List<BuiltinIndexHit>> searchAll(
    String query, {
    int limitPerSection = 100,
  }) async {
    final q = query.trim();
    if (q.isEmpty) return const <BuiltinIndexHit>[];
    final m = _manifest;
    if (m == null) return const <BuiltinIndexHit>[];
    final out = <BuiltinIndexHit>[];
    for (final shard in m.shards) {
      final one =
          await searchDetailed(shard.key, q, limit: limitPerSection);
      out.addAll(one.hits);
    }
    return out;
  }

  /// 命中 → 可展示条目。
  ///
  /// `episodes` 为空是**刻意**的：内置索引只有「这部片存在」，
  /// 播放地址还没拿到。UI 用 [isBuiltinHitId] 判断是否需要先回源。
  VodItem toItem(BuiltinIndexHit hit, {String? sourceName}) {
    _remember(hit);
    final m = _manifest;
    final site = m != null && hit.siteIndex >= 0 && hit.siteIndex < m.sites.length
        ? m.sites[hit.siteIndex]
        : null;
    // 类目 id → 中文名（`25` → 「国产剧」）。查不到就留空，**不回退成 id**：
    // 界面上出现「25」这种数字类型，用户只会认为程序坏了。
    final typeLabel = m?.typeNameOf(hit.siteIndex, hit.typeId) ?? '';
    // 地区：命中里存的是词表下标，这里还原成规范词并用 `/` 连接
    // （`内地/中国香港`）—— 筛选侧 [vodAreaTokens] 会再拆回多个词。
    final areaWords = <String>[
      if (m != null)
        for (final i in hit.areas)
          if (m.areaNameOf(i).isNotEmpty) m.areaNameOf(i),
    ];
    return VodItem(
      id: hit.id,
      title: hit.name,
      subtitle: <String>[
        if (site != null) site.name,
        if (typeLabel.isNotEmpty) typeLabel,
        if (hit.year.isNotEmpty) hit.year,
      ].join(' · '),
      description: '内置索引收录：${hit.name}'
          '${site == null ? '' : '（${site.name}）'}。'
          '播放地址在打开时从采集接口获取。',
      license: '内置检索索引 · 播放地址来自第三方采集接口',
      section: vodSectionFromKey(hit.section),
      episodes: const <VodEpisode>[],
      sourceId: kVodBuiltinIndexSourceId,
      // 类型筛选靠 `genre` 走：`vodTypesOf` 的 genre 分支原样返回，
      // 因此索引条目按**原始类目名**（`国产剧` / `动作片`）精确可筛，
      // 与目录里列出的条件词是同一个集合 —— 列出来的词点下去一定有结果。
      genre: typeLabel,
      typeName: typeLabel,
      area: areaWords.join('/'),
      year: hit.year,
    );
  }

  void _remember(BuiltinIndexHit hit) {
    // 第二十四次修：原来到顶是 `_byId.clear()` —— 一次性把**屏幕上正在显示的
    // 那批卡片**的命中也一起扔掉，之后点它们就会撞上「索引记录已失效」。
    // 改成按插入顺序淘汰最早的四分之一（Dart 的 Map 保序，`keys.first` 就是
    // 最早进表的那条），代价是 `_byId` 最多少四分之一，收益是工作集不会
    // 被一次溢出整片清空。
    if (_byId.length >= kHitIndexCap) {
      final drop = kHitIndexCap ~/ 4;
      final stale = _byId.keys.take(drop).toList(growable: false);
      for (final k in stale) {
        _byId.remove(k);
      }
    }
    _byId[hit.id] = hit;
  }

  /// 由条目 id 反查命中（回源用）。只在**本次会话转出来的命中表**里找，
  /// 找不到返回 null。要「查不到也能回源」请用 [hitByIdOrRebuild]。
  BuiltinIndexHit? hitById(String id) => _byId[id];

  /// 由条目 id 反查命中；**表里没有就按 id 结构重建一条**。
  ///
  /// 第二十四次修。起因是用户看到「这条索引记录已失效，请重新检索」，
  /// 但过一会重开又好了、片子其实完全能播。根因：[hitById] 依赖的
  /// [_byId] 只是一个**会话级缓存** ——
  ///  * 到 [kHitIndexCap] 会整表清空（[_remember] 的老做法）；
  ///  * 进程重启后自然是空的；
  ///  * 而屏幕上的卡片是 `VodItem`，它不跟着缓存消失。
  /// 于是「缓存里没有」被当成了「索引失效」，把一次本来能成功的回源挡掉了。
  ///
  /// 条目 id 的格式是 `builtin:站点下标:vod_id`（见 [BuiltinIndexHit.id]），
  /// 而回源（`fetchDetail`）要的正好就是这两个字段 —— 所以只要 id 结构完好、
  /// 站点下标还落在 manifest 里，这条记录就**一定是可回源的**，不需要缓存。
  /// 片名 / 栏目只是展示用，按调用方给的补上即可。
  Future<BuiltinIndexHit?> hitByIdOrRebuild(
    String id, {
    String name = '',
    String section = '',
    String year = '',
  }) async {
    final cached = _byId[id];
    if (cached != null) return cached;
    final ref = parseBuiltinHitId(id);
    if (ref == null) return null;
    final m = await ensureManifest();
    if (m == null || ref.siteIndex >= m.sites.length) return null;
    return BuiltinIndexHit(
      siteIndex: ref.siteIndex,
      vodId: ref.vodId,
      // 类目 id 缺失只影响「类型」这一栏的展示；回源不读它，因此留空
      // 也不会把片子变不可播 —— 比拒绝回源好得多。
      typeId: '',
      name: name,
      section: section,
      year: year,
    );
  }

  /// 批量转换（保持命中顺序）。
  List<VodItem> toItems(Iterable<BuiltinIndexHit> hits) =>
      <VodItem>[for (final h in hits) toItem(h)];

  /// 回源取详情。成功后返回可播条目（`episodes` 非空）。
  ///
  /// 主记录失败（站点挂了 / 该 vod_id 已下架 / 详情里没有直链）时，
  /// 依次试同名的备选来源。全部失败才返回 null —— 这是 `--keep-per-title 2`
  /// 的唯一目的，没有换源的话「保留两条」只是白占体积。
  Future<VodItem?> resolve(BuiltinIndexHit hit) async {
    final primary = await _tryResolve(hit);
    if (primary != null) return primary;
    for (final alt in _alts[hit.id] ?? const <BuiltinIndexHit>[]) {
      final item = await _tryResolve(alt);
      if (item != null) return item;
    }
    return null;
  }

  Future<VodItem?> _tryResolve(BuiltinIndexHit hit) async {
    try {
      final item = await fetchDetail(hit);
      // 无剧集的条目等于不可播（详情接口偶尔返回空 `vod_play_url`），
      // 当失败处理才能走到备选来源。
      if (item == null || item.episodes.isEmpty) return null;
      return item;
    } catch (_) {
      return null;
    }
  }

  /// 某个主命中有几个备选来源（诊断 / 门禁用）。
  int altCountFor(String id) => _alts[id]?.length ?? 0;
}

/// 一次关键词检索的结论：卡片列表 + **整份目录**的命中总数。
///
/// [total] 可能远大于 [hits] 长度：命中上万条时只铺前 N 张卡，
/// 但「命中多少」必须如实报，否则用户会以为目录里就这么多片。
class BuiltinIndexSearchResult {
  const BuiltinIndexSearchResult(this.hits, this.total);

  final List<BuiltinIndexHit> hits;
  final int total;

  static const BuiltinIndexSearchResult empty =
      BuiltinIndexSearchResult(<BuiltinIndexHit>[], 0);
}

/// 内置索引条目的 sourceId 前缀。与第三方源 id 区分开：
/// 内置索引条目在回源成功前**不可播**，UI 必须据此拦一道。
const String kVodBuiltinIndexSourceId = 'builtin-index';

/// 条目 id 是否是内置索引命中（尚未回源）。
bool isBuiltinHitId(String id) => id.startsWith('builtin:');

/// `builtin:<站点下标>:<vod_id>` 的拆解结果。
class BuiltinHitRef {
  const BuiltinHitRef(this.siteIndex, this.vodId);

  final int siteIndex;
  final String vodId;

  @override
  String toString() => 'BuiltinHitRef($siteIndex, $vodId)';
}

/// 拆 `builtin:<站点下标>:<vod_id>`；结构不对返回 null。
///
/// 单独做成顶层纯函数，是为了让门禁能把各种畸形 id（负下标、空 vod_id、
/// 缺分隔符、多冒号）直接喂进来 —— 不必构造一整个服务，也不必读真实分片。
BuiltinHitRef? parseBuiltinHitId(String id) {
  const prefix = 'builtin:';
  if (!id.startsWith(prefix)) return null;
  final rest = id.substring(prefix.length);
  final sep = rest.indexOf(':');
  if (sep <= 0) return null;
  final siteIndex = int.tryParse(rest.substring(0, sep));
  if (siteIndex == null || siteIndex < 0) return null;
  // vod_id 正常不带冒号；真带了也要整段保留 —— 截断只会回源到另一部片，
  // 比「多留几个字符」危险得多。
  final vodId = rest.substring(sep + 1);
  if (vodId.isEmpty) return null;
  return BuiltinHitRef(siteIndex, vodId);
}

/// 栏目键 → [VodSection]。未知键回落 [VodSection.other]，
/// 与「认不出来就归其他、绝不污染电影栏目」的口径一致。
VodSection vodSectionFromKey(String key) {
  for (final s in VodSection.values) {
    if (s.name == key) return s;
  }
  return VodSection.other;
}
