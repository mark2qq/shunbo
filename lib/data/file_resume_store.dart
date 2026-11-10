import 'dart:convert';
import 'dart:io';

import 'resume_record.dart';
import 'resume_store.dart';

/// 真实落盘的续播存储（E6）：JSON 文件 + 原子替换 + 损坏容错，零外部依赖。
///
/// 只用 `dart:io`，因此三端（Android / 桌面 / TV）通用，且可在纯 `dart run`
/// 下完整验证，无需 shared_preferences / sqlite 等平台插件。
///
/// 关键性质：
/// - **原子写**：先写 `.tmp` → 旧文件转 `.bak` → `.tmp` 转正 → 删 `.bak`；
///   失败可回滚，避免写入中途崩溃导致续播数据整体损坏。
/// - **损坏容错**：文件缺失/JSON 损坏/字段不兼容时降级为空记录集，
///   绝不因读盘失败阻断播放；[degraded] 供诊断层上报。
/// - **写入失败降级**：沙盒只读或权限不足时退化为进程内存态，播放不中断。
class FileResumeStore implements ResumeStore {
  final File file;
  final Map<String, ResumeRecord> _cache = {};
  bool _loaded = false;
  bool _degraded = false;

  FileResumeStore(this.file);

  factory FileResumeStore.at(String path) => FileResumeStore(File(path));

  /// 是否发生过读/写降级（供 E7 诊断与埋点）。
  bool get degraded => _degraded;

  Future<void> _ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    try {
      if (!await file.exists()) return;
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! List) throw const FormatException('续播文件根节点应为数组');
      for (final item in decoded) {
        if (item is! Map) continue;
        final r = ResumeRecord.fromJson(Map<String, dynamic>.from(item));
        _cache[r.mediaId] = r;
      }
    } catch (_) {
      // 损坏或版本不兼容：宁可丢进度，也不能让续播功能整体不可用。
      _cache.clear();
      _degraded = true;
    }
  }

  Future<void> _flush() async {
    final tmp = File('${file.path}.tmp');
    final bak = File('${file.path}.bak');
    try {
      final dir = file.parent;
      if (!await dir.exists()) await dir.create(recursive: true);
      final sorted = _cache.values.toList()
        ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      await tmp.writeAsString(
        jsonEncode(sorted.map((r) => r.toJson()).toList()),
      );
      if (await bak.exists()) await bak.delete();
      if (await file.exists()) await file.rename(bak.path);
      try {
        await tmp.rename(file.path);
      } catch (_) {
        // 转正失败：回滚旧文件，保证至少不丢原有进度。
        if (await bak.exists() && !await file.exists()) {
          await bak.rename(file.path);
        }
        rethrow;
      }
      if (await bak.exists()) await bak.delete();
    } catch (_) {
      _degraded = true; // 降级为内存态，播放链路不受影响
    } finally {
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {
        // 临时文件清理失败可忽略，不影响续播读取
      }
    }
  }

  @override
  Future<void> save(ResumeRecord r) async {
    await _ensureLoaded();
    _cache[r.mediaId] = r;
    await _flush();
  }

  @override
  Future<ResumeRecord?> load(String mediaId) async {
    await _ensureLoaded();
    return _cache[mediaId];
  }

  @override
  Future<List<ResumeRecord>> all() async {
    await _ensureLoaded();
    final list = _cache.values.toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return List.unmodifiable(list);
  }

  @override
  Future<void> remove(String mediaId) async {
    await _ensureLoaded();
    _cache.remove(mediaId);
    await _flush();
  }
}
