/// 通道设置与地址表快照的落盘（研发方案 M5：兼容与回滚）。
///
/// 复用 `FileConfigStore.saveState` 的原子写 + 损坏容错，不新建表、不引数据库。
/// 老版本没有这两个键时一律读出「组播关闭 / 自动识别 / 无订阅」的默认值，
/// 也就是纯公网形态——升级不会改变任何既有行为。
library;

import '../../data/file_config_store.dart';
import 'carrier_playlist_importer.dart';
import 'channel_settings.dart';

class ChannelSettingsStore {
  const ChannelSettingsStore(this._store);

  final FileConfigStore _store;

  static const String settingsKey = 'network-channel';
  static const String tableKey = 'network-address-table';

  Future<ChannelSettings> load() async {
    try {
      final raw = await _store.loadState(settingsKey);
      if (raw == null) return const ChannelSettings();
      return ChannelSettings.fromJson(raw);
    } catch (_) {
      return const ChannelSettings();
    }
  }

  Future<void> save(ChannelSettings settings) =>
      _store.saveState(settingsKey, settings.toJson());

  Future<AddressTableSnapshot?> loadTable() async {
    try {
      final raw = await _store.loadState(tableKey);
      if (raw == null) return null;
      return AddressTableSnapshot.fromJson(raw);
    } catch (_) {
      return null;
    }
  }

  Future<void> saveTable(AddressTableSnapshot snapshot) =>
      _store.saveState(tableKey, snapshot.toJson());

  /// 回到上一版地址表；没有上一版时返回 null。
  Future<AddressTableSnapshot?> rollback() async {
    final current = await loadTable();
    if (current == null || !current.hasPrevious) return null;
    final previous = current.rollback();
    await saveTable(previous);
    return previous;
  }
}
