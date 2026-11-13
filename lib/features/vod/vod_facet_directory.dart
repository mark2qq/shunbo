/// 「检索条件目录」：从**整份片源索引目录**动态加载全部可筛选项
/// （1.0.5 第十七次修，纯 Dart，不依赖 Flutter / IO）。
///
/// ## 修之前错在哪
///
/// 顶部「类型 / 地区 / 时间」三行由 `VodFacetsCache.of(revision, all)` 统计，
/// 而 `all` 是**当前已经加载进列表的那 120 条**。再叠三层截断
/// （`minCount=2` 丢长尾、`maxTypes=36`、UI `take(9) / take(18)`），
/// 结果是「目录里明明有几十个类目，条件里只剩 8 个词」；内置精简索引
/// 根本没有 `vod_area` / `vod_year` 两列，地区与时间两行**整行消失**，
/// 界面也不说明为什么没有。条件随列表续载还会变，属于典型的过期 / 不一致。
///
/// ## 现在的口径
///
/// * 条件来自**目录本身**：
///   - 随包内置索引 → 解本栏目那一片，逐行统计 `(站点, 类目)` 的全部取值，
///     经 `typeNames` 映射成中文类目名；
///   - 生成目录 `vod-index.json` → 遍历该栏目全部条目的
///     `genre / typeName / area / year`；
/// * **完整覆盖**：`minCount = 1`、不设 `maxTypes` 上限、不过滤长尾；
///   只剔除「点了必然筛不出东西」的值（与 `vodTypesOf` 同一套取词口径），
///   保证「列出来的条件」与「点下去能匹配的条件」是同一个集合；
/// * **变更同步**：缓存键含 `目录身份(来源+接口+时间戳+条数) \u0000 栏目`，
///   目录一换就是新键，自动重新加载；旧条件里已不存在的选中值会被清掉；
/// * **空 / 异常可见**：五态 `idle / loading / ready / empty / error`，
///   目录没读到是 error、读到了但没有任何可筛项是 empty，两者都在
///   检索区域给出明确文案 + 重试入口，**列表与关键词检索不受影响**。
library;

import 'dart:async';

import 'vod_builtin_index.dart';
import 'vod_catalog.dart';
import 'vod_facets.dart';

/// 筛选条件目录的加载状态。
enum VodFacetPhase {
  /// 还没触发加载（例如刚进页、索引闸门还在校验）。
  idle,

  /// 正在从目录统计条件。列表与检索照常可用。
  loading,

  /// 已拿到目录里的全部可筛项。
  ready,

  /// 目录读到了，但没有任何可用的筛选项。
  empty,

  /// 目录读取 / 解析失败。
  error,
}

/// 一次目录加载的结论。
class VodFacetCatalog {
  const VodFacetCatalog({
    required this.phase,
    required this.key,
    this.facets = VodFacets.empty,
    this.message = '',
    this.revision = 0,
  });

  final VodFacetPhase phase;
  final String key;

  /// 仅在 [phase] 为 `ready` 时非空。
  final VodFacets facets;
  final String message;
  final int revision;

  bool get usable => phase == VodFacetPhase.ready && !facets.isEmpty;

  static const VodFacetCatalog idle = VodFacetCatalog(
    phase: VodFacetPhase.idle,
    key: '',
    message: '等待片源索引目录就绪',
  );
}

/// 目录级排序：命中数降序、同数按字典序（保证每次渲染顺序稳定）。
///
/// [VodFacets.fromItems] 的 `minCount=2` 与 `maxTypes/maxAreas` 截断
/// **刻意不复用** —— 那是「当前页统计」的防刷屏策略，目录级要的是全覆盖。
List<String> rankFacetWords(Map<String, int> counts) {
  final entries = counts.entries.toList()
    ..sort((a, b) {
      final byCount = b.value.compareTo(a.value);
      return byCount != 0 ? byCount : a.key.compareTo(b.key);
    });
  return <String>[for (final e in entries) e.key];
}

