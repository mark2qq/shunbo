/// 直播投屏协调器（R12c）：把「直播调台」与「投屏会话」接在一起。
///
/// 为什么单独一层而不是让 `LivePage` 直接调 `CastFallbackController`：
/// 1. 直播页是纯 UI，不应该知道 DLNA、中继、模式记忆这些概念；
/// 2. 换台重下发需要一个**持续存在**的对象持有设备连接与中继，
///    放在 State 字段里会随页面重建/热重载一起丢掉，电视立刻断流；
/// 3. 电视形态下投屏入口本来就不该出现（R12e），由协调器是否被注入决定，
///    UI 只判断「有没有」，不再各自复制一份形态判断。
///
/// 与点播投屏的关键差别：**直播不停本机播放**。
/// 本机的看门狗靠「画面是否在动」判断这条线路是否还有效，一旦本机停播，
/// 看门狗会把一条完全正常的线路判死并自动换台 —— 结果就是电视刚放上
/// 两秒就被换走。所以投屏期间两路同时拉流，代价是带宽翻倍，
/// 换来的是「换台判定与健康度不回退」。这一点在 UI 文案里要如实说明。
library;

import 'package:flutter/foundation.dart';

import '../core/cast/cast_fallback.dart';
import '../core/cast/cast_mode.dart';
import '../core/cast/cast_session.dart';
import '../core/cast/relay/relay_session.dart';
import '../core/diagnostics/diagnostic_sink.dart';

/// 直播投屏状态（给 UI 读的只读视图）。
class LiveCastStatus {
  const LiveCastStatus({
    required this.casting,
    required this.busy,
    required this.deviceName,
    required this.modeName,
    required this.message,
  });

  final bool casting;
  final bool busy;
  final String? deviceName;

  /// 「直推」/「串流」；未投屏时为 null。
  final String? modeName;
  final String message;

  static const LiveCastStatus idle = LiveCastStatus(
    casting: false,
    busy: false,
    deviceName: null,
    modeName: null,
    message: '',
  );
}

class LiveCastCoordinator extends ChangeNotifier {
  LiveCastCoordinator({
    required CastTransport transport,
    this.diagnostics = const NoopDiagnosticSink(),
    this.relayFactory,
    this.readMode,
    this.writeMode,
    this.probeUrlStatus,
    this.policy = const CastModePolicy(),
  }) : _transport = transport;

  final CastTransport _transport;
  final DiagnosticSink diagnostics;

  /// 为 null 表示本机不支持串流（无局域网地址等），只走直推。
  final CastRelayFactory? relayFactory;
  final CastModeReader? readMode;
  final CastModeWriter? writeMode;
  final CastUrlStatusProbe? probeUrlStatus;
  final CastModePolicy policy;

  CastSession? _session;
  bool _busy = false;
  bool _disposed = false;
  String _message = '';
  String? _lastSentUrl;
  String? _deviceName;
  CastMode? _mode;

  bool get isCasting => _session?.isActive ?? false;
  bool get isBusy => _busy;
  CastSession? get session => _session;

  LiveCastStatus get status => LiveCastStatus(
        casting: isCasting,
        busy: _busy,
        deviceName: _deviceName,
        modeName: _mode == null
            ? null
            : _mode == CastMode.relay
                ? '串流'
                : '直推',
        message: _message,
      );

  Future<List<CastDevice>> discover() async {
    try {
      return await _transport.discover().timeout(
            const Duration(seconds: 6),
            onTimeout: () => <CastDevice>[],
          );
    } catch (_) {
      return <CastDevice>[];
    }
  }

  /// 开始投屏到 [device]。
  ///
  /// 返回 true 表示设备已接受并且（至少看起来）在播。
  Future<bool> start({
    required CastDevice device,
    required String url,
    Map<String, String> headers = const <String, String>{},
    String sourceId = '',
  }) async {
    if (_disposed) return false;
    if (_busy) return false;
    if (url.isEmpty) {
      _setMessage('当前频道还没有可播放的线路，无法投屏。');
      return false;
    }
    // 已有会话还往第二台推：先干净地收掉前一个，否则旧设备会一直在播。
    await _endSession(silent: true);
    _busy = true;
    _deviceName = device.name;
    _setMessage('正在连接「${device.name}」…');

    try {
      bool connected;
      try {
        connected = await _transport.connect(device.id);
      } catch (_) {
        connected = false;
      }
      if (!connected) {
        _setMessage('无法连接「${device.name}」。请确认电视已开机并在同一 Wi-Fi。');
        return false;
      }

      // 模式决策与点播同源（R12b）：记忆优先，其次一次无头探测。
      final key = castModeKey(sourceId: sourceId, url: url);
      CastMode? remembered;
      if (readMode != null) {
        try {
          remembered = await readMode!(key);
        } catch (_) {
          remembered = null;
        }
      }
      int? probe;
      if (remembered != CastMode.relay && probeUrlStatus != null) {
        try {
          probe = await probeUrlStatus!(url);
        } catch (_) {
          probe = null;
        }
      }
      final decision =
          policy.decideInitial(remembered: remembered, probeStatus: probe);

      final session = CastSession(
        transport: _transport,
        device: device,
        mode: decision.mode,
        modeReason: decision.reason,
        sourceId: sourceId,
        headers: headers,
        relayFactory: relayFactory,
        diagnostics: diagnostics,
      );
      final result = await session.retarget(
        url: url,
        headers: headers,
        sourceId: sourceId,
        // 直播没有「续播位置」：DLNA 侧 0 秒直接跳过 Seek，
        // 传其它值反而会让某些电视卡在 seek 失败上。
        positionSeconds: 0,
      );
      if (!result.ok) {
        await session.stop();
        _setMessage('「${device.name}」投屏失败：${result.attempts.join(' / ')}');
        return false;
      }

      _session = session;
      _lastSentUrl = url;
      _mode = result.mode;
      _remember(key, result.mode, decision.reason, result.signal);
      _setMessage(result.mode == CastMode.relay
          // 串流分支必须说清「别退出 App」：一退出中继就没了，电视会黑屏。
          ? '已投屏到「${device.name}」（本机中转，本页面保持运行）'
          : '已投屏到「${device.name}」（直推）');
      return true;
    } catch (err) {
      _setMessage('投屏出错：$err');
      return false;
    } finally {
      _busy = false;
      _notify();
    }
  }

