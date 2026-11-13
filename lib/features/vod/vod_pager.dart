/// 第三方点播源的**分页拉取器**（纯 Dart，不依赖 Flutter，可裸 `dart run` 回归）。
///
/// 为什么需要它：1.0.5 之前的实现每个采集站只请求一次 `?ac=list`
/// （等价于 `pg=1`），再取 20 部就收工。默认源 20 个站合计只有 180 部，
/// 而接口自己统计的片量是 **1,197,091 部** —— 差额不是「取数失败」，
/// 是**从来没请求过第 2 页**。实测响应里明明白白带着
/// `"pagecount":4255,"total":85082`（电影天堂）、`"pagecount":8573,"total":171459`
/// （暴风资源），这些字段此前被整体丢弃。
///
/// 但百万级条目不可能一次装进电视内存（4000 部就已经是十几 MB 的 URI 表）。
/// 因此这里做成**游标式分页**：每次 [VodSourcePager.next] 只拉「若干个站各一页」，
/// 返回这一批新增条目；用户继续往下翻就继续 next()，直到所有站翻完或触到
/// [kMaxThirdPartyItems] 这个内存安全线。界面同时显示「接口统计 N 部 / 已加载 M 部」，
/// 让「进度」是可见的，而不是一个说不清的 180。
library;

import '../../data/onboarding/source_config_url.dart';
import 'third_party_vod.dart';
import 'vod_catalog.dart';

/// 取一段文本（列表 / 详情 / 派生地址探测都用它）。
typedef VodPageFetcher = Future<SourceConfigUrlResult> Function(
  String url, {
  bool allowInsecureHttp,
});

/// 一个采集站的分页游标。
class VodSiteCursor {
  VodSiteCursor(this.site);

  final CmsSite site;

  /// 下一次要请求的页码（1 起）。
  int page = 1;
  int pageCount = 0;
  int total = 0;
  bool done = false;

  /// 上一页第一条的 `vod_id`：有些站不认 `pg`，每页都返回同一批数据，
  /// 用它识别「翻页无效」，避免死循环。
  String lastFirstId = '';

  /// 连续取数失败次数（≥2 判定该站不可用）。
  int failures = 0;

  /// 该站是否已确认「能给出直链媒体」。`/play/` 派生只在确认后整站启用。
  bool directOk = false;

  /// 该站是否支持 `?ac=detail&pg=N` 合并接口（一次给全 20 部）。
  /// 不支持就回落成「列表 + 分批详情」，只是慢一些，结果一样。
  bool useDetailPage = true;

  /// 该站是否已做过「播放页 → index.m3u8」的采样验证（每站只做一次）。
  bool deriveProbed = false;
  bool deriveWorks = false;

  /// 站点类目表（`type_pid` 父链）。`?ac=detail&pg=N` 响应里没有 `class`，
  /// 所以第一页会并行取一次 `?ac=list` 拿它，用于把「现代言情」这类
  /// 短剧子类目归到短视频栏目。失败回落空表，不影响本页出片。
  CmsCategoryTable categories = CmsCategoryTable.empty;
  bool categoriesProbed = false;
  Future<void>? categoryProbe;

  /// 该站已成功贡献的条目数。
  int contributed = 0;
}

/// 一轮分页的结果。
class VodBatch {
  const VodBatch({
    this.items = const <VodItem>[],
    this.added = 0,
    this.fetched = 0,
    this.discoveredTotal = 0,
    this.loadedTotal = 0,
    this.done = false,
    this.sitesLoaded = 0,
    this.sitesTotal = 0,
    this.pages = 0,
  });

  /// 本批新增条目（已去重）。
  final List<VodItem> items;

  /// 实际新增条数（可能小于 [items] 长度，不会：items 就是新增）。
  final int added;

  /// 本批从接口取回多少条（含被去重丢掉的）。
  final int fetched;

