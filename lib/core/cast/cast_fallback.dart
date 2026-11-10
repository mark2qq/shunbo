/// 投屏兜底（E5 体验，闭合评估报告点名的「投屏与源全失效的兜底 UX 不足」）。
///
/// 设计铁律（与 E7 自动换源一致）：
/// - 投屏控制器**只上报失效与物理坐标，不决定内容语义**。降级结果携带的是
///   **源原始坐标**（rawEpisode / rawSeconds），由调度层用 `rawToContent` 换算回
///   规范内容坐标后重新 `startPlayback` —— 绝不把投屏设备的含广告位置直接当内容进度。
/// - 任何失败路径都必须给出「可继续看」的结果：切回本机播放且进度不丢失，
///   不留「投屏失败 → 黑屏/无路可走」的死路。
/// - 进度只许前进不许倒退：设备上报位置比本地已知位置更小时，保留本地位置。
library;

import '../diagnostics/diagnostic_sink.dart';
import 'cast_metrics.dart';
import 'cast_mode.dart';
import 'relay/relay_session.dart';

enum CastPhase {
  idle,
  discovering,
  connecting,
  casting,

  /// 已起播，但走的是本机中继（R12b 的「串流」模式）。
  relaying,
  failed,
  localFallback,
}

/// 「不带鉴权头取一次」的探测：返回 HTTP 状态码，null 表示探测本身失败。
///
/// 探测失败**不**用来判定「必须串流」：一次网络抖动不该把一个源永久记成 relay。
typedef CastUrlStatusProbe = Future<int?> Function(String url);

/// 读该源记忆的投屏模式。
typedef CastModeReader = Future<CastMode?> Function(String key);

/// 写该源记忆的投屏模式。
typedef CastModeWriter = Future<void> Function(String key, CastMode mode);

enum CastFailureReason {
  noDevice,
  connectFailed,
  playbackError,
  connectionLost,

  /// 用户主动点「结束投屏回到本机」：不是故障，文案不该说「连接中断」。
  userStopped,
}

class CastDevice {
  final String id;
  final String name;
  final String protocol;

  const CastDevice({
    required this.id,
    required this.name,
    this.protocol = 'dlna',
  });
}

/// 起播信号：`play()` 成功只说明**控制指令被接受**，不代表设备真的解出了画面。
///
/// 这个区分是本轮的核心：防盗链源上 DLNA 的 `Play` 照样回 200，屏幕却是黑的。
/// 三档而不是 bool，是因为「未确认」和「确认失败」要区别对待 —— 把
/// 「电视没告诉我们位置」（直播流常见）当成失败，会让本来正常出图的投屏
/// 被误判成故障并强行降级，比原问题更糟。
enum CastStartSignal {
  /// 有客观证据：位置在前进，或传输状态由暂停/停止切实转成了播放。
  confirmed,

  /// 设备自称在播、但拿不到位置（直播流常态）。既不能断言有图，也不能断言没图。
  playingUnverified,

  /// 明确失败：设备回到停止/无媒体状态，或位置不前进且状态异常。
  failed,
}

/// 投屏传输抽象。真实实现：DLNA / Chromecast / 厂商私有协议；
/// 验证用 [FakeCastTransport]，纯 Dart 不依赖平台通道。
abstract class CastTransport {
  Future<List<CastDevice>> discover();
  Future<bool> connect(String deviceId);
  Future<bool> play({required String url, required double positionSeconds});
  Future<double> currentPositionSeconds();
  Future<void> disconnect();

  /// 观察起播信号（R12b 的「首帧」判定）。
  ///
  /// 默认实现基于位置前进：这对点播流足够，对直播流会返回
  /// [CastStartSignal.playingUnverified]（直播没有时长，位置常常恒为 0），
  /// 具体实现（如 DLNA）应覆写它以补充「传输状态跃迁」这一条证据。
  Future<CastStartSignal> awaitStartSignal({
    Duration timeout = const Duration(seconds: 5),
    Duration pollInterval = const Duration(milliseconds: 300),
  }) async {
    final watch = Stopwatch()..start();
    double baseline;
    try {
      baseline = await currentPositionSeconds();
    } catch (_) {
      baseline = 0;
    }
    while (watch.elapsed < timeout) {
      await Future<void>.delayed(pollInterval);
      double now;
      try {
        now = await currentPositionSeconds();
      } catch (_) {
        continue;
      }
      if (now.isFinite && now - baseline >= 0.5) return CastStartSignal.confirmed;
    }
    return CastStartSignal.playingUnverified;
  }
}

