/// 频道与节目的**数字编号**配置。
///
/// 目标（用户需求原文）：
/// * 所有频道及节目均分配**唯一、稳定的数字编号**；
/// * **央视一套对应数字编号 1**；
/// * 其余频道编号参考主流直播软件的常规编号方式，便于记忆且避免冲突；
/// * 安卓 TV 端装到电视上后，用户可用遥控器**直接输入数字**切换到对应频道。
///
/// 编号方案（号段即来源，与 [ChannelTaxonomy] 的来源归属一一对应）：
/// ```text
///    1 –  99  央视（CCTV-1 = 1 … CCTV-17 = 17，CCTV-5+ = 18，CCTV 4K = 19，
///               CGTN = 20，CGTN 纪录 = 21，中国教育 1–4 = 22–25）
///  101 – 199  省级卫视（按 GB/T 2260 行政区划顺序，北京 = 101 …）
///  201 – 899  地方频道（苏州 = 201–205，其余按台名稳定分配）
///  901 – 999  全网其它视频源（其它来源的台）
/// 1001 – 1099 节目（点播条目）
/// 1101 – 1999 节目分集（1100 + 节目序号 × 10 + 集号）
/// ```
///
/// 「稳定」靠两件事保证：
/// 1. **号段由来源决定**，来源由台名/tvg-id 判定，与索引返回顺序无关；
/// 2. **首次分配即落盘**（`ChannelNumberStore`），之后同一台永远同一个号，
///    新增台不会挤掉老台的号码。
library;

import 'channel_taxonomy.dart';
import 'live_channel.dart';

/// 一个号段。
class NumberBand {
  const NumberBand(this.source, this.start, this.end);

  final ChannelSource source;
  final int start;
  final int end;

  int get size => end - start + 1;

  bool contains(int n) => n >= start && n <= end;
}

/// 各来源的号段。
const List<NumberBand> kChannelBands = <NumberBand>[
  NumberBand(ChannelSource.cctv, 1, 99),
  NumberBand(ChannelSource.satellite, 101, 199),
  NumberBand(ChannelSource.local, 201, 899),
  NumberBand(ChannelSource.web, 901, 999),
];

/// 节目（点播条目）号段。
const int kProgramBandStart = 1001;
const int kProgramBandEnd = 1099;

/// 节目分集号段起点：分集号 = 1100 + 节目序号 × 10 + 集号。
const int kEpisodeBandStart = 1101;
const int kEpisodeBandEnd = 1999;

/// 省级卫视固定编号（按 GB/T 2260 省级行政区划顺序，与主流直播软件一致）。
///
/// 键是**归一化台名**（小写、去分隔符），见 [numberKey]。
const Map<String, int> kSatelliteNumbers = <String, int>{
  '北京卫视': 101,
  '天津卫视': 102,
  '河北卫视': 103,
  '山西卫视': 104,
  '内蒙古卫视': 105,
  '辽宁卫视': 106,
  '吉林卫视': 107,
  '黑龙江卫视': 108,
  // 注意：旧名「上海卫视」2002 年已更名「东方卫视」，二者本为同一台。
  // 重复声明 109 会导致 rebuild 第一轮 `used.contains(109)` 把其中一个跳过、
  // 落到自动分配，频道栏出现「双列」。现只在 [LiveCatalogService.canonicalName]
  // 里把「上海卫视」归一成「东方卫视」，这里只保留一个 109。
  '东方卫视': 109,
  '江苏卫视': 110,
  '浙江卫视': 111,
  '安徽卫视': 112,
  '福建卫视': 113,
  '江西卫视': 114,
  '山东卫视': 115,
  '河南卫视': 116,
  '湖北卫视': 117,
  '湖南卫视': 118,
  '广东卫视': 119,
  '广西卫视': 120,
  '海南卫视': 121,
  '重庆卫视': 122,
  '四川卫视': 123,
  '贵州卫视': 124,
  '云南卫视': 125,
  '西藏卫视': 126,
  '陕西卫视': 127,
  '甘肃卫视': 128,
  '青海卫视': 129,
  '宁夏卫视': 130,
  '新疆卫视': 131,
  '深圳卫视': 132,
  '厦门卫视': 133,
  '三沙卫视': 134,
  '农林卫视': 135,
  // 特殊卫视（不属于 GB/T 2260 省级序列，但 satelliteAliases 会把英文写法
  // 归一成这两个中文名）：不给固定号就会在号段内自动分配，索引一刷新号码就漂移。
  // 放在常规卫视之后、4K 变体（141–151）之前，两段互不挤占。
  '兵团卫视': 136,
  '延边卫视': 137,
  // 真实公开索引里出现、但不属于省级行政区划序列的卫视。
  // 不给固定号时它们走号段自动分配（实测拿到 134/135/138/139/140），
  // 索引一刷新就漂移，且会挤占 4K 变体的号段。
  '东南卫视': 138,
  '大湾区卫视': 139,
  '康巴卫视': 140,
  // 141–159 保留给画质变体（见 [kSatelliteQualityNumbers]），
  // 其余特殊卫视从 160 起续排。
  '蒙语卫视': 160,
};

