/// 投屏会话（R12c）：一次投屏从「起播成功」到「结束投屏」之间的**所有换源重下发**。
///
/// 为什么必须单独抽出来：`CastFallbackController.startCast` 是一次性动作
/// （发现 → 连接 → 起播 → 首帧）。直播换台、点播换线路却是**长生命周期**的，
/// 每次重发都重新发现设备既慢（5 秒预算直接爆掉）又不稳（设备可能被同名
/// 另一个 IP 抢走）。会话把「已经确认的那台设备 + 已选定的模式 + 已在跑的
/// 中继」保留下来，重发只剩一次 `SetAVTransportURI + Play`。
///
/// 三条设计铁律：
/// 1. **后发先至压制**：[retarget] 串行执行且带 epoch。用户连按「下一个台」时，
///    前一次还没等完起播信号就已经作废，绝不能让旧台的结果覆盖新台的状态
///    （旧结果会让 UI 显示 A 台而电视在放 B 台）。
/// 2. **中继不能想当然复用**：中继在启动时把鉴权头固定注入，换台若换了源站
///    （或该线路的 headers 不同），继续用旧中继就是把上一路的 Referer 发给新源站，
///    轻则 403、重则串到别人的授权内容。所以 headers/sourceId 变了一定重启中继。
/// 3. **直播不拿「未确认」当失败**：直播流没有时长，设备上报位置常恒为 0，
///    首帧几乎必然是 [CastStartSignal.playingUnverified]。把它当失败会让每次
///    换台都报一次错并降级回本机 —— 比原来的问题更糟。只有设备**明确拒绝**
///    （`play` 返回 false）或传输状态回到停止，才切模式重试。
library;

import '../diagnostics/diagnostic_sink.dart';
import 'cast_fallback.dart';
import 'cast_metrics.dart';
import 'cast_mode.dart';
import 'relay/relay_session.dart';

/// 一次重下发的结局。
enum CastRetargetOutcome {
  /// 设备接受了新地址（可能只是「自称在播」，见 [CastRetargetResult.signal]）。
  accepted,

  /// 换了个模式才成功（直推→串流，或串流→直推）。
  acceptedAfterSwitch,

  /// 两种模式都没成：投屏侧已经无法继续。调用方应结束投屏并给出可执行提示。
  failed,

  /// 期间用户又换了台，本次结果已过期 —— **不是错误**，不要弹任何提示。
  superseded,

  /// 会话已结束（用户点了「结束投屏」），一律忽略。
  inactive,

  /// 参数不合法（空地址 / 非 http(s)），不下发，避免把垃圾推给电视。
  rejected,
}

class CastRetargetResult {
  const CastRetargetResult({
    required this.outcome,
    required this.url,
    required this.mode,
    required this.signal,
    required this.attempts,
    required this.elapsedMillis,
  });

  final CastRetargetOutcome outcome;

  /// 本次实际交给设备的地址（串流模式下是**中继地址**，不是上游地址）。
  final String url;

  final CastMode mode;
  final CastStartSignal signal;
  final List<String> attempts;
  final int elapsedMillis;

  /// 是否算「电视那边已经换过去了」。
  bool get ok =>
      outcome == CastRetargetOutcome.accepted ||
      outcome == CastRetargetOutcome.acceptedAfterSwitch;

  /// 是否应该结束投屏（失败）。过期/无权的情况不该被当成故障。
  bool get shouldStopCasting => outcome == CastRetargetOutcome.failed;

  /// 是否换了模式（UI 需要更新「直推 / 串流」这一行）。
  bool get switchedMode => outcome == CastRetargetOutcome.acceptedAfterSwitch;

  @override
  String toString() =>
      'CastRetarget(${outcome.name}, ${mode.name}, ${signal.name}, ${elapsedMillis}ms)';
}

/// 投屏会话：持有「已连接的那台设备」与「当前模式」。
class CastSession {
  CastSession({
    required CastTransport transport,
    required CastDevice device,
    required CastMode mode,
    required CastModeReason modeReason,
    String sourceId = '',
    Map<String, String> headers = const <String, String>{},
    CastRelaySession? relay,
    CastRelayFactory? relayFactory,
    DiagnosticSink diagnostics = const NoopDiagnosticSink(),
  })  : _transport = transport,
        _device = device,
        _mode = mode,
        _modeReason = modeReason,
        _sourceId = sourceId,
        _headers = Map<String, String>.from(headers),
        _relay = relay,
        _relayFactory = relayFactory,
        _diagnostics = diagnostics;

