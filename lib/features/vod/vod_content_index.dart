/// 点播接口数据的**本地内容检索记录**（纯 Dart，裸 `dart run` 可回归）。
///
/// 主流播放器拿到采集接口数据后不会让 UI 直接读网络响应，而是先落一份本地
/// 媒体库：按稳定 id upsert、同名去重、记录最后核对时间，界面与检索都查本地，
/// 后台再慢慢与接口同步。这一层就是顺播的那份媒体库：
///
///  * [VodContentRecord]：一条记录 = 片名 / 类型 / 上映年份 / 地区 + 展示与
///    播放所需的全部字段，附带 `updatedAt`（最后一次与接口核对的时间）；
///  * [VodContentIndex]：id → 记录的**唯一真相**。`栏目内容` 由它恢复，
///    `内容检索` 也查它，所以两者不可能不一致；
///  * 同步：`upsertItems` 按 id 覆盖元数据、按 `片名|年份` 去重；
///    `pruneExpired` 把接口已不再返回且超过 TTL 的记录清掉。
///
/// 刻意不引入数据库：电视盒子 / API18 单包里没有可用的 SQLite 插件，
/// 一个 1~2 MB 的 JSON 用原子替换写盘就够，读盘实测 38 ms。
library;

import 'dart:collection';

import 'third_party_vod.dart';
import 'vod_catalog.dart';
import 'vod_search.dart';

/// 本地记录文件格式版本。v1 是 1.0.5 早期只存 6 个字段的缓存，
/// 由 `VodLibraryStore` 兼容读回并升级成 v2 记录。
const int kVodContentIndexVersion = 2;

/// 记录 TTL：接口已不再返回、且 30 天没被核对过的本地记录视为过期。
///
/// 不设成「本次同步没出现就删」：分页是增量浏览，一次只翻 5 个站各一页，
/// 全库有百万条，没出现在这一批里的绝大多数只是还没翻到，当场删掉
/// 会把用户已经看过的片库清空。TTL 才是「过期」的正确判据。
const Duration kVodRecordTtl = Duration(days: 30);

/// 本地记录何时该后台重新核对（与片库缓存的 freshness 同一口径）。
const Duration kVodRecordRefreshAfter = Duration(hours: 12);

/// 一条内容检索记录。
class VodContentRecord {
  const VodContentRecord({
    required this.id,
    required this.title,
    required this.typeName,
    required this.genre,
    required this.area,
    required this.year,
    required this.subtitle,
    required this.description,
    required this.license,
    required this.posterUrl,
    required this.section,
    required this.episodes,
    required this.sourceId,
    required this.sourceName,
    required this.headers,
    required this.updatedAt,
    this.accentSeed = 0,
  });

  factory VodContentRecord.fromItem(
    VodItem item, {
    required String sourceId,
    required String sourceName,
    required Map<String, String> headers,
    required DateTime updatedAt,
  }) =>
      VodContentRecord(
        id: item.id,
        title: item.title,
        typeName: item.typeName,
        genre: item.genre,
        area: item.area,
        year: item.year,
        subtitle: item.subtitle,
        description: item.description,
        license: item.license,
        posterUrl: item.posterUrl,
        section: item.section,
        episodes: List<VodEpisode>.unmodifiable(item.episodes),
        sourceId: sourceId.isEmpty ? item.sourceId : sourceId,
        sourceName: sourceName,
        headers: Map<String, String>.unmodifiable(
            headers.isEmpty ? item.headers : headers),
        updatedAt: updatedAt,
        accentSeed: item.accentSeed,
      );

  final String id;
  final String title;

  /// 类型：采集站栏目类目 `type_name`（短剧 / 欧美剧 / 剧情片…）。
  final String typeName;

  /// 类型：`vod_class`（喜剧,爱情…），与上面的栏目类目互补。
  final String genre;

  /// 地区。
  final String area;

  /// 上映年份。
  final String year;

  final String subtitle;
  final String description;
  final String license;
  final String posterUrl;
  final VodSection section;
  final List<VodEpisode> episodes;
  final String sourceId;
  final String sourceName;
  final Map<String, String> headers;

  /// 最后一次与接口数据核对的时间（不是「内容变更」时间）。
  /// 仍在接口里出现的条目每次同步都会续期，只有真正下架的才会过期。
  final DateTime updatedAt;
  final int accentSeed;

