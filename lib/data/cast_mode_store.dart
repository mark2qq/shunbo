import 'dart:convert';
import 'dart:io';

import '../core/cast/cast_mode.dart';

/// 「该源该用直推还是串流」的持久化记忆（`cast-mode.json`）。
///
/// R12b 要求「并记住该源，下次直接走串流」。这份记忆必须在**重启后仍有效**：
/// 只放内存的话，用户每次开应用投同一个源都要再等 5 秒才自动改串流，
/// 等于这条要求没落地。
///
/// 存储选择 JSON 而不是纯文本：需要同时保存「键 → 模式」的映射；
/// 但仍然沿用项目里所有落盘文件的同一套纪律：
/// * **原子写**：`.tmp` → 旧文件转 `.bak` → `.tmp` 转正 → 删 `.bak`；
/// * **读失败即降级**：文件被改坏 / 权限不足 / 不是合法 JSON，一律当「没有记忆」，
///   绝不让一个偏好文件把投屏拦住（丢了最多多等 5 秒）；
/// * **有界**：条目数与键长都设上限。这文件躺在用户目录里，可以被任意写大，
///   无界解析会在启动时吃掉内存。
class CastModeStore {
  CastModeStore(this.file);

  factory CastModeStore.at(String path) => CastModeStore(File(path));

  final File file;

  /// 最多记住多少个源站。超出后按「最近写入的留下」裁掉最旧的 ——
  /// 普通用户一辈子也到不了这个量级，设上限是为了防被写坏的文件。
  static const int maxEntries = 200;

  /// 单个键的最大长度（`sourceId|host`，正常远小于此）。
  static const int maxKeyLength = 200;

  /// 文件体积上限：200 条 × 约 220 字节，留一倍余量。
  static const int maxBytes = 96 * 1024;

  /// 是否发生过读写降级（供诊断展示，不影响投屏）。
  bool degraded = false;

  /// 读回全部记忆。任何异常都返回空表。
  Future<Map<String, CastMode>> load() async {
    try {
      if (!await file.exists()) return <String, CastMode>{};
      final stat = await file.stat();
      if (stat.size <= 0 || stat.size > maxBytes) {
        degraded = true;
        return <String, CastMode>{};
      }
      final text = await file.readAsString();
      if (text.trim().isEmpty) return <String, CastMode>{};
      final decoded = jsonDecode(text);
      if (decoded is! Map) {
        degraded = true;
        return <String, CastMode>{};
      }
      final out = <String, CastMode>{};
      for (final entry in decoded.entries) {
        final k = entry.key;
        final v = entry.value;
        if (k is! String || k.isEmpty || k.length > maxKeyLength) continue;
        // 只认白名单值：文件可被手工编辑成任意字符串。
        if (v == 'relay') {
          out[k] = CastMode.relay;
        } else if (v == 'direct') {
          out[k] = CastMode.direct;
        }
      }
      if (out.length > maxEntries) {
        degraded = true;
        return <String, CastMode>{};
      }
      return out;
    } catch (_) {
      degraded = true;
      return <String, CastMode>{};
    }
  }

  /// 写入一条记忆（整体重写，条目上限内裁剪）。
  Future<bool> put(String key, CastMode mode) async {
    if (key.isEmpty || key.length > maxKeyLength) return false;
    try {
      final current = await load();
      // 重新插入保证「最近写入的排在后面」，裁剪时先丢最早的。
      current.remove(key);
      current[key] = mode;
      final trimmed = current.length > maxEntries
          ? Map<String, CastMode>.fromEntries(
              current.entries.skip(current.length - maxEntries))
          : current;
      return await _write(trimmed);
    } catch (_) {
      degraded = true;
      return false;
    }
  }

  Future<bool> _write(Map<String, CastMode> data) async {
    final tmp = File('${file.path}.tmp');
    final bak = File('${file.path}.bak');
    try {
      await file.parent.create(recursive: true);
      final payload = jsonEncode(<String, String>{
        for (final e in data.entries) e.key: e.value.name,
      });
      await tmp.writeAsString(payload, flush: true);
      if (await file.exists()) {
        if (await bak.exists()) await bak.delete();
        await file.rename(bak.path);
      }
      await tmp.rename(file.path);
      if (await bak.exists()) await bak.delete();
      return true;
    } catch (_) {
      degraded = true;
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {
        // 清理失败不影响投屏。
      }
      return false;
    }
  }
}
