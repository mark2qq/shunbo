/// 点播接口数据的**本地内容检索记录库**（1.0.5 第十次修）。
///
/// 1.0.5 第三次修时这里只是「冷启动秒开」的片库缓存：只存 6 个字段，
/// 界面先读它、后台再走网络。本次按需求升级成主流播放器的做法 ——
/// 接口数据落地成一份可检索的本地媒体库：
///
///  * 每条记录持久化**片名 / 类型(`type_name`+`vod_class`) / 上映年份 / 地区**
///    等基本信息，另带播放地址、海报、请求头与最后核对时间；
///  * 系统启动时优先 `load()` 这份记录，栏目展示与内容检索都用它恢复的
///    [VodLibrary]，因此栏目、记录、检索结果来自同一份数据；
///  * 每次接口刷新走 `upsert` 而不是「整份覆盖」：同 id 更新元数据并续期、
///    同名不同 id 的镜像去重、超过 [kVodRecordTtl] 未再出现的记录清理；
///  * 换源（sourceId 变化）整库重建，绝不让两家接口的条目混在一起。
///
/// 沿用同一个 `vod-library.json` 文件名：**只保留一份真相**。再开一个
/// 「检索索引」文件就会出现「记录和缓存各写各的」这种必然漂移的设计。
/// v1 旧缓存仍可读，读回时自动升级成 v2 记录并做短视频栏目迁移。
library;

import 'dart:convert';
import 'dart:io';

import '../../features/vod/third_party_vod.dart';
import '../../features/vod/vod_catalog.dart';
import '../../features/vod/vod_content_index.dart';

/// 读回的本地记录快照。
class VodLibraryCache {
  const VodLibraryCache({
    required this.sourceId,
    required this.sourceName,
    required this.items,
    required this.headers,
    required this.savedAt,
    this.records = const <VodContentRecord>[],
  });

  final String sourceId;
  final String sourceName;
  final List<VodItem> items;
  final Map<String, String> headers;
  final DateTime savedAt;

  /// 与 [items] 一一对应的检索记录（[items] 就是从它们派生出来的）。
  final List<VodContentRecord> records;
}

class VodLibraryStore {
  // 不是 const：要维护「最近一次落盘的记录条数」这个运行期计数。
  VodLibraryStore(this.file);

  final File file;

  factory VodLibraryStore.at(String path) => VodLibraryStore(File(path));

  /// 最近一次成功落盘的记录条数（界面 / 门禁对账用）。
  int get lastRecordCount => _lastRecordCount;
  int _lastRecordCount = 0;

  Future<VodLibraryCache?> load() async {
    try {
      if (!await file.exists()) return null;
      // 体积护栏：正常 10000 条约 24 MB，超过 [kMaxVodLibraryBytes] 说明文件
      // 被外部改过或旧版本写坏，直接当没有缓存 —— 否则一个畸形大文件会让
      // `jsonDecode` 卡住几秒，用户看到的是「启动黑屏」而不是「慢一点」。
      final size = await file.length();
      if (size <= 0 || size > kMaxVodLibraryBytes) return null;
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final m = Map<String, dynamic>.from(decoded);
      final version = m['version'];
      if (version != 1 && version != kVodContentIndexVersion) return null;
      final sourceId = (m['sourceId'] ?? '').toString();
      final sourceName = (m['sourceName'] ?? '').toString();
      if (sourceId.isEmpty) return null;
      final headers = _headersFrom(m['headers'], const <String, String>{});
      final savedAt = DateTime.tryParse((m['savedAt'] ?? '').toString()) ??
          DateTime.fromMillisecondsSinceEpoch(0);

      final VodContentIndex index;
      if (version == kVodContentIndexVersion) {
        index = VodContentIndex.fromRecords(
          m['records'],
          fallbackSourceId: sourceId,
          fallbackSourceName: sourceName,
          fallbackHeaders: headers,
          fallbackUpdatedAt: savedAt,
        );
      } else {
        // v1 → v2：老缓存没有类型 / 年份 / 地区，只能留空；
        // 但栏目归一仍要做，短视频条目的片名/副标题足以认出来。
        final records = <VodContentRecord>[];
        final list = m['items'];
        if (list is List) {
          for (final r in list) {
            if (records.length >= kVodCacheMaxItems) break;
            final item = _decodeItem(r, sourceId, headers);
            if (item == null) continue;
            records.add(VodContentRecord.fromItem(
              normalizeVodItem(item),
              sourceId: sourceId,
              sourceName: sourceName,
              headers: headers,
              updatedAt: savedAt,
            ));
          }
        }
        index = VodContentIndex(records);
      }
      // 下架 / 换源遗留的旧记录在这里统一清掉，读回来就是干净的一份。
      index.pruneExpired(DateTime.now(), kVodRecordTtl);
      if (index.isEmpty) return null;
      if (version == 1) {
        // 老缓存**当场升级落盘**：否则「已获取内容」的元数据永远只存在于
        // 内存里，下次冷启动又得重解析一遍 v1。写失败不影响本次显示。
        try {
          await save(
            sourceId: sourceId,
            sourceName: sourceName.isEmpty ? sourceId : sourceName,
            headers: headers,
            items: index.items,
            now: savedAt,
          );
        } catch (_) {}
      }
      _lastRecordCount = index.length;
      return VodLibraryCache(
        sourceId: sourceId,
        sourceName: sourceName.isEmpty ? sourceId : sourceName,
        items: index.items,
        records: index.records,
        headers: Map<String, String>.unmodifiable(headers),
        savedAt: savedAt,
      );
    } catch (_) {
      // 缓存损坏不该影响启动：当作没有缓存，走网络。
      return null;
    }
  }

