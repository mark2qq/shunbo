import 'dart:io';

import '../app/form_factor.dart';

/// 形态偏好落盘（R1「判定结果需持久化」）。
///
/// 存的是**用户偏好**（auto / phone / tv），不是判定结果本身：
/// 判定结果的输入是「当前设备的输入能力」，设备接了口红盘、换了 HDMI 口
/// 都可能变化；把上一次的结论直接当缓存复用，就会出现「上次接键盘所以这次
/// 还当电视」的错判。持久化偏好才能既稳定又可纠正。
///
/// 与 `LiveRegionStore` 同一套策略：单行文本、原子写、读坏即降级为 auto。
/// 这个文件丢了最坏是回到自动判定，绝不该影响启动。
class FormFactorStore {
  FormFactorStore(this.file);

  factory FormFactorStore.at(String path) => FormFactorStore(File(path));

  /// 单行文本上限：外部文件可被手工改坏，读回时也要设上界。
  static const int maxBytes = 32;

  final File file;

  /// 是否发生过读写降级（供诊断使用）。
  bool degraded = false;

  Future<FormFactorPreference> load() async {
    try {
      if (!await file.exists()) return FormFactorPreference.auto;
      final text = (await file.readAsString()).trim();
      if (text.isEmpty || text.length > maxBytes) return FormFactorPreference.auto;
      return FormFactorPreference.fromKey(text);
    } catch (_) {
      degraded = true;
      return FormFactorPreference.auto;
    }
  }

  /// 原子写：`.tmp` → 旧文件转 `.bak` → `.tmp` 转正 → 删 `.bak`。
  Future<void> save(FormFactorPreference pref) async {
    final tmp = File('${file.path}.tmp');
    final bak = File('${file.path}.bak');
    try {
      await file.parent.create(recursive: true);
      await tmp.writeAsString(pref.key, flush: true);
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
        // 清理失败不影响启动。
      }
    }
  }
}
