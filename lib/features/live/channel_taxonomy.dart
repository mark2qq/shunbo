/// 频道的**内容来源归属**与**分类归属策略**。
///
/// 这是「频道分类 + 数字编号」配置的骨架：
/// * **来源归属**决定数字号段（央视 1–99 / 卫视 101–199 / 地方 201–899 /
///   全网其它视频源 901–999）；
/// * **分类策略**决定某个分类收录哪些来源的内容。
///
/// 策略本身是**配置**而不是散落在解析器里的 if：用户要求
/// 「新闻 / 少儿 / 体育 覆盖央视、卫视、地方三类来源；纪实覆盖央视与全网其它
/// 视频源；其余来源统一归入『其它』」——这几句话必须能在一个地方看全、
/// 能被回归脚本逐条断言，改策略不用改解析器。
///
/// 刻意不 import flutter：这一层要能被裸 `dart run` 的回归脚本直接引用
/// （本机 flutter_tester 不可用，见项目 README）。
library;

/// 频道的内容来源。
enum ChannelSource {
  /// 央视体系：CCTV / CGTN / 中国教育电视台。
  cctv('央视'),

  /// 省级卫视。
  satellite('卫视'),

  /// 地方台：省市频道、地市台。
  local('地方'),

  /// 全网其它视频源：境外台、无来源标识的聚合条目等。
  web('全网其它视频源');

  const ChannelSource(this.label);

  /// 中文名，用于配置说明与文档输出。
  final String label;
}

/// 一次分类求解的结果。
class ChannelTaxonomyResult {
  const ChannelTaxonomyResult({
    required this.source,
    required this.primary,
    required this.thematic,
    required this.categories,
  });

  /// 内容来源归属。
  final ChannelSource source;

  /// 主分类（频道栏里作为「归属」的那一个）。
  final String primary;

  /// 内容分类（新闻 / 体育 / 少儿 / 纪实 / 影视 / 生活），没有则为 null。
  final String? thematic;

  /// 全部所属分类：主分类 + （策略允许时）内容分类。
  final List<String> categories;
}

/// 分类与来源的策略表。
abstract final class ChannelTaxonomy {
  // ── 主分类名 ─────────────────────────────────────────────
  static const String cctvGroup = '央视频道';
  static const String satelliteGroup = '卫视频道';
  static const String localGroup = '地方频道';
  static const String otherGroup = '其它频道';

  // ── 内容分类名 ───────────────────────────────────────────
  static const String newsGroup = '新闻';
  static const String sportsGroup = '体育';
  static const String moviesGroup = '影视';
  static const String kidsGroup = '少儿';
  static const String documentaryGroup = '纪实';
  static const String lifeGroup = '生活';

  /// **分类 → 允许收录的内容来源**。这是整套配置的核心声明。
  ///
  /// 需求原文：
  /// * 新闻 / 少儿 / 体育 —— 内容来源覆盖**央视、卫视、地方**三类频道；
  /// * 纪实 —— 内容来源为**央视及全网其它视频源**；
  /// * 除上述已列来源之外的其它来源视频，统一归入「其它」频道。
  ///
  /// 「影视 / 生活」沿用同一口径（央视 + 卫视 + 地方）：这两类在主流直播软件里
  /// 也是以国内台为主，境外片库走点播栏目，不该混进直播分类。
  static const Map<String, Set<ChannelSource>> categorySources =
      <String, Set<ChannelSource>>{
    newsGroup: <ChannelSource>{
      ChannelSource.cctv,
      ChannelSource.satellite,
      ChannelSource.local,
    },
    kidsGroup: <ChannelSource>{
      ChannelSource.cctv,
      ChannelSource.satellite,
      ChannelSource.local,
    },
    sportsGroup: <ChannelSource>{
      ChannelSource.cctv,
      ChannelSource.satellite,
      ChannelSource.local,
    },
    moviesGroup: <ChannelSource>{
      ChannelSource.cctv,
      ChannelSource.satellite,
      ChannelSource.local,
    },
    lifeGroup: <ChannelSource>{
      ChannelSource.cctv,
      ChannelSource.satellite,
      ChannelSource.local,
    },
    documentaryGroup: <ChannelSource>{ChannelSource.cctv, ChannelSource.web},
    otherGroup: <ChannelSource>{ChannelSource.web},
  };

  /// 全部内容分类（不含主分类）。
  static const List<String> thematicGroups = <String>[
    newsGroup,
    sportsGroup,
    moviesGroup,
    kidsGroup,
    documentaryGroup,
    lifeGroup,
  ];

  /// 央视台名识别：`CCTV-*` / `CGTN-*` / `CETV-*`。
  ///
  /// 前面的 `(^|[^a-z])` 不能去掉：`WCETV`（美国台）里也含 `CETV`，
  /// 去掉后它会被误判成央视台。
  static final RegExp _cctvPattern =
      RegExp(r'(^|[^a-z])(cctv|cgtn|cetv)', caseSensitive: false);

  /// 中文央视台名：`央视` / `中央电视` / `中国教育（电视台）`。
  static final RegExp _cctvWords = RegExp(r'央视|中央电视|中国教育|教育电视');

  static final RegExp _chinese = RegExp(r'[\u4e00-\u9fa5]');

  /// 判断某个内容分类是否收录该来源。
  static bool categoryAllows(String category, ChannelSource source) =>
      categorySources[category]?.contains(source) ?? false;