  /// 由一次成功的 [CastResult] 建立会话。
  ///
  /// [relay] 来自 `CastResult.relay` —— 中继必须由会话持有而不是界面字段：
  /// 界面重建（切栏、旋转、热重载）会把字段丢掉，电视立刻断流。
  factory CastSession.fromResult(
    CastResult result, {
    required CastTransport transport,
    CastRelayFactory? relayFactory,
    DiagnosticSink diagnostics = const NoopDiagnosticSink(),
  }) {
    return CastSession(
      transport: transport,
      device: result.device ??
          CastDevice(id: 'unknown', name: '投屏设备'),
      mode: result.mode,
      modeReason: result.modeReason,
      relay: result.relay,
      relayFactory: relayFactory,
      diagnostics: diagnostics,
    );
  }

  final CastTransport _transport;
  final CastDevice _device;
  final CastRelayFactory? _relayFactory;
  final DiagnosticSink _diagnostics;

  CastMode _mode;
  CastModeReason _modeReason;
  String _sourceId;
  Map<String, String> _headers;
  CastRelaySession? _relay;

  /// 串行队列的队尾：保证同一时刻只有一次重下发在跑。
  Future<void> _tail = Future<void>.value();

  int _epoch = 0;
  bool _closed = false;

  CastRetargetResult? _last;
  int _retargetCount = 0;

  CastMode get mode => _mode;
  CastModeReason get modeReason => _modeReason;
  CastDevice get device => _device;
  bool get isActive => !_closed;
  CastRelaySession? get relay => _relay;
  CastRetargetResult? get lastResult => _last;

  /// 已经重下发过多少次（诊断用：一次投屏里换台太频繁多半有问题）。
  int get retargetCount => _retargetCount;

  /// 换源重下发：把新地址推给同一台设备。
  ///
  /// [url] 是**上游**地址（不是中继地址）；串流模式下由会话自己包一层。
  /// [positionSeconds] 对直播传 0；点播换线路时传当前物理位置。
  Future<CastRetargetResult> retarget({
    required String url,
    Map<String, String> headers = const <String, String>{},
    String sourceId = '',
    double positionSeconds = 0,
    Duration? firstFrameTimeout,
  }) async {
    if (_closed) {
      return CastRetargetResult(
        outcome: CastRetargetOutcome.inactive,
        url: url,
        mode: _mode,
        signal: CastStartSignal.failed,
        attempts: const <String>['投屏已结束'],
        elapsedMillis: 0,
      );
    }
    if (!_isPlayableUrl(url)) {
      return CastRetargetResult(
        outcome: CastRetargetOutcome.rejected,
        url: url,
        mode: _mode,
        signal: CastStartSignal.failed,
        attempts: const <String>['地址不合法，未下发'],
        elapsedMillis: 0,
      );
    }

    final myEpoch = ++_epoch;
    // 串行化：前一次重下发必须彻底收尾，后一次才开始 —— 否则两次
    // `SetAVTransportURI` 会交错，设备上最终播哪一路取决于网络时序。
    //
    // epoch 必须在**调用时**就自增（而不是排队轮到时），这样队列里已经作废的
    // 旧请求进入 `_runGuarded` 后第一个检查点就退出，不会白推一次旧台。
    final prev = _tail;
    final done = prev.then((_) => _runGuarded(myEpoch, url, headers, sourceId,
        positionSeconds, firstFrameTimeout));
    // `_tail` 只用于排队，不透传结果也不透传异常（否则一次失败会卡死后续所有换台）。
    _tail = done.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    final result = await done;
    _markDone(result);
    return result;
  }

  void _markDone(CastRetargetResult r) {
    // 只有最新一次的结果才有资格成为「当前状态」。
    if (r.outcome == CastRetargetOutcome.superseded ||
        r.outcome == CastRetargetOutcome.inactive) {
      return;
    }
    _last = r;
    if (r.ok) _retargetCount++;
  }