/// 省级卫视**画质变体**（4K / 8K）的固定编号。
///
/// 这些是与基础台同名但**独立的频道**（如 `深圳卫视4K` ≠ `深圳卫视`），
/// 必须给固定号，否则走号段自动分配后，频道集一旦变化（索引增删条目），
/// 它们的号码就会漂移，遥控器按号跳台不再稳定。
///
/// 号段放在卫视号段尾部（141–159），排在常规卫视（101–140）之后，
/// 既属于卫视来源（`ChannelTaxonomy` 按「卫视」判定）、又在卫星号段内，
/// 不会被第二轮自动分配抢占；160 起留给其它特殊卫视。
///
/// 键是 [numberKey] 归一形式：`4K` → `4k` 小写、`8K` → `8k` 小写。
/// （结尾带「超清 / 高清」的写法会被 [LiveCatalogService.canonicalName] 归一进
/// 基础台，不算独立频道，无需在此列出。）
const Map<String, int> kSatelliteQualityNumbers = <String, int>{
  '深圳卫视4k': 141,
  '浙江卫视4k': 142,
  '广东卫视4k': 143,
  '江苏卫视4k': 144,
  '湖南卫视4k': 145,
  '东方卫视4k': 146,
  '北京卫视4k': 147,
  '山东卫视4k': 148,
  '湖北卫视4k': 149,
  '四川卫视4k': 150,
  '深圳卫视8k': 151,
};

///
/// 只固定用户最常看的几个城市；其余地方台走稳定分配。
const Map<String, int> kLocalNumbers = <String, int>{
  '苏州新闻综合': 201,
  '苏州社会经济': 202,
  '苏州文化生活': 203,
  '苏州生活资讯': 204,
  '苏州4k': 205,
  '南京新闻综合': 206,
  '南京文体综合': 207,
  '无锡新闻综合': 208,
  '无锡生活频道': 209,
  '常州新闻综合': 210,
  '杭州综合': 211,
  '杭州影视频道': 212,
  '上海新闻综合': 213,
  '上海东方明珠': 214,
};

/// 节目（点播条目）编号。
const Map<String, int> kProgramNumbers = <String, int>{
  'big-buck-bunny-hls': 1001,
  'big-buck-bunny-mp4': 1002,
  'sintel-trailer': 1003,
  'demo-series': 1004,
  'doc-oceans': 1005,
  'doc-flower': 1006,
};

/// 央视台号 → 固定编号。
///
/// `CCTV-1` = 1 是整套编号的锚点（用户需求明确要求）。
/// `CCTV-5+`（体育赛事）与 `CCTV 4K`（超高清）分别是 18 / 19——
/// 它们与 `CCTV-5` / `CCTV-4` 是不同的台，不能共用一个号。
const Map<int, int> kCctvNumbers = <int, int>{
  1: 1, 2: 2, 3: 3, 4: 4, 5: 5, 6: 6, 7: 7, 8: 8, 9: 9, 10: 10,
  11: 11, 12: 12, 13: 13, 14: 14, 15: 15, 16: 16, 17: 17,
};

