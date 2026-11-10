import 'dart:async';

import '../../data/resume_record.dart';
import '../../data/resume_store.dart';
import '../diagnostics/diagnostic_sink.dart';
import '../player/player_controller.dart';
import '../source/source_profile.dart';
import 'alignment.dart';

/// 一次播放的「坐标锚点」：告诉上报器当前播的是哪个源的哪一集、载入点在哪。
///
/// 刻意不直接接收 `PlaybackSession`（那会让本文件反向依赖编排层，形成环）：
/// 锚点自带 [profile]，因为播放中采样到的物理位置必须用**当前源的画像**换算成
/// 内容坐标；换源后若仍用旧画像换算，广告错位会被算进进度里。
class ProgressAnchor {
  final String mediaId;
  final String title;
  final String sourceId;
  final SourceProfile profile;

  /// 当前所在源原始集（含偏移）。
  final int rawEpisode;

  /// 载入时的源原始秒数（含广告）。
  final double rawSeconds;

  const ProgressAnchor({
    required this.mediaId,
    required this.title,
    required this.sourceId,
    required this.profile,
    required this.rawEpisode,
    required this.rawSeconds,
  });
}

/// 落盘节流策略。
///
/// 三个参数各挡一类问题，缺一不可：
/// - [minInterval]：`FileResumeStore` 是原子写（tmp→bak→转正），每 200ms 写一次会打满磁盘；
/// - [minDeltaSeconds]：播放器位置抖动/缓冲回跳会产生 ±1s 的噪声，不该当成「新进度」；
/// - [tickInterval]：采样频率本身，低于落盘频率才有意义（否则每次采样都在写盘）。
class ProgressPolicy {
  final Duration tickInterval;
  final Duration minInterval;
  final double minDeltaSeconds;

  const ProgressPolicy({
    this.tickInterval = const Duration(seconds: 5),
    this.minInterval = const Duration(seconds: 10),
    this.minDeltaSeconds = 5,
  });
}

/// 片尾判定策略（E6）。
///
/// 为什么必须有：没有它，「看到最后一分钟退出」会把续播点写成「本集末尾」，
/// 下次进来又从字幕里开始播——用户看到的是「续播坏了」，而日志一切正常。
///
/// 两个阈值各挡一类误判：
/// - [tailSeconds]：距结尾多少秒算「已看完」。设太小（如 10s）挡不住用户
///   在片尾字幕里退出；设太大（如 300s）会把「还有 4 分钟没看」判成看完。
/// - [minEpisodeSeconds]：把预告、花絮、短视频排除在外。这类内容本来就只有
///   一两分钟，任何「距结尾小于 90s」的规则都会把它们判成已看完。
class EndingPolicy {
  final double tailSeconds;
  final double minEpisodeSeconds;

  const EndingPolicy({
    this.tailSeconds = 90,
    this.minEpisodeSeconds = 300,
  });

  /// 本集内容时长是否足够长到可以做片尾判定（0 / 未知一律不判）。
  bool appliesTo(double contentDurationSeconds) =>
      contentDurationSeconds >= minEpisodeSeconds;

  /// 该位置是否已进入片尾区。
  bool inTail(double contentDurationSeconds, double contentSeconds) =>
      contentDurationSeconds - contentSeconds <= tailSeconds;
}

/// 跳过落盘的原因（UI/诊断可区分「没在播」与「被节流」，避免误判为故障）。
enum ProgressSkip {
  /// 没有活跃会话（未开始播放或已停止）。
  noSession,

  /// 位置未实质前进（暂停中、刚载入、或抖动小于阈值）。
  noAdvance,

  /// 距上次成功落盘不足 [ProgressPolicy.minInterval]。
  throttled,

  /// 播放器给不出可信位置（NaN/无穷/负数/抛异常）。
  invalidPosition,

  /// 已在片尾区且「已看完」已记过，不再把位置往片尾刷（保持 finished 记录稳定）。
  ending,
}

/// 一次采样的结果。[skip] 为 null 表示已提交写入（等待写入完成）。
class ProgressTick {
  final ProgressSkip? skip;
  final int contentEpisode;
  final double contentSeconds;
  final bool persisted;

  /// 本次采样是否判定为「本集看完」（片尾判定命中）。
  final bool finished;

  /// 本集内容时长（秒）；0 表示内核没给时长，片尾判定未参与。
  final double contentDuration;

  const ProgressTick({
    this.skip,
    this.contentEpisode = 0,
    this.contentSeconds = 0,
    this.persisted = false,
    this.finished = false,
    this.contentDuration = 0,
  });

