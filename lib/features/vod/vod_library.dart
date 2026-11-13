// 刻意不依赖 flutter/foundation：门禁脚本用裸 `dart run` 回归，
// ChangeNotifier 会拉进 dart:ui 而在 Dart CLI 下无法加载。
// 这里自带极简监听协议，UI 侧调用方式不变（addListener/removeListener）。
import '../../core/scheduler/source_catalog.dart';
import '../../core/source/memory_source_adapter.dart';
import '../../core/source/source_adapter.dart';
import '../../core/source/source_profile.dart';
import '../../core/source/source_registry.dart';
import 'vod_catalog.dart';
import 'vod_search.dart';

/// 1.0.5：可在运行期替换的「外部点播片库」。
///
/// 内置片库（6 条公开授权素材）永远在位；第三方接口接入的条目作为**一组外部源**
/// 追加进来，并注册成普通 [MemorySourceAdapter]。这样起播、续播、进度落盘、
/// 自动连播、换源对齐全都复用 1.0.4 的既有链路，不需要第二套播放逻辑。
///
/// 默认没有任何外部条目 ⇒ 列表与 1.0.4 逐项一致。
///
/// 1.0.5 第三次修：改成**增量追加**（[append]）。分页接入时每批只有几十条，
/// 原来每批都 `clear + 重建适配器`，4000 条时每批要重算一遍全部剧集/地址表；
/// 现在适配器只注册一次、直接指向同一份可变表，追加是 O(新增条数)。
class VodLibrary {
  VodLibrary({required SourceRegistry registry, required SourceCatalog catalog})
      : _registry = registry,
        _catalog = catalog {
    final builtIn = VodCatalog.buildAdapter();
    _registry.register(builtIn);
    _catalog.register(builtIn.profile);
  }

  final SourceRegistry _registry;
  final SourceCatalog _catalog;

  final List<VodItem> _external = <VodItem>[];
  final Set<String> _itemIds = <String>{};

  /// `id → 在 _external 里的下标`。接口刷新时同一 id 会带着新元数据再回来，
  /// 就地更新而不是丢掉，否则「本地记录随接口更新同步」就是一句空话。
  final Map<String, int> _indexById = <String, int>{};

  /// `片名|年份 → id`。分页器、片库、本地检索记录三处共用 `vodContentKey`，
  /// 保证「栏目里有几条、本地记录就有几条」，不会出现两处各去重一遍。
  final Map<String, String> _keyToId = <String, String>{};

  /// 适配器持有的剧集 / 地址表。**同一份实例**随条目一起增长，
  /// 因此追加不需要重建适配器。
  final Map<String, List<EpisodeInfo>> _episodes = <String, List<EpisodeInfo>>{};
  final Map<String, List<PlayUrl>> _urls = <String, List<PlayUrl>>{};
  MemorySourceAdapter? _adapter;
  String? _adapterSourceId;

  Map<String, String> _headers = const <String, String>{};

  /// 分栏缓存（1.0.5 第四次修）。
  ///
  /// 原实现每次 build 都 `[...内置, ...外部].where(section)` 重新算一遍：
  /// 外部条目到 360 部后，三个栏目页 + 每秒一次进度刷新叠加起来就是
  /// 每秒几十次 O(n) 分配，切栏目时肉眼可见地卡。改为按栏缓存 + 版本号失效，
  /// 空查询时直接返回**同一个列表实例**，SliverGrid 的 childCount 也稳定。
  final Map<VodSection, List<VodItem>> _sectionCache =
      <VodSection, List<VodItem>>{};
  List<VodItem>? _allCache;

  /// 片库版本号：任何增删都 +1。UI 可据此判断「列表真的变了」而不是每次都重建。
  int get revision => _revision;
  int _revision = 0;

  String? _activeSourceName;
  String? _lastNote;

  /// 本地缓存写入时间（从磁盘恢复时赋值）。界面据此判断「能不能先秒开」。
  DateTime? cachedAt;

