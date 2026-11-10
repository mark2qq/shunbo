import '../diagnostics/diagnostic_sink.dart';
import '../source/source_adapter.dart';
import '../source/source_registry.dart';
import 'playback_failure.dart';
import 'playback_orchestrator.dart';
import 'source_catalog.dart';

/// 自动连播的推进结果。
enum QueueAdvanceReason {
  /// 已切到下一集并成功起播。
  advanced,

  /// 用户关闭了自动连播（设计稿「自动连播可关闭」）。
  disabled,

  /// 没有活跃会话（还没开始播）。
  noSession,

  /// 剧集列表里没有下一集（最后一集 / 单集片）。
  noNextEpisode,

  /// 片尾事件不属于当前会话（换源/换集之后迟到的旧回调）。
  staleEvent,

  /// 上一次推进还没结束，本次丢弃（防止重复起播）。
  busy,

  /// 所有候选源都无法起播下一集。
  failed,
}

/// 一次推进的完整现场，供 UI 展示与回归断言。
class QueueAdvance {
  final QueueAdvanceReason reason;

  /// 成功推进后的新会话；失败/未推进时为 null。
  final PlaybackSession? session;

  /// 目标集（规范内容坐标）；无下一集时为 null。
  final int? nextEpisode;

  /// 人类可读说明（UI 直接展示，不含英文枚举名）。
  final String message;

  const QueueAdvance({
    required this.reason,
    this.session,
    this.nextEpisode,
    required this.message,
  });

  bool get advanced => reason == QueueAdvanceReason.advanced;
}

/// 播放列表 / 自动连播能力层（补上「看完一集停在片尾」的最后一环）。
///
/// 为什么单独一层而不是塞进 `ProgressReporter` 或编排层：
/// - [ProgressReporter] 只负责「把位置写对」，它不知道剧集列表，也不该知道从哪个源起播；
/// - 编排层 [PlaybackOrchestrator] 是**无状态**的单次载入执行器，把「当前播到第几集、
///   接下来播哪一集」放进去会让它同时承担会话状态，换源与换集两条路径互相污染。
///
/// 与 E7 的职责边界（重要）：
/// - [SourceFailover] 负责**同一内容位置**的换源重试（播放中断、解析失败）；
/// - 本类负责**下一个内容位置**的起播选源。两者不重叠：这里失败时不会退化成
///   「把当前集重播一遍」，也不会接管播放中失效的决策权。
///
/// 自动连播的三个易错点（都有回归用例）：
/// 1. **迟到事件**：换源/手动选集之后，上一集排队的片尾回调仍可能到达，
///    必须比对当前内容集数，不一致就丢弃，否则会把用户刚点开的新一集直接跳过。
/// 2. **重复推进**：`onEpisodeFinished` 只保证每集一次，但 UI/同步可能重复触发，
///    用 `_inFlight` 串行化，避免两条起播链路争抢同一个播放器。
/// 3. **最后一集**：没有下一集时返回 [QueueAdvanceReason.noNextEpisode] 而不是
///    「重播本集」或「抛异常」——用户此时应该看到的是「已看完」而不是莫名其妙重播。
class PlaybackQueue {
  final PlaybackOrchestrator orchestrator;
  final SourceRegistry registry;
  final SourceCatalog catalog;
  final DiagnosticSink diagnostics;

  /// 自动连播开关（设计稿：可关闭）。关闭后片尾事件仍会推进续播记录，只是不自动换集。
  bool autoNext;

  /// 推进成功/失败后的回调（UI 用于刷新会话与提示）。
  ///
  /// 可变：队列在 `main()` 里构造，UI 在 `initState` 时挂上自己的刷新逻辑，
  /// 避免 core 层反向依赖 Widget。
  void Function(QueueAdvance result)? onAdvanced;

  /// 开关变更的持久化钩子（可空：纯内存演示场景）。
  final Future<void> Function(bool enabled)? persistAutoNext;

  /// 当前平台：决定「下一集能在哪些源上播」（jar 源在桌面端不可用）。
  SourcePlatform platform;

  List<EpisodeInfo> _episodes = const <EpisodeInfo>[];
  PlaybackSession? _current;
  bool _inFlight = false;

  PlaybackQueue({
    required this.orchestrator,
    required this.registry,
    required this.catalog,
    this.diagnostics = const NoopDiagnosticSink(),
    this.autoNext = true,
    this.platform = SourcePlatform.desktop,
    this.onAdvanced,
    this.persistAutoNext,
  });

  /// 当前剧集表（按集数升序，去重）。
  List<EpisodeInfo> get episodes => List<EpisodeInfo>.unmodifiable(_episodes);

  /// 当前会话（null 表示尚未开始播放）。
  PlaybackSession? get current => _current;

  bool get inFlight => _inFlight;

  /// 设置剧集表：排序 + 按集数去重（源站经常返回乱序/重复）。
  void setEpisodes(Iterable<EpisodeInfo> episodes) {
    final byEpisode = <int, EpisodeInfo>{};
    for (final e in episodes) {
      byEpisode.putIfAbsent(e.episode, () => e);
    }
    final sorted = byEpisode.values.toList()
      ..sort((a, b) => a.episode.compareTo(b.episode));
    _episodes = sorted;
  }

