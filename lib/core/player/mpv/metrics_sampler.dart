import 'player_metrics.dart';

/// 首帧尚未到达时的哨兵值（门禁必判失败）。
const int kFirstFramePendingMs = 999999;

/// 可注入时钟，便于确定性验证（不依赖真实墙钟）。
abstract class SamplerClock {
  int nowMs();
}

class SystemSamplerClock implements SamplerClock {
  @override
  int nowMs() => DateTime.now().millisecondsSinceEpoch;
}

class FakeSamplerClock implements SamplerClock {
  int _ms;
  FakeSamplerClock([this._ms = 0]);

  void advance(int ms) => _ms += ms;

  @override
  int nowMs() => _ms;
}

/// 内核调优参数：三项指标相互牵制的可调旋钮。
///
/// - [prebufferFrames] 预解码帧数：↑ 首帧更快，但内存更高。
/// - [cacheMb] 缓冲大小：↑ 更不卡顿，但内存更高。
class KernelTuning {
  final int prebufferFrames;
  final double cacheMb;

  const KernelTuning({this.prebufferFrames = 8, this.cacheMb = 16});

  @override
  String toString() => 'KernelTuning(prebuffer=$prebufferFrames, cache=${cacheMb}MB)';
}

/// 运行时指标采样器：把内核事件流转换为 [PlayerMetrics]。
///
/// 三项指标由**同一次采样**产出，交由 [PlayerMetricGate] 统一判定——这正是设计稿
/// "首帧快 ↔ 内存低 ↔ 不卡顿三者相互牵制"的落地：不允许靠单点优化牺牲另一项。
///
/// 事件由渲染层/内核回调驱动，内存由平台探针提供，因此本类为纯 Dart、可独立验证。
class MetricsSampler {
  final SamplerClock clock;

  /// 平台内存探针（MB）；真实环境由 FFI 属性查询 / 平台通道提供。
  final double Function() memoryProbe;

  /// 期望帧率，用于内核未显式上报丢帧时按窗口推断。
  final double expectedFps;

  /// 统计窗口长度（ms）。
  final int windowMs;

  int? _loadStartMs;
  int? _firstFrameMs;
  int _renderedFrames = 0;
  int _droppedFrames = 0;
  int _windowStartMs = 0;

  MetricsSampler({
    SamplerClock? clock,
    required this.memoryProbe,
    this.expectedFps = 30.0,
    this.windowMs = 10000,
  }) : clock = clock ?? SystemSamplerClock();

  /// 一次载入开始（每次 load 必须调用，重置窗口）。
  void onLoadStart() {
    final now = clock.nowMs();
    _loadStartMs = now;
    _windowStartMs = now;
    _firstFrameMs = null;
    _renderedFrames = 0;
    _droppedFrames = 0;
  }

  /// 首帧渲染完成（仅首次生效）。
  void onFirstFrame() => _firstFrameMs ??= clock.nowMs();

  void onFrameRendered() => _renderedFrames++;
  void onDroppedFrame() => _droppedFrames++;

  /// 由渲染层批量上报帧事件。
  void reportFrame({bool dropped = false}) {
    if (dropped) {
      onDroppedFrame();
    } else {
      onFrameRendered();
    }
  }

  /// 采样产出指标。
  PlayerMetrics sample() {
    final now = clock.nowMs();
    final firstFrameMs = (_firstFrameMs != null && _loadStartMs != null)
        ? _firstFrameMs! - _loadStartMs!
        : kFirstFramePendingMs;

    final total = _renderedFrames + _droppedFrames;
    double droppedRate;
    if (total > 0) {
      droppedRate = _droppedFrames / total;
    } else {
      // 内核未显式上报时，按窗口内「期望帧数 vs 实际渲染帧数」推断。
      final elapsedMs = (now - _windowStartMs).clamp(1, windowMs).toInt();
      final expected = elapsedMs / 1000.0 * expectedFps;
      droppedRate = expected > 0
          ? ((expected - _renderedFrames) / expected).clamp(0.0, 1.0).toDouble()
          : 0.0;
    }

    return PlayerMetrics(
      firstFrameMs: firstFrameMs,
      memoryMb: memoryProbe(),
      droppedFrameRate: droppedRate,
    );
  }
}

/// 首帧 ↔ 内存 ↔ 卡顿 的牵制模型（E3 门禁的量化落地）。
///
/// 简化但可解释的线性模型，用于集成前在参数空间里找可行解，避免"压首帧把内存顶爆"
/// 或"降内存把卡顿拉高"。系数为真机实测前的初版占位，集成时按机型校准。
class KernelTradeoffModel {
  final PlayerMetricGate gate;

  const KernelTradeoffModel({this.gate = const PlayerMetricGate()});

  PlayerMetrics estimate(KernelTuning t) {
    final ff = (900 - 45 * t.prebufferFrames).clamp(120, 3000).toInt();
    final mem = 40.0 + 3.0 * t.prebufferFrames + t.cacheMb;
    final drop = (0.06 - 0.0025 * t.cacheMb).clamp(0.0, 1.0).toDouble();
    return PlayerMetrics(
      firstFrameMs: ff,
      memoryMb: mem,
      droppedFrameRate: drop,
    );
  }

  /// 在参数网格中枚举可行解，返回**内存最小**者（体现"不能只压首帧"）。
  /// 返回 null 表示当前门禁下无可行参数，须调整阈值或优化内核。
  KernelTuning? findBalancedTuning({
    Iterable<int> prebuffer = const [0, 4, 8, 12, 16, 24],
    Iterable<double> cache = const [0, 8, 16, 24, 32],
  }) {
    KernelTuning? best;
    double bestMem = double.infinity;
    for (final p in prebuffer) {
      for (final c in cache) {
        final t = KernelTuning(prebufferFrames: p, cacheMb: c);
        final m = estimate(t);
        if (gate.evaluate(m).passed && m.memoryMb < bestMem) {
          best = t;
          bestMem = m.memoryMb;
        }
      }
    }
    return best;
  }
}