  final List<void Function()> _listeners = <void Function()>[];

  /// 极简可监听协议：与 ChangeNotifier 的调用形状一致，
  /// 但不引入 dart:ui，纯 Dart 门禁可以直接实例化。
  void addListener(void Function() listener) => _listeners.add(listener);

  void removeListener(void Function() listener) => _listeners.remove(listener);

  void _notify() {
    _invalidateCache();
    for (final l in List<void Function()>.of(_listeners)) {
      l();
    }
  }

  void _invalidateCache() {
    _revision++;
    _allCache = null;
    _sectionCache.clear();
  }

  /// 内置 + 外部，内置始终在前（空查询时顺序与 1.0.4 一致）。
  List<VodItem> get items =>
      _allCache ??= List<VodItem>.unmodifiable(<VodItem>[
        ...VodCatalog.all,
        ..._external,
      ]);

  /// 栏目展示。电影栏目额外过一道 [isMovieSectionItem]：即使有条目绕过
  /// [normalizeVodItem] 混进来（契约 JSON、旧缓存），也不会出现在电影页。
  List<VodItem> inSection(VodSection section) => _sectionCache[section] ??=
      List<VodItem>.unmodifiable(items
          .where((i) =>
              i.section == section &&
              (section != VodSection.movies || isMovieSectionItem(i)))
          .toList(growable: false));

  /// 本地内容检索目录命中（纯内存、**不发网络请求**）。
  ///
  /// 与 `vod-library.json` 同源：冷启动由 [restore] 读回那一份记录，同步过程中
  /// 每批 [append] 增量并入，因此任何时刻「栏目里看得到的」和「检索能命中的」
  /// 都是同一份数据，检索结果不会比栏目里更新或更旧。
  List<VodItem> localMatches(String query) => filterVodItems(items, query);

  VodItem? byId(String id) {
    for (final i in items) {
      if (i.id == id) return i;
    }
    return null;
  }

  int get externalCount => _external.length;

  String? get activeSourceName => _activeSourceName;

  String? get lastNote => _lastNote;

  /// 当前外部源的请求头（Referer / UA）。落盘缓存要带着它，
  /// 否则冷启动恢复出来的条目一播 403。
  Map<String, String> get headers => _headers;

  /// 外部条目的只读快照（落盘用）。
  List<VodItem> get externalItems => List<VodItem>.unmodifiable(_external);

  /// 缓存是否还新鲜（默认 12 小时）。新鲜时栏目页直接秒开，不重新拉网。
  bool cacheFresh({Duration maxAge = const Duration(hours: 12)}) {
    final t = cachedAt;
    if (t == null || _external.isEmpty) return false;
    return DateTime.now().difference(t) < maxAge;
  }

  /// 安装（替换）外部源：清空后追加。保留给「换地址 / 重置」这条路径。
  int install({
    required String sourceId,
    required List<VodItem> incoming,
    required String sourceName,
    Map<String, String> headers = const <String, String>{},
  }) {
    _clearExternal();
    return append(
      sourceId: sourceId,
      incoming: incoming,
      sourceName: sourceName,
      headers: headers,
    );
  }

