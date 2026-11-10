import 'dart:convert';
import 'dart:io';

import 'config_store.dart';

/// 真实落盘的配置存储（E6）：实现 [ConfigStore]，纯 `dart:io` + JSON，零平台插件。
///
/// 用途：源配置、播放进度，以及**首次配置引导状态**（原为内存态，重启后引导会重复出现）。
/// 与 `FileResumeStore` 同构：原子写、损坏容错、写入失败降级为内存态，
/// 因此三端通用且可在裸 `dart run` 下完整验证。
class FileConfigStore implements ConfigStore {
  final File file;
  final Map<String, Object?> _state = <String, Object?>{};
  bool _loaded = false;
  bool _degraded = false;

  FileConfigStore(this.file);

  factory FileConfigStore.at(String path) => FileConfigStore(File(path));

  /// 是否发生过读/写降级（供 E7 诊断上报）。
  bool get degraded => _degraded;

  Future<void> _ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    try {
      if (!await file.exists()) return;
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) throw const FormatException('配置文件根节点应为对象');
      _state.addAll(Map<String, Object?>.from(decoded));
    } catch (_) {
      _state.clear();
      _degraded = true;
    }
  }

  Future<void> _flush() async {
    final tmp = File('${file.path}.tmp');
    final bak = File('${file.path}.bak');
    try {
      final dir = file.parent;
      if (!await dir.exists()) await dir.create(recursive: true);
      await tmp.writeAsString(jsonEncode(_state));
      if (await bak.exists()) await bak.delete();
      if (await file.exists()) await file.rename(bak.path);
      try {
        await tmp.rename(file.path);
      } catch (_) {
        if (await bak.exists() && !await file.exists()) {
          await bak.rename(file.path);
        }
        rethrow;
      }
      if (await bak.exists()) await bak.delete();
    } catch (_) {
      _degraded = true;
    } finally {
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {
        // 清理失败可忽略
      }
    }
  }

  Future<void> _put(String key, Object? value) async {
    await _ensureLoaded();
    _state[key] = value;
    await _flush();
  }

  Future<Map<String, dynamic>?> _getMap(String key) async {
    await _ensureLoaded();
    final v = _state[key];
    if (v is! Map) return null;
    return Map<String, dynamic>.from(v);
  }

  @override
  Future<void> saveSourceConfig(Map<String, dynamic> config) =>
      _put('sourceConfig', config);

  @override
  Future<Map<String, dynamic>?> loadSourceConfig() => _getMap('sourceConfig');

  @override
  Future<void> savePlaybackProgress(
          String mediaId, int episode, double contentSeconds) =>
      _put('progress:$mediaId', <String, dynamic>{
        'episode': episode,
        'contentSeconds': contentSeconds,
      });

  @override
  Future<(int, double)?> loadPlaybackProgress(String mediaId) async {
    final m = await _getMap('progress:$mediaId');
    if (m == null) return null;
    final ep = m['episode'];
    final sec = m['contentSeconds'];
    if (ep is! int || sec is! num) return null;
    return (ep, sec.toDouble());
  }

  /// 通用命名状态存取（引导流程、UI 偏好等），避免为每个状态扩展抽象接口。
  Future<void> saveState(String key, Map<String, dynamic> state) =>
      _put('state:$key', state);

  Future<Map<String, dynamic>?> loadState(String key) => _getMap('state:$key');
}