  Future<CastRetargetResult> _runGuarded(
    int myEpoch,
    String url,
    Map<String, String> headers,
    String sourceId,
    double positionSeconds,
    Duration? firstFrameTimeout,
  ) async {
    if (_closed) {
      return _superseded(url, const <String>['投屏已结束']);
    }
    if (myEpoch != _epoch) {
      return _superseded(url, const <String>['已被更新的换台请求取代']);
    }
    final watch = Stopwatch()..start();
    final attempts = <String>[];
    var mode = _mode;

    for (var round = 0; round < 2; round++) {
      if (myEpoch != _epoch || _closed) {
        return _superseded(url, attempts);
      }
      final target = await _targetFor(mode, url, headers, sourceId, attempts);
      if (myEpoch != _epoch || _closed) return _superseded(url, attempts);
      if (target == null) {
        // 中继起不来：不当作重下发失败，退回直推再试一次（宁可试一次）。
        attempts.add('串流中继不可用，改为直推');
        mode = CastMode.direct;
        continue;
      }

      final played = await _play(target, positionSeconds);
      if (myEpoch != _epoch || _closed) return _superseded(url, attempts);
      if (!played) {
        attempts.add('${_modeLabel(mode)}下发被设备拒绝');
        await _switchModeAwayFrom(mode);
        mode = mode == CastMode.direct ? CastMode.relay : CastMode.direct;
        // 已切模式：下一轮必须重建目标地址（串流要新起的 baseUri）。
        continue;
      }

      final signal = await _awaitSignal(mode, firstFrameTimeout);
      if (myEpoch != _epoch || _closed) return _superseded(url, attempts);
      watch.stop();
      if (signal == CastStartSignal.failed) {
        attempts.add('${_modeLabel(mode)}未出图（设备已停止）');
        await _switchModeAwayFrom(mode);
        mode = mode == CastMode.direct ? CastMode.relay : CastMode.direct;
        continue;
      }

      _mode = mode;
      _modeReason = signal == CastStartSignal.confirmed
          ? (mode == CastMode.relay
              ? CastModeReason.relayConfirmed
              : CastModeReason.probeOk)
          : _modeReason;
      _headers = Map<String, String>.from(headers);
      _sourceId = sourceId;
      _diagnostics.record(DiagnosticEvent(
        kind: DiagnosticKind.castStarted,
        at: DateTime.now(),
        mediaId: url,
        detail: '投屏换源重下发（${mode.name}/${signal.name}）',
        attributes: <String, Object?>{
          'deviceId': _device.id,
          'mode': mode.name,
          'signal': signal.name,
          'elapsedMillis': watch.elapsedMilliseconds,
          'positionSeconds': positionSeconds,
        },
      ));
      return CastRetargetResult(
        outcome: round == 0
            ? CastRetargetOutcome.accepted
            : CastRetargetOutcome.acceptedAfterSwitch,
        url: target,
        mode: mode,
        signal: signal,
        attempts: List<String>.unmodifiable(attempts),
        elapsedMillis: watch.elapsedMilliseconds,
      );
    }

    watch.stop();
    _diagnostics.record(DiagnosticEvent(
      kind: DiagnosticKind.castFallback,
      at: DateTime.now(),
      mediaId: url,
      detail: '换源重下发失败，投屏无法继续',
      attributes: <String, Object?>{
        'deviceId': _device.id,
        'attempts': attempts.length,
        'mode': mode.name,
      },
    ));
    return CastRetargetResult(
      outcome: CastRetargetOutcome.failed,
      url: url,
      mode: mode,
      signal: CastStartSignal.failed,
      attempts: List<String>.unmodifiable(attempts),
      elapsedMillis: watch.elapsedMilliseconds,
    );
  }

  /// 计算本次要交给设备的地址；串流模式下必要时重启中继。
  Future<String?> _targetFor(
    CastMode mode,
    String url,
    Map<String, String> headers,
    String sourceId,
    List<String> attempts,
  ) async {
    if (mode == CastMode.direct) {
      // 已经不需要中继了（上一轮刚从串流切回直推）：立刻关掉，别白烧流量。
      await _dropRelay();
      return url;
    }
    final needNew = _relay == null ||
        !_sameHeaders(headers, _headers) ||
        sourceId != _sourceId;
    if (needNew) {
      final factory = _relayFactory;
      if (factory == null) return null;
      // 先停旧的再起新的：两个中继同时活着会各自占一个端口，而且旧的那个
      // 还在用上一路的鉴权头服务——留着只有风险没有收益。
      await _dropRelay();
      try {
        final started = await factory(headers);
        if (started == null) {
          attempts.add('本机没有可用局域网地址，无法串流');
          return null;
        }
        _relay = started;
        final base = started.baseUri;
        attempts.add(base == null
            ? '串流中继已启动（地址未就绪）'
            : '串流中继已重启：${base.host}:${base.port}');
      } catch (err) {
        attempts.add('串流中继启动失败：$err');
        return null;
      }
    }
    final relayed = _relay?.relayUrlFor(url);
    if (relayed == null) {
      attempts.add('串流地址生成失败');
      return null;
    }
    return relayed;
  }

