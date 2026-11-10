/// 平台网络事件的**纯 Dart** 解析与去重（R14 / 方案 14.8）。
///
/// 刻意不 import `package:flutter/*`：本项目 `flutter test` 在本机不可用，
/// 所有回归都用裸 `dart run tooling/verify_*.dart`，一旦这里拉进 `dart:ui`
/// 就整套验证跑不起来。Flutter 通道封装放在 `lib/platform/network_watch.dart`。
///
/// 平台事件是「不可信输入」：字段可能缺失、类型可能不对、缓存键可能超长或
/// 带控制字符（会污染诊断页与 `CarrierDetector` 的缓存键）。一律先净化，
/// 净化失败按「受限网络」处理——宁可暂停内网通道，也不能在未知网络上
/// 沿用上一段网络的运营商结论。
library;

import 'carrier_detector.dart';
import 'live_channel.dart';

/// 缓存键最大长度。平台侧用「传输类型:接口名:计费属性」，正常远小于此。
const int kNetworkKeyMaxLength = 128;

/// 允许出现在缓存键里的字符。接口名只允许 `[a-z0-9._-]`，分隔符是冒号。
final RegExp _keyAllowed = RegExp(r'^[A-Za-z0-9._:\-]+$');

/// 一次网络快照。字段与 `NetworkWatch.kt` 的 Map 逐字对应。
class NetworkSnapshot {
  const NetworkSnapshot({
    required this.state,
    required this.connected,
    this.restricted = false,
    this.metered = false,
    this.vpn = false,
    this.iface = '',
    this.rawKind = 'unknown',
  });

  final NetworkState state;

  /// 系统是否报告了一个可用默认网络。false 时绝不发起归属探测。
  final bool connected;

  /// 受限网络：离线 / VPN / 未知传输。此时只走公网源、零探测请求。
  bool get shouldSuspend => !connected || restricted;

  final bool restricted;
  final bool metered;
  final bool vpn;
  final String iface;

  /// 原始传输类型，仅用于诊断展示。
  final String rawKind;

  /// 把平台 Map 解析成快照；任何不合法输入都返回「受限」而不是 null，
  /// 这样解析失败也会触发暂停而不是被当成「没有事件」静默跳过。
  static NetworkSnapshot? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final kindText = _text(raw['kind'], max: 24).toLowerCase();
    final connected = raw['connected'] == true;
    final vpn = raw['vpn'] == true || kindText == 'vpn';
    final knownTransport = kindText == 'wifi' ||
        kindText == 'ethernet' ||
        kindText == 'cellular';
    final restricted = !connected ||
        vpn ||
        !knownTransport ||
        raw['restricted'] == true;

    final Carrier? hint;
    final hintText = _text(raw['carrierHint'], max: 96);
    if (hintText.isEmpty || !connected) {
      hint = null;
    } else {
      final parsed = CarrierDetector.parseCarrierText(hintText);
      hint = parsed == Carrier.unknown ? null : parsed;
    }

    final kind = switch (kindText) {
      'wifi' => NetworkKind.wifi,
      'ethernet' => NetworkKind.ethernet,
      'cellular' => NetworkKind.cellular,
      _ => NetworkKind.unknown,
    };

    final rawKey = _text(raw['key'], max: kNetworkKeyMaxLength * 2);
    final key = _cleanKey(rawKey, fallback: restricted ? 'restricted' : kind.name);

    return NetworkSnapshot(
      state: NetworkState(kind: kind, key: key, carrierHint: hint),
      connected: connected,
      restricted: restricted,
      metered: raw['metered'] == true,
      vpn: vpn,
      iface: _text(raw['iface'], max: 64),
      rawKind: kindText.isEmpty ? 'unknown' : kindText,
    );
  }

  /// 只回显安全字符，避免把平台字符串直接拼进诊断 / 缓存键。
  static String _cleanKey(String raw, {required String fallback}) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty ||
        trimmed.length > kNetworkKeyMaxLength ||
        !_keyAllowed.hasMatch(trimmed)) {
      return '$fallback:untrusted';
    }
    return trimmed;
  }

  static String _text(Object? value, {required int max}) {
    if (value is! String || value.isEmpty || value.length > max) return '';
    // 控制字符会让诊断行错位，也可能被用于伪装成另一条记录。
    if (value.codeUnits.any((c) => c < 0x20 || c == 0x7f)) return '';
    return value;
  }
}

/// 事件去重：只有影响通道准入的字段变了才通知调度层。
///
/// `onCapabilitiesChanged` 在 Android 上会因信号强度 / 计费变化连发多次，
/// 每次都触发一次公网归属探测会白白消耗请求并让识别耗时数字失真。
class NetworkChangeGate {
  NetworkSnapshot? _last;

  NetworkSnapshot? get last => _last;

  /// 返回「语义发生变化」的快照，重复事件返回 null。
  NetworkSnapshot? acceptAndParse(Object? raw) {
    final s = NetworkSnapshot.tryParse(raw);
    if (s == null) return null;
    final prev = _last;
    _last = s;
    if (prev == null) return s;
    final changed = prev.state.key != s.state.key ||
        prev.state.kind != s.state.kind ||
        prev.connected != s.connected ||
        prev.restricted != s.restricted ||
        prev.state.carrierHint != s.state.carrierHint;
    return changed ? s : null;
  }

  void reset() => _last = null;
}
