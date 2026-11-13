import 'vod_catalog.dart';

/// 顶部筛选面板：**只统计真实存在的维度**。
///
/// 设计稿（爱奇艺）有「类型 / 地区 / 时间 / 资费 / 奖项 / 推荐」六行，
/// 但我们能拿到的采集字段只有 `vod_class`（类型）、`type_name`（站点分类）、
/// `vod_area`（地区）、`vod_year`（年份）。资费、奖项、推荐**没有数据支撑**，
/// 硬做出来就是一排点了没反应的死按钮 —— 那是欺骗，不是「对齐设计稿」。
/// 所以只实现有数据的四个维度，其余留空并在文档里说明。
///
/// ## 第二十三次修（用户红标）
///
/// * **「分类」整行删除**。原先为了让可筛条件变多，把站点原始类目名
///   （`剧情片 / 国产剧 / Netflix电影`）单独列了一行，结果那一行既是
///   用户看不懂的采集站内部叫法，又和「类型」「地区」语义重叠。
/// * **「类型」改成固定词表**，照爱奇艺的「类型」行：`喜剧 / 动画 / 动作 /
///   爱情 / … / 西部 / 其他`，顺序也照它。采集站写「剧情片」「动作片」，
///   剥掉体裁后缀再比词表即可对齐（见 [vodGenreKeyOf]）；词表外的东西
///   （`4K` / `Netflix` / `邵氏`）不再往类型行里塞。
///
/// 统计口径：
/// * **类型取 `vod_class`**（`genre`），缺失时才回落到 `type_name` —— 详见
///   [vodTypesOf]；
/// * 多值串会拆词（`喜剧,爱情` / `喜剧 爱情`），再逐个归一进词表；
/// * 地区 / 时间按**命中条目数降序**排（时间按时间轴），类型按词表顺序排；
/// * 页码级统计（[VodFacets.fromItems]）里，出现次数少于 [minCount] 的词丢掉，
///   目录级（`facetOptionsFrom*`）一个不丢。
class VodFacets {
  const VodFacets({
    this.typeCounts = const <String, int>{},
    this.areas = const <String>[],
    this.times = const <String>[],
  });

  /// 类型词 → 命中条目数。键**一定**落在 [kVodGenreVocabulary] 内。
  ///
  /// 存计数而不是存排好序的词表，是因为目录级条件要能把「分片统计」与
  /// 「本地增补条目统计」相加（[mergeVodFacets]）；顺序由词表固定，
  /// 不靠计数重排 —— 爱奇艺那行的顺序是认知习惯，不该因为某个词片多
  /// 就跳到最前面。
  final Map<String, int> typeCounts;

  /// 类型行：按固定词表顺序列出**有片**的词。
  List<String> get types => <String>[
        for (final w in kVodGenreVocabulary)
          if ((typeCounts[w] ?? 0) > 0) w,
      ];

  /// 地区规范词（`内地` / `中国香港` / `美国` …）。
  final List<String> areas;

  /// 时间档：具体年份（2026/2025…2020）在前，年代档（10年代/00年代…）在后。
  final List<String> times;

  static const VodFacets empty = VodFacets();

  bool get isEmpty => types.isEmpty && areas.isEmpty && times.isEmpty;

  /// 出现次数低于这个值的维度词不进**页码级**筛选项。
  static const int minCount = 2;

  /// 地区 / 时间最多保留多少个。
  static const int maxAreas = 24;
  static const int maxTimes = 20;