/// `CCTV-5+`（体育赛事）的固定编号。
const int kCctvSportsPlusNumber = 18;

/// `CCTV 4K`（超高清）的固定编号。
const int kCctv4kNumber = 19;

/// `CCTV-8K`（8K 超高清试验频道）的固定编号。
///
/// 真实索引里 `CCTV-4K` 与 `CCTV-8K` 是**两个不同的台**。旧实现把任何
/// `cctvNk` 都当成 4K 台返回 19，导致 8K 台与 4K 台抢同一个号、
/// rebuild 只留一个、另一个被自动分配到 34——按 19 跳台会切错。
const int kCctv8kNumber = 26;

/// `CGTN`（综合）的固定编号。
const int kCgtnNumber = 20;

/// `CGTN 纪录` 的固定编号。
const int kCgtnDocumentaryNumber = 21;

/// 中国教育电视台 1–4 的固定编号（央视体系内的四个教育台）。
const Map<int, int> kEducationNumbers = <int, int>{
  1: 22, 2: 23, 3: 24, 4: 25,
};

/// 归一化台名：小写、只保留字母/数字/汉字/`+`，其余（空格、连字符、括号）去掉。
///
/// 编号匹配、落盘键都用它：`CCTV-1 综合` 与 `CCTV-1` 归一后只差一个后缀，
/// 靠它把两种写法收敛到同一个键。
String numberKey(String name) {
  final b = StringBuffer();
  for (final r in name.runes) {
    final c = String.fromCharCode(r);
    if (c == '+') {
      b.write(c);
      continue;
    }
    final lower = c.toLowerCase();
    if (lower.codeUnitAt(0) >= 0x61 && lower.codeUnitAt(0) <= 0x7a) {
      b.write(lower);
      continue;
    }
    if (lower.codeUnitAt(0) >= 0x30 && lower.codeUnitAt(0) <= 0x39) {
      b.write(lower);
      continue;
    }
    if (lower.codeUnitAt(0) >= 0x4e00 && lower.codeUnitAt(0) <= 0x9fa5) {
      b.write(c);
    }
  }
  return b.toString();
}

/// 央视台名归一用的后缀词（`CCTV-1 综合` → `cctv1`）。
///
/// 这些词是**台名里的栏目说明**，不是台的身份；把它们从匹配键里去掉，
/// `CCTV-1` 与 `CCTV-1 综合` 才会落到同一个固定编号上。
const List<String> kCctvSuffixWords = <String>[
  // 栏目/语种说明词：真实索引里 `CCTV-4中文国际`、`CCTV-5+体育赛事`、
  // `CCTV-8K超高清` 这类台名必须能剥到 `cctvN` 才拿得到固定号。
  // **注意两点**：
  //  1. `美洲 / 欧洲 / 亚洲` 等是**独立海外台**，绝不能放进这张表，
  //     否则它们会把 4 号抢走（实测踩过）；
  //  2. 必须**长词在前**：`_stripCctvWords` 只剥第一个命中的词，
  //     `超高清` 若排在 `高清` 后面，会先被剥成 `cctv8k超` 从而失配。
  '中文国际', '体育赛事', '社会与法', '国防农业', '农业农村', '超高清',
  '综合', '财经', '综艺', '国际', '体育', '电影', '电视剧', '纪录', '科教',
  '戏曲', '新闻', '少儿', '音乐', '奥林匹克', '军事', '农村', '农业',
  '高清', '超清',
];

/// 去掉央视台名里的栏目后缀词。
String _stripCctvWords(String key) {
  var k = key;
  for (final w in kCctvSuffixWords) {
    if (k.length > w.length && k.endsWith(w)) {
      k = k.substring(0, k.length - w.length);
      break;
    }
  }
  return k;
}

/// 央视 `cctv<N>` / `cctv<N>+` / `cctv<N>k` 的固定号。
///
/// 只有 `cctv4k`（CCTV 4K）与 `cctv8k`（CCTV-8K）是独立的超高清台。
/// 旧实现把**任何** `k` 结尾写法都返回 19，于是 `CCTV-8K` 与 `CCTV-4K`
/// 抢同一个号；其余 `k` 写法不认，交给号段自动分配。
int? _cctvFixed(int n, String? suffix) {
  if (suffix == '+') return kCctvSportsPlusNumber;
  if (suffix == 'k') {
    if (n == 4) return kCctv4kNumber;
    if (n == 8) return kCctv8kNumber;
    return null;
  }
  return kCctvNumbers[n];
}

