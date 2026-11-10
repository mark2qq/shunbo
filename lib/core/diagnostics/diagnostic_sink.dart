/// 诊断事件类型（E7 可观测性 + E3 门禁退化上报）。
enum DiagnosticKind {
  playbackFailure,
  failoverAttempt,
  failoverRecovered,
  failoverExhausted,
  metricGateFailed,
  storeDegraded,
  mpvEventMalformed,
  syncConflict,
  syncOffline,
  syncApplied,
  castStarted,
  castFallback,

  /// 播放中进度落盘失败（磁盘满/权限/原子写异常）。进度仍在内存推进，但重启会丢。
  progressWriteFailed,

  /// 片尾判定命中（E6）：该集被视为已看完，续播标记写入 finished。
  /// 供「自动连播 / 看完打卡 / 推荐下一集」等能力消费。
  episodeFinished,

  /// 自动连播成功切到下一集（`playback_queue.dart`）。
  autoNextAdvanced,

  /// 自动连播在所有候选源上都起播失败。
  autoNextFailed,
}

/// 一条可上报的诊断事件（结构化，便于埋点/日志/远端聚合）。
class DiagnosticEvent {
  final DiagnosticKind kind;
  final DateTime at;
  final String sourceId;
  final String mediaId;
  final String detail;
  final Map<String, Object?> attributes;

  const DiagnosticEvent({
    required this.kind,
    required this.at,
    this.sourceId = '',
    this.mediaId = '',
    this.detail = '',
    this.attributes = const <String, Object?>{},
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
        'kind': kind.name,
        'at': at.toIso8601String(),
        'sourceId': sourceId,
        'mediaId': mediaId,
        'detail': detail,
        'attributes': attributes,
      };

  @override
  String toString() => 'Diagnostic(${kind.name}/$sourceId/$mediaId): $detail';
}

/// 诊断上报抽象。同步接口：真实实现（网络/日志）内部自行排队，不阻塞播放链路。
abstract class DiagnosticSink {
  void record(DiagnosticEvent event);
}

/// 空实现（默认）：不接入埋点时零开销，保证上层无需判空。
class NoopDiagnosticSink implements DiagnosticSink {
  const NoopDiagnosticSink();

  @override
  void record(DiagnosticEvent event) {}
}

/// 内存实现（测试 / 本地诊断面板用）。
class MemoryDiagnosticSink implements DiagnosticSink {
  final List<DiagnosticEvent> _events = [];

  List<DiagnosticEvent> get events => List.unmodifiable(_events);

  List<DiagnosticEvent> ofKind(DiagnosticKind kind) =>
      List.unmodifiable(_events.where((e) => e.kind == kind).toList());

  List<DiagnosticKind> get kinds => _events.map((e) => e.kind).toList();

  void clear() => _events.clear();

  @override
  void record(DiagnosticEvent event) => _events.add(event);
}