  /// 从条目里统计出三个维度。
  ///
  /// 复杂度 O(n·k)，n 是条目数、k 是单条的类型词数；几千条一次几毫秒。
  /// 调用方要缓存（[VodFacetsCache]），不要每帧调。
  factory VodFacets.fromItems(List<VodItem> items) {
    final typeCount = <String, int>{};
    final areaCount = <String, int>{};
    final timeCount = <String, int>{};
    for (final it in items) {
      for (final t in vodGenreKeysOfItem(it)) {
        typeCount[t] = (typeCount[t] ?? 0) + 1;
      }
      for (final a in vodAreaTokens(it.area)) {
        areaCount[a] = (areaCount[a] ?? 0) + 1;
      }
      final bucket = vodTimeBucket(it.year);
      if (bucket.isNotEmpty) timeCount[bucket] = (timeCount[bucket] ?? 0) + 1;
    }

    final areas = _rank(areaCount, maxAreas);
    // 时间要按**真实时间顺序**排，不是按命中数：筛时间时人是照时间轴找的，
    // 「2026」排在「90年代」前面才符合直觉，哪怕 90 年代的片子更多。
    final times = timeCount.keys.where((k) => timeCount[k]! >= minCount).toList()
      ..sort((a, b) => _timeRank(b).compareTo(_timeRank(a)));

    return VodFacets(
      typeCounts: <String, int>{
        for (final e in typeCount.entries)
          if (e.value >= minCount) e.key: e.value,
      },
      areas: areas,
      times: times,
    );
  }

  static List<String> _rank(Map<String, int> counts, int limit) {
    final keys = counts.entries
        .where((e) => e.value >= minCount)
        .toList()
      ..sort((a, b) {
        final byCount = b.value.compareTo(a.value);
        // 命中数一样时按字典序，保证同一份数据每次渲染顺序稳定
        // （否则 facet 顺序在两次 build 之间抖动，光标会跑去别的词上）。
        return byCount != 0 ? byCount : a.key.compareTo(b.key);
      });
    return <String>[for (final e in keys.take(limit)) e.key];
  }

  static int _timeRank(String bucket) {
    final y = int.tryParse(bucket);
    if (y != null) return y;
    // 年代档：'10年代' → 2010 段，'90年代' → 1990 段；'更早' 最小。
    if (bucket == '更早') return 0;
    final m = RegExp(r'^(\d{2})年代$').firstMatch(bucket);
    if (m != null) {
      final d = int.tryParse(m.group(1)!);
      if (d == null) return 0;
      return (d >= 30 ? 1900 : 2000) + d;
    }
    return 0;
  }
}

/// 类型维度取词：**`genre`（`vod_class`）优先，`typeName` 兜底**。
///
/// ## 曾经错在哪（1.0.5 第十五次修）
///
/// 原来只读 `item.typeName`，而 `type_name` 是**采集站的栏目类目**
/// （「欧美剧」「国产剧」「AI漫剧」「篮球」）。栏目类目本身就带着地区，
/// 于是「类型」行排出来的是一排国家名，和下面的「地区」行撞车 ——
/// 用户看到三行「内地 / 美国 / 韩国」，红标「类型不对」。
///
/// `VodItem.genre` 的注释早就写明了「`type_name` 是栏目类目，
/// `vod_class` 才是用户理解的类型」，只是这里一直没读它。
///
/// ## 为什么还必须兜底
///
/// 采集站的**列表接口**（`?ac=list`）不返回 `vod_class`，只有详情接口
/// （`?ac=detail`）才给。实测本机 1 万条缓存：`genre` 唯一词 128 个、
/// **空值率 71.5%**。纯用 `genre` 会让七成条目在「类型」维度上彻底
/// 消失 —— 点了筛选项什么都没剩，比筛错更糟。
///
/// 兜底时要把**地区 / 纯体裁词**剔掉（[isNonGenreLabel]），否则地区
/// 维度又会被复制回类型维度。宁可类型词少几个，也不要「类型」行里
/// 出现「欧美剧」。
List<String> vodTypesOf(VodItem item) {
  final genre = _splitTypeWords(item.genre);
  if (genre.isNotEmpty) return genre;
  return vodTypeWordsFromLabel(item.typeName);
}

