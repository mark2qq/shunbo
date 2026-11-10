/// libmpv 播放内核的运行时指标（E3 实测门禁对象）。
///
/// 设计稿明示三大指标**相互牵制**：首帧快 ↔ 内存低 ↔ 不卡顿。
/// 典型博弈：为压低首帧而预解码会推高内存；为降内存而减少缓冲会抬升卡顿率。
/// 因此门禁须三项同时达标，且不能靠单点优化牺牲另一项。
class PlayerMetrics {
  /// 首帧渲染耗时（ms），越小越快。
  final int firstFrameMs;

  /// 常驻内存占用（MB），越小越低。
  final double memoryMb;

  /// 卡顿率 = 丢帧数 / 总帧数，越小越稳。
  final double droppedFrameRate;

  const PlayerMetrics({
    required this.firstFrameMs,
    required this.memoryMb,
    required this.droppedFrameRate,
  });

  PlayerMetrics copyWith({
    int? firstFrameMs,
    double? memoryMb,
    double? droppedFrameRate,
  }) =>
      PlayerMetrics(
        firstFrameMs: firstFrameMs ?? this.firstFrameMs,
        memoryMb: memoryMb ?? this.memoryMb,
        droppedFrameRate: droppedFrameRate ?? this.droppedFrameRate,
      );
}

/// E3 指标门禁：三项须同时达标，任一项超标即判失败（缺省阈值为初版目标，集成时按机型校准）。
///
/// - maxFirstFrameMs：首帧耗时上限（默认 800ms）。
/// - maxMemoryMb：内存上限（默认 120MB，移动端尤需严控）。
/// - maxDroppedFrameRate：卡顿率上限（默认 1%）。
class PlayerMetricGate {
  final int maxFirstFrameMs;
  final double maxMemoryMb;
  final double maxDroppedFrameRate;

  const PlayerMetricGate({
    this.maxFirstFrameMs = 800,
    this.maxMemoryMb = 120.0,
    this.maxDroppedFrameRate = 0.01,
  });

  /// 评估一组指标，返回逐项结论。
  GateResult evaluate(PlayerMetrics m) {
    final failures = <String>[];
    if (m.firstFrameMs > maxFirstFrameMs) {
      failures.add('首帧 ${m.firstFrameMs}ms > 上限 ${maxFirstFrameMs}ms');
    }
    if (m.memoryMb > maxMemoryMb) {
      failures.add('内存 ${m.memoryMb.toStringAsFixed(1)}MB > 上限 ${maxMemoryMb.toStringAsFixed(1)}MB');
    }
    if (m.droppedFrameRate > maxDroppedFrameRate) {
      failures.add('卡顿率 ${(m.droppedFrameRate * 100).toStringAsFixed(2)}% > 上限 '
          '${(maxDroppedFrameRate * 100).toStringAsFixed(2)}%');
    }
    return GateResult(passed: failures.isEmpty, failures: failures);
  }
}

/// 门禁评估结果。
class GateResult {
  final bool passed;
  final List<String> failures;

  const GateResult({required this.passed, required this.failures});
}
