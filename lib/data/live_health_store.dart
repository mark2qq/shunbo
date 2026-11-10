import 'dart:io';

/// 线路健康度落盘（`live-health.json`）。
///
/// 只做两件事：读回上次的健康度、原子写回新的。**不做任何解析判断**——
/// 结构解析在 [StreamHealthBoard.loadEncoded] 里，这样 UI 层/回归都能复用，
/// 不必为了测「坏文件不崩」去碰文件系统。
///
/// 为什么这里可以失败：健康度只是「选源更快」的优化项，
/// 读不到就用默认分（所有线路等价），写不进就只在内存里生效。
/// 它**绝不允许**影响开播——所以所有异常都被吞掉并记在 [degraded] 上。
class LiveHealthStore {
  LiveHealthStore(this.file);

  factory LiveHealthStore.at(String path) => LiveHealthStore(File(path));

  final File file;

  /// 是否发生过读写降级（供诊断使用）。
  bool degraded = false;

  /// 读取上次保存的健康度文本；没有文件或读取失败返回 null。
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
  /// 为什么不用「直接覆盖」：健康度文件很小，但写入时机可能是「播到一半换线」，
  /// 这时如果进程被杀，直接覆盖会留下半个 JSON，下次启动整份记录作废。
  /// 原子替换至少保证「要么是新的，要么是上一份完整的」。
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
      // 清理半成品，避免下次启动读到截断内容。
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {
        // 清理失败也不影响播放。
      }
    }
  }
}
