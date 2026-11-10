import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'metrics_sampler.dart';
import 'mpv_ffi_bindings.dart';
import 'mpv_native.dart';
import 'player_metrics.dart';

/// 基于 [MpvFfiBindings] 的真实 [MpvNative] 实现（桌面/TV FFI 路径）。
///
/// 坐标约定：一切 `seconds` 均为**源原始坐标（含广告）**；去广告换算在调度层。
/// 指标：由外部注入的 [MetricsSampler] 采集（首帧/丢帧由渲染层回调驱动，
/// 内存由平台探针提供），本类负责把 mpv 命令/属性映射到 [MpvNative] 契约。
class MpvFfiNative implements MpvNative {
  final MpvFfiBindings bindings;
  final MetricsSampler sampler;

  Pointer<Void> _handle = nullptr;
  final Map<String, String> _pendingOptions = {};

  MpvFfiNative({required this.bindings, required this.sampler});

  bool get isCreated => _handle != nullptr;

  @override
  Future<void> create() async {
    _handle = bindings.create();
    final code = bindings.initialize(_handle);
    if (code < 0) {
      throw StateError('mpv_initialize 失败，错误码 $code');
    }
    for (final e in _pendingOptions.entries) {
      _setOption(e.key, e.value);
    }
    _pendingOptions.clear();
  }

  void _setOption(String key, String value) {
    final k = key.toNativeUtf8();
    final v = value.toNativeUtf8();
    try {
      bindings.setOptionString(_handle, k, v);
    } finally {
      calloc.free(k);
      calloc.free(v);
    }
  }

  int _command(String cmd) {
    final c = cmd.toNativeUtf8();
    try {
      return bindings.commandString(_handle, c);
    } finally {
      calloc.free(c);
    }
  }

  /// 读取 mpv 字符串属性（如 time-pos / duration），由 mpv_free 释放。
  String? _getProperty(String name) {
    final n = name.toNativeUtf8();
    try {
      final ptr = bindings.getPropertyString(_handle, n);
      if (ptr == nullptr) return null;
      try {
        return ptr.toDartString();
      } finally {
        bindings.free(ptr.cast());
      }
    } finally {
      calloc.free(n);
    }
  }

  /// 渲染层在首帧到达时回调（驱动指标采样）。
  void notifyFirstFrame() => sampler.onFirstFrame();

  /// 渲染层每帧回调（dropped=true 表示丢帧）。
  void notifyFrame({bool dropped = false}) =>
      sampler.reportFrame(dropped: dropped);

  @override
  Future<void> setOption(String key, String value) async {
    if (!isCreated) {
      _pendingOptions[key] = value;
      return;
    }
    _setOption(key, value);
  }

  @override
  Future<void> load(String url) async {
    sampler.onLoadStart();
    // libmpv 命令字符串参数以空格分隔，含空格的 URL 需引号包裹。
    _command('loadfile "${url.replaceAll('"', '\\"')}" replace');
    await play();
  }

  @override
  Future<void> play() async => _command('set pause no');

  @override
  Future<void> pause() async => _command('set pause yes');

  @override
  Future<void> seek(double seconds) async =>
      _command('seek ${seconds.toStringAsFixed(3)} absolute');

  @override
  Future<double> getTime() async =>
      double.tryParse(_getProperty('time-pos') ?? '') ?? 0.0;

  @override
  Future<double> getDuration() async =>
      double.tryParse(_getProperty('duration') ?? '') ?? 0.0;

  @override
  Future<PlayerMetrics> sampleMetrics() async => sampler.sample();

  @override
  Future<void> dispose() async {
    if (isCreated) {
      bindings.terminateDestroy(_handle);
      _handle = nullptr;
    }
  }
}