/// 把**一条目录类目名**展开成真正能被筛中的类型词。
///
/// 第十七次修新增：筛选条件改为从整份索引目录加载时，内置目录里只有
/// 类目名字符串（没有 VodItem），但取词口径必须和 [vodTypesOf] 的回落分支
/// **逐字一致** —— 否则条件里列出的词点下去筛不出东西，就是「条件不一致」。
/// 单独抽出来供目录层复用，而不是复制一份判定逻辑。
List<String> vodTypeWordsFromLabel(String label) {
  final out = <String>[];
  for (final t in _splitTypeWords(label)) {
    if (isNonGenreLabel(t)) continue;
    out.add(t);
  }
  return out;
}

/// 一条 `vod_class` 可能写成 `喜剧,爱情` / `喜剧 爱情` / `喜剧/爱情`。
/// 拆成词表，去空白、去空串、去重。
List<String> _splitTypeWords(String raw) {
  if (raw.isEmpty) return const <String>[];
  final out = <String>[];
  for (final piece in raw.split(RegExp(r'[,，/、|\s]+'))) {
    final t = piece.trim();
    if (t.isEmpty || t.length > 12) continue;
    if (!out.contains(t)) out.add(t);
  }
  return out;
}

/// 体裁后缀。剥掉之后才好判断「这个词的核心是地区」还是「核心是题材」。
///
/// 长后缀必须排在短后缀前面：`电视剧` 不先剥就会只剥掉 `剧`，剩下
/// 「电视」，反而绕过了地区判据。
const List<String> _kFormSuffixes = <String>[
  '电视剧',
  '网络剧',
  '动画片',
  '纪录片',
  '专题片',
  '动漫',
  '动画',
  '综艺',
  '电影',
  '短剧',
  '剧场',
  '节目',
  '视频',
  '片',
  '剧',
];

/// 地区词（剥掉体裁后缀之后比对）。命中即视为「这是地区，不是类型」。
///
/// 只收录采集站 `type_name` 里真实出现过的地区词（本轮实测 78 个类目
/// 去重后的结果）。宁可漏收：漏收只是让个别词留在类型行，误收会让
/// 真正的题材词（「动作」「科幻」）从筛选条上消失。
const Set<String> _kAreaCores = <String>{
  '国产',
  '国内',
  '中国',
  '内地',
  '大陆',
  '港台',
  '港澳',
  '香港',
  '台湾',
  '澳门',
  '欧美',
  '美国',
  // 第二十次修：采集站把「日本剧」简写成「日剧」、「韩国剧」简写成
  // 「韩剧」，剥掉「剧」只剩一个单字。不补这几个，类型行里仍会留一排
  // 「日剧 / 韩剧 / 港剧 / 台剧 / 泰剧」，用户红标的「类型不对」就没修净。
  // 只收单字地区简称，不收「美少女 / 日记」这类题材词（词表里没有）。
  '日',
  '韩',
  '港',
  '台',
  '泰',
  '马泰',
  '日本',
  '韩国',
  '日韩',
  '泰国',
  '印度',
  '英国',
  '法国',
  '德国',
  '意大利',
  '西班牙',
  '俄罗斯',
  '新加坡',
  '马来西亚',
  '加拿大',
  '澳大利亚',
  '海外',
  '亚洲',
  '欧洲',
  '美洲',
  '非洲',
  '其他',
  '其它',
};

/// 纯体裁词：剥完什么都不剩，或者本身就是体裁，不带任何题材信息。
/// 放在「类型」行里等于没筛，直接不进筛选条。
const Set<String> _kFormOnly = <String>{
  '电影',
  '电视剧',
  '动漫',
  '动画',
  '综艺',
  '短剧',
  '剧场',
  '专题',
  '节目',
  '视频',
  '剧',
  '片',
};