/// 固定编号查表。
///
/// 返回 null 表示该台没有固定编号，走号段内稳定分配。
int? fixedNumberOf(String name) {
  final key = numberKey(name);
  // 央视：cctv + 号码（+ / k 结尾是独立台）。
  //
  // 央视：cctv + 号码（+ / k 结尾是独立台）。
  //
  // 这里**整串匹配**（末尾锚定 `$`）：带栏目/语种后缀的台名（`CCTV-4中文国际`）
  // 由下面的 `_stripCctvWords` 白名单剥离后再匹配——用白名单而不是「任意中文
  // 后缀」，是因为 `CCTV-4美洲` 这类独立海外台也是中文结尾，放开会把 4 号抢走。
  final cctv = RegExp(r'^cctv(\d{1,2})(k|\+)?$').firstMatch(key);
  if (cctv != null) {
    final v = _cctvFixed(int.parse(cctv.group(1)!), cctv.group(2));
    if (v != null) return v;
  }
  // 央视台名带栏目后缀时（`CCTV-1 综合`）再试一次。
  final stripped = _stripCctvWords(key);
  if (stripped != key) {
    final again = RegExp(r'^cctv(\d{1,2})(k|\+)?$').firstMatch(stripped);
    if (again != null) {
      final v = _cctvFixed(int.parse(again.group(1)!), again.group(2));
      if (v != null) return v;
    }
  }
  // CGTN：综合 20 / 纪录 21。
  //
  // 旧实现用 `key.startsWith('cgtn')` 把所有 CGTN 子频道（英语/俄语/法语/
  // 西语/阿语/Global Biz/Arabic/French/Russian/Spanish…）一律返回 20，
  // 于是十几个**不同的台**抢同一个号，rebuild 只留一个、其余被自动分配到
  // 47–58，按 20 跳台必然切错。这里改成只认综合台与纪录台的精确写法，
  // 其余子频道走央视号段自动分配（首次分配即落盘，仍然稳定）。
  // 纪录频道的中英文/错字写法已在 canonicalName 归一成「CGTN纪录」。
  if (key == 'cgtn' || key == 'cgtn综合') return kCgtnNumber;
  if (key == 'cgtn纪录' || key == 'cgtndocumentary' || key == 'cgtn记录') {
    return kCgtnDocumentaryNumber;
  }
  // 中国教育电视台 1–4。
  final edu = RegExp(r'^中国教育(?:电视台)?([1-4])台?$').firstMatch(key);
  if (edu != null) return kEducationNumbers[int.parse(edu.group(1)!)]!;
  // CETV 写法（归一前的原始台名）：与「中国教育N台」是同一个台、同一个号。
  final cetv = RegExp(r'^cetv([1-4])$').firstMatch(key);
  if (cetv != null) return kEducationNumbers[int.parse(cetv.group(1)!)]!;
  // 省级卫视画质变体（4K / 8K）：与基础台同名但独立频道，给固定号防漂移。
  // 放在卫视查表之后、地方台之前：变体仍属卫视来源，且号码落在卫视号段内。
  final q = kSatelliteQualityNumbers[key];
  if (q != null) return q;
  // 省级卫视。
  final sat = kSatelliteNumbers[key];
  if (sat != null) return sat;
  // 地方台（苏州等固定城市台）。
  final loc = kLocalNumbers[key];
  if (loc != null) return loc;
  return null;
}

/// 编号的持久化接口（实现见 `data/channel_number_store.dart`）。
abstract class ChannelNumberStore {
  /// 读回「归一化台名 → 编号」。
  Map<String, int> load();

  /// 写回。
  Future<void> save(Map<String, int> map);
}