  /// 切换模式时必须把「旧模式的产物」清掉，否则失败的那条路还在后台跑。
  Future<void> _switchModeAwayFrom(CastMode from) async {
    if (from == CastMode.relay) {
      await _dropRelay();
    }
  }

  Future<bool> _play(String url, double positionSeconds) async {
    try {
      return await _transport.play(url: url, positionSeconds: positionSeconds);
    } catch (_) {
      return false;
    }
  }

  Future<CastStartSignal> _awaitSignal(CastMode mode, Duration? override) async {
    try {
      return await _transport.awaitStartSignal(
        timeout: override ??
            (mode == CastMode.relay
                ? CastBudgets.relayFirstFrame
                : CastBudgets.directFirstFrame),
        pollInterval: CastBudgets.progressPoll,
      );
    } catch (_) {
      // 读不到信号不等于没出图（直播常态）：保持投屏，别谎报失败。
      return CastStartSignal.playingUnverified;
    }
  }

  /// 结束投屏：停中继、断开设备。可重复调用。
  Future<void> stop() async {
    if (_closed) return;
    _closed = true;
    _epoch++;
    await _dropRelay();
    try {
      await _transport.disconnect();
    } catch (_) {
      // 断不开也不影响本机播放。
    }
  }

  Future<void> _dropRelay() async {
    final r = _relay;
    _relay = null;
    if (r == null) return;
    try {
      await r.stop();
    } catch (_) {
      // 停不掉时 socket 随进程释放。
    }
  }

  CastRetargetResult _superseded(String url, List<String> attempts) {
    return CastRetargetResult(
      outcome: _closed ? CastRetargetOutcome.inactive : CastRetargetOutcome.superseded,
      url: url,
      mode: _mode,
      signal: CastStartSignal.playingUnverified,
      attempts: List<String>.unmodifiable(attempts),
      elapsedMillis: 0,
    );
  }

  static bool _sameHeaders(
    Map<String, String> a,
    Map<String, String> b,
  ) {
    if (a.length != b.length) return false;
    for (final e in a.entries) {
      if (b[e.key] != e.value) return false;
    }
    return true;
  }

  /// 只放行 http/https 绝对地址，且**必须带主机名**。
  ///
  /// 设备端会把这个字符串原样交给它的播放器：`file://` 可能让它去读自己的
  /// 本地文件，`ms-cast://` 这类私有 scheme 则是「看起来成功、实际没内容」。
  /// `http://` 这种「有 scheme 有 `//` 但没有主机名」的串同样要拦：
  /// `hasAuthority` 对它为 true，可电视拿到它只会进错误态。
  static bool _isPlayableUrl(String url) {
    if (url.isEmpty) return false;
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasAuthority || uri.host.isEmpty) return false;
    return uri.scheme == 'http' || uri.scheme == 'https';
  }

  static String _modeLabel(CastMode mode) =>
      mode == CastMode.relay ? '串流' : '直推';
}

/// 直播换台时是否需要向投屏设备重下发（R12c 的判定唯一出处）。
///
/// 抽成纯函数而不是散在 UI 的 `if` 里，是因为这四个条件缺一不可，
/// 而每一种缺失都会对应一种真实故障：
/// * 未在投屏 → 重下发等于偷偷把画面推到电视上；
/// * 还没真出图（`playing` 为 false）→ 推的是「正在连接」的中间态线路，
///   等真出图后还得再推一次，白折腾电视；
/// * 地址为空 → DLNA 会收到空 `CurrentURI`，某些电视直接进入错误态；
/// * 与上次已推送的地址相同 → 看门狗/健康度回写会反复触发同一台，
///   导致电视被反复 `SetAVTransportURI`，画面每次都从头缓冲。
bool shouldRetargetLiveCast({
  required bool casting,
  required bool playing,
  required String? streamUrl,
  required String? lastSentUrl,
}) {
  if (!casting) return false;
  if (!playing) return false;
  if (streamUrl == null || streamUrl.isEmpty) return false;
  return streamUrl != lastSentUrl;
}