/// 生成目录：遍历**该栏目全部条目**得到三个维度（类型 / 地区 / 时间）的取值。
///
/// 与过滤函数严格同源：类型走 [vodGenreKeysOfItem]（再归一进固定词表）、
/// 地区走 [looksLikeVodArea]、时间走 [vodTimeBucket]。
VodFacets facetOptionsFromItems(Iterable<VodItem> items) {
  final types = <String, int>{};
  final areas = <String, int>{};
  final times = <String, int>{};
  for (final it in items) {
    for (final t in vodGenreKeysOfItem(it)) {
      types[t] = (types[t] ?? 0) + 1;
    }
    final area = vodAreaTokens(it.area);
    for (final a in area) {
      areas[a] = (areas[a] ?? 0) + 1;
    }
    final bucket = vodTimeBucket(it.year);
    if (bucket.isNotEmpty) times[bucket] = (times[bucket] ?? 0) + 1;
  }
  final rankedTimes = times.keys.toList()
    ..sort((a, b) => _timeRank(b).compareTo(_timeRank(a)));
  return VodFacets(
    typeCounts: types,
    areas: rankFacetWords(areas),
    times: rankedTimes,
  );
}

/// 内置索引：逐行统计本栏目**全部维度**。
///
/// * **类型** = 该行类目名经 [vodGenreKeysOf] 归一进固定词表（`剧情片` →
///   `剧情`）。第二十三次修（用户红标「类型不对」+ 参考爱奇艺）：类型行
///   只放词表里的三十三个词，采集站内部叫法（`4K电影` / `邵氏电影` /
///   `国产剧`）一概不进 —— 上一版把它们分到「分类」行，那行也按红标删了。
/// * **地区** = 行内地区下标 → manifest `areas` 规范词（一行可多值）。
/// * **时间** = 行内年份 → [vodTimeBucket]，按时间轴倒序。
///
/// 逐行只累加 `int`，不还原片名、不建 60 万个对象；一次扫描的最大片
/// 约 6 MB 文本，真正占内存的只有两个计数字典（几十项）。
VodFacets facetOptionsFromShard(
  String body,
  BuiltinIndexManifest manifest,
  String sectionKey,
) {
  final typeCounts = <String, int>{};
  final areaCounts = <String, int>{};
  final timeCounts = <String, int>{};
  final labelByIndex = <int, String>{};
  var start = 0;
  final len = body.length;
  while (start <= len) {
    var end = body.indexOf('\n', start);
    if (end < 0) end = len;
    if (end > start) {
      final line = BuiltinIndexLine.parse(body.substring(start, end),
          format: manifest.version);
      if (line != null) {
        final label = labelByIndex.putIfAbsent(
          line.typeIndex,
          () => line.typeIndex >= 0 && line.typeIndex < manifest.typeNames.length
              ? manifest.typeNames[line.typeIndex].trim()
              : '',
        );
        if (label.isNotEmpty) {
          for (final t in vodGenreKeysOf(label)) {
            typeCounts[t] = (typeCounts[t] ?? 0) + 1;
          }
        }
        for (final i in line.areas) {
          final word = manifest.areaNameOf(i);
          if (word.isNotEmpty) {
            areaCounts[word] = (areaCounts[word] ?? 0) + 1;
          }
        }
        final bucket = vodTimeBucket(line.year);
        if (bucket.isNotEmpty) {
          timeCounts[bucket] = (timeCounts[bucket] ?? 0) + 1;
        }
      }
    }
    if (end >= len) break;
    start = end + 1;
  }
  // 时间按真实时间轴排（年份倒序），不按命中数：筛时间时人是照时间轴找的。
  final times = timeCounts.keys.toList()
    ..sort((a, b) => _timeRank(b).compareTo(_timeRank(a)));
  return VodFacets(
    typeCounts: typeCounts,
    areas: rankFacetWords(areaCounts),
    times: times,
  );
}