  /// 绑定当前会话（每次成功起播/换源后调用），后续片尾事件以此判断归属。
  void attach(PlaybackSession session) => _current = session;

  /// 清空会话（回到搜索页）：保留剧集表，方便用户再次进入时直接连播。
  void detach() => _current = null;

  /// 切换自动连播开关并持久化。
  Future<void> setAutoNext(bool enabled) async {
    if (autoNext == enabled) return;
    autoNext = enabled;
    await persistAutoNext?.call(enabled);
  }

  /// 片尾回调入口：接到 `ProgressReporter.onEpisodeFinished`。
  ///
  /// [canonicalEpisode] 是**规范内容集数**（去广告坐标），与 [PlaybackSession.contentEpisode]
  /// 同口径，因此可以直接比对，不需要反查源画像。
  Future<QueueAdvance> handleEpisodeFinished(int canonicalEpisode) async {
    final s = _current;
    if (s == null) {
      return _result(QueueAdvanceReason.noSession, '没有活跃会话，忽略片尾事件');
    }
    if (!autoNext) {
      return _result(QueueAdvanceReason.disabled, '自动连播已关闭');
    }
    if (canonicalEpisode != s.contentEpisode) {
      // 迟到事件：用户已经换源/手动选集，别把新会话跳过一集。
      return _result(
        QueueAdvanceReason.staleEvent,
        '片尾事件属于第 $canonicalEpisode 集，当前是第 ${s.contentEpisode} 集，已忽略',
      );
    }
    if (_inFlight) {
      return _result(QueueAdvanceReason.busy, '上一次连播仍在进行中');
    }

    final next = _nextEpisodeAfter(canonicalEpisode);
    if (next == null) {
      return _result(
        QueueAdvanceReason.noNextEpisode,
        '已是最后一集（共 ${_episodes.length} 集），不会自动重播',
      );
    }

    _inFlight = true;
    final failures = <String>[];
    try {
      // 优先沿用当前源（连续观看时少一次换源抖动）；它不可用/起播失败再换下一个可用源。
      for (final sourceId in _candidateSources(s.sourceId)) {
        try {
          final session = await orchestrator.startPlayback(
            sourceId: sourceId,
            mediaId: s.mediaId,
            mediaTitle: s.mediaTitle,
            canonicalEpisode: next,
            canonicalSeconds: 0.0,
          );
          _current = session;
          diagnostics.record(DiagnosticEvent(
            kind: DiagnosticKind.autoNextAdvanced,
            at: DateTime.now(),
            sourceId: sourceId,
            mediaId: s.mediaId,
            detail: '自动连播：第 ${s.contentEpisode} 集 → 第 $next 集',
            attributes: <String, Object?>{
              'fromEpisode': s.contentEpisode,
              'toEpisode': next,
              'fromSourceId': s.sourceId,
              'failures': failures.length,
            },
          ));
          final r = QueueAdvance(
            reason: QueueAdvanceReason.advanced,
            session: session,
            nextEpisode: next,
            message: '自动连播：第 $next 集（源 $sourceId）',
          );
          onAdvanced?.call(r);
          return r;
        } on PlaybackFailureException catch (e) {
          failures.add('$sourceId/${e.reason.name}');
        } catch (e) {
          // 源未注册 / 画像缺失属于配置错误，同样不该让整条播放链路崩掉：
          // 记下原因继续尝试下一个源，全部失败后如实返回。
          failures.add('$sourceId/$e');
        }
      }
      final r = QueueAdvance(
        reason: QueueAdvanceReason.failed,
        nextEpisode: next,
        message: '第 $next 集在所有可用源上都起播失败'
            '${failures.isEmpty ? '' : '（${failures.join('、')}）'}',
      );
      diagnostics.record(DiagnosticEvent(
        kind: DiagnosticKind.autoNextFailed,
        at: DateTime.now(),
        mediaId: s.mediaId,
        detail: r.message,
        attributes: <String, Object?>{
          'fromEpisode': s.contentEpisode,
          'toEpisode': next,
          'failures': failures.length,
        },
      ));
      onAdvanced?.call(r);
      return r;
    } finally {
      _inFlight = false;
    }
  }

  /// 下一集：严格大于当前集的最小集数（源站跳集时也能接上）。
  int? _nextEpisodeAfter(int episode) {
    int? best;
    for (final e in _episodes) {
      if (e.episode > episode && (best == null || e.episode < best)) {
        best = e.episode;
      }
    }
    return best;
  }

  /// 候选源顺序：当前源优先 + 当前平台其它可用源（保持注册表顺序）。
  List<String> _candidateSources(String preferred) {
    final available = registry
        .availableOn(platform)
        .map((a) => a.id)
        .where((id) => catalog.get(id) != null)
        .toList();
    if (!available.contains(preferred) &&
        registry.get(preferred) != null &&
        catalog.get(preferred) != null &&
        registry.get(preferred)!.supportedPlatforms.contains(platform)) {
      available.insert(0, preferred);
    } else if (available.remove(preferred)) {
      available.insert(0, preferred);
    }
    return available;
  }

  QueueAdvance _result(QueueAdvanceReason reason, String message) =>
      QueueAdvance(reason: reason, message: message);
}
