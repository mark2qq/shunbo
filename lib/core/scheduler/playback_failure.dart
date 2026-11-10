/// 播放失效与换源韧性的领域模型（E7）。
///
/// 对应《技术评估与研发执行计划》登记的「产品根本脆弱性」：
/// 聚合型播放器在没有可用源时体验会直接归零，因此必须把「失效」建模成
/// 一等事件，而不是让上层在空地址/异常处各自兜底。
library;

/// 播放失效原因（供诊断上报与兜底文案分流）。
enum PlaybackFailureReason {
  /// 源解析成功但没有可播放地址（最常见：站点改版 / 版权下架）。
  emptyPlayUrl,
  networkError,
  decodeError,
  stallTimeout,
  unknown,
}

/// 一次可捕获的播放失效。
///
/// 编排层在「解析不到地址」时抛出，由 E7 自动换源统一处理；
/// 这与程序员错误（StateError，如源未注册）刻意区分开。
class PlaybackFailureException implements Exception {
  final PlaybackFailureReason reason;
  final String sourceId;
  final String message;

  const PlaybackFailureException({
    required this.reason,
    required this.sourceId,
    required this.message,
  });

  @override
  String toString() => 'PlaybackFailure(${reason.name}/$sourceId): $message';
}

/// 自动换源结果类型。
enum FailoverOutcome { recovered, allSourcesFailed }

/// 单次换源尝试记录（供 UI 展示「已尝试哪些源」与诊断上报）。
class FailoverAttempt {
  final String sourceId;
  final bool succeeded;
  final String detail;

  const FailoverAttempt({
    required this.sourceId,
    required this.succeeded,
    required this.detail,
  });

  @override
  String toString() => '$sourceId: ${succeeded ? "成功" : "失败"}($detail)';
}

/// 自动换源策略（业务能力层 R1 唯一权威，播放内核不参与决策）。
class FailoverPolicy {
  /// 单次失效最多尝试的备用源数量（防止在源很多时长时间卡住用户）。
  final int maxAttempts;

  const FailoverPolicy({this.maxAttempts = 3});
}
