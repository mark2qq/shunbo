import '../source/source_profile.dart';

/// 源注册表：管理所有可用源的元信息（E2 源适配将在此登记具体适配器）。
///
/// 换源决策的唯一权威是业务能力层（R1）；本目录下的 [switchSource] 与注册表
/// 共同构成「换源调度」核心，任何其他层不得自行决定切换目标。
class SourceCatalog {
  final Map<String, SourceProfile> _profiles = {};

  void register(SourceProfile p) => _profiles[p.name] = p;

  void unregister(String name) => _profiles.remove(name);

  SourceProfile? get(String name) => _profiles[name];

  List<String> get names => _profiles.keys.toList();

  bool contains(String name) => _profiles.containsKey(name);
}