/// 投屏结果。降级时 [rawEpisode]/[rawSeconds] 是交给调度层换算的**权威物理坐标**。
class CastResult {
  final bool casting;
  final CastPhase phase;
  final CastFailureReason? reason;
  final String mediaId;
  final int rawEpisode;
  final double rawSeconds;
  final CastDevice? device;
  final List<String> attempts;
  final String userMessage;

  /// 本次实际使用的模式与其判定依据（R12b 的可诊断性）。
  final CastMode mode;
  final CastModeReason modeReason;

  /// 本次实测指标（R12d）。
  final CastReport report;

  /// 本次投屏若走了串流，这是仍在运行的中继会话。
  ///
  /// 必须由 `CastSession`（R12c）接管：换台重下发要用它生成新地址，
  /// 结束投屏要用它停止转发。扔在这里不管，就是一个永久跑着的后台上传。
  final CastRelaySession? relay;

  const CastResult({
    required this.casting,
    required this.phase,
    required this.mediaId,
    required this.rawEpisode,
    required this.rawSeconds,
    required this.attempts,
    required this.userMessage,
    required this.mode,
    required this.modeReason,
    required this.report,
    this.reason,
    this.device,
    this.relay,
  });

  bool get fallbackToLocal => !casting;
}

/// 投屏状态机 + 唯一兜底决策点。
class CastFallbackController {
  final CastTransport transport;
  final DiagnosticSink diagnostics;
  final int maxConnectAttempts;

  /// 起串流中继的工厂。为 null 时「改串流」这条路走不通，
  /// 直推失败即直接降级本机（行为与旧版一致，不会假装成功）。
  final CastRelayFactory? relayFactory;

  /// 「不带鉴权头取一次」的探测器。为 null 时跳过预探测，只靠首帧兜底。
  final CastUrlStatusProbe? probeUrlStatus;

  /// 模式记忆的读/写（R12b「记住该源」）。为 null 时退化为不记忆。
  final CastModeReader? readMode;
  final CastModeWriter? writeMode;

  final CastModePolicy policy;

  CastFallbackController({
    required this.transport,
    this.diagnostics = const NoopDiagnosticSink(),
    this.maxConnectAttempts = 2,
    this.relayFactory,
    this.probeUrlStatus,
    this.readMode,
    this.writeMode,
    this.policy = const CastModePolicy(),
  });

