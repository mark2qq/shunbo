/// 安装包内置的点播检索索引（纯 Dart，不依赖 Flutter，可裸 `dart run` 回归）。
///
/// ## 为什么需要它
///
/// 采集接口全量 135 万条，`?ac=detail` 单条 17 KB（`vod_play_url` 占 13.6 KB），
/// 完整目录约 21 GB —— 装不进任何安装包。但「首次打开 App 要先等网络同步完
/// 才能搜到片」是不可接受的。折中方案：把**检索元数据**（站点 + vod_id +
/// type_id + 片名）打包进安装包，全量约 13 MB，启动即可检索；
/// 用户点开某部片时再用 `?ac=detail&ids=` 回源取播放地址。
///
/// 索引负责「搜得到」，详情接口负责「播得了」。这条分工与主流播放器一致。
///
/// ## 为什么是流式扫描而不是建对象图
///
/// 真机是 Letv S50 Air（API 18 / armv7a，内存紧张）。135 万条
/// [VodItem] 至少 400 MB，解完就 OOM。这里全程只做两件事：
///  * 解 gzip → 按 `\n` 切行 → 逐行判断是否命中 → 命中才建对象；
///  * 片名做前端编码（只存与上一行的公共前缀长度 + 后缀），扫描时维护
///    一个「上一行完整片名」的滚动变量即可还原。
///
/// 一次检索的内存峰值 ≈ 一个分片的解压后字节数（最大片约 6 MB）+ 命中结果。
library;

import 'dart:convert';
import 'dart:io' show gzip;
import 'dart:typed_data';

/// 索引格式版本。与 `tooling/pack_vod_index.py` 的 `version` 必须一致。
///
/// * **1** —— `站点 \t vod_id \t 类目下标 \t 前缀长度 \t 后缀`，只有四个字段，
///   没有地区 / 年份 ⇒ 「地区」「时间」两个筛选维度整行缺失（第十七次修的症状）。
/// * **2** —— 行尾追加 `年份` 与 `地区下标表`：
///   `站点 \t vod_id \t 类目下标 \t 前缀长度 \t 年份 \t 地区下标 \t 后缀`。
///   地区词表放在 manifest 的 `areas` 里，行内只存下标（省体积，且换词表时
///   不必改分片格式）。
///
/// 解析侧按**列数**自适配（`>= 7` 走 v2），manifest 版本只用于提示与门禁，
/// 这样「旧分片 + 新代码」也能读出类型（地区/时间为空，UI 明确说明不可筛）。
const int kBuiltinIndexVersion = 2;

/// 一个分片在 manifest 里的描述。
class BuiltinIndexShard {
  const BuiltinIndexShard({
    required this.key,
    required this.label,
    required this.file,
    required this.records,
    required this.gzBytes,
    required this.sha256,
    this.withYear = 0,
    this.withArea = 0,
  });

  /// 栏目键（`movies` / `series` / `documentaries` / `shortVideo` /
  /// `anime` / `other`），与 [VodSection.name] 同名。
  final String key;
  final String label;
  final String file;
  final int records;
  final int gzBytes;
  final String sha256;

  /// 带年份 / 地区字段的条数（v2 才有）。
  ///
  /// 不是「装饰性统计」：有些采集站这两个字段是空的，如果覆盖率太低，
  /// 「时间 / 地区」筛下去会大面积漏片 —— 界面必须能据此说明，
  /// 门禁也要能断言覆盖率没有塌下来。
  final int withYear;
  final int withArea;

  static BuiltinIndexShard? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final key = '${raw['key'] ?? ''}';
    final file = '${raw['file'] ?? ''}';
    if (key.isEmpty || file.isEmpty) return null;
    int num(Object? v) => v is int ? v : int.tryParse('$v') ?? 0;
    return BuiltinIndexShard(
      key: key,
      label: '${raw['label'] ?? key}',
      file: file,
      records: num(raw['records']),
      gzBytes: num(raw['gzBytes']),
      sha256: '${raw['sha256'] ?? ''}',
      withYear: num(raw['withYear']),
      withArea: num(raw['withArea']),
    );
  }
}

