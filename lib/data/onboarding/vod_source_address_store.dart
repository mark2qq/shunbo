/// G1 点播源地址设置的落盘（1.0.5）。
///
/// 复用 `FileConfigStore.saveState/loadState` 的原子写与损坏容错，不新建表、
/// 不引数据库。老版本没有这个键时一律读出「关闭 + 内置片库」的默认值，
/// 因此从 1.0.4 覆盖升级后播放行为不变。
library;

import '../file_config_store.dart';
import 'vod_source_address.dart';

class VodSourceAddressStore {
  const VodSourceAddressStore(this._store);

  final FileConfigStore _store;

  static const String stateKey = 'vod-source-address';

  Future<VodSourceAddressSettings> load() async {
    try {
      final raw = await _store.loadState(stateKey);
      if (raw == null) return VodSourceAddressSettings.defaults;
      return VodSourceAddressSettings.fromJson(raw);
    } catch (_) {
      return VodSourceAddressSettings.defaults;
    }
  }

  Future<void> save(VodSourceAddressSettings settings) =>
      _store.saveState(stateKey, settings.toJson());

  /// 是否已经**显式设定过**可用的片源接口（1.0.5 第十六次修）。
  ///
  /// 「从未保存过」与「保存过但选的是内置片库（空地址）」都返回 false ——
  /// 后者同样属于需求里的「接口未设定」，初次使用必须弹输入页。
  /// 判据走一遍 [VodSourceAddressSettings.fromJson]：落盘内容可能被外部改过，
  /// 或明文 http 因未放行而被打回内置片库，直接读原始 selectedUrl 会误判。
  Future<bool> isConfigured() async {
    try {
      final raw = await _store.loadState(stateKey);
      if (raw == null) return false;
      return !VodSourceAddressSettings.fromJson(raw).usesBuiltIn;
    } catch (_) {
      return false;
    }
  }

  /// 回到 1.0.4 的等价状态：关闭外部地址、清空选中项。
  Future<void> reset() => save(VodSourceAddressSettings.defaults);
}