  /// 发起投屏：发现 → 连接（最多 [maxConnectAttempts] 次）→ 起播 → 首帧确认。
  ///
  /// 双模式（R12b）：
  /// 1. 按记忆 / 预探测决定先直推还是先串流；
  /// 2. 直推后 5 秒拿不到起播证据 → 原地改串流重推（同一台设备，不重新发现）；
  /// 3. 串流仍未确认 → 只改文案，不谎报失败（设备自称在播，我们无权断言它黑屏）。
  ///
  /// [sourceId] 与 [headers] 是新增的：前者用来拼记忆键，后者是串流中继要补的
  /// 鉴权头（来自源适配器的 `playbackHeaders`）。直推路径不用 [headers]，
  /// 因为电视没有替我们补头的能力 —— 这正是需要中继的原因。
  Future<CastResult> startCast({
    required String mediaId,
    required String url,
    required int rawEpisode,
    required double rawSeconds,
    String? preferredDeviceId,
    String sourceId = '',
    Map<String, String> headers = const <String, String>{},
  }) async {
    final attempts = <String>[];
    final discoverWatch = Stopwatch()..start();
    List<CastDevice> devices;
    try {
      devices = await transport.discover().timeout(
            CastBudgets.discovery,
            onTimeout: () => <CastDevice>[],
          );
    } catch (_) {
      devices = <CastDevice>[];
      attempts.add('设备发现异常');
    }
    discoverWatch.stop();
    if (devices.isEmpty) {
      attempts.add('未发现可用设备');
      return _fallback(
        mediaId: mediaId,
        reason: CastFailureReason.noDevice,
        rawEpisode: rawEpisode,
        rawSeconds: rawSeconds,
        attempts: attempts,
        mode: CastMode.direct,
        modeReason: CastModeReason.probeOk,
        discoveryMillis: discoverWatch.elapsedMilliseconds,
      );
    }
    final ordered = List<CastDevice>.from(devices);
    if (preferredDeviceId != null) {
      ordered.sort((a, b) => (a.id == preferredDeviceId ? 0 : 1)
          .compareTo(b.id == preferredDeviceId ? 0 : 1));
    }

    // ---- 模式决策（在连接之前做完，避免连上才发现要走串流）----
    final key = castModeKey(sourceId: sourceId, url: url);
    CastMode? remembered;
    if (readMode != null) {
      try {
        remembered = await readMode!(key);
      } catch (_) {
        remembered = null;
      }
    }
    int? probeStatus;
    // 已经记住要串流的源不再探测：那 5 秒本该省下来（R12b 的收益点）。
    if (remembered != CastMode.relay && probeUrlStatus != null) {
      try {
        probeStatus = await probeUrlStatus!(url);
      } catch (_) {
        probeStatus = null;
      }
    }
    final decision =
        policy.decideInitial(remembered: remembered, probeStatus: probeStatus);

    var tried = 0;
    for (final d in ordered) {
      if (tried >= maxConnectAttempts) break;
      tried++;
      bool connected;
      try {
        connected = await transport.connect(d.id);
      } catch (_) {
        connected = false;
      }
      attempts.add('连接 ${d.name}：${connected ? '成功' : '失败'}');
      if (!connected) continue;

      final startWatch = Stopwatch()..start();
      var mode = decision.mode;
      var reason = decision.reason;
      CastRelaySession? relay;
      CastStartSignal? directSignal;

      Future<CastStartSignal> pushAndWait(String target, CastMode m) async {
        bool played;
        try {
          played = await transport.play(url: target, positionSeconds: rawSeconds);
        } catch (_) {
          played = false;
        }
        if (!played) return CastStartSignal.failed;
        return transport.awaitStartSignal(
          timeout: m == CastMode.direct
              ? CastBudgets.directFirstFrame
              : CastBudgets.relayFirstFrame,
          pollInterval: CastBudgets.progressPoll,
        );
      }

      String targetUrl = url;
      if (mode == CastMode.relay) {
        relay = await _startRelay(headers, attempts);
        if (relay == null) {
          // 起不了中继（本机无局域网地址）就退回直推：宁可试一次，
          // 也不要直接告诉用户「投屏失败」。
          attempts.add('串流中继不可用，改为直推');
          mode = CastMode.direct;
          reason = CastModeReason.probeOk;
        } else {
          final relayed = _relayUrl(relay, url);
          if (relayed == null) {
            await _stopRelay(relay);
            relay = null;
            mode = CastMode.direct;
            reason = CastModeReason.probeOk;
          } else {
            targetUrl = relayed;
          }
        }
      }

      var signal = await pushAndWait(targetUrl, mode);
      if (mode == CastMode.direct) directSignal = signal;

      // 直推没拿到起播证据 → 改串流（R12b 的核心动作）。
      if (mode == CastMode.direct &&
          policy.shouldFallbackToRelay(mode,
              firstFrameConfirmed: signal == CastStartSignal.confirmed)) {
        attempts.add(signal == CastStartSignal.failed
            ? '直推未出图（设备已停止），改串流'
            : '直推 ${CastBudgets.directFirstFrame.inSeconds} 秒未确认出图，改串流');
        final started = await _startRelay(headers, attempts);
        if (started != null) {
          final relayed = _relayUrl(started, url);
          if (relayed != null) {
            relay = started;
            mode = CastMode.relay;
            reason = CastModeReason.firstFrameTimeout;
            signal = await pushAndWait(relayed, CastMode.relay);
            if (signal == CastStartSignal.confirmed) {
              reason = CastModeReason.relayConfirmed;
            }
          } else {
            await _stopRelay(started);
          }
        }
      }

      startWatch.stop();
      // 串流都确认失败才算真失败；只是「未确认」时保持投屏，不谎报故障。
      if (signal == CastStartSignal.failed) {
        attempts.add('${d.name} 起播失败');
        final recovered = await _safePosition(rawSeconds);
        await _stopRelay(relay);
        await _safeDisconnect();
        return _fallback(
          mediaId: mediaId,
          reason: CastFailureReason.playbackError,
          rawEpisode: rawEpisode,
          rawSeconds: recovered,
          attempts: attempts,
          mode: mode,
          modeReason: reason,
          discoveryMillis: discoverWatch.elapsedMilliseconds,
        );
      }

      // 记住该源（只在拿到可信结论时记）。
      final rememberedMode = _modeToRemember(
        mode: mode,
        signal: signal,
        directSignal: directSignal,
        decision: decision,
      );
      if (rememberedMode != null && writeMode != null) {
        try {
          await writeMode!(key, rememberedMode);
        } catch (_) {
          // 记忆失败不影响本次投屏。
        }
      }

      final report = CastReport(
        discoveryMillis: discoverWatch.elapsedMilliseconds,
        startMillis: startWatch.elapsedMilliseconds,
        modeName: mode.name,
        reasonName: reason.name,
        signalName: signal.name,
        relayed: mode == CastMode.relay,
      );
      diagnostics.record(DiagnosticEvent(
        kind: DiagnosticKind.castStarted,
        at: DateTime.now(),
        mediaId: mediaId,
        detail: '已投屏到 ${d.name}（${mode.name}/${reason.name}）',
        attributes: <String, Object?>{
          'deviceId': d.id,
          'rawEpisode': rawEpisode,
          'rawSeconds': rawSeconds,
          'mode': mode.name,
          'modeReason': reason.name,
          'signal': signal.name,
          'startMillis': report.startMillis,
          'discoveryMillis': report.discoveryMillis,
        },
      ));
      final unverified = signal == CastStartSignal.playingUnverified;
      return CastResult(
        casting: true,
        phase: mode == CastMode.relay ? CastPhase.relaying : CastPhase.casting,
        mediaId: mediaId,
        rawEpisode: rawEpisode,
        rawSeconds: rawSeconds,
        device: d,
        mode: mode,
        modeReason: reason,
        report: report,
        // 中继交给调用方（CastSession）持有：控制器是短生命周期对象，
        // 把它留在这里等于返回瞬间就断流。
        relay: relay,
        attempts: List<String>.unmodifiable(attempts),
        userMessage: '已投屏到「${d.name}」，本机可作为遥控器。'
            '${mode == CastMode.relay ? '（该源需要中继，已由本机转发）' : ''}'
            '${unverified ? '未能从设备读回播放位置，画面请以电视为准。' : ''}',
      );
    }

    await _safeDisconnect();
    return _fallback(
      mediaId: mediaId,
      reason: CastFailureReason.connectFailed,
      rawEpisode: rawEpisode,
      rawSeconds: rawSeconds,
      attempts: attempts,
      mode: decision.mode,
      modeReason: decision.reason,
      discoveryMillis: discoverWatch.elapsedMilliseconds,
    );
  }