/// 内置索引清单（`assets/vod_index/manifest.json`）。
class BuiltinIndexManifest {
  const BuiltinIndexManifest({
    required this.version,
    required this.generatedAt,
    required this.sourceUrl,
    required this.sites,
    required this.types,
    required this.shards,
    required this.total,
    this.typeNames = const <String>[],
    this.typeSites = const <int>[],
    this.areas = const <String>[],
    this.rawTotal = 0,
    this.dedupDropped = 0,
    this.excludedSites = const <String>[],
  });

  final int version;

  /// 打包时间（UTC ISO8601）。这是「内置索引有多旧」的唯一判据。
  final DateTime generatedAt;

  /// 打包时的接口地址。与用户当前设定不一致 ⇒ 索引内容对不上，必须重下。
  final String sourceUrl;

  /// 打包时纳入的站点（顺序即分片里的站点下标）。
  final List<BuiltinIndexSite> sites;

  /// 类目字典：分片里的 `type` 列是这张表的下标。
  final List<String> types;

  /// 类目**名字**表：与 [types] 一一对应（`typeNames[i]` 是 `types[i]` 的中文名）。
  ///
  /// 为什么单独存一份：分片里每行只有 `type` 下标（省体积），manifest 里原来
  /// 也只写了 id 数组。App 回填 `VodItem.typeName` 时手上只有 id，界面上
  /// 就出现「25」这种数字类型。打包侧本来就有类目名字典，只是没写出来 ——
  /// 四百余项不到 8 KB，没有不带的理由（1.0.5 第十五次修）。
  final List<String> typeNames;

  /// [types] 每一项属于哪个站（站点下标）。
  ///
  /// 必须有这一列：`type_id` 是**各站自己的编号**，`1` 在 A 站是「电影」、
  /// 在 B 站是「电视剧」。只按 `type_id` 查名字，会把「电视剧」标到一部
  /// 电影上 —— 不报错，只是标错。有了站点列，查询才是唯一命中的。
  final List<int> typeSites;

  /// 地区**规范词表**：分片里的地区列是这张表的下标。
  ///
  /// 打包时把各站方言（`中国大陆` / `大陆` / `内地` / `港台`…）统一映射到
  /// `kVodAreaVocabulary` 里的规范词，再按下标落盘。词表由数据驱动
  /// （按命中数降序），所以「地区」行的默认顺序就是最常用的那几个。
  ///
  /// 老索引（v1）没有这个字段 ⇒ 空表 ⇒ 地区维度整体不可用，UI 会明说。
  final List<String> areas;

  /// 地区下标 → 规范词。越界返回空串。
  String areaNameOf(int index) =>
      index >= 0 && index < areas.length ? areas[index] : '';

  /// (站点下标, 类目 id) → 显示名。查不到返回**空串**，不回退成 id。
  ///
  /// 宁可这一条在界面上没有类型，也不要显示「25」：数字类型会让用户以为
  /// 程序坏了，而没有类型只是「这个站没给类目名」。
  String typeNameOf(int siteIndex, String typeId) {
    if (typeId.isEmpty) return '';
    for (var i = 0; i < types.length; i++) {
      if (types[i] == typeId &&
          i < typeSites.length &&
          typeSites[i] == siteIndex) {
        return i < typeNames.length ? typeNames[i] : '';
      }
    }
    return '';
  }

  final List<BuiltinIndexShard> shards;

  /// 去重后的总条数（分片 records 之和）。
  final int total;

  /// 抓取到的原始条数（去重前）。
  final int rawTotal;

  /// 因跨站同名被丢弃的条数。
  final int dedupDropped;

  /// 因未抓全而被排除的站点 key。
  final List<String> excludedSites;

  bool get isEmpty => total == 0 || shards.isEmpty;

  int get gzBytes =>
      shards.fold<int>(0, (sum, s) => sum + s.gzBytes);

  BuiltinIndexShard? shardFor(String sectionKey) {
    for (final s in shards) {
      if (s.key == sectionKey) return s;
    }
    return null;
  }