  VodItem toItem() => VodItem(
        id: id,
        title: title,
        subtitle: subtitle,
        description: description,
        license: license,
        section: section,
        episodes: episodes,
        accentSeed: accentSeed,
        sourceId: sourceId,
        headers: headers,
        posterUrl: posterUrl,
        typeName: typeName,
        area: area,
        year: year,
        genre: genre,
      );

  String get fingerprint => vodContentFingerprint(toItem());
  String get contentKey => vodContentKey(toItem());

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'title': title,
        'type': typeName,
        'genre': genre,
        'area': area,
        'year': year,
        'subtitle': subtitle,
        'description': description,
        'license': license,
        'poster': posterUrl,
        'section': section.name,
        'sourceId': sourceId,
        'sourceName': sourceName,
        'headers': headers,
        'updatedAt': updatedAt.toIso8601String(),
        'accentSeed': accentSeed,
        'episodes': <List<Object?>>[
          for (final e in episodes) <Object?>[e.number, e.title, e.url],
        ],
      };

  /// 坏记录直接丢弃（磁盘被外部改过也不会把整份索引带崩）。
  static VodContentRecord? fromJson(
    Object? raw, {
    required String fallbackSourceId,
    required String fallbackSourceName,
    required Map<String, String> fallbackHeaders,
    required DateTime fallbackUpdatedAt,
  }) {
    if (raw is! Map) return null;
    final m = Map<String, dynamic>.from(raw);
    String text(String key) => (m[key] ?? '').toString();
    final id = text('id');
    final title = text('title');
    if (id.isEmpty || title.isEmpty) return null;
    final epsRaw = m['episodes'];
    if (epsRaw is! List) return null;
    final episodes = <VodEpisode>[];
    for (final x in epsRaw) {
      if (episodes.length >= kMaxThirdPartyEpisodes) break;
      if (x is! List || x.length < 3) continue;
      final number = x[0] is int ? x[0] as int : int.tryParse('${x[0]}');
      final url = '${x[2]}';
      if (number == null || !safeMediaUrl(url)) continue;
      episodes.add(VodEpisode(number: number, title: '${x[1]}', url: url));
    }
    if (episodes.isEmpty) return null;
    final sectionName = text('section');
    final headers = <String, String>{};
    final h = m['headers'];
    if (h is Map) {
      h.forEach((k, v) {
        final key = k.toString();
        if (kAllowedPlaybackHeaderNames.contains(key.toLowerCase())) {
          headers[key] = v.toString();
        }
      });
    }
    final sourceId = text('sourceId').isEmpty
        ? fallbackSourceId
        : text('sourceId');
    final decoded = VodItem(
      id: id,
      title: title,
      subtitle: text('subtitle'),
      description: text('description'),
      license: text('license').isEmpty
          ? kThirdPartyLicense
          : text('license'),
      section: VodSection.values.firstWhere(
        (s) => s.name == sectionName,
        // 未知 / 缺失的 section 不能再兜底成电影：那会把综艺体育又放回电影栏目。
        orElse: () => VodSection.other,
      ),
      episodes: List<VodEpisode>.unmodifiable(episodes),
      accentSeed: int.tryParse(text('accentSeed')) ?? 0,
      sourceId: sourceId,
      headers: Map<String, String>.unmodifiable(
          headers.isEmpty ? fallbackHeaders : headers),
      posterUrl: text('poster'),
      typeName: text('type'),
      genre: text('genre'),
      area: text('area'),
      year: text('year'),
    );
    // 读回也走同一套归一（短视频栏目 + 老副标题字段回填），
    // 记录与栏目不会各算一套。
    return VodContentRecord.fromItem(
      normalizeVodItem(decoded),
      sourceId: sourceId,
      sourceName: text('sourceName').isEmpty
          ? fallbackSourceName
          : text('sourceName'),
      headers: headers.isEmpty ? fallbackHeaders : headers,
      updatedAt: DateTime.tryParse(text('updatedAt')) ?? fallbackUpdatedAt,
    );
  }
}

/// 一次同步的结果（给门禁和界面对账用）。
class VodIndexSync {
  const VodIndexSync({
    this.added = 0,
    this.updated = 0,
    this.duplicates = 0,
    this.touched = 0,
  });

  final int added;
  final int updated;
  final int duplicates;
  final int touched;

  int get changed => added + updated;
}

/// 本地内容检索记录库。
class VodContentIndex {
  VodContentIndex([Iterable<VodContentRecord>? initial]) {
    if (initial != null) {
      for (final r in initial) {
        _put(r);
      }
    }
  }