  /// 来源归属判定。
  ///
  /// 顺序即优先级：**台名 → 远端 group-title → tvg-id 国家码**。
  /// * 台名优先：「江苏卫视」这种台名本身就是最强的归属证据；
  /// * group-title 次之：国内聚合表直接写「📺央视频道」「📡卫视频道」
  ///   「☘️江苏频道」，比台名更可靠——`综合频道` 这种台名单看完全判不出归属，
  ///   但它挂在「央视频道」分节下，归属是央视；
  /// * tvg-id 兜底：`Xinjiang TV 1` / `XinjiangTV1.cn`。
  static ChannelSource sourceOf(
    String name, {
    String? tvgId,
    String? remoteGroup,
  }) {
    final n = name.toLowerCase();
    if (_cctvPattern.hasMatch(n)) return ChannelSource.cctv;
    if (_cctvWords.hasMatch(name)) return ChannelSource.cctv;
    if (name.contains('卫视')) return ChannelSource.satellite;
    if (remoteGroup != null && remoteGroup.isNotEmpty) {
      if (remoteGroup.contains('央视')) return ChannelSource.cctv;
      if (remoteGroup.contains('卫视')) return ChannelSource.satellite;
      final g = remoteGroup.trimRight();
      if (g.contains('地方') || g.endsWith('频道')) return ChannelSource.local;
    }
    if (_chinese.hasMatch(name)) return ChannelSource.local;
    final id = (tvgId ?? '').toLowerCase();
    if (id.endsWith('.cn') ||
        id.endsWith('.tw') ||
        id.endsWith('.hk') ||
        id.endsWith('.mo')) {
      return ChannelSource.local;
    }
    return ChannelSource.web;
  }

  /// 内容分类判定：台名关键词 + 远端 group-title 关键词。
  ///
  /// 判定顺序有讲究：
  /// * 「少儿 / 体育」先判——`CCTV-14 少儿`、`百事通体育1` 这类台名自带栏目词；
  /// * 「影视 / 纪实」先于「新闻」——`CGTN Documentary` 含 `Documentary`，
  ///   若先判新闻会被归错；
  /// * 「新闻」放最后——它同时要吃 `CGTN` 这种不带栏目词的台名。
  static String? thematicOf(String name, [String? remoteGroup]) {
    final n = name.toLowerCase();
    final g = (remoteGroup ?? '').toLowerCase();
    bool has(List<String> words, String text) {
      for (final w in words) {
        if (text.contains(w)) return true;
      }
      return false;
    }

    if (has(const <String>['少儿', '卡通', '动画', 'kids', 'children', 'cartoon', 'anime'], n) ||
        has(const <String>['kids', 'animation', 'children'], g)) {
      return kidsGroup;
    }
    if (has(const <String>['体育', '足球', '篮球', 'sport'], n) ||
        has(const <String>['sport'], g)) {
      return sportsGroup;
    }
    if (has(const <String>['影视', '电影', '电视剧', '剧场', 'movie'], n) ||
        has(const <String>['movie'], g)) {
      return moviesGroup;
    }
    if (has(const <String>['纪实', '纪录', 'documentary'], n) ||
        has(const <String>['documentary'], g)) {
      return documentaryGroup;
    }
    if (has(const <String>['生活', '综艺', '娱乐', '旅游'], n) ||
        has(const <String>['lifestyle', 'entertainment', 'music'], g)) {
      return lifeGroup;
    }
    if (has(const <String>['新闻', 'news', 'cgtn'], n) ||
        has(const <String>['news'], g)) {
      return newsGroup;
    }
    return null;
  }

  /// 主分类：来源决定归属，内容分类只在**允许该来源**时才顶替主分类。
  ///
  /// 例：境外纪实台（来源=全网其它视频源、内容=纪实）→ 主分类「纪实」；
  /// 境外新闻台（来源=全网其它视频源、内容=新闻，而新闻不收该来源）
  /// → 主分类「其它频道」。
  static String primaryOf(ChannelSource source, String? thematic) {
    switch (source) {
      case ChannelSource.cctv:
        return cctvGroup;
      case ChannelSource.satellite:
        return satelliteGroup;
      case ChannelSource.local:
        return localGroup;
      case ChannelSource.web:
        if (thematic != null && categoryAllows(thematic, source)) {
          return thematic;
        }
        return otherGroup;
    }
  }

  /// 一次求解：来源 + 主分类 + 内容分类 + 全部所属分类。
  ///
  /// [originalName] 是**台名归一之前**的原始写法：台名归一会削掉央视的栏目
  /// 后缀（`CCTV-13 新闻` → `CCTV-13`），而栏目名正是内容分类的线索——
  /// 少了它，CCTV-13 就不会被认成新闻台。
  static ChannelTaxonomyResult resolve(
    String name, {
    String? remoteGroup,
    String? tvgId,
    String? originalName,
  }) {
    final source = sourceOf(name, tvgId: tvgId, remoteGroup: remoteGroup);
    final thematic = thematicOf(
      (originalName == null || originalName.trim().isEmpty) ? name : originalName,
      remoteGroup,
    );
    final primary = primaryOf(source, thematic);
    final categories = <String>[primary];
    if (thematic != null &&
        thematic != primary &&
        categoryAllows(thematic, source)) {
      categories.add(thematic);
    }
    return ChannelTaxonomyResult(
      source: source,
      primary: primary,
      thematic: thematic,
      categories: categories,
    );
  }
}