  /// 接口自己报的总片量（已知站点的 `total` 之和；0 表示接口没给）。
  final int discoveredTotal;

  /// 目前已加载条目数（分页器累计）。
  final int loadedTotal;

  /// 是否已经翻到所有站点的最后一页 / 触到上限。
  final bool done;

  final int sitesLoaded;
  final int sitesTotal;

  /// 本批实际发了多少页列表请求。
  final int pages;

  bool get empty => items.isEmpty;
}

/// 分页拉取器。
class VodSourcePager {
  VodSourcePager({
    required List<CmsSite> sites,
    required String sourceId,
    required VodPageFetcher fetcher,
    this.headers = const <String, String>{},
    this.allowInsecureHttp = false,
    this.itemsPerPage = kVodItemsPerSitePage,
    this.sitesPerBatch = kVodSitesPerBatch,
    this.maxItems = kMaxThirdPartyItems,
    List<VodSiteCursor>? cursors,
    Set<String>? seenKeys,
  })  : _cursors = cursors ?? <VodSiteCursor>[for (final s in sites) VodSiteCursor(s)],
        _sourceId = sourceId,
        _fetcher = fetcher,
        _seenKeys = seenKeys ?? <String>{};

  final List<VodSiteCursor> _cursors;
  final String _sourceId;
  final VodPageFetcher _fetcher;
  final Map<String, String> headers;
  final bool allowInsecureHttp;
  final int itemsPerPage;
  final int sitesPerBatch;
  final int maxItems;

  /// 跨站去重键（`标题|年份`）。九个站里同一个片子往往有六七份，
  /// 全留着只会让同一张海报刷满整个栏目。
  final Set<String> _seenKeys;

  int _roundRobin = 0;
  int _loaded = 0;
  int _discovered = 0;
  bool _done = false;

  List<CmsSite> get sites =>
      List<CmsSite>.unmodifiable(_cursors.map((c) => c.site));

  int get siteCount => _cursors.length;

  /// 已经翻完（或判定不可用）的站点数。
  int get finishedSites => _cursors.where((c) => c.done).length;

  /// 至少成功取到过一页的站点数。
  int get loadedSites => _cursors.where((c) => c.contributed > 0).length;

  int get loadedTotal => _loaded;

  /// 接口自己统计的总片量（未知为 0）。
  int get discoveredTotal => _discovered;

  bool get done => _done;

  /// 拉下一批：每个「还没翻完」的站点各取一页，站点之间轮转，
  /// 因此连点加载更多会把各站的第 1、2、3… 页均匀地铺开，而不是
  /// 先把某个站翻到底再换下一个（那样前几十页全是同一家的片）。
  Future<VodBatch> next() async {
    if (_done) {
      return VodBatch(loadedTotal: _loaded, discoveredTotal: _discovered, done: true,
          sitesLoaded: loadedSites, sitesTotal: siteCount);
    }
    if (_loaded >= maxItems) {
      _done = true;
      return VodBatch(loadedTotal: _loaded, discoveredTotal: _discovered, done: true,
          sitesLoaded: loadedSites, sitesTotal: siteCount);
    }

    final targets = <VodSiteCursor>[];
    var scanned = 0;
    while (targets.length < sitesPerBatch && scanned < _cursors.length) {
      final c = _cursors[(_roundRobin + scanned) % _cursors.length];
      if (!c.done) targets.add(c);
      scanned++;
    }
    _roundRobin = (_roundRobin + (scanned == 0 ? 1 : scanned)) % _cursors.length;

    if (targets.isEmpty) {
      _done = true;
      return VodBatch(loadedTotal: _loaded, discoveredTotal: _discovered, done: true,
          sitesLoaded: loadedSites, sitesTotal: siteCount);
    }

    final results = await Future.wait(<Future<_PageOutcome>>[
      for (final c in targets) _loadPage(c),
    ]);

    final items = <VodItem>[];
    var fetched = 0;
    for (final r in results) {
      fetched += r.fetched;
      for (final item in r.items) {
        if (_loaded + items.length >= maxItems) break;
        final key = _dedupeKey(item);
        if (key.isNotEmpty && !_seenKeys.add(key)) continue;
        items.add(item);
      }
    }
    _loaded += items.length;
    _discovered = _recomputeDiscovered();
    if (_cursors.every((c) => c.done) || _loaded >= maxItems) _done = true;

    return VodBatch(
      items: List<VodItem>.unmodifiable(items),
      added: items.length,
      fetched: fetched,
      discoveredTotal: _discovered,
      loadedTotal: _loaded,
      done: _done,
      sitesLoaded: loadedSites,
      sitesTotal: siteCount,
      pages: results.where((r) => r.pages > 0).length,
    );
  }