  /// 结论可信才记忆。规则见 [CastModePolicy.rememberAfter] 的注释。
  CastMode? _modeToRemember({
    required CastMode mode,
    required CastStartSignal signal,
    required CastStartSignal? directSignal,
    required CastModeDecision decision,
  }) {
    if (mode == CastMode.direct) {
      return policy.rememberAfter(
        attempted: CastMode.direct,
        firstFrameConfirmed: signal == CastStartSignal.confirmed,
      );
    }
    if (signal == CastStartSignal.confirmed) return CastMode.relay;
    // 未确认是否真有画面时，只有「直推确实失败过」或「预探测说必须带鉴权头」
    // 才算证据充分 —— 否则可能是直播流读不到位置，与防盗链无关。
    if (directSignal == CastStartSignal.failed) return CastMode.relay;
    if (decision.reason == CastModeReason.requiresAuthHeaders ||
        decision.reason == CastModeReason.rememberedRelay) {
      return CastMode.relay;
    }
    return null;
  }

  Future<CastRelaySession?> _startRelay(
    Map<String, String> headers,
    List<String> attempts,
  ) async {
    final factory = relayFactory;
    if (factory == null) {
      attempts.add('未配置串流中继');
      return null;
    }
    try {
      final session = await factory(headers);
      if (session == null) {
        attempts.add('本机没有可用的局域网地址，无法串流');
        return null;
      }
      final base = session.baseUri;
      attempts.add(base == null
          ? '串流中继已启动（地址未就绪）'
          : '串流中继已启动：${base.host}:${base.port}');
      return session;
    } catch (err) {
      attempts.add('串流中继启动失败：$err');
      return null;
    }
  }