  /// 从 JSON 文本解析。字段缺失 / 版本不符返回 null（调用方回退网络同步）。
  static BuiltinIndexManifest? decode(String text) {
    Object? raw;
    try {
      raw = jsonDecode(text);
    } catch (_) {
      return null;
    }
    if (raw is! Map) return null;
    final version = raw['version'] is int
        ? raw['version'] as int
        : int.tryParse('${raw['version']}') ?? 0;
    // 认得两版：v1（无地区/年份）与 v2（行尾带年份 + 地区下标）。
    // 其它版本一律拒绝 —— 说明这份索引比程序新，字段含义未知，硬读会串位。
    if (version != 1 && version != kBuiltinIndexVersion) return null;
    final sites = <BuiltinIndexSite>[];
    final sitesRaw = raw['sites'];
    if (sitesRaw is List) {
      for (final s in sitesRaw) {
        final site = BuiltinIndexSite.fromJson(s);
        if (site != null) sites.add(site);
      }
    }
    final types = <String>[];
    final typesRaw = raw['types'];
    if (typesRaw is List) {
      for (final t in typesRaw) {
        types.add('$t');
      }
    }
    // 老 manifest 没有这个字段 ⇒ 空表 ⇒ [typeNameOf] 一律返回空串，
    // 界面表现为「类型行少一个词」而不是显示数字 id。
    final typeNames = <String>[];
    final namesRaw = raw['typeNames'];
    if (namesRaw is List) {
      for (final n in namesRaw) {
        typeNames.add(n == null ? '' : '$n');
      }
    }
    final typeSites = <int>[];
    final typeSitesRaw = raw['typeSites'];
    if (typeSitesRaw is List) {
      for (final s in typeSitesRaw) {
        typeSites.add(s is int ? s : int.tryParse('$s') ?? -1);
      }
    }
    final shards = <BuiltinIndexShard>[];
    final shardsRaw = raw['sections'];
    if (shardsRaw is List) {
      for (final s in shardsRaw) {
        final shard = BuiltinIndexShard.fromJson(s);
        if (shard != null) shards.add(shard);
      }
    }
    // 地区规范词表（v2 才有）。缺失 / 非列表 ⇒ 空表 ⇒ 地区维度不可筛。
    final areas = <String>[];
    final areasRaw = raw['areas'];
    if (areasRaw is List) {
      for (final a in areasRaw) {
        final word = a == null ? '' : '$a'.trim();
        if (word.isNotEmpty) areas.add(word);
      }
    }
    int num(Object? v) => v is int ? v : int.tryParse('$v') ?? 0;
    final excluded = <String>[];
    final exRaw = raw['excludedSites'];
    if (exRaw is List) {
      for (final e in exRaw) {
        excluded.add('$e');
      }
    }
    return BuiltinIndexManifest(
      version: version,
      generatedAt: DateTime.tryParse('${raw['generatedAt'] ?? ''}')?.toUtc() ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      sourceUrl: '${raw['sourceUrl'] ?? ''}',
      sites: List<BuiltinIndexSite>.unmodifiable(sites),
      types: List<String>.unmodifiable(types),
      typeNames: List<String>.unmodifiable(typeNames),
      typeSites: List<int>.unmodifiable(typeSites),
      areas: List<String>.unmodifiable(areas),
      shards: List<BuiltinIndexShard>.unmodifiable(shards),
      total: num(raw['total']),
      rawTotal: num(raw['rawTotal']),
      dedupDropped: num(raw['dedupDropped']),
      excludedSites: List<String>.unmodifiable(excluded),
    );
  }
}

/// 打包时纳入的一个采集站。
class BuiltinIndexSite {
  const BuiltinIndexSite({
    required this.key,
    required this.name,
    required this.api,
    required this.total,
  });

  final String key;
  final String name;

  /// 站点接口地址（已补 `?`/`&`）。回源取详情要用它。
  final String api;
  final int total;

  static BuiltinIndexSite? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final key = '${raw['key'] ?? ''}';
    final api = '${raw['api'] ?? ''}';
    if (key.isEmpty || api.isEmpty) return null;
    return BuiltinIndexSite(
      key: key,
      name: '${raw['name'] ?? key}',
      api: api,
      total: raw['total'] is int ? raw['total'] as int : 0,
    );
  }
}