  int _recomputeDiscovered() {
    var n = 0;
    for (final c in _cursors) {
      if (c.total > 0) n += c.total;
    }
    return n;
  }

  String _dedupeKey(VodItem item) => vodContentKey(item);

  Future<_PageOutcome> _loadPage(VodSiteCursor c) async {
    if (c.done) return const _PageOutcome();
    // 类目探测与取页并行：只发一次，且失败绝不连累本页内容。
    c.categoryProbe ??= _ensureCategories(c);
    try {
      // 首选合并接口：一次请求拿到 20 部的元数据 + 播放地址。
      if (c.useDetailPage) {
        final fast = await _loadViaDetailPage(c);
        if (fast != null) return fast;
        // 该站不支持合并接口（返回里没有播放地址）：本页退回老路径。
        c.useDetailPage = false;
      }
      return await _loadViaList(c);
    } catch (_) {
      _fail(c);
      return const _PageOutcome();
    }
  }

  /// 取一次站点类目表。任何失败都只回落空表，**不调用 `_fail`**：
  /// 少一个类目字段不该让整个站被判死。
  Future<void> _ensureCategories(VodSiteCursor c) async {
    if (c.categoriesProbed) return;
    c.categoriesProbed = true;
    try {
      final res = await _fetcher(
        c.site.listUrl,
        allowInsecureHttp: allowInsecureHttp,
      );
      if (!res.ok || res.text == null) return;
      final table = parseCmsCategories(res.text!);
      if (!table.isEmpty) c.categories = table;
    } catch (_) {
      // 类目表拿不到就按文本关键词归类。
    }
  }

  /// `?ac=detail&pg=N` 路径。返回 null 表示该站不支持，交给调用方回退。
  Future<_PageOutcome?> _loadViaDetailPage(VodSiteCursor c) async {
    final res = await _fetcher(
      c.site.detailPageUrl(c.page),
      allowInsecureHttp: allowInsecureHttp,
    );
    if (!res.ok || res.text == null) {
      // 站点级不可达直接判死；HTTP 错误（比如某站封了 ac=detail）则回退老路径，
      // 别因为一个接口形态不兼容就丢掉整个站。
      final networkDown = res.failure == SourceConfigUrlFailure.timeout ||
          res.failure == SourceConfigUrlFailure.connection;
      if (networkDown) {
        _fail(c, res.failure);
        return const _PageOutcome();
      }
      return null;
    }
    final page = await parseCmsDetailPageAsync(
      res.text!,
      maxItems: itemsPerPage,
      baseUrl: c.site.api,
    );
    if (page.entries.isEmpty) {
      c.done = true;
      return const _PageOutcome();
    }
    if (!page.hasPlayableDetails) return null; // 站不支持，回退
    if (!page.categories.isEmpty) c.categories = page.categories;

    if (!_advanceCursor(c, page.page, page.pageCount, page.total,
        page.entries.first.id)) {
      return const _PageOutcome();
    }
    final built = await _finishPage(c, page.entries, page.details);
    if (built == null) {
      c.done = true;
      return _PageOutcome(fetched: page.entries.length, pages: 1);
    }
    c.contributed += built.length;
    return _PageOutcome(
        items: built, fetched: page.entries.length, pages: 1);
  }