/// 这个词能否进「类型」行。
///
/// 返回 true（不进类型行）的三种情况：
///  1. 本身就是纯体裁词（`电影` / `动漫` / `剧`）—— 不带题材信息；
///  2. 剥掉体裁后缀后是地区词（`欧美剧` / `国产动漫` / `日韩剧`）——
///     它们属于「地区」维度，留在类型行就是重复；
///  3. 剥完什么都不剩（`专题片` → 空）—— 同上。
///
/// 其余一律 false（`动作片` / `喜剧` / `篮球` / `纪录片` 都可以筛）。
bool isNonGenreLabel(String word) {
  final w = word.trim();
  if (w.isEmpty) return true;
  if (_kFormOnly.contains(w)) return true;
  if (_kAreaCores.contains(w)) return true;
  for (final suffix in _kFormSuffixes) {
    if (w.length > suffix.length && w.endsWith(suffix)) {
      final core = w.substring(0, w.length - suffix.length);
      return core.isEmpty || _kAreaCores.contains(core);
    }
  }
  return false;
}

/// 「类型」维度的**固定词表**（顺序即界面顺序）。
///
/// 照爱奇艺「类型」筛选行抄的清单（第二十三次修，用户给的参考截图）。
/// 之前类型行是从目录里**统计**出来的：有什么类目就列什么词，于是采集站
/// 的内部叫法（`剧情片` / `4K电影` / `Netflix电影` / `邵氏电影`）直接
/// 铺在筛选条上 —— 用户红标「类型不对」说的就是这件事。
///
/// 固定词表的好处是「筛选条长得像一个筛选条」，代价是词表外的片子在这
/// 一维上筛不到（仍都在「全部」里，地区 / 时间两维也不受影响）。这是
/// 有意的取舍：宁可按用户熟悉的三十三个词筛，也不列一百个采集站方言。
const List<String> kVodGenreVocabulary = <String>[
  '喜剧',
  '动画',
  '动作',
  '爱情',
  '恐怖',
  '战争',
  '惊悚',
  '枪战',
  '科幻',
  '犯罪',
  '悬疑',
  '奇幻',
  '剧情',
  '青春',
  '冒险',
  '家庭',
  '少儿',
  '警匪',
  '历史',
  '武侠',
  '伦理',
  '灾难',
  '传记',
  '运动',
  '音乐',
  '魔幻',
  '歌舞',
  '戏曲',
  '玄幻',
  '悲剧',
  '史诗',
  '西部',
  '其他',
];

/// 把一个类型词归一成固定词表里的词；归不进词表返回 `''`。
///
/// 采集站写的是 `剧情片` / `动作片` / `喜剧`，词表写的是 `剧情` / `动作` ——
/// 差的就是一个体裁后缀。剥掉 [_kFormSuffixes]（长的先剥）再查词表；
/// 查不到就放弃（`4K电影` → `4K`、`Netflix电影` → `Netflix`、`邵氏电影`
/// → `邵氏` 都不在词表里，于是不进类型行）。
String vodGenreKeyOf(String word) {
  final w = word.trim();
  if (w.isEmpty) return '';
  if (kVodGenreVocabulary.contains(w)) return w;
  for (final suffix in _kFormSuffixes) {
    if (w.length > suffix.length && w.endsWith(suffix)) {
      final core = w.substring(0, w.length - suffix.length);
      if (kVodGenreVocabulary.contains(core)) return core;
    }
  }
  return '';
}

/// 一条类目名 / 多值类型串（`剧情片,动作`）→ 词表内的词（去重、保序）。
List<String> vodGenreKeysOf(String raw) {
  final out = <String>[];
  for (final t in _splitTypeWords(raw)) {
    final k = vodGenreKeyOf(t);
    if (k.isNotEmpty && !out.contains(k)) out.add(k);
  }
  return out;
}

/// 一个条目命中的类型词（词表口径）：`genre` 优先，缺失时回落 `typeName`。
///
/// 与 [vodTypesOf] 的区别只在最后一步「归一进词表」：过滤与统计必须用
/// 同一个口径，否则筛选条上点「剧情」，目录里记的是「剧情片」就筛不出。
List<String> vodGenreKeysOfItem(VodItem item) {
  final out = <String>[];
  for (final w in vodTypesOf(item)) {
    final k = vodGenreKeyOf(w);
    if (k.isNotEmpty && !out.contains(k)) out.add(k);
  }
  return out;
}