  /// 增量追加 / 就地更新（分页加载与本地记录恢复共用的主路径）。
  ///
  /// 换源（sourceId 不同）会先清空旧源；同源时：
  ///  * 新条目接到尾部；
  ///  * 同 id 但元数据变了（片名、类型、年份、地区、剧集地址、栏目）就地替换，
  ///    这是「本地记录随接口数据更新同步」的落点；
  ///  * 同 `片名|年份` 但 id 不同的镜像条目丢弃，避免重复；
  ///  * 每个条目都过 [normalizeVodItem]，短视频内容统一归入短视频栏目 ——
  ///    老版本缓存恢复与后续新取的数据走的是同一条规则。
  int append({
    required String sourceId,
    required List<VodItem> incoming,
    required String sourceName,
    Map<String, String> headers = const <String, String>{},
  }) {
    if (_adapterSourceId != null && _adapterSourceId != sourceId) {
      _clearExternal();
    }
    final builtInIds = VodCatalog.all.map((i) => i.id).toSet();
    final accepted = <VodItem>[];
    var changed = 0;
    for (final raw in incoming) {
      final item = normalizeVodItem(raw);
      if (builtInIds.contains(item.id)) continue;
      final key = vodContentKey(item);
      final owner = key.isEmpty ? null : _keyToId[key];
      if (owner != null && owner != item.id) continue; // 跨站同名镜像
      final at = _indexById[item.id];
      if (at != null) {
        final old = _external[at];
        if (vodContentFingerprint(old) == vodContentFingerprint(item)) {
          continue;
        }
        // 年份/片名变了会同时改变去重键，旧键必须撤掉，
        // 否则刷新后「同名镜像」判不出来，栏目里会出现两条。
        final oldKey = vodContentKey(old);
        if (oldKey.isNotEmpty && oldKey != key && _keyToId[oldKey] == item.id) {
          _keyToId.remove(oldKey);
        }
        if (key.isNotEmpty) _keyToId[key] = item.id;
        _unregisterItem(old.id);
        _external[at] = item;
        _registerItem(item);
        changed++;
        continue;
      }
      if (!_itemIds.add(item.id)) continue;
      if (key.isNotEmpty) _keyToId[key] = item.id;
      _indexById[item.id] = _external.length + accepted.length;
      accepted.add(item);
      changed++;
    }
    if (changed == 0) {
      // 重复条目（跨站同名 / 同一页重复拉 / 刷新后元数据没变）
      // 不算失败，也不触发整页重建。
      return 0;
    }
    for (final item in accepted) {
      _registerItem(item);
    }
    if (headers.isNotEmpty) _headers = Map<String, String>.unmodifiable(headers);
    _ensureAdapter(sourceId);
    _external.addAll(accepted);
    _activeSourceName = sourceName;
    _lastNote = '已接入 $sourceName：${_external.length} 部可播放条目';
    _notify();
    return changed;
  }

  void _registerItem(VodItem item) {
    _episodes[item.id] = item.episodes
        .map((e) => EpisodeInfo(episode: e.number, title: e.title))
        .toList(growable: false);
    for (final e in item.episodes) {
      _urls['${item.id}#${e.number}'] = <PlayUrl>[
        PlayUrl(url: e.url, qualityRank: 50),
      ];
    }
  }

  /// 已注册过适配器的源 id。外部采集源之外，内置索引回源的条目也要有自己的
  /// 适配器（`sourceId` 不同就是不同的源），但**不能**走 [_ensureAdapter]
  /// —— 那会把「当前外部源」指针指过去，外部目录的去重就全乱了。
  final Set<String> _adapterIds = <String>{};

  /// 把「内置索引回源成功」的条目挂进播放链路。
  ///
  /// 为什么不能直接用 [append]：`append` 发现 `sourceId` 变了会
  /// `_clearExternal()`，即「从内置索引点开一部片」会把用户已经同步下来的
  /// 几万条外部目录整批清空。回源条目属于内置索引这条源，与外部采集源并行
  /// 存在，所以这里只做两件事：注册剧集/地址表 + 保证该 sourceId 有适配器。
  ///
  /// 不写进 [_external] 也不进栏目列表：内置索引有十几万条，塞进来既撑爆
  /// 一万条缓存上限，也会让「栏目」变成另一个检索结果页。索引只负责搜得到。
  void adoptResolved(VodItem item) {
    if (item.episodes.isEmpty) return;
    _registerItem(item);
    _ensureAdapterFor(item.sourceId);
    _notify();
  }