  /// 换台后重下发。**任何异常都不许把 App 带崩**，也不许把「过期结果」
  /// 当成故障弹给用户 —— 连按换台时前一次的作废是正常现象。
  Future<void> retarget({
    required String url,
    Map<String, String> headers = const <String, String>{},
    String sourceId = '',
    bool playing = true,
  }) async {
    final s = _session;
    if (s == null || _disposed) return;
    if (!shouldRetargetLiveCast(
      casting: s.isActive,
      playing: playing,
      streamUrl: url,
      lastSentUrl: _lastSentUrl,
    )) {
      return;
    }
    // 先把「已下发」记下来：即使后面失败也不该对同一个地址反复重推。
    _lastSentUrl = url;
    final result = await s.retarget(
      url: url,
      headers: headers,
      sourceId: sourceId,
      positionSeconds: 0,
    );
    if (_disposed) return;
    switch (result.outcome) {
      case CastRetargetOutcome.superseded:
      case CastRetargetOutcome.inactive:
      case CastRetargetOutcome.rejected:
        // 已被更新的换台取代 / 投屏已结束：静默，别用旧结果覆盖新状态。
        return;
      case CastRetargetOutcome.failed:
        final name = _deviceName ?? '电视';
        await s.stop();
        _session = null;
        _lastSentUrl = null;
        _mode = null;
        _setMessage('「$name」已无法继续接收画面，已结束投屏并返回本机。');
        return;
      case CastRetargetOutcome.accepted:
      case CastRetargetOutcome.acceptedAfterSwitch:
        _mode = result.mode;
        _setMessage(result.signal == CastStartSignal.playingUnverified
            ? '已换台（${result.mode == CastMode.relay ? '串流' : '直推'}），'
                '直播流读不到位置属正常，画面请以电视为准。'
            : '已换台（${result.mode == CastMode.relay ? '串流' : '直推'}）');
        return;
    }
  }

  /// 结束投屏。可以重复调用。
  Future<void> stop() => _endSession(silent: false);

  Future<void> _endSession({required bool silent}) async {
    final s = _session;
    _session = null;
    _lastSentUrl = null;
    _mode = null;
    if (s != null) {
      try {
        await s.stop();
      } catch (_) {
        // 断不掉不影响本机播放。
      }
    }
    // 本来就没在投屏时，不该凭空冒出一句「已结束投屏」。
    if (!silent && s != null) _setMessage('已结束投屏，返回本机播放。');
  }

  /// 只在结论可信时记忆（与点播投屏同一套规则，见 `CastModePolicy.rememberAfter`）。
  void _remember(
    String key,
    CastMode mode,
    CastModeReason reason,
    CastStartSignal signal,
  ) {
    final writer = writeMode;
    if (writer == null) return;
    final value = mode == CastMode.direct
        ? policy.rememberAfter(
            attempted: CastMode.direct,
            firstFrameConfirmed: signal == CastStartSignal.confirmed,
          )
        : (signal == CastStartSignal.confirmed ||
                reason == CastModeReason.requiresAuthHeaders ||
                reason == CastModeReason.rememberedRelay)
            ? CastMode.relay
            : null;
    if (value == null) return;
    // 记忆失败不影响本次投屏，也不该让调用方等它。
    writer(key, value).catchError((Object _) {});
  }

  void _setMessage(String message) {
    _message = message;
    _notify();
  }

  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  /// `ChangeNotifier` 在 dispose 之后调用 add/removeListener 会断言失败。
  ///
  /// 这个顺序在本工程是**真会**发生的：外壳的 `dispose` 先于子页面，
  /// 于是协调器先被销毁，紧接着 `LivePage.dispose` 又来摘监听 —— debug 下直接抛。
  /// 这里把两个方法都做成 no-op，让「销毁顺序」不再是隐式约定。
  @override
  void addListener(VoidCallback listener) {
    if (_disposed) return;
    super.addListener(listener);
  }

  @override
  void removeListener(VoidCallback listener) {
    if (_disposed) return;
    super.removeListener(listener);
  }

  @override
  void dispose() {
    _disposed = true;
    final s = _session;
    _session = null;
    if (s != null) {
      // 不 await：dispose 不能异步。中继的 socket 会随 stop 立即释放监听。
      s.stop().catchError((Object _) {});
    }
    super.dispose();
  }
}