  String? _relayUrl(CastRelaySession session, String url) {
    try {
      return session.relayUrlFor(url);
    } catch (_) {
      return null;
    }
  }

  Future<void> _stopRelay(CastRelaySession? session) async {
    if (session == null) return;
    try {
      await session.stop();
    } catch (_) {
      // 停不掉也不影响本机续播；进程退出时 socket 一并释放。
    }
  }

  /// 投屏播放中连接中断（设备关机 / Wi-Fi 切换 / 被抢占）。
  Future<CastResult> onConnectionLost({
    required String mediaId,
    required int rawEpisode,
    required double lastKnownRawSeconds,
  }) async {
    final recovered = await _safePosition(lastKnownRawSeconds);
    await _safeDisconnect();
    return _fallback(
      mediaId: mediaId,
      reason: CastFailureReason.connectionLost,
      rawEpisode: rawEpisode,
      rawSeconds: recovered,
      attempts: <String>['投屏连接中断'],
      mode: CastMode.direct,
      modeReason: CastModeReason.probeOk,
      discoveryMillis: 0,
    );
  }

  /// 主动结束投屏（用户点「回到本机播放」），同样返回可续播坐标。
  Future<CastResult> stopCasting({
    required String mediaId,
    required int rawEpisode,
    required double lastKnownRawSeconds,
  }) async {
    final recovered = await _safePosition(lastKnownRawSeconds);
    await _safeDisconnect();
    return _fallback(
      mediaId: mediaId,
      reason: CastFailureReason.userStopped,
      rawEpisode: rawEpisode,
      rawSeconds: recovered,
      attempts: <String>['用户主动结束投屏'],
      mode: CastMode.direct,
      modeReason: CastModeReason.probeOk,
      discoveryMillis: 0,
    );
  }

  Future<double> _safePosition(double localKnown) async {
    try {
      final p = await transport.currentPositionSeconds();
      // 设备可能缓冲落后或时间倒退：只允许进度前进。
      if (p.isFinite && p >= 0 && p >= localKnown) return p;
      return localKnown;
    } catch (_) {
      return localKnown;
    }
  }

  Future<void> _safeDisconnect() async {
    try {
      await transport.disconnect();
    } catch (_) {
      // 断开失败不影响本机续播
    }
  }

  CastResult _fallback({
    required String mediaId,
    required CastFailureReason reason,
    required int rawEpisode,
    required double rawSeconds,
    required List<String> attempts,
    required CastMode mode,
    required CastModeReason modeReason,
    required int discoveryMillis,
  }) {
    final label = switch (reason) {
      CastFailureReason.noDevice => '未发现可用投屏设备',
      CastFailureReason.connectFailed => '投屏设备连接失败',
      CastFailureReason.playbackError => '投屏起播失败',
      CastFailureReason.connectionLost => '投屏连接中断',
      CastFailureReason.userStopped => '已结束投屏',
    };
    diagnostics.record(DiagnosticEvent(
      kind: DiagnosticKind.castFallback,
      at: DateTime.now(),
      mediaId: mediaId,
      detail: label,
      attributes: <String, Object?>{
        'reason': reason.name,
        'rawEpisode': rawEpisode,
        'rawSeconds': rawSeconds,
        'attempts': attempts.length,
        'mode': mode.name,
        'modeReason': modeReason.name,
      },
    ));
    return CastResult(
      casting: false,
      phase: CastPhase.localFallback,
      reason: reason,
      mediaId: mediaId,
      rawEpisode: rawEpisode,
      rawSeconds: rawSeconds,
      mode: mode,
      modeReason: modeReason,
      report: CastReport(
        discoveryMillis: discoveryMillis,
        startMillis: 0,
        modeName: mode.name,
        reasonName: modeReason.name,
        signalName: CastStartSignal.failed.name,
        relayed: mode == CastMode.relay,
      ),
      attempts: List<String>.unmodifiable(attempts),
      userMessage: reason == CastFailureReason.userStopped
          // 主动结束时不该再劝用户「检查 Wi-Fi 后重试投屏」：那是故障文案。
          ? '$label，已切回本机播放（第$rawEpisode集 ${_fmt(rawSeconds)}），进度不丢失。'
          : '$label，已切回本机播放（第$rawEpisode集 ${_fmt(rawSeconds)}），'
              '进度不丢失。可检查设备与本机是否在同一 Wi-Fi 后重试投屏。',
    );
  }
}