  bool get skipped => skip != null;

  @override
  String toString() => skipped
      ? 'ProgressTick.skip(${skip!.name})'
      : 'ProgressTick.saved(ep=$contentEpisode, ${contentSeconds.toStringAsFixed(1)}s'
          '${finished ? ', 本集看完' : ''})';
}

/// 播放中进度上报（E6 跨端续播的缺失一环）。
///
/// 背景：此前编排层只在 `load` 那一刻写一次续播记录，`PlayerController.currentRawSeconds()`
/// **从未被任何代码调用** —— 也就是说「续播」存下来的永远是「这一集的起点」，
/// 用户看了 40 分钟再换端，另一台设备依然从起点开始。本类补上播放中的数据流。
///
/// 四个必须做对的点（都有对应回归用例）：
/// 1. **坐标换算**：采样值是该源的物理秒数（含广告），落盘前必须用锚点画像 [rawToContent]
///    转成规范内容坐标，否则跨源/跨端会带着广告偏移漂移。
/// 2. **不乱写**：未前进（暂停/刚载入）不写、位移不足不写、间隔不足不写；
///    否则刚打开就落盘会把上次的 40 分钟覆盖成 0。
/// 3. **写入串行 + 合并**：慢盘上并发写会让先发的旧位置后落盘、覆盖新位置。
///    这里用单写者 + 待写槽（只保留最新一帧）串行化，队列长度恒定为 1。
/// 4. **换源护栏**：`begin` 先把旧会话写入排空（等在飞的那一帧落地）再递增 epoch；
///    切换时刻之后仍在排队的旧帧一律丢弃。结论是「旧位置要么先落地、要么被丢弃，
///    绝不会晚于新位置落地」—— 反过来就会让刚切换的新记录被旧源坐标覆盖。
/// 5. **片尾判定**：距结尾不足 [EndingPolicy.tailSeconds] 时记「本集看完」而不是
///    「末尾第 2680 秒」。少了这一步，用户看完一集再换端，会被送回片尾字幕。
class ProgressReporter {
  final PlayerController player;
  final ResumeStore store;
  final DiagnosticSink diagnostics;
  final ProgressPolicy policy;
  final EndingPolicy ending;
  final DateTime Function() _now;

  /// 片尾判定命中时回调一次（每集一次）。供「自动连播」等上层能力消费。
  final void Function(int canonicalEpisode)? onEpisodeFinished;

  /// 为 true 时 `begin` 自动起定时采样（生产用）；回归脚本传 false 手动 `tick`。
  final bool autoTick;

  ProgressAnchor? _anchor;
  Timer? _timer;

  /// 会话代号：每次 `begin` 递增，迟到的旧会话写入靠它作废。
  int _epoch = 0;

  /// 已确认落盘的内容坐标（也作为「是否前进」的基准，初值为锚点位置）。
  int _savedEpisode = 0;
  double _savedSeconds = 0;
  DateTime? _savedAt;
  ResumeRecord? _lastSaved;

  /// 本集原始时长缓存（0 表示未知，会重试读取；读到有效值后不再重读）。
  double _rawDuration = 0;

  /// 时长读取尝试次数上限：`file-loaded` 之前读不到是常态，
  /// 但直播流永远读不到，无限重试等于每 5s 白打一次原生调用。
  int _durationTries = 0;

  /// 已记过「看完」的集（规范集数）；同一集不重复写 finished，也不回吞位置。
  int? _finishedEpisode;

  bool _degraded = false;
  bool _writing = false;
  ResumeRecord? _pending;
  int _pendingEpoch = 0;
  Future<void> _chain = Future<void>.value();

  ProgressReporter({
    required this.player,
    required this.store,
    this.diagnostics = const NoopDiagnosticSink(),
    this.policy = const ProgressPolicy(),
    this.ending = const EndingPolicy(),
    this.onEpisodeFinished,
    this.autoTick = true,
    DateTime Function()? clock,
  }) : _now = clock ?? DateTime.now;

  /// 时长读取的最多尝试次数（每 tick 至多一次）。
  static const int _maxDurationTries = 8;

  ProgressAnchor? get anchor => _anchor;

  /// 最近一次确认落盘的记录（null 表示本次会话尚未成功落盘）。
  ResumeRecord? get lastSaved => _lastSaved;

  /// 写入是否降级（落盘失败后置位，供 UI/诊断提示「进度可能未保存」）。
  bool get degraded => _degraded;

