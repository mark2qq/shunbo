import '../diagnostics/diagnostic_sink.dart';
import '../source/source_adapter.dart';
import '../source/source_registry.dart';
import 'playback_failure.dart';
import 'playback_orchestrator.dart';
import 'source_catalog.dart';

/// 自动换源结果。
class FailoverResult {
  final FailoverOutcome outcome;

  /// 成功恢复后的播放会话（失败时为 null）。
  final PlaybackSession? session;
  final List<FailoverAttempt> attempts;
  final PlaybackFailureReason reason;

  const FailoverResult._({
    required this.outcome,
    required this.session,
    required this.attempts,
    required this.reason,
  });

  factory FailoverResult.recovered({
    required PlaybackSession session,
    required List<FailoverAttempt> attempts,
    required PlaybackFailureReason reason,
  }) =>
      FailoverResult._(
        outcome: FailoverOutcome.recovered,
        session: session,
        attempts: List.unmodifiable(attempts),
        reason: reason,
      );

  factory FailoverResult.failed({
    required List<FailoverAttempt> attempts,
    required PlaybackFailureReason reason,
  }) =>
      FailoverResult._(
        outcome: FailoverOutcome.allSourcesFailed,
        session: null,
        attempts: List.unmodifiable(attempts),
        reason: reason,
      );

  bool get recovered => outcome == FailoverOutcome.recovered;

  /// 面向用户的兜底文案：成功说明「无感」，失败给出可执行的下一步。
  String get userMessage {
    if (recovered) {
      return '已自动切换到「${session!.sourceId}」，播放位置保持不变。';
    }
    if (attempts.isEmpty) {
      return '当前平台没有其他可用源。请检查网络与源配置，或稍后重试。';
    }
    return '当前所有可用源均不可用（已尝试 ${attempts.length} 个源）。'
        '请检查网络、稍后重试，或导入新的源配置。';
  }
}

/// 自动换源韧性（E7）：源失效 → 按平台可用源逐个对齐重试 → 全失效兜底。
///
/// 设计铁律（对应计划中「换源决策权唯一收敛到业务能力层 R1」）：
/// 1. 播放内核只上报失效，不自己挑源；本类是唯一的重试决策点。
/// 2. 每次尝试都从 **失败瞬间的原始坐标** 出发重新对齐，
///    绝不在失败的中间结果上继续换算，避免多次重试累积集数/时间漂移。
/// 3. 只有拿到真实播放地址才算成功；不允许「切换成功但没东西可播」的静默假成功。
/// 4. 候选源按当前平台裁剪，且必须有对齐画像（否则无法保证内容坐标守恒）。
/// 5. 全过程结构化埋点（[DiagnosticSink]），轨迹可直接作为线上排障数据源。
class SourceFailover {
  final PlaybackOrchestrator orchestrator;
  final SourceRegistry registry;
  final SourceCatalog catalog;
  final FailoverPolicy policy;
  final DiagnosticSink diagnostics;

  const SourceFailover({
    required this.orchestrator,
    required this.registry,
    required this.catalog,
    this.policy = const FailoverPolicy(),
    this.diagnostics = const NoopDiagnosticSink(),
  });

  /// 从一次播放失效中恢复。
  ///
  /// [failedSession] 为失效瞬间的会话快照；[excludeSources] 可排除已知坏源，
  /// 便于连续失效时逐步收敛，而不是反复重试同一个源。
  Future<FailoverResult> recover({
    required PlaybackSession failedSession,
    required PlaybackFailureException failure,
    required SourcePlatform platform,
    Set<String> excludeSources = const <String>{},
  }) async {
    final tried = <String>{failedSession.sourceId, ...excludeSources};
    final candidates = registry
        .availableOn(platform)
        .where((a) => !tried.contains(a.id) && catalog.get(a.id) != null)
        .map((a) => a.id)
        .take(policy.maxAttempts)
        .toList();

    diagnostics.record(DiagnosticEvent(
      kind: DiagnosticKind.playbackFailure,
      at: DateTime.now(),
      sourceId: failedSession.sourceId,
      mediaId: failedSession.mediaId,
      detail: failure.message,
      attributes: <String, Object?>{
        'reason': failure.reason.name,
        'platform': platform.name,
        'candidates': candidates.length,
        'contentEpisode': failedSession.contentEpisode,
        'contentSeconds': failedSession.contentSeconds,
      },
    ));

    final attempts = <FailoverAttempt>[];

    void recordAttempt(String id, FailoverAttempt a) {
      diagnostics.record(DiagnosticEvent(
        kind: DiagnosticKind.failoverAttempt,
        at: DateTime.now(),
        sourceId: id,
        mediaId: failedSession.mediaId,
        detail: a.detail,
        attributes: <String, Object?>{
          'succeeded': a.succeeded,
          'attemptIndex': attempts.length,
        },
      ));
    }

    for (final id in candidates) {
      try {
        // 恒定基准：始终用 failedSession 的原始坐标，避免重试累积漂移。
        final r = await orchestrator.switchSourceAligned(
          fromSourceId: failedSession.sourceId,
          toSourceId: id,
          mediaId: failedSession.mediaId,
          mediaTitle: failedSession.mediaTitle,
          fromRawEpisode: failedSession.rawEpisode,
          fromRawSeconds: failedSession.rawSeconds,
        );
        // 编排层已保证「无地址必抛异常」；此处再防一道空串，杜绝静默假成功。
        final ok = r.playUrl.url.isNotEmpty;
        final attempt = FailoverAttempt(
          sourceId: id,
          succeeded: ok,
          detail: ok ? r.playUrl.url : '播放地址为空串',
        );
        attempts.add(attempt);
        recordAttempt(id, attempt);
        if (!ok) continue;

        diagnostics.record(DiagnosticEvent(
          kind: DiagnosticKind.failoverRecovered,
          at: DateTime.now(),
          sourceId: id,
          mediaId: failedSession.mediaId,
          detail: '自动换源成功，内容坐标守恒',
          attributes: <String, Object?>{
            'attempts': attempts.length,
            'reason': failure.reason.name,
          },
        ));
        return FailoverResult.recovered(
          session: r.session,
          attempts: attempts,
          reason: failure.reason,
        );
      } on PlaybackFailureException catch (e) {
        final attempt = FailoverAttempt(
            sourceId: id, succeeded: false, detail: e.message);
        attempts.add(attempt);
        recordAttempt(id, attempt);
      } catch (e) {
        final attempt =
            FailoverAttempt(sourceId: id, succeeded: false, detail: '$e');
        attempts.add(attempt);
        recordAttempt(id, attempt);
      }
    }

    diagnostics.record(DiagnosticEvent(
      kind: DiagnosticKind.failoverExhausted,
      at: DateTime.now(),
      sourceId: failedSession.sourceId,
      mediaId: failedSession.mediaId,
      detail: '所有候选源均不可用',
      attributes: <String, Object?>{
        'attempts': attempts.length,
        'reason': failure.reason.name,
      },
    ));
    return FailoverResult.failed(attempts: attempts, reason: failure.reason);
  }
}