  /// 批量把「生成索引目录」里的可播条目挂进播放链路（1.0.5 第十六次修）。
  ///
  /// 与 [adoptResolved] 同一口径：不写 [_external]、不碰当前外部源指针，
  /// 只注册剧集/地址表并保证 sourceId 有适配器 —— 这样 `startPlayback`
  /// 用 `sourceId + mediaId` 就能找到地址，续播 / 换源 / 自动连播全部复用。
  ///
  /// 差别只在**只 notify 一次**：首屏一次挂上百条，逐条 [adoptResolved]
  /// 会触发上百次整页重建（栏目页监听着本对象）。
  int adoptMany(Iterable<VodItem> items) {
    var n = 0;
    for (final item in items) {
      if (item.episodes.isEmpty) continue;
      // 冷启动时 `_headers` 可能还没从本地缓存恢复：条目自带的请求头
      // （Referer / UA）补上，否则适配器取地址时不会带，一播就 403。
      if (_headers.isEmpty && item.headers.isNotEmpty) {
        _headers = Map<String, String>.unmodifiable(item.headers);
      }
      _registerItem(item);
      _ensureAdapterFor(item.sourceId);
      n++;
    }
    if (n > 0) _notify();
    return n;
  }

  void _ensureAdapterFor(String sourceId) {
    if (sourceId.isEmpty) return;
    // 已经是「当前外部源」：适配器在手，剧集表本来就是同一份实例，直接复用。
    if (sourceId == _adapterSourceId) return;
    if (!_adapterIds.add(sourceId)) return;
    final adapter = MemorySourceAdapter(
      id: sourceId,
      profile: SourceProfile(name: sourceId),
      qualityRank: 30,
      episodes: _episodes,
      urls: _urls,
      playbackHeaders: _headers,
    );
    _registry.register(adapter);
    _catalog.register(adapter.profile);
  }

  void _unregisterItem(String id) {
    _episodes.remove(id);
    _urls.removeWhere((k, _) => k.startsWith('$id#'));
  }

  /// 从磁盘缓存恢复（冷启动秒开）。
  ///
  /// 与 [append] 的差别：恢复历史时间戳、不把 `cachedAt` 覆盖成「现在」。
  void restore({
    required String sourceId,
    required List<VodItem> items,
    required String sourceName,
    Map<String, String> headers = const <String, String>{},
    DateTime? savedAt,
  }) {
    if (items.isEmpty) return;
    append(
      sourceId: sourceId,
      incoming: items,
      sourceName: sourceName,
      headers: headers,
    );
    cachedAt = savedAt ?? DateTime.now();
  }

  /// 记录「这次数据已经落盘」。UI 据此在下次启动时判定缓存是否新鲜。
  void markCached(DateTime at) => cachedAt = at;

  void _ensureAdapter(String sourceId) {
    if (_adapterSourceId == sourceId && _adapter != null) return;
    _adapterSourceId = sourceId;
    final adapter = MemorySourceAdapter(
      id: sourceId,
      // 第三方采集接口不声明集数偏移 / 广告插入，画像保持全零，
      // 内容坐标与原始坐标一致，续播不会「差一集」。
      profile: SourceProfile(name: sourceId),
      qualityRank: 40,
      episodes: _episodes,
      urls: _urls,
      playbackHeaders: _headers,
    );
    _registry.register(adapter);
    _catalog.register(adapter.profile);
    _adapter = adapter;
  }

  /// 清空外部源并注销适配器（换地址 / 恢复默认时调用）。
  void clearExternal() {
    if (_itemIds.isEmpty && _external.isEmpty) return;
    _clearExternal();
    _lastNote = '已移除第三方点播源，恢复内置片库';
    _notify();
  }

  void _clearExternal() {
    final id = _adapterSourceId;
    if (id != null) {
      _registry.unregister(id);
      _catalog.unregister(id);
    }
    _adapterSourceId = null;
    _adapter = null;
    _itemIds.clear();
    _indexById.clear();
    _keyToId.clear();
    _external.clear();
    _episodes.clear();
    _urls.clear();
    _activeSourceName = null;
    cachedAt = null;
  }
}