  /// 老路径：`?ac=list&pg=N` + 分批详情。
  Future<_PageOutcome> _loadViaList(VodSiteCursor c) async {
    final result = await _fetcher(
      c.site.listUrlAt(c.page),
      allowInsecureHttp: allowInsecureHttp,
    );
    if (!result.ok || result.text == null) {
      _fail(c, result.failure);
      return const _PageOutcome();
    }
    final listing = await parseCmsListingAsync(
      result.text!,
      maxItems: itemsPerPage,
      baseUrl: c.site.api,
    );
    if (listing.entries.isEmpty) {
      c.done = true;
      return const _PageOutcome();
    }
    if (!listing.categories.isEmpty) c.categories = listing.categories;
    if (!_advanceCursor(c, listing.page, listing.pageCount, listing.total,
        listing.entries.first.id)) {
      return const _PageOutcome();
    }
    final built = await _buildForPage(c, listing.entries);
    if (built == null) {
      c.done = true;
      return _PageOutcome(fetched: listing.entries.length, pages: 1);
    }
    c.contributed += built.length;
    return _PageOutcome(
        items: built, fetched: listing.entries.length, pages: 1);
  }

  /// 推进游标；返回 false 表示「这页不用继续处理」（翻页无效 / 已到底）。
  bool _advanceCursor(
      VodSiteCursor c, int echoedPage, int pageCount, int total, String firstId) {
    if (pageCount > 0) c.pageCount = pageCount;
    if (total > 0) c.total = total;
    // 站不认 `pg`：每页都回同一批数据 → 认定翻到底，别再空转请求。
    if (c.lastFirstId.isNotEmpty && c.lastFirstId == firstId) {
      c.done = true;
      return false;
    }
    c.lastFirstId = firstId;
    c.failures = 0;
    final echoed = echoedPage > 0 ? echoedPage : c.page;
    c.page = echoed + 1;
    if (c.pageCount > 0 && c.page > c.pageCount) c.done = true;
    return true;
  }

  void _fail(VodSiteCursor c, [SourceConfigUrlFailure? reason]) {
    // 「连不上 / 超时」基本等于这个站已经死了：实测一轮导入里这类站点占一半，
    // 每次都要白等一个超时窗口。直接判死，别让它们把每一批都拖到 6 秒。
    // 其它失败（HTTP 5xx、偶发脏数据）给两次机会，避免一次抖动丢掉几千部。
    if (reason == SourceConfigUrlFailure.timeout ||
        reason == SourceConfigUrlFailure.connection) {
      c.done = true;
      return;
    }
    c.failures++;
    if (c.failures >= 2) c.done = true;
    c.page++; // 跳过这一页继续，别在同一页上反复卡
  }

  /// 取详情 → 合并成条目 → 校正「播放页 / 直链」形态。返回 null 表示该站不可用。
  ///
  /// 详情按 4 部一批、**所有批次同时发**：原来是一个 for 循环串行等，
  /// 一页 20 部就是 5 个往返排队，单站要 5–8 秒。并发之后一页的耗时
  /// 约等于「最慢的那个批次」，是分页能快起来的关键。
  Future<List<VodItem>?> _buildForPage(
      VodSiteCursor c, List<CmsEntry> entries) async {
    final details = <String, CmsDetail>{};
    var detailFailures = 0;
    final batches = <Future<Map<String, CmsDetail>?>>[];
    for (var i = 0; i < entries.length; i += 4) {
      final end = i + 4 > entries.length ? entries.length : i + 4;
      final batch = entries.sublist(i, end);
      batches.add(_fetchDetails(c, batch));
    }
    for (final r in await Future.wait(batches)) {
      if (r == null) {
        detailFailures++;
        continue;
      }
      details.addAll(r);
    }
    if (details.isEmpty) {
      if (detailFailures > 0) _fail(c);
      return const <VodItem>[];
    }
    return _finishPage(c, entries, details);
  }