/// 编号表：把频道表映射成唯一、稳定的数字编号。
///
/// 用法：
/// ```dart
/// final book = ChannelNumberBook(store: store);
/// book.rebuild(channels);              // 频道表变化时重建
/// book.numberOf(channel.id);           // 频道 id → 编号
/// book.channelForNumber(channels, 1);  // 编号 → 频道（CCTV-1）
/// ```
class ChannelNumberBook {
  ChannelNumberBook({ChannelNumberStore? store}) : _store = store;

  final ChannelNumberStore? _store;

  /// 归一化台名 → 编号。
  final Map<String, int> _byKey = <String, int>{};

  /// 频道 id → 编号。
  final Map<String, int> _byChannelId = <String, int>{};

  /// 编号 → 归一化台名。
  final Map<int, String> _keyByNumber = <int, String>{};

  /// 上次分配结果（跨会话保留，保证号码不跳）。
  Map<String, int> _persisted = <String, int>{};

  bool _loaded = false;

  /// 频道 id → 编号。
  int? numberOf(String channelId) => _byChannelId[channelId];

  /// 归一化台名 → 编号。
  int? numberOfKey(String key) => _byKey[key];

  /// 编号 → 归一化台名。
  String? keyOfNumber(int number) => _keyByNumber[number];

  /// 编号 → 频道（按当前频道表查）。
  ///
  /// 用「频道 id → 编号」反查，而不是用台名：同名台可能有两个频道 id
  /// （来自不同索引），只有按 id 反查才能准确落到被点的那一个。
  LiveChannel? channelForNumber(Iterable<LiveChannel> channels, int number) {
    for (final c in channels) {
      if (_byChannelId[c.id] == number) return c;
    }
    return null;
  }

  /// 频道表变化后重建编号表，返回「频道 id → 编号」。
  Map<String, int> rebuild(Iterable<LiveChannel> channels) {
    _loadPersisted();
    _byKey.clear();
    _byChannelId.clear();
    _keyByNumber.clear();

    final list = channels.toList();
    // 按台名排序：同一份频道表无论索引返回顺序如何，分配结果都一样。
    final sorted = list.toList()
      ..sort((a, b) {
        final byName = numberKey(a.name).compareTo(numberKey(b.name));
        return byName != 0 ? byName : a.id.compareTo(b.id);
      });

    final used = <int>{};

    // 第一轮：固定编号（央视 / 卫视 / 苏州等）。
    for (final c in sorted) {
      final key = numberKey(c.name);
      final fixed = fixedNumberOf(c.name);
      if (fixed == null) continue;
      if (used.contains(fixed)) continue;
      used.add(fixed);
      _byKey[key] = fixed;
      _keyByNumber[fixed] = key;
    }

    // 第二轮：其余台在**自己来源的号段**里分配。
    final assigned = <String, int>{};
    for (final c in sorted) {
      final key = numberKey(c.name);
      if (_byKey.containsKey(key)) {
        assigned[key] = _byKey[key]!;
        continue;
      }
      final source = ChannelTaxonomy.sourceOf(c.name, tvgId: c.tvgId);
      final band = bandOf(source);
      int number;
      final remembered = _persisted[key];
      if (remembered != null && band.contains(remembered) && !used.contains(remembered)) {
        number = remembered;
      } else {
        number = _nextFree(band, used);
      }
      used.add(number);
      _byKey[key] = number;
      _keyByNumber[number] = key;
      assigned[key] = number;
    }

    // 频道 id → 编号（同名台共享编号：它们本来就是同一个台）。
    //
    // 极端情况：归一化后仍撞号（同一个台的两种写法没被归一），
    // 这时给后来者另分配一个号——「编号唯一」是硬要求，
    // 任何输入下都不能让两个台在遥控器上抢同一个号。
    //
    // 两个集合要分清：
    // * `reserved` —— 前两轮已分配的全部号码（固定编号 + 号段内分配），
    //   兜底分配**不能**再占用它们（实测 `Ando TV` 曾抢走苏州台预留的 207，
    //   把 `无锡生活频道` 的号占掉，连带苏州几个台被迫挪到 331/344/345）；
    // * `usedById` —— 已经落到某个具体频道 id 上的号，用来判断「同名台
    //   是否撞号」（同一个台名出现两份时，第二份要另给一个号）。
    final reserved = <int>{...used};
    final usedById = <int>{};
    for (final c in list) {
      if (_byChannelId.containsKey(c.id)) continue;
      final key = numberKey(c.name);
      var n = _byKey[key];
      if (n == null || usedById.contains(n)) {
        final source = ChannelTaxonomy.sourceOf(c.name, tvgId: c.tvgId);
        n = _nextFree(bandOf(source), {...reserved, ...usedById});
        // 不覆盖 `_byKey[key]`：那是该台名的「规范编号」，
        // 同名台多出来的那一份要自己的号，但不能改掉规范编号。
      }
      usedById.add(n);
      _byChannelId[c.id] = n;
      _keyByNumber.putIfAbsent(n, () => key);
    }

    _persist(assigned);
    return Map<String, int>.of(_byChannelId);
  }