int _timeRank(String bucket) {
  final y = int.tryParse(bucket);
  if (y != null) return y;
  if (bucket == '更早') return 0;
  final m = RegExp(r'^(\d{2})年代$').firstMatch(bucket);
  if (m != null) {
    final d = int.tryParse(m.group(1)!);
    if (d == null) return 0;
    return (d >= 30 ? 1900 : 2000) + d;
  }
  return 0;
}

/// 分享给六个栏目页的条件目录（按 `目录身份 × 栏目` 缓存）。
///
/// 不做成单例全局状态：每个 key 独立，页面切栏目不会串到别的栏目条件；
/// 目录变化时旧 key 自然失效，无需手工广播「清缓存」。
class VodFacetDirectory {
  final Map<String, VodFacetCatalog> _catalogs = <String, VodFacetCatalog>{};
  final Set<String> _loading = <String>{};
  final List<void Function()> _listeners = <void Function()>[];
  int _revision = 0;

  static String keyOf(String scope, VodSection section) =>
      '$scope\u0000${section.name}';

  int get revision => _revision;
  int get catalogCount => _catalogs.length;

  VodFacetCatalog? catalogFor(String scope, VodSection section) =>
      _catalogs[keyOf(scope, section)];

  void addListener(void Function() l) => _listeners.add(l);
  void removeListener(void Function() l) => _listeners.remove(l);

  void _notify() {
    for (final l in List<void Function()>.of(_listeners)) {
      l();
    }
  }

  /// 目录身份变了就丢弃全部结论（下次 [ensureLoaded] 重新统计）。
  void invalidate() {
    _catalogs.clear();
    _loading.clear();
    _revision++;
    _notify();
  }

  /// 异步加载某个 `目录 × 栏目` 的条件；重复调用不会重复发任务。
  ///
  /// [loader] 返回 null 表示「目录读取失败」→ error；返回空 [VodFacets]
  /// 表示「目录读到了但没有可筛项」→ empty；抛异常同样是 error。
  /// [force] 用于错误态的「重试」。
  Future<void> ensureLoaded({
    required String scope,
    required VodSection section,
    required Future<VodFacets?> Function() loader,
    bool force = false,
  }) async {
    final key = keyOf(scope, section);
    final existing = _catalogs[key];
    if (_loading.contains(key)) return;
    if (!force && existing != null && existing.phase != VodFacetPhase.idle) {
      // error / empty 都不自动重试：避免每次 setState 都去读一遍坏目录。
      return;
    }
    _loading.add(key);
    _catalogs[key] = VodFacetCatalog(
      phase: VodFacetPhase.loading,
      key: key,
      message: '正在从片源索引目录读取筛选条件…',
      revision: ++_revision,
    );
    _notify();

    VodFacets? facets;
    Object? error;
    try {
      facets = await loader();
    } catch (e) {
      error = e;
    }
    _loading.remove(key);

    late final VodFacetCatalog next;
    if (error != null) {
      next = VodFacetCatalog(
        phase: VodFacetPhase.error,
        key: key,
        message: '筛选条件加载失败：$error',
        revision: ++_revision,
      );
    } else if (facets == null) {
      next = VodFacetCatalog(
        phase: VodFacetPhase.error,
        key: key,
        message: '片源索引目录读取失败或不含有效片源',
        revision: ++_revision,
      );
    } else if (facets.isEmpty) {
      next = VodFacetCatalog(
        phase: VodFacetPhase.empty,
        key: key,
        message: '当前目录没有可筛选的字段',
        revision: ++_revision,
      );
    } else {
      next = VodFacetCatalog(
        phase: VodFacetPhase.ready,
        key: key,
        facets: facets,
        message: '已载入目录内全部可筛选项',
        revision: ++_revision,
      );
    }
    _catalogs[key] = next;
    _notify();
  }
}
