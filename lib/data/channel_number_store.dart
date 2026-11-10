import 'dart:convert';
import 'dart:io';

import '../features/live/channel_numbering.dart';

/// 频道数字编号落盘（`channel-numbers.json`）。
///
/// 为什么必须落盘：编号要在「频道表每次刷新后」保持不变。
/// 公开索引每次返回的台集合都不一样（镜像增减、线路更新），
/// 只靠内存里的「按顺序分配」会让老台的号码随刷新漂移——
/// 用户记住了「218 是江苏卫视」，刷新后 218 变成别的台，就再也不敢用数字键了。
///
/// 落盘内容是「归一化台名 → 编号」，与频道 id 无关：
/// 同一个台在不同索引里的 id 可能变化（分组策略调整会改 id），
/// 但台名稳定，用台名做键才不会因为一次升级就把老号码全丢掉。
///
/// 写盘失败**不影响播放**：号码在内存里已经定了，丢的只是「跨会话的稳定性」。
class FileChannelNumberStore implements ChannelNumberStore {
  FileChannelNumberStore(this.file);

  factory FileChannelNumberStore.at(String path) =>
      FileChannelNumberStore(File(path));

  final File file;

  /// 是否发生过读写降级（供诊断使用）。
  bool degraded = false;

  /// 单文件大小上限：这是我们自己写的小 JSON，超大即视为损坏。
  static const int maxBytes = 512 * 1024;

  @override
  Map<String, int> load() {
    try {
      if (!file.existsSync()) return <String, int>{};
      final bytes = file.lengthSync();
      if (bytes <= 0 || bytes > maxBytes) return <String, int>{};
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! Map) return <String, int>{};
      final out = <String, int>{};
      decoded.forEach((k, v) {
        if (k is! String || v is! int) return;
        if (v <= 0 || v >= 100000) return;
        out[k] = v;
      });
      return out;
    } catch (_) {
      degraded = true;
      return <String, int>{};
    }
  }

  @override
  Future<void> save(Map<String, int> map) async {
    final tmp = File('${file.path}.tmp');
    final bak = File('${file.path}.bak');
    try {
      await file.parent.create(recursive: true);
      await tmp.writeAsString(jsonEncode(map), flush: true);
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
