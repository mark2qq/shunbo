import 'dart:io';

import '../features/live/live_region.dart';

/// 用户选择的「地方频道城市」偏好落盘（`live-region.txt`）。
///
/// 只存一个城市名，不做 JSON：少一层解析就少一处「坏文件拖累首屏」的可能。
/// 与健康度落盘同样采用「失败即降级」策略——这个偏好丢了最多是回到
/// 「全部城市」，绝不该影响开播。
class LiveRegionStore {
  LiveRegionStore(this.file);

  factory LiveRegionStore.at(String path) => LiveRegionStore(File(path));

  /// 允许写入的最大长度（外部文件可能被改坏，读回时也要校验）。
  static const int maxCityLength = 32;

  final File file;

  /// 是否发生过读写降级（供诊断使用）。
  bool degraded = false;

  /// 读回上次的选择；文件缺失 / 损坏 / 内容不是合法城市都返回 null。
  ///
  /// 校验 [CityDirectory.isValidSelection] 很重要：这个文件躺在用户目录里，
  /// 可能被手工编辑成任意字符串，直接拿去当 UI 标题或比较键会带进脏数据。
  Future<String?> load() async {
    try {
      if (!await file.exists()) return null;
      final text = (await file.readAsString()).trim();
      if (text.isEmpty || text.length > maxCityLength) return null;
      return CityDirectory.isValidSelection(text) ? text : null;
    } catch (_) {
      degraded = true;
      return null;
    }
  }

  /// 原子写：`.tmp` → 旧文件转 `.bak` → `.tmp` 转正 → 删 `.bak`。
  Future<void> save(String city) async {
    if (!CityDirectory.isValidSelection(city) || city.length > maxCityLength) {
      return;
    }
    final tmp = File('${file.path}.tmp');
    final bak = File('${file.path}.bak');
    try {
      await file.parent.create(recursive: true);
      await tmp.writeAsString(city, flush: true);
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
