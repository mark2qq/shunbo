/// 配置/持久化抽象（E6）。
///
/// 具体实现将落地到各端持久化机制（SharedPreferences / 文件 / 数据库）。
/// 注意（安全/隐私需求，主计划已登记）：本应用允许导入外部源配置，
/// 该接口是潜在的代码执行面，E6 实现须对导入配置做严格白名单校验与沙箱隔离。
abstract class ConfigStore {
  /// 保存源配置（含用户校准后的源画像）。
  Future<void> saveSourceConfig(Map<String, dynamic> config);

  /// 读取已保存的源配置；无则返回 null。
  Future<Map<String, dynamic>?> loadSourceConfig();

  /// 记录跨端续播进度（规范内容坐标）。
  Future<void> savePlaybackProgress(String mediaId, int episode, double contentSeconds);

  Future<(int, double)?> loadPlaybackProgress(String mediaId);
}