  /// 开始/切换一个播放会话。
  ///
  /// [flushPrevious] 默认 true：先把旧会话的当前位置落盘再切锚点（顺序颠倒会丢最后几分钟）。
  /// **调用方若已自行 flush 过**（例如编排层在换源入口先落盘），必须传 false ——
  /// 否则这次「兜底 flush」会在新会话记录已写入之后，用旧源坐标把它覆盖回旧源。
  Future<void> begin(ProgressAnchor anchor, {bool flushPrevious = true}) async {
    if (flushPrevious) await flush();
    _epoch++;
    _anchor = anchor;
    final c = rawToContent(anchor.profile, anchor.rawEpisode, anchor.rawSeconds);
    _savedEpisode = c.$1;
    _savedSeconds = c.$2;
    _savedAt = null;
    _lastSaved = null;
    // 新会话必读新时长：上一集的时长沿用到本集会让片尾判定按错误的结尾算。
    _rawDuration = 0;
    _durationTries = 0;
    _finishedEpisode = null;
    if (autoTick) {
      _timer?.cancel();
      _timer = Timer.periodic(policy.tickInterval, (_) {
        // 定时采样不等待：写盘串行化后，重叠采样最多产生一次合并写入。
        unawaited(tick());
      });
    }
  }

  /// 采样一次并按策略决定是否落盘。
  ///
  /// [force] 忽略节流（暂停、切源、退到后台、退出前必须用它），但仍做坐标换算与合法性校验。
  Future<ProgressTick> tick({bool force = false}) async {
    final a = _anchor;
    if (a == null) return const ProgressTick(skip: ProgressSkip.noSession);

    double raw;
    try {
      raw = await player.currentRawSeconds();
    } catch (_) {
      return const ProgressTick(skip: ProgressSkip.invalidPosition);
    }
    if (raw.isNaN || raw.isInfinite || raw < 0) {
      return const ProgressTick(skip: ProgressSkip.invalidPosition);
    }

    final c = rawToContent(a.profile, a.rawEpisode, raw);
    final ep = c.$1;
    final sec = c.$2;

    final durRaw = await _resolveRawDuration();
    final dur = durRaw <= 0
        ? 0.0
        : rawToContent(a.profile, a.rawEpisode, durRaw).$2;

    // 片尾判定（先于节流）：进片尾区后要写的是「本集看完」，而不是「末尾秒数」。
    if (dur > 0 && ending.appliesTo(dur) && ending.inTail(dur, sec)) {
      if (_finishedEpisode == ep) {
        // 已看过这一集的片尾：不再往结尾刷位置，保持记录里的「看完」语义稳定。
        return ProgressTick(
          skip: ProgressSkip.ending,
          contentEpisode: ep,
          contentSeconds: sec,
          finished: true,
          contentDuration: dur,
        );
      }
      _finishedEpisode = ep;
      final record = ResumeRecord(
        mediaId: a.mediaId,
        title: a.title,
        sourceId: a.sourceId,
        canonicalEpisode: ep,
        canonicalSeconds: dur,
        finished: true,
        updatedAt: _now(),
      );
      final epoch = _epoch;
      await _enqueue(record, epoch);
      final persisted = epoch == _epoch &&
          _savedEpisode == ep &&
          (_savedSeconds - dur).abs() < 0.001;
      if (persisted) {
        // 事件与回调都只在**确认落盘之后**发：写盘失败时每 5s 重试一次，
        // 若在尝试时就上报，一次磁盘故障会刷出一串「本集看完」，把日志冲掉。
        diagnostics.record(DiagnosticEvent(
          kind: DiagnosticKind.episodeFinished,
          at: _now(),
          sourceId: a.sourceId,
          mediaId: a.mediaId,
          detail: '片尾判定命中，本集标记为已看完',
          attributes: <String, Object?>{
            'canonicalEpisode': ep,
            'contentSeconds': sec,
            'contentDuration': dur,
            'tailSeconds': ending.tailSeconds,
          },
        ));
        onEpisodeFinished?.call(ep);
      } else if (epoch == _epoch) {
        // 写失败/被合并 → 别把「已看完」当成既成事实，否则磁盘恢复后也不会补写。
        _finishedEpisode = null;
      }
      return ProgressTick(
        contentEpisode: ep,
        contentSeconds: dur,
        persisted: persisted,
        finished: true,
        contentDuration: dur,
      );
    }

    // 从片尾区退回中段（用户回看）：允许重新写「未看完」的记录。
    if (_finishedEpisode == ep && (dur <= 0 || !ending.inTail(dur, sec))) {
      _finishedEpisode = null;
    }
    if (!force) {
      // 集内位移不足：暂停中、刚载入、抖动都属于这一类，不能当成新进度。
      if (ep == _savedEpisode &&
          (sec - _savedSeconds).abs() < policy.minDeltaSeconds) {
        return ProgressTick(
            skip: ProgressSkip.noAdvance, contentEpisode: ep, contentSeconds: sec);
      }
      final at = _savedAt;
      if (at != null && _now().difference(at) < policy.minInterval) {
        return ProgressTick(
            skip: ProgressSkip.throttled, contentEpisode: ep, contentSeconds: sec);
      }
    }

    final record = ResumeRecord(
      mediaId: a.mediaId,
      title: a.title,
      sourceId: a.sourceId,
      canonicalEpisode: ep,
      canonicalSeconds: sec,
      updatedAt: _now(),
    );
    final epoch = _epoch;
    await _enqueue(record, epoch);
    final persisted = epoch == _epoch &&
        _savedEpisode == ep &&
        (_savedSeconds - sec).abs() < 0.001;
    return ProgressTick(
        contentEpisode: ep, contentSeconds: sec, persisted: persisted);
  }