/// 两份条件统计相加：类型按计数累加，地区 / 时间取并集。
///
/// 用途是把「随包分片统计」与「本地增补条目统计」合成一份（默认接口的
/// 追加更新不动随包索引，新片源单独存在本地文件里）。类型顺序由词表
/// 固定，所以只需要加计数，不需要重排。
VodFacets mergeVodFacets(VodFacets a, VodFacets b) {
  final types = <String, int>{...a.typeCounts};
  b.typeCounts.forEach((k, v) => types[k] = (types[k] ?? 0) + v);
  final areas = <String>[...a.areas];
  for (final w in b.areas) {
    if (!areas.contains(w)) areas.add(w);
  }
  final times = <String>[...a.times];
  for (final t in b.times) {
    if (!times.contains(t)) times.add(t);
  }
  times.sort((x, y) => VodFacets._timeRank(y).compareTo(VodFacets._timeRank(x)));
  return VodFacets(typeCounts: types, areas: areas, times: times);
}

/// 地区维度的**规范词表**。
///
/// 采集站的 `vod_area` 是一堆方言：`中国大陆` / `大陆` / `内地` / `国内` 说的是
/// 同一个地方，`香港` / `中国香港` 也是。直接按原串计数，地区行会出现
/// 「内地 / 大陆 / 中国大陆 / 国内」四个词各命中几千条 —— 用户点哪个都对，
/// 但看就是一排同义词，等于没有筛选。
///
/// 所以：**原串只在抓取侧出现一次**，落进索引前统一映射到这张表；
/// Dart 侧统计与过滤都按这张表。`tooling/pack_vod_index.py` 里有一份逐字
/// 相同的映射（门禁 F03 校验索引里的地区词都在这张表内）。
const List<String> kVodAreaVocabulary = <String>[
  '内地',
  '中国香港',
  '中国台湾',
  '中国澳门',
  '美国',
  '韩国',
  '日本',
  '泰国',
  '英国',
  '法国',
  '德国',
  '印度',
  '俄罗斯',
  '加拿大',
  '澳大利亚',
  '新加坡',
  '马来西亚',
  '意大利',
  '西班牙',
  '其他',
];

/// 方言 → 规范词。一个方言可能对应多个地区（`港台` 就是香港 + 台湾）。
const Map<String, List<String>> _kAreaAliases = <String, List<String>>{
  '中国大陆': <String>['内地'],
  '大陆': <String>['内地'],
  '内地': <String>['内地'],
  '国内': <String>['内地'],
  '中国': <String>['内地'],
  '大陆地区': <String>['内地'],
  '中国香港': <String>['中国香港'],
  '香港': <String>['中国香港'],
  '港': <String>['中国香港'],
  '中国台湾': <String>['中国台湾'],
  '台湾': <String>['中国台湾'],
  '台湾地区': <String>['中国台湾'],
  '台': <String>['中国台湾'],
  '中国澳门': <String>['中国澳门'],
  '澳门': <String>['中国澳门'],
  '港台': <String>['中国香港', '中国台湾'],
  '港澳台': <String>['中国香港', '中国澳门', '中国台湾'],
  '美国': <String>['美国'],
  '韩国': <String>['韩国'],
  '日本': <String>['日本'],
  '泰国': <String>['泰国'],
  '英国': <String>['英国'],
  '法国': <String>['法国'],
  '德国': <String>['德国'],
  '印度': <String>['印度'],
  '俄罗斯': <String>['俄罗斯'],
  '加拿大': <String>['加拿大'],
  '澳大利亚': <String>['澳大利亚'],
  '澳洲': <String>['澳大利亚'],
  '新加坡': <String>['新加坡'],
  '马来西亚': <String>['马来西亚'],
  '意大利': <String>['意大利'],
  '西班牙': <String>['西班牙'],
};

