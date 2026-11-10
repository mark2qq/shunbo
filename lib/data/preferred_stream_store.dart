import 'dart:io';

import '../features/live/preferred_stream.dart';

/// 每频道优选线路落盘（`live-preferred.json`）。
///
/// 与 [LiveHealthStore] 同策略：只做读回 / 原子写，不做任何解析判断
/// （结构解析在 [PreferredStreamBoard.loadEncoded]），所有异常被吞掉并记在
/// [degraded] 上。缓存只是「切换更快」的加速项，读不到就用默认（无偏好），
/// 写不进就只在内存里生效——它**绝不允许**影响开播。
class PreferredStreamStore {
  PreferredStreamStore(this.file);

  factory PreferredStreamStore.at(String path) => PreferredStreamStore(File(path));

  final File file;

  /// 是否发生过读写降级（供诊断使用）。
  bool degraded = false;

  /// 读取上次保存的偏好文本；没有文件或读取失败返回 null。
  Future<String?> load() async {
    try {
      if (!await file.exists()) return null;
      final text = await file.readAsString();
      return text.trim().isEmpty ? null : text;
    } catch (_) {
      degraded = true;
      return null;
    }
  }

  /// 原子写：`.tmp` → 旧文件转 `.bak` → `.tmp` 转正 → 删 `.bak`。
  ///
  /// 写入时机可能是「播到一半换线」，这时进程被杀直接覆盖会留下半个 JSON，
  /// 下次启动整份偏好作废。原子替换保证「要么是新的，要么是上一份完整的」。
  Future<void> save(String json) async {
    final tmp = File('${file.path}.tmp');
    final bak = File('${file.path}.bak');
    try {
      await file.parent.create(recursive: true);
      await tmp.writeAsString(json, flush: true);
      if (await file.exists()) {
        if (await bak.exists()) await bak.delete();
        await file.rename(bak.path);
      }
      await tmp.rename(file.path);
      if (await bak.exists()) await bak.delete();
    } catch (_) {
      degraded = true;
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {
        // 清理失败也不影响播放。
      }
    }
  }
}
