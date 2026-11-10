import 'source_adapter.dart';

/// 源适配器注册表（E2）。
///
/// 与 [SourceCatalog]（profile 注册表，调度层换源决策权威）协同：
/// 注册 adapter 时其 [SourceAdapter.profile] 应同步登记到 [SourceCatalog]。
///
/// 关键职责：按 [SourcePlatform] 裁剪可注册源，规避原评估指出的
/// 「桌面/TV 端列出 Android 专属 jar 源」的体验陷阱。
class SourceRegistry {
  final Map<String, SourceAdapter> _adapters = {};

  void register(SourceAdapter a) => _adapters[a.id] = a;

  void unregister(String id) => _adapters.remove(id);

  SourceAdapter? get(String id) => _adapters[id];

  List<String> get ids => _adapters.keys.toList();

  /// 返回当前平台可用的适配器（[SourceAdapter.supportedPlatforms] 含 [platform]）。
  List<SourceAdapter> availableOn(SourcePlatform platform) =>
      _adapters.values.where((a) => a.supportedPlatforms.contains(platform)).toList();
}