/// 把一行的 `vod_area` 拆成规范地区词（去重、保序）。
///
/// 多值串（`中国香港 / 中国大陆`、`美国,英国`）会拆成多个词；
/// 含数字 / 更新状态 / 画质备注的脏词直接丢掉（不并进「其他」——
/// `全80集` 不是地区，硬归到「其他」会让那个词变成垃圾桶）。
List<String> vodAreaTokens(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return const <String>[];
  final out = <String>[];
  for (final piece in text.split(RegExp(r'[/、,，|&和\s]+'))) {
    final t = piece.trim();
    if (t.isEmpty) continue;
    final mapped = _kAreaAliases[t];
    if (mapped != null) {
      for (final m in mapped) {
        if (!out.contains(m)) out.add(m);
      }
      continue;
    }
    if (kVodAreaVocabulary.contains(t)) {
      if (!out.contains(t)) out.add(t);
      continue;
    }
    // 认不出来的地名（`巴西` / `墨西哥` …）归到「其他」，但更新状态 / 画质
    // 备注这类根本不是地名的脏值必须排除，否则「其他」会被它们灌满。
    if (looksLikeVodArea(t) && !out.contains('其他')) out.add('其他');
  }
  return out;
}

/// `vod_area` 是否像**地区名**。
///
/// 实测本机 1 万条缓存，「地区」行里混进了 `已完结`、`全80集（合全集）`、
/// `正片` —— 有些采集站的 `vod_area` 字段实际放的是更新状态 / 备注。
/// 这些词出现在地区维度里，用户点了只会得到一堆不相关的片。
///
/// 判据刻意保守（宁可漏挡，不可误杀真地区）：
///  * 含数字 ⇒ 不是地区（`全80集`）；
///  * 含「集 / 完结 / 更新 / 正片」⇒ 更新状态（`全60集（合全集）`、`已完结`）；
///  * 含片源标记（`HD` / `BD` / `TC` / `抢先`）⇒ 画质备注；
///  * 长度 > 8 ⇒ 不是地名。
bool looksLikeVodArea(String area) {
  final a = area.trim();
  if (a.isEmpty || a.length > 8) return false;
  if (RegExp(r'[0-9]').hasMatch(a)) return false;
  for (final bad in _kAreaJunkMarkers) {
    if (a.contains(bad)) return false;
  }
  return true;
}

/// 出现在 `vod_area` 里的「非地区」标记（更新状态 / 画质备注）。
const List<String> _kAreaJunkMarkers = <String>[
  '集',
  '完结',
  '更新',
  '正片',
  '预告',
  '花絮',
  '抢先',
  'HD',
  'BD',
  'TC',
];

/// 年份 → 时间档。数字年份 >= 2020 用具体年份，更早按年代归并。
///
/// 为什么 2020 是个分界：采集站给的老片年份断断续续（1994、2003…），
/// 逐个列出来会变成几十个只命中一两部的档位；近几年才是用户真正会筛的。
String vodTimeBucket(String rawYear) {
  final y = int.tryParse(rawYear.trim());
  if (y == null || y < 1900 || y > 2100) return '';
  if (y >= 2020) return '$y';
  if (y >= 2010) return '10年代';
  if (y >= 2000) return '00年代';
  if (y >= 1990) return '90年代';
  if (y >= 1980) return '80年代';
  return '更早';
}

/// 顶部筛选条件。[empty] 表示不限。
class VodFilter {
  const VodFilter({
    this.type = '',
    this.area = '',
    this.time = '',
    this.sort = VodSort.relevance,
  });

  /// 类型词，取值一定来自 [kVodGenreVocabulary]。
  ///
  /// 第二十三次修删掉了 `category`（站点原始类目名）：那一行是按用户红标
  /// 整行去掉的，`分类` 这个维度不再存在。
  final String type;
  final String area;
  final String time;
  final VodSort sort;

  static const VodFilter empty = VodFilter();

  bool get isActive => type.isNotEmpty || area.isNotEmpty || time.isNotEmpty;

  /// 生效的筛选项个数（用来在「筛选」按钮上显示数量）。
  int get activeCount =>
      (type.isEmpty ? 0 : 1) + (area.isEmpty ? 0 : 1) + (time.isEmpty ? 0 : 1);

