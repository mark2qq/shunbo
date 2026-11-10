/// Android `ConnectivityManager` 精确网络状态的 Flutter 侧封装（R14）。
///
/// 与 `NetworkWatch.kt` 的通道名逐字一致：`shunbo/network`（一次性快照）、
/// `shunbo/network/events`（变化事件）。桌面端 / 未注册通道的旧包一律
/// 确定性回落到 `DefaultNetworkStateProvider`，绝不抛 MissingPluginException
/// 打断开播。
library;

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/services.dart';

import '../features/live/carrier_detector.dart';
import '../features/live/network_event.dart';

class NetworkWatch {
  NetworkWatch({
    MethodChannel? methodChannel,
    EventChannel? eventChannel,
    NetworkStateProvider? fallback,
    // 版本兼容分支：低版本 / 探测失败时停用 API 24+ 专属的原生精确网络回调，
    // 直接走既有的 DefaultNetworkStateProvider 兜底。默认 false ⇒ 原有行为逐字不变。
    this.legacyCompat = false,
  })  : _method = methodChannel ?? const MethodChannel(kNetworkMethodChannel),
        _events = eventChannel ?? const EventChannel(kNetworkEventChannel),
        _fallback = fallback ?? DefaultNetworkStateProvider();

  static const String kNetworkMethodChannel = 'shunbo/network';
  static const String kNetworkEventChannel = 'shunbo/network/events';

  final MethodChannel _method;
  final EventChannel _events;
  final NetworkStateProvider _fallback;

  /// 是否处于版本兼容分支（只读，启动时由分支决策注入，运行期不变）。
  final bool legacyCompat;

  /// 只有 Android 有这套原生实现；桌面端连一次平台调用都不发。
  static bool get isSupported => Platform.isAndroid;

  /// 启动 / 回前台时主动取一次精确快照。失败返回 null，由调用方回落。
  ///
  /// 与 [current] 的区别：这里保留 `connected` / `restricted`，回前台时
  /// 才能判断「该暂停」还是「该重新识别」，而不是一律发起归属探测。
  Future<NetworkSnapshot?> currentSnapshot() async {
    if (!isSupported) return null;
    // 兼容分支不发起原生调用；调用方已有确定性兜底，播放主链路不受影响。
    if (legacyCompat) return null;
    try {
      final raw = await _method.invokeMethod<Object?>('current');
      return NetworkSnapshot.tryParse(raw);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    } catch (_) {
      return null;
    }
  }

  /// 只取状态（给 `CarrierDetector` 的 [NetworkStateProvider] 用）。
  Future<NetworkState?> current() async => (await currentSnapshot())?.state;

  /// 语义去重后的网络变化流。**单订阅者**（main 里只 listen 一次）。
  ///
  /// 平台事件解析失败返回 null 并被丢弃，此时不触发任何网络请求；
  /// 下一次成功事件会与上一次成功快照比较，不会因为中间一条脏数据而漏判。
  Stream<NetworkSnapshot> get changes {
    if (!isSupported) return const Stream<NetworkSnapshot>.empty();
    // 兼容分支不订阅原生事件流；CarrierDetector 仍走 provider 的兜底状态源。
    if (legacyCompat) return const Stream<NetworkSnapshot>.empty();
    final gate = NetworkChangeGate();
    return _events
        .receiveBroadcastStream()
        .map(gate.acceptAndParse)
        .where((s) => s != null)
        .cast<NetworkSnapshot>();
  }

  /// 给 `CarrierDetector` 用的状态源：精确探测优先、失败回落接口名推断。
  NetworkStateProvider get provider =>
      _AndroidNetworkStateProvider(this, _fallback);
}

class _AndroidNetworkStateProvider implements NetworkStateProvider {
  const _AndroidNetworkStateProvider(this.watch, this.fallback);

  final NetworkWatch watch;
  final NetworkStateProvider fallback;

  @override
  Future<NetworkState> current() async {
    final precise = await watch.current();
    return precise ?? fallback.current();
  }
}
