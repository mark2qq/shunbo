import 'dart:async';

/// 串行门闩：把「会碰播放内核」的异步流程排成一条队。
///
/// 直播切台闪退最常见的成因不是 Dart 异常，而是**两条流程同时调 libmpv**：
/// 看门狗正在切备用线路、用户又点了一个台、失败自动切台的定时器同时触发，
/// 三个 `player.load()` 叠在一起，原生侧的资源分配/释放顺序就不可控了。
///
/// epoch 只能丢弃「过期结果」，**挡不住已经发出的原生调用**——
/// 所以还必须在调用之前排队。这里刻意做成纯 Dart（无 Flutter 依赖），
/// 让并发顺序、异常隔离都能用 `dart run` 直接回归，而不必等真机复现。
class AsyncSerialGate {
  Future<void> _tail = Future<void>.value();
  bool _closed = false;
  int _pending = 0;

  /// 当前排队（含正在执行）的操作数。
  int get pending => _pending;

  bool get isClosed => _closed;

  /// 排队执行 [body]：前一个操作没结束前不会开始下一个。
  ///
  /// [body] 抛出的异常原样交给调用方（由调用方决定降级），
  /// 但绝不会卡死队列——`finally` 一定会放行后续操作。
  Future<void> run(Future<void> Function() body) async {
    if (_closed) return;
    final previous = _tail;
    final release = Completer<void>();
    _tail = release.future;
    _pending++;
    try {
      // previous 只会正常完成（见 finally），所以无需 catchError：
      // 一个操作的失败不该连带把后面排队的操作全部取消。
      await previous;
      if (_closed) return;
      await body();
    } finally {
      _pending--;
      if (!release.isCompleted) release.complete();
    }
  }

  /// 关闭门闩：已排队但还没开始的操作直接跳过（用于 dispose）。
  void close() => _closed = true;
}