  VodFilter copyWith({
    String? type,
    String? area,
    String? time,
    VodSort? sort,
  }) =>
      VodFilter(
        type: type ?? this.type,
        area: area ?? this.area,
        time: time ?? this.time,
        sort: sort ?? this.sort,
      );

  /// 值相等：`_filteredFor` 的缓存键直接用它，
  /// 不实现的话每次 `copyWith` 都是新对象，缓存永远命中不了。
  @override
  bool operator ==(Object other) =>
      other is VodFilter &&
      other.type == type &&
      other.area == area &&
      other.time == time &&
      other.sort == sort;

  @override
  int get hashCode => Object.hash(type, area, time, sort);
}

enum VodSort {
  /// 相关性 / 源的原始顺序（采集站的列表本身就是最近更新在前）。
  relevance('默认'),
  yearDesc('最新年份'),
  titleAsc('片名');

  const VodSort(this.label);
  final String label;
}

/// 过滤 + 排序。返回**新列表**，不修改入参。
///
/// 三个维度（类型 / 地区 / 时间）是「与」关系：选了「喜剧 + 内地 + 2024」
/// 就是要同时满足。类型按 [kVodGenreVocabulary] 归一后比对 ——
/// 选「剧情」能筛到目录里的「剧情片」。
List<VodItem> applyVodFilter(List<VodItem> items, VodFilter filter) {
  var out = items;
  if (filter.type.isNotEmpty) {
    out = [
      for (final it in out)
        if (vodGenreKeysOfItem(it).contains(filter.type)) it,
    ];
  }
  if (filter.area.isNotEmpty) {
    out = [
      for (final it in out)
        // 多地区条目（`中国香港 / 中国大陆`）在任一地区下都要能出现，
        // 所以按规范词表比对，而不是原串相等。
        if (vodAreaTokens(it.area).contains(filter.area)) it,
    ];
  }
  if (filter.time.isNotEmpty) {
    out = [
      for (final it in out)
        if (vodTimeBucket(it.year) == filter.time) it,
    ];
  }
  switch (filter.sort) {
    case VodSort.relevance:
      break;
    case VodSort.yearDesc:
      // 稳定排序：年份相同保持原顺序，避免每次渲染卡片顺序乱跳。
      final indexed = <MapEntry<int, VodItem>>[
        for (var i = 0; i < out.length; i++) MapEntry(i, out[i]),
      ]..sort((a, b) {
          final ya = int.tryParse(a.value.year) ?? 0;
          final yb = int.tryParse(b.value.year) ?? 0;
          final byYear = yb.compareTo(ya);
          return byYear != 0 ? byYear : a.key.compareTo(b.key);
        });
      out = [for (final e in indexed) e.value];
    case VodSort.titleAsc:
      final indexed = <MapEntry<int, VodItem>>[
        for (var i = 0; i < out.length; i++) MapEntry(i, out[i]),
      ]..sort((a, b) {
          final byTitle = a.value.title.compareTo(b.value.title);
          return byTitle != 0 ? byTitle : a.key.compareTo(b.key);
        });
      out = [for (final e in indexed) e.value];
  }
  return out;
}

/// facets 缓存：同一份源列表 + 同一个版本只统计一次。
///
/// 之所以要单独抽一个类：`build()` 每帧都会调，几千条扫三遍在低端电视盒上
/// 是肉眼可见的掉帧（滚动时尤其明显）。
class VodFacetsCache {
  int _revision = -1;
  List<VodItem>? _source;
  VodFacets _facets = VodFacets.empty;

  VodFacets of(int revision, List<VodItem> items) {
    if (revision == _revision && identical(items, _source)) return _facets;
    _revision = revision;
    _source = items;
    _facets = VodFacets.fromItems(items);
    return _facets;
  }

  void clear() {
    _revision = -1;
    _source = null;
    _facets = VodFacets.empty;
  }
}
