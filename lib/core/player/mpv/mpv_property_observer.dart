import 'metrics_sampler.dart';
import 'mpv_event.dart';
import 'mpv_event_loop.dart';
import 'player_metrics.dart';

/// 由 property-change 事件累积出的内核运行态。
class MpvRuntimeState {
  final bool paused;
  final double timePos;
  final double cacheSeconds;

  /// 累计丢帧/已渲染帧（libmpv 上报的是**累计值**，需取差值喂给采样器）。
  final int droppedFramesTotal;
  final int renderedFramesTotal;

  const MpvRuntimeState({
    this.paused = false,
    this.timePos = 0.0,
    this.cacheSeconds = 0.0,
    this.droppedFramesTotal = 0,
    this.renderedFramesTotal = 0,
  });

  MpvRuntimeState copyWith({
    bool? paused,
    double? timePos,
    double? cacheSeconds,
    int? droppedFramesTotal,
    int? renderedFramesTotal,
  }) =>
      MpvRuntimeState(
        paused: paused ?? this.paused,
        timePos: timePos ?? this.timePos,
        cacheSeconds: cacheSeconds ?? this.cacheSeconds,
        droppedFramesTotal: droppedFramesTotal ?? this.droppedFramesTotal,
        renderedFramesTotal: renderedFramesTotal ?? this.renderedFramesTotal,
      );
}

/// Property 观察器：把内核事件流接到 [MetricsSampler] 与 [PlayerMetricGate]。
///
/// 这是「真机集成」缺失的一环：此前采样器需手工调用，真机上无法自动产出指标。
/// 现在 event loop → observer → sampler → gate 全链路事件驱动，且纯 Dart 可验证。
///
/// 关键语义：
/// - `file-loaded` 重置采样窗口；`playback-restart` 标记首帧（首帧未到达时门禁必失败）。
/// - `drop-frame-count` / `estimated-frame-count` 为**累计值**，用差值驱动帧事件，
///   避免重复计数；同时维护 [state] 供 UI 显示缓冲/进度。
/// - 每累计 [sampleEveryFrames] 帧自动采样并跑门禁，退化可被即时卡住。
class MpvPropertyObserver {
  final MetricsSampler sampler;
  final PlayerMetricGate gate;
  final int sampleEveryFrames;
  final void Function(PlayerMetrics metrics, GateResult result)? onSample;

  MpvRuntimeState state;
  int _sinceSample = 0;

  PlayerMetrics? lastMetrics;
  GateResult? lastGate;
  int sampleCount = 0;

  MpvPropertyObserver({
    required this.sampler,
    this.gate = const PlayerMetricGate(),
    this.sampleEveryFrames = 300,
    this.onSample,
    this.state = const MpvRuntimeState(),
  });

  /// 绑定到事件循环（订阅全部事件，内部按类型分派）。
  MpvEventSubscription bindTo(MpvEventLoop loop) => loop.on(null, handle);

  void handle(MpvEvent ev) {
    switch (ev.kind) {
      case MpvEventKind.fileLoaded:
        sampler.onLoadStart();
        _sinceSample = 0;
        break;
      case MpvEventKind.playbackRestart:
        sampler.onFirstFrame();
        break;
      case MpvEventKind.propertyChange:
        _applyProperty(ev);
        break;
      default:
        break;
    }
  }

  void _applyProperty(MpvEvent ev) {
    final name = ev.name;
    if (name == null) return;
    switch (name) {
      case 'time-pos':
        state = state.copyWith(timePos: ev.numericData ?? state.timePos);
        break;
      case 'pause':
        state = state.copyWith(paused: ev.data == true || ev.data == 'yes');
        break;
      case 'demuxer-cache-duration':
        state = state.copyWith(cacheSeconds: ev.numericData ?? state.cacheSeconds);
        break;
      case 'drop-frame-count':
        _accumulate(ev.numericData, dropped: true);
        break;
      case 'estimated-frame-count':
        _accumulate(ev.numericData, dropped: false);
        break;
      default:
        break;
    }
    if (_sinceSample >= sampleEveryFrames) _emitSample();
  }

  void _accumulate(double? raw, {required bool dropped}) {
    if (raw == null) return;
    final v = raw.toInt();
    final old = dropped ? state.droppedFramesTotal : state.renderedFramesTotal;
    if (v <= old) return; // 累计值回退（如 seek）不产生负增量
    final delta = v - old;
    for (var i = 0; i < delta; i++) {
      sampler.reportFrame(dropped: dropped);
    }
    state = dropped
        ? state.copyWith(droppedFramesTotal: v)
        : state.copyWith(renderedFramesTotal: v);
    _sinceSample += delta;
  }

  /// 立即采样并跑门禁（如 seek / 换源完成时主动触发）。
  void forceSample() => _emitSample();

  void _emitSample() {
    _sinceSample = 0;
    lastMetrics = sampler.sample();
    lastGate = gate.evaluate(lastMetrics!);
    sampleCount++;
    onSample?.call(lastMetrics!, lastGate!);
  }
}