  /// LinkedHashMap 保序：恢复出来的卡片顺序与上次浏览时一致，
  /// 不会每次冷启动都重排一遍。
  final LinkedHashMap<String, VodContentRecord> _byId =
      LinkedHashMap<String, VodContentRecord>();
  final Map<String, String> _keyToId = <String, String>{};

  void _put(VodContentRecord r) {
    final old = _byId[r.id];
    final key = r.contentKey;
    final owner = key.isEmpty ? null : _keyToId[key];
    // 从磁盘读回旧版记录时也可能带同名镜像：直接丢掉，保证
    // 「本地记录条数 == 栏目条目数」，不会出现两处各去重一遍。
    if (old == null && owner != null && owner != r.id) return;
    if (old != null) {
      final oldKey = old.contentKey;
      if (oldKey != key && _keyToId[oldKey] == r.id) {
        _keyToId.remove(oldKey);
      }
    }
    _byId[r.id] = r;
    if (key.isNotEmpty) _keyToId[key] = r.id;
  }

  int get length => _byId.length;
  bool get isEmpty => _byId.isEmpty;

  List<VodContentRecord> get records =>
      List<VodContentRecord>.unmodifiable(_byId.values);

  /// 栏目展示与检索共用这一份派生列表。
  List<VodItem> get items => <VodItem>[
        for (final r in _byId.values) r.toItem(),
      ];

  VodContentRecord? byId(String id) => _byId[id];

  /// 只保留前 [max] 条（按写入顺序）。落盘上限用，不改变原索引。
  VodContentIndex limited(int max) =>
      VodContentIndex(_byId.values.take(max));

  /// 内容检索：只查本地记录，不发网络请求。
  List<VodItem> search(String query) => filterVodItems(items, query);

  /// 与接口数据同步：同一 id 覆盖元数据并续期，同名不同 id 的镜像丢弃。
  VodIndexSync upsertItems(
    Iterable<VodItem> incoming, {
    required String sourceId,
    required String sourceName,
    required Map<String, String> headers,
    required DateTime now,
  }) {
    var added = 0;
    var updated = 0;
    var duplicates = 0;
    var touched = 0;
    for (final raw in incoming) {
      final item = normalizeVodItem(raw);
      final key = vodContentKey(item);
      final owner = key.isEmpty ? null : _keyToId[key];
      if (owner != null && owner != item.id) {
        duplicates++;
        continue;
      }
      final old = _byId[item.id];
      final next = VodContentRecord.fromItem(
        item,
        sourceId: sourceId,
        sourceName: sourceName,
        headers: headers,
        updatedAt: now,
      );
      if (old == null) {
        _put(next);
        added++;
      } else if (old.fingerprint != next.fingerprint) {
        _put(next);
        updated++;
      } else {
        // 内容没变也要续期：这条仍在接口里，不该被 TTL 判成过期。
        _put(next);
      }
      touched++;
    }
    return VodIndexSync(
        added: added,
        updated: updated,
        duplicates: duplicates,
        touched: touched);
  }

  /// 清理过期记录。返回被删掉的条数。
  int pruneExpired(DateTime now, Duration ttl) {
    final cutoff = now.subtract(ttl);
    final stale = <String>[
      for (final r in _byId.values)
        if (r.updatedAt.isBefore(cutoff)) r.id,
    ];
    for (final id in stale) {
      final r = _byId.remove(id);
      if (r != null) {
        final key = r.contentKey;
        if (key.isNotEmpty && _keyToId[key] == id) _keyToId.remove(key);
      }
    }
    return stale.length;
  }

  List<Map<String, dynamic>> toJson() => <Map<String, dynamic>>[
        for (final r in _byId.values) r.toJson(),
      ];

  static VodContentIndex fromRecords(
    Object? raw, {
    required String fallbackSourceId,
    required String fallbackSourceName,
    required Map<String, String> fallbackHeaders,
    required DateTime fallbackUpdatedAt,
    int maxItems = kVodCacheMaxItems,
  }) {
    final out = <VodContentRecord>[];
    if (raw is List) {
      for (final r in raw) {
        if (out.length >= maxItems) break;
        final rec = VodContentRecord.fromJson(
          r,
          fallbackSourceId: fallbackSourceId,
          fallbackSourceName: fallbackSourceName,
          fallbackHeaders: fallbackHeaders,
          fallbackUpdatedAt: fallbackUpdatedAt,
        );
        if (rec != null) out.add(rec);
      }
    }
    return VodContentIndex(out);
  }
}