  /// 与接口数据同步后落盘。
  ///
  /// 不是「把当前内存列表整份写进去」：先读回磁盘上已有的记录，
  /// 再做 upsert / 去重 / 过期清理，这样刷新只翻一页也不会把之前
  /// 积累的几千条冲掉。
  Future<void> save({
    required String sourceId,
    required String sourceName,
    required Map<String, String> headers,
    required List<VodItem> items,
    DateTime? now,
  }) async {
    if (items.isEmpty) return;
    final stamp = now ?? DateTime.now();
    final previous = await _readIndex();
    final index = previous.sourceId == sourceId
        ? previous.index
        : VodContentIndex();
    index.upsertItems(
      items,
      sourceId: sourceId,
      sourceName: sourceName,
      headers: headers,
      now: stamp,
    );
    index.pruneExpired(stamp, kVodRecordTtl);
    final limited = index.length > kVodCacheMaxItems
        ? index.limited(kVodCacheMaxItems)
        : index;
    final payload = <String, dynamic>{
      'version': kVodContentIndexVersion,
      'sourceId': sourceId,
      'sourceName': sourceName,
      'savedAt': stamp.toIso8601String(),
      'headers': headers,
      'recordCount': limited.length,
      'records': limited.toJson(),
    };
    final tmp = File('${file.path}.tmp');
    try {
      final dir = file.parent;
      if (!await dir.exists()) await dir.create(recursive: true);
      await tmp.writeAsString(jsonEncode(payload), flush: true);
      if (await file.exists()) await file.delete();
      await tmp.rename(file.path);
      _lastRecordCount = limited.length;
    } catch (_) {
      // 写失败（磁盘满 / 权限）不影响本次使用，只是下次还得走网络。
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}
    }
  }

  Future<void> clear() async {
    try {
      if (await file.exists()) await file.delete();
      _lastRecordCount = 0;
    } catch (_) {}
  }

  /// 读回磁盘上的索引（供 [save] 做增量同步）。坏文件返回空索引。
  Future<({String sourceId, VodContentIndex index})> _readIndex() async {
    try {
      if (!await file.exists()) {
        return (sourceId: '', index: VodContentIndex());
      }
      // 与 [load] 同一道体积护栏：畸形大文件不解析，按「没有旧记录」处理。
      final size = await file.length();
      if (size <= 0 || size > kMaxVodLibraryBytes) {
        return (sourceId: '', index: VodContentIndex());
      }
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return (sourceId: '', index: VodContentIndex());
      final m = Map<String, dynamic>.from(decoded);
      final sourceId = (m['sourceId'] ?? '').toString();
      if (m['version'] != kVodContentIndexVersion || sourceId.isEmpty) {
        return (sourceId: '', index: VodContentIndex());
      }
      final fallbackHeaders =
          _headersFrom(m['headers'], const <String, String>{});
      final savedAt = DateTime.tryParse((m['savedAt'] ?? '').toString()) ??
          DateTime.fromMillisecondsSinceEpoch(0);
      return (
        sourceId: sourceId,
        index: VodContentIndex.fromRecords(
          m['records'],
          fallbackSourceId: sourceId,
          fallbackSourceName: (m['sourceName'] ?? '').toString(),
          fallbackHeaders: fallbackHeaders,
          fallbackUpdatedAt: savedAt,
        ),
      );
    } catch (_) {
      return (sourceId: '', index: VodContentIndex());
    }
  }

  Map<String, String> _headersFrom(
      Object? raw, Map<String, String> fallback) {
    final headers = <String, String>{};
    if (raw is Map) {
      raw.forEach((k, v) {
        final key = k.toString();
        if (kAllowedPlaybackHeaderNames.contains(key.toLowerCase())) {
          headers[key] = v.toString();
        }
      });
    }
    return headers.isEmpty ? Map<String, String>.of(fallback) : headers;
  }

  /// v1 旧缓存的条目解码（字段少，只用于升级迁移）。
  VodItem? _decodeItem(
      Object? raw, String sourceId, Map<String, String> headers) {
    if (raw is! Map) return null;
    final m = Map<String, dynamic>.from(raw);
    final id = (m['id'] ?? '').toString();
    final title = (m['title'] ?? '').toString();
    if (id.isEmpty || title.isEmpty) return null;
    final eps = m['episodes'];
    if (eps is! List) return null;
    final episodes = <VodEpisode>[];
    for (final x in eps) {
      if (episodes.length >= kMaxThirdPartyEpisodes) break;
      if (x is! List || x.length < 3) continue;
      final number = x[0] is int ? x[0] as int : int.tryParse('${x[0]}');
      final url = '${x[2]}';
      if (number == null || !safeMediaUrl(url)) continue;
      episodes.add(VodEpisode(
        number: number,
        title: '${x[1]}',
        url: url,
      ));
    }
    if (episodes.isEmpty) return null;
    final sectionName = (m['section'] ?? '').toString();
    return VodItem(
      id: id,
      title: title,
      subtitle: (m['subtitle'] ?? '').toString(),
      description: '',
      license: kThirdPartyLicense,
      section: VodSection.values.firstWhere(
        (s) => s.name == sectionName,
        orElse: () => VodSection.other,
      ),
      episodes: List<VodEpisode>.unmodifiable(episodes),
      accentSeed: episodes.length % 8,
      sourceId: sourceId,
      headers: headers,
      posterUrl: (m['poster'] ?? '').toString(),
      typeName: (m['type'] ?? '').toString(),
      genre: (m['genre'] ?? '').toString(),
      area: (m['area'] ?? '').toString(),
      year: (m['year'] ?? '').toString(),
    );
  }
}