  /// 取本集原始时长；未知时返回 0（片尾判定不参与）。
  ///
  /// 为什么要缓存：`file-loaded` 之前内核读不到时长是常态，同一个会话里
  /// 每 5s 都去问一次原生层纯属浪费；但要**允许重试有限次**——刚载入时读不到、
  /// 两秒后就有的情况非常常见，一次性判死会让片尾判定整场失效。
  Future<double> _resolveRawDuration() async {
    if (_rawDuration > 0) return _rawDuration;
    if (_durationTries >= _maxDurationTries) return 0;
    _durationTries++;
    try {
      final d = await player.duration();
      if (d.isFinite && d > 0) _rawDuration = d;
    } catch (_) {
      // 读时长失败不能影响进度落盘：降级为「未知时长」，其余逻辑照常。
    }
    return _rawDuration;
  }

  /// 立即落盘并等待写完（暂停/切源/退后台/退出前调用）。
  /// 即使锚点已被 [dispose] 清空，也要等**在飞的写入**落地：`dispose` 是同步的，
  /// 它发起的 flush 稍后才真正写盘；下一次 `begin` 若不等它，就会与它抢同一个 key。
  Future<void> flush() async {
    if (_anchor != null) await tick(force: true);
    await _chain;
  }

  /// 停止采样。[flush] 为 true 时先把当前位置写盘。
  Future<void> stop({bool flush = true}) async {
    _timer?.cancel();
    _timer = null;
    if (flush) await this.flush();
    _anchor = null;
  }

  /// 释放（Widget `dispose` 等同步场景）：取消定时器并尽力落盘一次。
  ///
  /// 同步接口拿不到 await，因此写盘结果无法回传；需要确定性收尾请用 [stop]。
  void dispose() {
    _timer?.cancel();
    _timer = null;
    unawaited(this.flush());
    _anchor = null;
  }

  /// 单写者 + 待写槽：队列长度恒定为 1，永远不会出现旧位置覆盖新位置。
  Future<void> _enqueue(ResumeRecord record, int epoch) {
    if (_writing) {
      _pending = record;
      _pendingEpoch = epoch;
      return _chain;
    }
    _writing = true;
    _chain = _drain(record, epoch);
    return _chain;
  }

  Future<void> _drain(ResumeRecord first, int firstEpoch) async {
    var current = first;
    var epoch = firstEpoch;
    try {
      while (true) {
        // epoch 不匹配说明已经切到别的会话，这一帧属于上一个源，必须丢弃。
        if (epoch == _epoch) {
          try {
            await store.save(current);
            if (epoch == _epoch) {
              _lastSaved = current;
              _savedEpisode = current.canonicalEpisode;
              _savedSeconds = current.canonicalSeconds;
              _savedAt = _now();
            }
          } catch (e) {
            _degraded = true;
            diagnostics.record(DiagnosticEvent(
              kind: DiagnosticKind.progressWriteFailed,
              at: _now(),
              sourceId: _anchor?.sourceId ?? '',
              mediaId: current.mediaId,
              detail: '续播进度落盘失败：$e',
              attributes: <String, Object?>{
                'canonicalEpisode': current.canonicalEpisode,
                'canonicalSeconds': current.canonicalSeconds,
              },
            ));
          }
        }
        final next = _pending;
        if (next == null) break;
        _pending = null;
        current = next;
        epoch = _pendingEpoch;
      }
    } finally {
      _writing = false;
    }
  }
}
