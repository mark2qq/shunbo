/// 信任库的落盘适配：复用 `FileConfigStore.saveState` 的原子写与损坏容错。
///
/// 不新建表、不引数据库。老版本没有 `source-trust` 这个键时读出空库，
/// 也就是所有来源都回到「首次使用需确认」——升级不会静默授予任何信任。
library;

import '../file_config_store.dart';

class SourceTrustFileStore {
  const SourceTrustFileStore(this._store);

  static const String stateKey = 'source-trust';

  final FileConfigStore _store;

  Future<Map<String, dynamic>?> load() async {
    try {
      return await _store.loadState(stateKey);
    } catch (_) {
      return null;
    }
  }

  Future<void> save(Map<String, dynamic> json) =>
      _store.saveState(stateKey, json);
}
