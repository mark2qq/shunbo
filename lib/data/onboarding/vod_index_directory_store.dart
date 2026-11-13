/// 用户提交新接口后生成的「片源索引目录文件」（1.0.5 第十六次修）。
///
/// ## 与默认索引目录的关系
///
/// 默认索引目录是随包的 `assets/vod_index/manifest.json` + 6 个 gzip 分片，
/// 里面是**精简检索索引**（站点 + vod_id + 片名），点开要回源取播放地址。
/// 用户换了一个接口后，那份内置索引的 `vod_id` 就全部指向别的站，不能再用；
/// 于是按新地址取回片源、生成一份新的目录文件落进数据目录。
///
/// **沿用同一套处理规则**（需求里的原话）：
///  * 同一份清单字段：`version` / `sourceUrl` / `generatedAt` / `total` /
///    按栏目分节的 `sections` —— 校验与覆盖策略读的正是这几个；
///  * 同一个「接口地址」一致性判据（[VodIndexSnapshot.matches]）；
///  * 同一套按栏目加载、进入点播时优先复用、不做网络请求的流程；
///  * 同一套写盘纪律：先写 `.tmp` 再原子替换，坏文件按「没有索引」处理。
///
/// 差别只有一处，且是刻意的：新目录的条目来自 [VodSession] 已取回的**可播片源**，
/// 自带 `episodes`，因此点开即播，不需要回源。内置索引是打包时固化的精简数据，
/// 拿不到播放地址，只能点开再回源。两种条目都通过 [VodItem] 交给同一个列表。
///
/// ## 第二十三次修：默认接口也能「立即获取最新片源」
///
/// 上一版把默认接口的追加**整条跳过**（`appendFor` 直接返回 skipped），
/// 设置页点了按钮只得到一句「默认片源索引随包只读，无需更新」—— 用户红标：
/// 「只要立即获取最新片源，这边就要追加方式去获取一遍，不是只读不能获取」。
///
/// 现在的分工：
///  * **独立目录**（用户自己填的接口）→ `vod-index-<hash>.json`，可整份重写，
///    也可追加；
///  * **默认接口** → 随包索引依旧只读、一个字节都不改，新片源写进
///    `vod-index-<hash>.json` 这份**本地增补**文件（[loadSupplementFor]），
///    点播页浏览时并进列表最前面。同一个派生规则，但读的入口分开，
///    所以闸门永远不会把增补文件当成「默认目录被替换了」。
library;

import 'dart:convert';
import 'dart:io';

import '../../features/vod/third_party_vod.dart'
    show kMaxThirdPartyEpisodes, kMaxVodLibraryBytes, safeMediaUrl;
import '../../features/vod/vod_catalog.dart';
import '../../features/vod/vod_index_gate.dart' show VodIndexOrigin, VodIndexSnapshot;

const int kVodIndexDirectoryVersion = 1;
const String kVodIndexDirectoryFormat = 'shunbo-vod-index-directory';

/// 旧版（1.0.5 第十六～二十次修）所有新接口共用这一个文件。第二十一次修起
/// 改成按地址独立存放，这个文件**只读兼容**：升级后仍能被认出来，但不再写入。
const String kLegacyVodIndexFile = 'vod-index.json';

/// 该地址是不是「默认片源索引地址」。
///
/// 默认索引是**随包分发的只读资产**（`assets/vod_index/manifest.json` +
/// 6 个 gzip 分片）。填这个地址必须走「直接复用默认记录、零网络」分支，
/// 既不能为它生成新目录，也不能往任何本地文件里追加 —— 否则默认记录就
/// 被运行期数据改变了，这正是需求里明令禁止的「覆盖或影响默认索引」。
bool isDefaultVodIndexSource(String url, String defaultSourceUrl) {
  final a = url.trim();
  final b = defaultSourceUrl.trim();
  return b.isNotEmpty && a == b;
}