/// 内置索引里命中的一条记录（**不是** [VodItem]：没有剧集、没有简介）。
///
/// 刻意与 [VodItem] 分开：内置索引命中一条只代表「这部片存在、在哪个站、
/// 叫什么」，播放地址还没拿到。硬凑成 [VodItem] 会让 UI 以为可以播，
/// 点进去必然失败。走 [toItem] 时明确标记成「待回源」状态。
class BuiltinIndexHit {
  const BuiltinIndexHit({
    required this.siteIndex,
    required this.vodId,
    required this.typeId,
    required this.name,
    required this.section,
    this.year = '',
    this.areas = const <int>[],
  });

  /// 站点下标（指向 [BuiltinIndexManifest.sites]）。
  final int siteIndex;

  /// 采集站内的 `vod_id`。
  final String vodId;

  /// 采集站类目 id（可空）。
  final String typeId;

  /// 片名。
  final String name;

  /// 所属栏目键。
  final String section;

  /// 年份原串（`2026`）。采集站没给就是空串。
  final String year;

  /// 地区下标（指向 [BuiltinIndexManifest.areas]）。一行可能有多个。
  final List<int> areas;

  /// 全局唯一 id。与网络同步条目的 id 口径一致（`站点key:vod_id`），
  /// 这样「内置索引搜到」与「网络同步过」是同一部片，不会出现两条。
  String get id => 'builtin:$siteIndex:$vodId';
}

/// 前端编码的一行：`站点下标 \t vod_id \t 类目下标 \t 前缀长度 \t 后缀`。
///
/// 单独抽出来是为了让门禁能直接断言解析正确性（不必解 gzip）。
class BuiltinIndexLine {
  const BuiltinIndexLine({
    required this.siteIndex,
    required this.vodId,
    required this.typeIndex,
    required this.prefixLength,
    required this.suffix,
    this.year = '',
    this.areas = const <int>[],
  });

  final int siteIndex;
  final String vodId;
  final int typeIndex;
  final int prefixLength;
  final String suffix;

  /// 年份原串。老索引（v1）恒为空串。
  final String year;

  /// 地区下标表。老索引（v1）恒为空表。
  final List<int> areas;

  /// 解析一行。
  ///
  /// 两种列式都认：
  ///  * v1（5 列）：`站点 · vod_id · 类目下标 · 前缀长度 · 后缀`；
  ///  * v2（7 列起）：`站点 · vod_id · 类目下标 · 前缀长度 · 年份 · 地区下标 · 后缀`
  ///    —— 数值列在前、后缀永远在最后，这样片名里出现制表符也不会错位
  ///    （后缀取第 7 段之后的全部）。
  ///
  /// [format] 取 manifest 的版本号：v1 的片名若带制表符会凑出 6 段，
  /// 光看列数无法与 v2 区分，所以由调用方明确告知。
  static BuiltinIndexLine? parse(String line, {int format = 2}) {
    if (line.isEmpty) return null;
    final parts = line.split('\t');
    if (parts.length < 5) return null;
    final site = int.tryParse(parts[0]);
    final typeIndex = int.tryParse(parts[2]);
    final prefix = int.tryParse(parts[3]);
    if (site == null || typeIndex == null || prefix == null) return null;
    final vodId = parts[1];
    if (vodId.isEmpty) return null;
    if (format >= 2 && parts.length >= 7) {
      final areaIdx = <int>[];
      for (final piece in parts[5].split(',')) {
        final i = int.tryParse(piece.trim());
        if (i != null && i >= 0) areaIdx.add(i);
      }
      return BuiltinIndexLine(
        siteIndex: site,
        vodId: vodId,
        typeIndex: typeIndex,
        prefixLength: prefix,
        suffix: parts.sublist(6).join('\t'),
        year: parts[4].trim(),
        areas: List<int>.unmodifiable(areaIdx),
      );
    }
    // 后缀本身允许含 tab（片名里出现制表符极罕见，但不能因此丢掉整行）：
    // 第 5 段之后全部拼回后缀。
    final suffix = parts.length == 5 ? parts[4] : parts.sublist(4).join('\t');
    return BuiltinIndexLine(
      siteIndex: site,
      vodId: vodId,
      typeIndex: typeIndex,
      prefixLength: prefix,
      suffix: suffix,
    );
  }
}