  /// 某个来源对应的号段。
  static NumberBand bandOf(ChannelSource source) {
    for (final b in kChannelBands) {
      if (b.source == source) return b;
    }
    return kChannelBands.last;
  }

  /// 号段内的下一个空闲编号。
  ///
  /// 号段用尽时**继续向上找**（而不是返回 `band.end`）：返回一个已被占用的
  /// 号会直接打破「编号唯一」这条硬约束——两个台抢同一个号，按号切台就会
  /// 切到另一个台。宁可让编号越过号段边界，也不能重号。
  int _nextFree(NumberBand band, Set<int> used) {
    for (var n = band.start; n <= band.end; n++) {
      if (!used.contains(n)) return n;
    }
    var n = band.end + 1;
    while (used.contains(n)) {
      n++;
    }
    return n;
  }

  void _loadPersisted() {
    if (_loaded) return;
    _loaded = true;
    final store = _store;
    if (store == null) return;
    try {
      final map = store.load();
      _persisted = map;
    } catch (_) {
      // 读不到就当没有历史分配：号码会重新分配，但仍然唯一。
      _persisted = <String, int>{};
    }
  }

  /// 落盘**当前频道表**的规范编号（台名键 → 号）。
  ///
  /// 旧实现是 `{..._persisted, ...assigned}`：把历史会话的条目永久累加。
  /// 实测累积到 **1051 条、其中 208 个号码重复**（同一号被早已下线的台名占着），
  /// 文件既膨胀又给「按号切台」埋下无法解释的错台风险。
  ///
  /// 现在只写 `_byKey`——它恰好覆盖当前表的每个台名键，是唯一的事实来源；
  /// 历史条目只要当前表里没有就自然消失，不再污染。
  void _persist(Map<String, int> assigned) {
    final store = _store;
    if (store == null) return;
    // `assigned` 是 `_byKey` 的子集（前两轮的分配结果），直接用 `_byKey` 更完整，
    // 也能顺带清掉历史遗留条目。
    final current = <String, int>{..._byKey};
    _persisted = current;
    // 落盘失败不影响播放：号码已经在内存里定下来了。
    store.save(current).catchError((_) {});
  }
}

/// 遥控器数字输入解析：把按键序列变成一个编号。
///
/// 主流机顶盒的行为：**逐位累积**，超过设定时间没继续按就提交；
/// 按「确认」立即提交；按「返回 / 退出」取消。
class NumberInputBuffer {
  NumberInputBuffer({this.timeout = const Duration(milliseconds: 1500)});

  /// 累积超时：超时即把已输入的数字当成编号提交。
  final Duration timeout;

  String _buffer = '';

  /// 当前已输入的数字串。
  String get buffer => _buffer;

  bool get isEmpty => _buffer.isEmpty;

  /// 输入一位数字。返回 true 表示缓冲有变化。
  bool addDigit(int digit) {
    if (digit < 0 || digit > 9) return false;
    // 最多 4 位：号段最大是 4 位（节目分集）。
    if (_buffer.length >= 4) return false;
    _buffer = '$_buffer$digit';
    return true;
  }

  /// 取出并清空（提交用）。
  String take() {
    final v = _buffer;
    _buffer = '';
    return v;
  }

  /// 清空（取消用）。
  void clear() => _buffer = '';
}
