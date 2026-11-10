/// 每频道「上次顺畅播放」的线路缓存（纯 Dart，无 Flutter 依赖）。
///
/// 解决的问题（对应「按频道记住上次的流畅线路，下次直接选用」）：
/// * 直播换台慢的根因是「每条线路都要先探测 4 秒、再挨个试」；
/// * 用户反复看的台（CCTV-1、本地台…）其实上次就播得很顺，这个事实如果
///   **跨会话保留**，下次切回去直接选那条线路、跳过探测，延迟从「黑屏几秒」
///   降到「几乎无缝」；
/// * 与 [StreamHealthBoard] 的区别：健康度是「所有线路的相对快慢」用于排序，
///   这里是「这个频道的最优线路是谁」用于**直达**——两条信息互补，不重复。
///
/// 只做纯数据与编解码，不碰文件系统，方便 `dart run` 直接回归。
library;

import 'dart:convert';

/// 单条「频道 → 线路」记录：记下 URL 与上一次成功时间。
class PreferredStreamBoard {
  PreferredStreamBoard({DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;

  /// 频道 id → 上次顺畅播放的线路地址。
  final Map<String, _Entry> _map = <String, _Entry>{};

  /// 一条记录的有效期。
  ///
  /// 公开源会换 token / 限流，太久以前的「最优线路」未必还能播。但这里可以
  /// 放得比较宽（7 天），因为记忆有**三重自愈**，长 TTL 不会把用户钉在死链上：
  ///
  /// 1. 地址已不在该频道的线路表里（换 token / 换路径 / 换镜像）→ 立即作废；
  /// 2. 拿它起播失败 → 立即作废（`_forgetPreferred`）；
  /// 3. 本会话内已被判失效 → 不前置，走正常排序。
  ///
  /// 反过来，TTL 太短会直接违背「持久保存」的诉求：用户隔天回来看同一个台，
  /// 记忆已经过期，又要重新检索一遍。24 小时只够覆盖「当天连看」。
  static const Duration ttl = Duration(days: 7);

  /// 记录条数上限：一个会话可能接触上千个台，留最近一批就够。
  static const int maxEntries = 800;

  /// 这个频道上次顺畅播放的线路；过期或不存在返回 null。
  String? preferredFor(String channelId) {
    final e = _map[channelId];
    if (e == null) return null;
    if (_clock().difference(e.at) > ttl) {
      _map.remove(channelId);
      return null;
    }
    return e.url;
  }

  /// 记录一条「顺畅播放」的线路。后写的覆盖先写的：永远保留**最近一次**成功的。
  void record(String channelId, String url) {
    if (channelId.isEmpty || url.isEmpty) return;
    _map[channelId] = _Entry(url, _clock());
    _trim();
  }

  /// 作废某个频道的记忆。
  ///
  /// 两种情况必须调用它，否则记忆会变成「永远先试一条已知播不了的线」：
  /// * 记录的地址已经不在该频道的线路表里（源站换了 token / 路径）；
  /// * 记录的地址起播失败。
  void forget(String channelId) {
    if (channelId.isEmpty) return;
    _map.remove(channelId);
  }

  bool get isEmpty => _map.isEmpty;

  int get length => _map.length;

  /// 超上限时丢最久没被更新的记录。
  void _trim() {
    if (_map.length <= maxEntries) return;
    final ordered = _map.entries.toList()
      ..sort((a, b) => a.value.at.compareTo(b.value.at));
    final excess = _map.length - maxEntries;
    for (var i = 0; i < excess && i < ordered.length; i++) {
      _map.remove(ordered[i].key);
    }
  }

  /// 导出为可落盘 JSON（只写有效记录）。
  String encode() {
    final map = <String, Object?>{
      for (final e in _map.entries)
        if (_clock().difference(e.value.at) <= ttl)
          e.key: <String, Object?>{
            'u': e.value.url,
            't': e.value.at.millisecondsSinceEpoch,
          },
    };
    return jsonEncode(<String, Object?>{'version': 1, 'preferred': map});
  }

  /// 从落盘 JSON 恢复。**任何异常都当作「没有记录」**：这只是加速项，
  /// 坏文件绝不该挡住开播。
  void loadEncoded(String? text) {
    if (text == null || text.isEmpty) return;
    try {
      final decoded = jsonDecode(text);
      if (decoded is! Map) return;
      final preferred = decoded['preferred'];
      if (preferred is! Map) return;
      for (final e in preferred.entries) {
        final key = e.key;
        if (key is! String || key.isEmpty) continue;
        final v = e.value;
        if (v is! Map) continue;
        final u = v['u'];
        final t = v['t'];
        if (u is! String || u.isEmpty || t is! num) continue;
        _map[key] = _Entry(u, DateTime.fromMillisecondsSinceEpoch(t.toInt()));
      }
      _trim();
    } catch (_) {
      // 损坏文件直接忽略。
    }
  }
}

class _Entry {
  _Entry(this.url, this.at);

  final String url;
  final DateTime at;
}
