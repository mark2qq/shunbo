import 'dart:async';

import '../../diagnostics/diagnostic_sink.dart';
import 'metrics_sampler.dart';
import 'mpv_event_loop.dart';
import 'mpv_property_observer.dart';
import 'player_metrics.dart';

/// 事件驱动指标管线（E3 真机集成的一行式接线）。
///
/// 原生事件源 → [MpvEventLoop]（解析/分发/隔离）→ [MpvPropertyObserver]
/// → [MetricsSampler] → [PlayerMetricGate]。真机侧只需：
/// ```dart
/// final pipeline = MpvEventPipeline.attach(
///   MpvEventChannelSource(),           // 或 FFI 侧 mpv_wait_event 推入的流
///   sampler: MetricsSampler(memoryProbe: platformMemoryMb),
///   diagnostics: sink,
/// );
/// ```
class MpvEventPipeline {
  final MpvEventLoop loop;
  final MpvPropertyObserver observer;
  final StreamSubscription<String> _subscription;
  final DiagnosticSink? _diagnostics;
  int _reportedMalformed = 0;

  MpvEventPipeline._(
    this.loop,
    this.observer,
    this._subscription,
    this._diagnostics,
  );

  static MpvEventPipeline attach(
    MpvEventSource source, {
    required MetricsSampler sampler,
    PlayerMetricGate gate = const PlayerMetricGate(),
    int sampleEveryFrames = 300,
    int maxQueueSize = 256,
    DiagnosticSink? diagnostics,
    void Function(PlayerMetrics metrics, GateResult result)? onSample,
  }) {
    final loop = MpvEventLoop(maxQueueSize: maxQueueSize);
    final observer = MpvPropertyObserver(
      sampler: sampler,
      gate: gate,
      sampleEveryFrames: sampleEveryFrames,
      onSample: (m, g) {
        if (!g.passed) {
          diagnostics?.record(DiagnosticEvent(
            kind: DiagnosticKind.metricGateFailed,
            at: DateTime.now(),
            detail: g.failures.join('; '),
            attributes: <String, Object?>{
              'firstFrameMs': m.firstFrameMs,
              'memoryMb': m.memoryMb,
              'droppedFrameRate': m.droppedFrameRate,
            },
          ));
        }
        onSample?.call(m, g);
      },
    );
    observer.bindTo(loop);
    final sub = loop.attach(
      source,
      onError: (Object e) => diagnostics?.record(DiagnosticEvent(
        kind: DiagnosticKind.mpvEventMalformed,
        at: DateTime.now(),
        detail: '事件流异常: $e',
      )),
    );
    return MpvEventPipeline._(loop, observer, sub, diagnostics);
  }

  /// 上报自上次调用以来新增的坏行数（去重，避免每帧刷屏）。
  void reportMalformed() {
    if (_diagnostics == null || loop.malformed <= _reportedMalformed) return;
    final delta = loop.malformed - _reportedMalformed;
    _reportedMalformed = loop.malformed;
    _diagnostics.record(DiagnosticEvent(
      kind: DiagnosticKind.mpvEventMalformed,
      at: DateTime.now(),
      detail: '跳过 $delta 条无法解析的内核事件',
    ));
  }

  void dispose() {
    _subscription.cancel();
  }
}