/// 一次扫描的结论：命中列表 + **全目录命中总数**。
///
/// 为什么要有总数：检索现在是「当前栏目整份目录」，命中可能上万条，
/// 卡片只能铺前 [limit] 张。只报卡片数会让用户以为目录里就这么多；
/// 报总数才能说明「索引确实查了整份目录」，也是需求「全目录检索」的可见证据。
class BuiltinScanResult {
  const BuiltinScanResult(this.hits, this.total);

  final List<BuiltinIndexHit> hits;
  final int total;

  static const BuiltinScanResult empty = BuiltinScanResult(<BuiltinIndexHit>[], 0);
}

/// 扫描回调：拿到**还原后的完整片名**（已小写）与该行的全部字段。
///
/// 把整行交给调用方，是为了让「按年份 / 地区 / 类型检索」与「按片名检索」
/// 走同一次扫描：年份与地区都不在片名里，只给片名的话 `2020` 永远搜不到。
typedef BuiltinIndexMatcher = bool Function(
    String lowerName, BuiltinIndexLine line);

/// 还原前端编码的片名：上一条片名保留前 [prefixLength] 个字符 + 本行后缀。
///
/// 按 **UTF-16 码元**截取与打包脚本一致：Python 侧按字符（码点）截取，
/// Dart 的 [String] 是 UTF-16，非 BMP 字符（emoji / 生僻字）会占 2 个码元。
/// 打包脚本刻意在字符边界回退，因此对 BMP 字符两者完全等价；
/// 遇到非 BMP 时可能多截/少截，[BuiltinIndexScanner] 用「截断后仍能拼回」
/// 的容错（越界就整条当无前缀）兜住，不会产生错误片名。
String applyFrontCode(String previous, int prefixLength, String suffix) {
  if (prefixLength <= 0) return suffix;
  if (prefixLength > previous.length) return suffix;
  return '${previous.substring(0, prefixLength)}$suffix';
}

/// 逐行扫描一个分片，收集命中的行。
///
/// 不做「先全解再筛」：边解边判，只把命中的行建成对象。
class BuiltinIndexScanner {
  BuiltinIndexScanner({
    required this.manifest,
    required this.sectionKey,
  });

  final BuiltinIndexManifest manifest;
  final String sectionKey;

  /// 分片的列式版本（= manifest 版本）。
  int get _format => manifest.version;

  /// 浏览模式：**不看关键词**，按行号等距采样收集一批片源。
  ///
  /// 为什么不能简单取前 N 行：分片是按片名排序后做前端编码的，前 200 行
  /// 全是 `#` / `0.` / `&quot;` 开头的符号片名（实测 movies 分片前 20 条
  /// 有 18 条如此），首屏铺出来完全不像片库。等距采样让一屏就覆盖整个分片，
  /// 观感与「内置了 60 万条」的事实一致。
  ///
  /// [offset] 是本轮在每段里的位移（0 基），[stride] 是段长：命中条件是
  /// `行号 >= offset && (行号 - offset) % stride == 0`。续载把 [offset] 加一
  /// 即可拿到每段的下一张卡，`offset >= stride` 时整片已被取完、自然返回空。
  ///
  /// 前端编码要求逐行维护 `previous`，所以**即使不命中也必须走完每一行**，
  /// 不能按行号跳跃 —— 跳行会拼出错误片名。
  List<BuiltinIndexHit> collect(
    String body, {
    int offset = 0,
    int stride = 1,
    int limit = 0,
  }) {
    final hits = <BuiltinIndexHit>[];
    final step = stride < 1 ? 1 : stride;
    final from = offset < 0 ? 0 : offset;
    var previous = '';
    var lineIndex = 0;
    var start = 0;
    final len = body.length;
    while (start <= len) {
      var end = body.indexOf('\n', start);
      if (end < 0) end = len;
      if (end > start) {
        final line =
            BuiltinIndexLine.parse(body.substring(start, end), format: _format);
        if (line != null) {
          final name =
              applyFrontCode(previous, line.prefixLength, line.suffix);
          previous = name;
          if (lineIndex >= from && (lineIndex - from) % step == 0) {
            hits.add(_hitOf(line, name));
            if (limit > 0 && hits.length >= limit) return hits;
          }
          lineIndex++;
        }
      }
      if (end >= len) break;
      start = end + 1;
    }
    return hits;
  }

