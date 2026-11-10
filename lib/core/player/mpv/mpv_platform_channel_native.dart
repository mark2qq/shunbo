import 'package:flutter/services.dart';

import 'mpv_native.dart';
import 'player_metrics.dart';

/// 平台通道版 [MpvNative]（Android 端 / libmpv 缺失时的 ExoPlayer 回退）。
///
/// 原生侧需实现 `shunbo/mpv` MethodChannel 的下列 method：
/// create / setOption / load / play / pause / seek / getTime / getDuration /
/// sampleMetrics / dispose。sampleMetrics 返回
/// `{firstFrameMs:int, memoryMb:double, droppedFrameRate:double}`。
///
/// 设计稿风险「跨内核画质桥接」：降级后能力/画质可能与 libmpv 不等价，
/// 调用方须在 UI 明示，不可静默降级（见 [MpvBackendResolution.reason]）。
class MpvPlatformChannelNative implements MpvNative {
  static const MethodChannel _channel = MethodChannel('shunbo/mpv');

  final String backendTag;

  MpvPlatformChannelNative({this.backendTag = 'ExoPlayer'});

  Future<T?> _invoke<T>(String method, [Map<String, dynamic>? args]) =>
      _channel.invokeMethod<T>(method, args);

  @override
  Future<void> create() => _invoke<void>('create');

  @override
  Future<void> setOption(String key, String value) =>
      _invoke<void>('setOption', {'key': key, 'value': value});

  @override
  Future<void> load(String url) => _invoke<void>('load', {'url': url});

  @override
  Future<void> play() => _invoke<void>('play');

  @override
  Future<void> pause() => _invoke<void>('pause');

  @override
  Future<void> seek(double seconds) =>
      _invoke<void>('seek', {'seconds': seconds});

  @override
  Future<double> getTime() async =>
      (await _invoke<num>('getTime'))?.toDouble() ?? 0.0;

  @override
  Future<double> getDuration() async =>
      (await _invoke<num>('getDuration'))?.toDouble() ?? 0.0;

  @override
  Future<PlayerMetrics> sampleMetrics() async {
    final raw = await _invoke<Map<dynamic, dynamic>>('sampleMetrics');
    if (raw == null) {
      // 取不到指标时返回「明确不达标」的保守值，避免门禁误放行。
      return const PlayerMetrics(
        firstFrameMs: 999999,
        memoryMb: double.infinity,
        droppedFrameRate: 1.0,
      );
    }
    return PlayerMetrics(
      firstFrameMs: (raw['firstFrameMs'] as num?)?.toInt() ?? 999999,
      memoryMb: (raw['memoryMb'] as num?)?.toDouble() ?? double.infinity,
      droppedFrameRate:
          (raw['droppedFrameRate'] as num?)?.toDouble() ?? 1.0,
    );
  }

  @override
  Future<void> dispose() => _invoke<void>('dispose');
}