/// 按接口地址派生**独立的目录文件名**。
///
/// 纯函数：FNV-1a 32 位（对 UTF-16 code unit 逐位），相同地址恒得同一文件名，
/// 不同地址几乎不可能撞。不用 URL 原文做文件名是因为里面有 `://`、端口、
/// 查询串，在 Windows / Android 上都不是合法文件名。
/// 空串与默认地址返回 ''（调用方据此拒绝写整份目录）。
/// 默认接口的**增补**文件另走 [vodIndexSupplementFileForUrl] —— 那里不排除
/// 默认地址，否则「立即获取最新片源」无处落盘。
String vodIndexFileForUrl(String raw, {String defaultSourceUrl = ''}) {
  final t = raw.trim();
  if (t.isEmpty || isDefaultVodIndexSource(t, defaultSourceUrl)) return '';
  var hash = 0x811c9dc5;
  for (final unit in t.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return 'vod-index-${hash.toRadixString(16).padLeft(8, '0')}.json';
}

/// 按接口地址派生**本地增补**文件名。
///
/// 与 [vodIndexFileForUrl] 同一套 FNV-1a 命名，唯一差别是**不排除默认地址**：
/// 默认接口的最新片源也得有地方落盘，否则「立即获取最新片源」就成了一句
/// 空话。默认地址只允许走这条增补通道（`saveFor` 仍然拒绝写它的整份目录）。
String vodIndexSupplementFileForUrl(String raw) {
  final t = raw.trim();
  if (t.isEmpty) return '';
  var hash = 0x811c9dc5;
  for (final unit in t.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return 'vod-index-${hash.toRadixString(16).padLeft(8, '0')}.json';
}

/// 追加合并的结果。门禁直接读这三个数，不必起文件 IO。
class VodIndexMergeResult {
  const VodIndexMergeResult({
    required this.items,
    required this.added,
    required this.duplicates,
  });

  /// 合并后的完整列表（旧条目在前，新条目追加在后，顺序稳定）。
  final List<VodItem> items;
  final int added;
  final int duplicates;

  int get total => items.length;
}

/// 追加式合并：**只按 `VodItem.id` 去重**，旧条目一条不删。
///
/// 与 `decodeVodIndexDocument` 的去重口径完全一致（那里也是 `seen.add(item.id)`），
/// 这样「写盘前合并」与「读盘后兜底」得到的是同一份列表，不会出现
/// 「写进去 100 条、读回来 98 条」的错位。
VodIndexMergeResult mergeVodIndexItems(
  Iterable<VodItem> existing,
  Iterable<VodItem> incoming,
) {
  final out = <VodItem>[];
  final seen = <String>{};
  for (final item in existing) {
    if (item.id.isEmpty || !seen.add(item.id)) continue;
    out.add(item);
  }
  var added = 0;
  var duplicates = 0;
  for (final item in incoming) {
    if (item.id.isEmpty || !seen.add(item.id)) {
      duplicates++;
      continue;
    }
    out.add(item);
    added++;
  }
  return VodIndexMergeResult(
    items: List<VodItem>.unmodifiable(out),
    added: added,
    duplicates: duplicates,
  );
}

/// 一次追加写盘的结论。
class VodIndexAppendResult {
  const VodIndexAppendResult({
    required this.ok,
    required this.added,
    required this.duplicates,
    required this.total,
    this.message = '',
  });

  final bool ok;
  final int added;
  final int duplicates;
  final int total;
  final String message;

  factory VodIndexAppendResult.skipped(String message) =>
      VodIndexAppendResult(
          ok: true, added: 0, duplicates: 0, total: 0, message: message);
}

/// 一份目录的完整内容。
class VodIndexDocument {
  const VodIndexDocument({
    required this.sourceUrl,
    required this.generatedAt,
    required this.items,
  });

  final String sourceUrl;
  final DateTime generatedAt;

  /// 可播条目（已按栏目归好类，解码时统一走 `normalizeVodItem`）。
  final List<VodItem> items;

  int get total => items.length;

  /// 按栏目键 → 条数。**键与内置 manifest 的 `sections[].key` 同名**，
  /// 这样同一套「按栏目加载」代码对两份目录都成立。
  Map<String, int> get sections {
    final out = <String, int>{};
    for (final i in items) {
      final key = i.section.name;
      out[key] = (out[key] ?? 0) + 1;
    }
    return out;
  }

  List<VodItem> inSection(VodSection section) =>
      <VodItem>[for (final i in items) if (i.section == section) i];

  VodIndexSnapshot get snapshot => VodIndexSnapshot(
        origin: VodIndexOrigin.generated,
        sourceUrl: sourceUrl,
        total: total,
        generatedAt: generatedAt,
      );
}

/// 纯函数：编码成清单 JSON 的结构（门禁可直接断言字段，不必写盘）。
Map<String, dynamic> encodeVodIndexDocument(VodIndexDocument doc) {
  return <String, dynamic>{
    'format': kVodIndexDirectoryFormat,
    'version': kVodIndexDirectoryVersion,
    'sourceUrl': doc.sourceUrl,
    'generatedAt': doc.generatedAt.toUtc().toIso8601String(),
    'total': doc.total,
    'sections': <Map<String, dynamic>>[
      for (final entry in doc.sections.entries)
        <String, dynamic>{
          'key': entry.key,
          'label': _sectionLabel(entry.key),
          'records': entry.value,
        },
    ],
    'items': <Map<String, dynamic>>[
      for (final i in doc.items) _encodeItem(i),
    ],
  };
}

/// 纯函数：解码。格式不对 / 版本不符 / 没有可播条目一律返回 null，
/// 让校验状态机落到「索引片源缺失」，而不是拿着半份数据硬进播放列表。
VodIndexDocument? decodeVodIndexDocument(Object? raw) {
  if (raw is! Map) return null;
  final m = Map<String, dynamic>.from(raw);
  if (m['format'] != kVodIndexDirectoryFormat) return null;
  if (m['version'] != kVodIndexDirectoryVersion) return null;
  final sourceUrl = (m['sourceUrl'] ?? '').toString().trim();
  if (sourceUrl.isEmpty) return null;
  final generatedAt = DateTime.tryParse((m['generatedAt'] ?? '').toString());
  if (generatedAt == null) return null;
  final rawItems = m['items'];
  if (rawItems is! List) return null;
  final items = <VodItem>[];
  final seen = <String>{};
  for (final r in rawItems) {
    final item = _decodeItem(r);
    if (item == null) continue;
    if (!seen.add(item.id)) continue; // 同一部片只留一张卡
    items.add(normalizeVodItem(item));
  }
  if (items.isEmpty) return null;
  return VodIndexDocument(
    sourceUrl: sourceUrl,
    generatedAt: generatedAt.toUtc(),
    items: List<VodItem>.unmodifiable(items),
  );
}

Map<String, dynamic> _encodeItem(VodItem i) => <String, dynamic>{
      'id': i.id,
      'title': i.title,
      'subtitle': i.subtitle,
      'description': i.description,
      'license': i.license,
      'section': i.section.name,
      'sourceId': i.sourceId,
      'poster': i.posterUrl,
      'type': i.typeName,
      'area': i.area,
      'year': i.year,
      'genre': i.genre,
      'accentSeed': i.accentSeed,
      if (i.headers.isNotEmpty) 'headers': i.headers,
      'episodes': <List<Object>>[
        for (final e in i.episodes)
          <Object>[e.number, e.title, e.url],
      ],
    };

VodItem? _decodeItem(Object? raw) {
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
    episodes.add(VodEpisode(number: number, title: '${x[1]}', url: url));
  }
  // 没有可播地址的条目不该进目录：用户点开会得到一张点不开的卡片。
  if (episodes.isEmpty) return null;
  final sectionName = (m['section'] ?? '').toString();
  final headers = <String, String>{};
  final h = m['headers'];
  if (h is Map) {
    h.forEach((k, v) => headers['$k'] = '$v');
  }
  return VodItem(
    id: id,
    title: title,
    subtitle: (m['subtitle'] ?? '').toString(),
    description: (m['description'] ?? '').toString(),
    license: (m['license'] ?? '').toString(),
    section: VodSection.values.firstWhere(
      (s) => s.name == sectionName,
      orElse: () => VodSection.other,
    ),
    episodes: List<VodEpisode>.unmodifiable(episodes),
    accentSeed: m['accentSeed'] is int ? m['accentSeed'] as int : 0,
    sourceId: (m['sourceId'] ?? '').toString(),
    posterUrl: (m['poster'] ?? '').toString(),
    typeName: (m['type'] ?? '').toString(),
    area: (m['area'] ?? '').toString(),
    year: (m['year'] ?? '').toString(),
    genre: (m['genre'] ?? '').toString(),
    headers: Map<String, String>.unmodifiable(headers),
  );
}

String _sectionLabel(String key) {
  for (final s in VodSection.values) {
    if (s.name == key) return s.label;
  }
  return key;
}

/// 落盘层。**体积护栏与 `vod-library.json` 同口径**：畸形大文件不解析，
/// 避免用户手工改坏文件后冷启动 OOM。
///
/// ## 第二十一次修：按接口地址独立存放
///
/// 之前所有新接口共用 [file]（`vod-index.json`）：用户换一次地址就把上一份
/// 目录覆盖掉，切回去只能全量重抓。现在每个地址一份
/// `vod-index-<hash>.json`，互不覆盖；**默认片源索引地址不生成「整份目录」**，
/// 它对应的是随包只读资产，地址一致时由闸门直接复用（零网络）。
/// 默认地址只允许写**增补**（[appendFor] → [loadSupplementFor]）：最新片源
/// 单独存一份，随包索引一个字节不动（第二十三次修，用户要求「点了按钮就
/// 真的去取一遍」）。
/// 旧单文件保留为「只读兼容」：仅当它记录的 sourceUrl 与当前地址逐字一致
/// 时才会被读到，追加写盘一律写进新地址自己的派生文件。
class VodIndexDirectoryStore {
  VodIndexDirectoryStore(this.file, {this.defaultSourceUrl = ''});

  static VodIndexDirectoryStore at(String path, {String defaultSourceUrl = ''}) =>
      VodIndexDirectoryStore(File(path), defaultSourceUrl: defaultSourceUrl);

  /// 旧版共用的那个文件（`AppPaths.vodIndexFile`）。
  final File file;

  /// 随包默认索引记录的接口地址（manifest 的 `sourceUrl`）。
  /// 为空表示「未注入」，此时所有地址都按独立文件处理（门禁构造用）。
  final String defaultSourceUrl;

  /// 该地址是否允许生成 / 追加本地目录文件。
  bool isIndependentSource(String url) =>
      url.trim().isNotEmpty &&
      vodIndexFileForUrl(url, defaultSourceUrl: defaultSourceUrl).isNotEmpty;

  /// 该地址专属的文件；默认地址 / 空地址返回 null。
  File? fileFor(String url) {
    final name = vodIndexFileForUrl(url, defaultSourceUrl: defaultSourceUrl);
    if (name.isEmpty) return null;
    return File('${file.parent.path}${Platform.pathSeparator}$name');
  }

  /// 该地址的**本地增补**文件。默认接口也有 —— 那是它唯一能落盘的地方。
  File? supplementFileFor(String url) {
    final name = vodIndexSupplementFileForUrl(url);
    if (name.isEmpty) return null;
    return File('${file.parent.path}${Platform.pathSeparator}$name');
  }

  /// 读默认接口的本地增补目录（非默认地址返回 null）。
  ///
  /// 只给「随包索引 + 本地新增」的合并浏览用。非默认地址不需要它：
  /// 它自己的目录文件已经是全量（追加也写在那份里）。
  Future<VodIndexDocument?> loadSupplementFor(String url) async {
    if (!isDefaultVodIndexSource(url, defaultSourceUrl)) return null;
    final f = supplementFileFor(url);
    if (f == null) return null;
    return _readFrom(f, url);
  }

  /// [url] 为 null 表示「不校验记录的接口地址」（老的单文件入口用）。
  /// 非 null 时必须逐字对上：文件可能被外部改过 / 是别的地址留下的，
  /// 否则宁可当作「没有目录」，绝不能把 A 接口的 id 当 B 接口的片源。
  Future<VodIndexDocument?> _readFrom(File f, String? url) async {
    try {
      if (!await f.exists()) return null;
      final size = await f.length();
      if (size <= 0 || size > kMaxVodLibraryBytes) return null;
      final decoded = jsonDecode(await f.readAsString());
      final doc = decodeVodIndexDocument(decoded);
      if (doc == null) return null;
      if (url != null && doc.sourceUrl.trim() != url.trim()) return null;
      return doc;
    } catch (_) {
      return null;
    }
  }

  /// 兼容入口：只读 [file] 本身，不校验地址（老调用方与门禁用）。
  Future<VodIndexDocument?> load() => _readFrom(file, null);

  /// 按地址读：先看自己的独立文件，再退回旧单文件（只读兼容）。
  Future<VodIndexDocument?> loadFor(String url) async {
    if (!isIndependentSource(url)) return null;
    final own = fileFor(url);
    if (own == null) return null;
    final fromOwn = await _readFrom(own, url);
    if (fromOwn != null) return fromOwn;
    final legacy = await _readFrom(file, url);
    return legacy;
  }

  /// 只取清单摘要（校验用），不把整份条目解出来。
  Future<VodIndexSnapshot?> snapshot() async => (await load())?.snapshot;

  /// 按地址取清单摘要。`readGenerated` 注入点用这个，保证闸门读到的
  /// **一定是当前设定地址对应的那份目录**，而不是上一任接口留下的文件。
  Future<VodIndexSnapshot?> snapshotFor(String url) async =>
      (await loadFor(url))?.snapshot;

  Future<void> _writeTo(File target, VodIndexDocument doc) async {
    if (doc.items.isEmpty) return;
    final payload = jsonEncode(encodeVodIndexDocument(doc));
    // 写入侧也设体积护栏：只追加不去重以外的裁剪，目录无限膨胀会把
    // 冷启动的 load() 直接打成 OOM（读侧虽会拒，但文件已经写坏了）。
    if (utf8.encode(payload).length > kMaxVodLibraryBytes) {
      throw StateError('片源索引目录超过 ${kMaxVodLibraryBytes ~/ 1024 ~/ 1024} MB 上限');
    }
    final tmp = File('${target.path}.tmp');
    try {
      final dir = target.parent;
      if (!await dir.exists()) await dir.create(recursive: true);
      await tmp.writeAsString(payload, flush: true);
      if (await target.exists()) await target.delete();
      await tmp.rename(target.path);
    } catch (_) {
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}
      rethrow;
    }
  }

  /// 兼容入口：写旧单文件。默认地址一律拒绝，避免运行期数据影响默认记录。
  Future<void> save(VodIndexDocument doc) async {
    if (isDefaultVodIndexSource(doc.sourceUrl, defaultSourceUrl)) {
      throw StateError('默认片源索引是随包只读资产，不允许写本地目录');
    }
    await _writeTo(file, doc);
  }

  /// 按地址写一份**全新**目录（初次接入时由闸门的 rebuild 调用）。
  Future<void> saveFor(String url, VodIndexDocument doc) async {
    final target = fileFor(url);
    if (target == null) {
      throw StateError('默认片源索引地址不生成独立目录，直接复用默认记录');
    }
    if (doc.sourceUrl.trim() != url.trim()) {
      throw ArgumentError('目录记录的接口地址与写入地址不一致');
    }
    await _writeTo(target, doc);
  }

  /// 追加合并：取回的最新一批片源**只加不删**，与已有目录按 id 去重后
  /// 原子写回该地址自己的文件。
  ///
  /// 默认接口写的是**本地增补**文件（[loadSupplementFor] 读的那份）：
  /// 随包索引一个字节都不动，新片源单独存、浏览时并进列表前面。
  /// 第二十三次修之前这里直接跳过，界面上就是「点了没反应」。
  Future<VodIndexAppendResult> appendFor(
    String url,
    Iterable<VodItem> incoming, {
    DateTime? now,
  }) async {
    final target = fileFor(url) ?? supplementFileFor(url);
    if (target == null) {
      return VodIndexAppendResult.skipped('接口地址为空，不参与追加更新');
    }
    // 已有内容：先读该地址自己的文件；默认接口读的是增补文件本身。
    // 独立目录还要兼容 1.0.5 早期那个共用文件（只读，地址逐字一致才算）。
    var existing = await _readFrom(target, url);
    if (existing == null && isIndependentSource(url)) {
      existing = await _readFrom(file, url);
    }
    final merged = mergeVodIndexItems(
        existing?.items ?? const <VodItem>[], incoming);
    if (merged.items.isEmpty) {
      return VodIndexAppendResult.skipped('没有可写入的片源');
    }
    final doc = VodIndexDocument(
      sourceUrl: url.trim(),
      generatedAt: (now ?? DateTime.now()).toUtc(),
      items: merged.items,
    );
    try {
      await _writeTo(target, doc);
    } catch (e) {
      return VodIndexAppendResult(
        ok: false,
        added: 0,
        duplicates: merged.duplicates,
        total: merged.total,
        message: '写盘失败：$e',
      );
    }
    return VodIndexAppendResult(
      ok: true,
      added: merged.added,
      duplicates: merged.duplicates,
      total: merged.total,
      message: '新增 ${merged.added} 条，重复 ${merged.duplicates} 条，'
          '目录共 ${merged.total} 条',
    );
  }

  Future<void> clear() async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }
}