String _fmt(double seconds) {
  final total = seconds.isFinite && seconds > 0 ? seconds.floor() : 0;
  final m = total ~/ 60;
  final s = total % 60;
  return '$m:${s.toString().padLeft(2, '0')}';
}

/// 可注入的投屏假实现（回归验证 / UI 演示用，不依赖任何平台能力）。
class FakeCastTransport implements CastTransport {
  List<CastDevice> devices;
  Set<String> connectFails;
  bool playFails;
  bool throwOnDiscover;
  bool throwOnPosition;
  double position;

  /// 起播信号的预设值：让测试能分别覆盖「确认出图」「设备自称在播但读不到位置」
  /// 「明确失败」三条路径，而不必真的等 5 秒。
  CastStartSignal signal;

  /// 最近一次 `play` 收到的地址（断言「改串流后推的是中继地址」用）。
  String? lastPlayUrl;

  /// 按地址决定信号：模拟「直推黑屏、串流能出图」这一真实故障。
  CastStartSignal? Function(String url)? signalFor;

  /// 按地址决定是否拒绝下发：模拟「直推被设备拒、串流正常」。
  ///
  /// 换源重下发（R12c）必须能把「直推失败」和「串流失败」分开构造，
  /// 否则一个全局开关只能测出「什么都失败」这一种最没信息量的结论。
  bool Function(String url)? playFailsFor;

  int connectCalls = 0;
  int playCalls = 0;
  bool disconnected = false;
  CastDevice? connected;

  FakeCastTransport({
    this.devices = const <CastDevice>[],
    this.connectFails = const <String>{},
    this.playFails = false,
    this.throwOnDiscover = false,
    this.throwOnPosition = false,
    this.position = 0.0,
    this.signal = CastStartSignal.confirmed,
    this.signalFor,
  });

  @override
  Future<List<CastDevice>> discover() async {
    if (throwOnDiscover) throw StateError('discovery failed');
    return devices;
  }

  @override
  Future<bool> connect(String deviceId) async {
    connectCalls++;
    if (connectFails.contains(deviceId)) return false;
    connected = null;
    for (final d in devices) {
      if (d.id == deviceId) {
        connected = d;
        break;
      }
    }
    connected ??= CastDevice(id: deviceId, name: deviceId);
    disconnected = false;
    return true;
  }

  @override
  Future<bool> play({required String url, required double positionSeconds}) async {
    playCalls++;
    lastPlayUrl = url;
    if (playFailsFor?.call(url) ?? playFails) return false;
    position = positionSeconds;
    return true;
  }

  @override
  Future<CastStartSignal> awaitStartSignal({
    Duration timeout = const Duration(seconds: 5),
    Duration pollInterval = const Duration(milliseconds: 300),
  }) async {
    final custom = signalFor?.call(lastPlayUrl ?? '');
    return custom ?? signal;
  }

  @override
  Future<double> currentPositionSeconds() async {
    if (throwOnPosition) throw StateError('position unavailable');
    return position;
  }

  @override
  Future<void> disconnect() async {
    disconnected = true;
    connected = null;
  }
}