  /// 直链校正 + 组装条目。返回 null 表示整站不可用（只给网页跳转页）。
  Future<List<VodItem>?> _finishPage(
      VodSiteCursor c, List<CmsEntry> entries, Map<String, CmsDetail> details) async {
    var effective = details;
    final hasDirect = _detailsHaveDirectMedia(details);
    if (!hasDirect) {
      if (!c.deriveProbed) {
        final derived = await _probeDerive(c, details);
        c.deriveProbed = true;
        c.deriveWorks = derived != null;
      }
      if (!c.deriveWorks) {
        // 整站只给网页跳转页（/share/<hash>）：留着只会让用户点开全黑。
        return null;
      }
      effective = _applyDerive(details);
    }
    c.directOk = true;

    // 类目探测与本页取数是并发的，组装前等它一下（超时/失败由
    // `_ensureCategories` 自己吞掉，这里不会把整页拖死）。
    final probe = c.categoryProbe;
    if (probe != null) {
      try {
        await probe;
      } catch (_) {}
    }
    return buildCmsItems(
      entries: entries,
      details: effective,
      sourceId: _sourceId,
      headers: headers,
      idScope: c.site.key.isEmpty
          ? 'site${_cursors.indexOf(c)}'
          : c.site.key,
      categories: c.categories,
    );
  }

  /// 取一批（≤4 部）详情；失败返回 null（由调用方计数，不抛异常）。
  Future<Map<String, CmsDetail>?> _fetchDetails(
      VodSiteCursor c, List<CmsEntry> batch) async {
    try {
      final res = await _fetcher(
        c.site.detailUrl(batch.map((e) => e.id)),
        allowInsecureHttp: allowInsecureHttp,
      );
      if (!res.ok || res.text == null) return null;
      return await parseCmsDetailsAsync(res.text!, baseUrl: c.site.api);
    } catch (_) {
      return null;
    }
  }

  bool _detailsHaveDirectMedia(Map<String, CmsDetail> details) {    for (final d in details.values) {
      for (final e in d.episodes) {
        if (looksLikeDirectMedia(e.url)) return true;
      }
    }
    return false;
  }

  /// 采样一条 `/play/<id>` → `/play/<id>/index.m3u8`，验证通过才整站改写。
  Future<Map<String, CmsDetail>?> _probeDerive(
      VodSiteCursor c, Map<String, CmsDetail> details) async {
    String? raw;
    for (final d in details.values) {
      for (final e in d.episodes) {
        if (deriveDirectMediaUrl(e.url) != null) {
          raw = e.url;
          break;
        }
      }
      if (raw != null) break;
    }
    if (raw == null) return null;
    final probe = deriveDirectMediaUrl(raw)!;
    final res =
        await _fetcher(probe, allowInsecureHttp: allowInsecureHttp);
    if (!res.ok || res.text == null) return null;
    if (!res.text!.trimLeft().startsWith('#EXTM3U')) return null;
    return details;
  }

  Map<String, CmsDetail> _applyDerive(Map<String, CmsDetail> details) =>
      <String, CmsDetail>{
        for (final entry in details.entries)
          entry.key: CmsDetail(
            content: entry.value.content,
            poster: entry.value.poster,
            episodes: <VodEpisode>[
              for (final e in entry.value.episodes)
                VodEpisode(
                  number: e.number,
                  title: e.title,
                  url: deriveDirectMediaUrl(e.url) ?? e.url,
                ),
            ],
          ),
      };
}

class _PageOutcome {
  const _PageOutcome({
    this.items = const <VodItem>[],
    this.fetched = 0,
    this.pages = 0,
  });

  final List<VodItem> items;
  final int fetched;
  final int pages;
}