  /// 扫描 [lines]（一个分片解压后的全部行），返回命中列表 + 全目录命中总数。
  ///
  /// [match] 拿到还原后的完整片名（已小写）与整行字段 —— 年份 / 地区不在
  /// 片名里，只给片名的话「搜 2020」永远为空。
  /// [limit] 为 0 表示不限；超出时仍会把整片扫完，只为拿到真实的命中总数
  /// （一次 6 MB 文本扫描在真机上约 60–120 ms，比「报个假数」划算）。
  BuiltinScanResult scan(
    String body, {
    required BuiltinIndexMatcher match,
    int limit = 0,
  }) {
    final hits = <BuiltinIndexHit>[];
    var total = 0;
    var previous = '';
    var start = 0;
    final len = body.length;
    while (start <= len) {
      var end = body.indexOf('\n', start);
      if (end < 0) end = len;
      if (end > start) {
        final line =
            BuiltinIndexLine.parse(body.substring(start, end), format: _format);
        if (line != null) {
          final name =
              applyFrontCode(previous, line.prefixLength, line.suffix);
          previous = name;
          if (match(name.toLowerCase(), line)) {
            total++;
            if (limit <= 0 || hits.length < limit) {
              hits.add(_hitOf(line, name));
            }
          }
        }
      }
      if (end >= len) break;
      start = end + 1;
    }
    return BuiltinScanResult(hits, total);
  }

  /// 行 → 命中（补上类目 id、年份、地区下标）。
  BuiltinIndexHit _hitOf(BuiltinIndexLine line, String name) => BuiltinIndexHit(
        siteIndex: line.siteIndex,
        vodId: line.vodId,
        typeId: line.typeIndex >= 0 && line.typeIndex < manifest.types.length
            ? manifest.types[line.typeIndex]
            : '',
        name: name,
        section: sectionKey,
        year: line.year,
        areas: line.areas,
      );
}

/// 把 gzip 字节解成 UTF-8 文本（供扫描）。
///
/// 抽成顶层函数是为了让门禁能在裸 `dart run` 下直接喂字节验证，
/// 不必构造整个资产加载链路。
String decodeShardBody(Uint8List gz) =>
    utf8.decode(gzip.decode(gz), allowMalformed: true);

/// 一致性判定：内置索引是否与用户当前设定的接口匹配。
///
/// 判据（缺一不可，任一不符就重下）：
///  1. **接口地址**必须一致 —— 索引里的 `vod_id` 只在对应采集站内有效，
///     换一个接口，内置索引里的 id 全部指向错误的片；
///  2. 索引不能比 [maxAge] 更旧 —— 采集站每天都在更新，一年前的索引
///     即使地址对得上，新片也搜不到；
///  3. manifest 不能是空的。
///
/// 刻意**不用** ETag / Last-Modified 做主判据：`config.json` 只有 10 KB，
/// 每次启动都拉一遍确认，比读本地时间戳更可靠，代价也可以忽略。
/// 但接口地址的一致性必须靠本地索引记录来判断（否则要等网络回来才知道）。
bool builtinIndexMatches({
  required BuiltinIndexManifest? manifest,
  required String selectedUrl,
  DateTime? now,
  Duration maxAge = const Duration(days: 7),
}) {
  if (manifest == null || manifest.isEmpty) return false;
  if (manifest.sourceUrl.trim() != selectedUrl.trim()) return false;
  final t = (now ?? DateTime.now()).toUtc();
  final age = t.difference(manifest.generatedAt);
  // 未来时间（用户改过系统时钟 / 打包机时区错）按「新鲜」处理，
  // 但不能无限：超过 maxAge 的未来同样视为不可信。
  if (age.isNegative) return age.abs() <= maxAge;
  return age <= maxAge;
}
