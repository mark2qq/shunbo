import 'dart:math' as math;

/// 底部控制区「自动隐藏 / 悬停唤出」策略（纯 Dart，不依赖 flutter / dart:ui，
/// 可直接被 `dart run tooling/verify_auto_hide_controls.dart` 回归）。
///
/// 需求与边界：
/// 1. **默认隐藏**：初值 [visible] = false；播放区空闲时也自动回到隐藏；
/// 2. **短暂停留才唤出**：鼠标进入底部触发带后累计 [hoverDelayMs] 才显示，
///    快速划过（进入后立刻离开，或窗口内累计位移超过 [hoverMaxDrift]）
///    一律不显示；
/// 3. **离开 / 空闲自动隐藏**：离开触发带走 [leaveHideDelayMs]，长时间无操作
///    走 [idleTimeoutMs]；鼠标停在控制条本身上时暂停空闲计时，保证显示期间
///    各控制项始终可点；
/// 4. **不重复触发**：隐藏后若鼠标仍停在触发带内，本轮不重新武装；必须先把
///    鼠标移出触发带再回来，才能开始下一轮停留计时（避免「隐藏→立刻又弹出」）；
/// 5. **时间由外部推进**：[advance] 用毫秒驱动，不持有 Timer / Stopwatch，
///    回归可以精确模拟任意时序，UI 层只需一个周期 Timer 把帧间隔喂进来。
///
/// 与 [EdgeHandlePolicy] 的分工：后者只管「一个手柄的淡入 + 一次点击」，
/// 本类管「一整条控制区的显示 / 保持 / 收起」三态，含空闲与重新武装。
class AutoHideControlsPolicy {
  AutoHideControlsPolicy({
    this.hoverDelayMs = 260,
    this.idleTimeoutMs = 3200,
    this.leaveHideDelayMs = 300,
    this.triggerHeight = 96,
    this.hoverMaxDrift = 120,
  })  : assert(hoverDelayMs > 0, 'hoverDelayMs 必须为正'),
        assert(idleTimeoutMs > 0, 'idleTimeoutMs 必须为正'),
        assert(leaveHideDelayMs > 0, 'leaveHideDelayMs 必须为正'),
        assert(triggerHeight > 0, 'triggerHeight 必须为正'),
        assert(hoverMaxDrift > 0, 'hoverMaxDrift 必须为正');

  /// 进入触发带后需要连续停留多久才显示（挡住快速划过）。
  final int hoverDelayMs;

  /// 显示后无任何鼠标操作多久自动隐藏。
  final int idleTimeoutMs;

  /// 鼠标离开触发带 / 控制条后延迟多久隐藏（给「移到按钮上」留过渡时间）。
  final int leaveHideDelayMs;

  /// 页面底部触发带高度（逻辑像素）。控制条本身落在带内，因此从触发带
  /// 移到控制条不会触发隐藏。
  final double triggerHeight;

  /// 一轮停留等待窗口内允许的最大累计位移；超过即视为「划过」，
  /// 重新计算停留时间。慢速小幅定位不受影响。
  final double hoverMaxDrift;

  bool _visible = false;
  bool _inTrigger = false;
  bool _overControls = false;

  /// 是否允许开始新一轮唤出。隐藏后鼠标若没离开触发带，保持 false。
  bool _armed = true;

  int _hoverMs = 0;
  int _idleMs = 0;
  int _leaveMs = 0;
  bool _leavePending = false;

  double? _anchorX;
  double? _anchorY;
  double _drift = 0;
  int _nowMs = 0;

  bool get visible => _visible;
  bool get inTrigger => _inTrigger;
  bool get overControls => _overControls;
  bool get armed => _armed;
  bool get leavePending => _leavePending;
  int get hoverMs => _hoverMs;
  int get idleMs => _idleMs;
  int get leaveMs => _leaveMs;
  int get nowMs => _nowMs;
  double get drift => _drift;

  /// 是否处在「需要计时」的状态。UI 层可据此决定是否继续喂 [advance]，
  /// 空闲时省掉无意义的周期回调。
  bool get needsTicking =>
      (!_visible && _armed && _inTrigger) ||
      (_visible && (_leavePending || !_overControls));

  /// 鼠标在播放区内移动。[height] 为播放区高度（来自 LayoutBuilder）；
  /// 无界 / 非法高度直接忽略，自动隐藏会由 UI 层回退成常显。
  void pointerMove({
    required double x,
    required double y,
    required double height,
  }) {
    if (!height.isFinite || height <= 0) return;
    final inside = y >= height - triggerHeight && y <= height + 1;
    if (inside != _inTrigger) {
      if (inside) {
        _enterTrigger(x, y);
      } else {
        _exitTrigger();
      }
    }

    // 任何一次鼠标移动都算「有操作」，重置空闲计时。
    _idleMs = 0;

    if (inside && !_visible && _armed) {
      final ax = _anchorX;
      final ay = _anchorY;
      if (ax == null || ay == null) {
        _anchorX = x;
        _anchorY = y;
        _drift = 0;
      } else {
        final dx = x - ax;
        final dy = y - ay;
        _drift += math.sqrt(dx * dx + dy * dy);
        _anchorX = x;
        _anchorY = y;
        if (_drift > hoverMaxDrift) {
          // 快速划过：本轮停留作废，但不永久禁用——鼠标停下来后重新计时，
          // 用户不必把鼠标移出再移回。
          _hoverMs = 0;
          _drift = 0;
        }
      }
    }

    if (!inside && !_overControls) _armed = true;
  }

  void _enterTrigger(double x, double y) {
    _inTrigger = true;
    _leavePending = false;
    _leaveMs = 0;
    _anchorX = x;
    _anchorY = y;
    _drift = 0;
    if (!_visible && _armed) _hoverMs = 0;
  }

  void _exitTrigger() {
    _inTrigger = false;
    _hoverMs = 0;
    _anchorX = null;
    _anchorY = null;
    _drift = 0;
    if (!_overControls) _armed = true;
    if (_visible && !_overControls) {
      _startLeave();
    } else {
      _leavePending = false;
      _leaveMs = 0;
    }
  }

  void _startLeave() {
    if (_leavePending) return;
    _leavePending = true;
    _leaveMs = 0;
  }

  /// 鼠标进入控制条本身：取消待隐藏、暂停空闲计时。
  void enterControls() {
    _overControls = true;
    _leavePending = false;
    _leaveMs = 0;
    _idleMs = 0;
  }

  /// 鼠标离开控制条：若此刻也不在触发带内，开始延迟隐藏。
  void exitControls() {
    _overControls = false;
    if (!_inTrigger) _armed = true;
    if (_visible && !_inTrigger) _startLeave();
  }

  /// 点击 / 拖动任意控制项：视为一次操作，重置空闲与待隐藏。
  void interaction() {
    _idleMs = 0;
    if (_visible) {
      _leavePending = false;
      _leaveMs = 0;
    }
  }

  /// 鼠标离开整个播放区（MouseRegion.onExit / 窗口失焦）。
  void pointerLeave() {
    _inTrigger = false;
    _overControls = false;
    _hoverMs = 0;
    _anchorX = null;
    _anchorY = null;
    _drift = 0;
    _armed = true;
    if (_visible) _startLeave();
  }

  /// 推进时间。返回 [visible] 是否发生变化（UI 据此 setState，避免每帧重建）。
  bool advance(int ms) {
    if (ms <= 0) return false;
    _nowMs += ms;
    final before = _visible;
    var justShown = false;

    // 1) 触发带内连续停留够久 → 唤出。
    if (!_visible && _armed && _inTrigger && !_overControls) {
      _hoverMs += ms;
      if (_hoverMs >= hoverDelayMs) {
        _show();
        justShown = true;
      }
    }

    // 2) 离开触发带 / 控制条 → 延迟隐藏。
    if (_visible && _leavePending) {
      _leaveMs += ms;
      if (_leaveMs >= leaveHideDelayMs) _hide();
    }

    // 3) 长时间无操作 → 隐藏。鼠标停在控制条上时暂停空闲计时，
    //    否则用户停在按钮上 3 秒后控制条消失，按钮就点不到了。
    //    刚唤出的这一帧是空闲计时起点，不重复计入，否则阈值会被吃掉一个 tick。
    if (_visible && !_overControls && !justShown) {
      _idleMs += ms;
      if (_idleMs >= idleTimeoutMs) _hide();
    }

    return before != _visible;
  }

  void _show() {
    _visible = true;
    _hoverMs = 0;
    _idleMs = 0;
    _leaveMs = 0;
    _leavePending = false;
    _drift = 0;
  }

  void _hide() {
    _visible = false;
    _hoverMs = 0;
    _idleMs = 0;
    _leaveMs = 0;
    _leavePending = false;
    _anchorX = null;
    _anchorY = null;
    _drift = 0;
    // 不重新武装：鼠标必须先离开触发带。否则隐藏的同一瞬间又满足
    // 「在触发带内」，下一帧就会重新累计 hoverDelay 并再次弹出。
    _armed = false;
  }

  /// 复位到初态（页面切走 / 形态切换 / 组件重建）。
  void reset() {
    _visible = false;
    _inTrigger = false;
    _overControls = false;
    _armed = true;
    _hoverMs = 0;
    _idleMs = 0;
    _leaveMs = 0;
    _leavePending = false;
    _anchorX = null;
    _anchorY = null;
    _drift = 0;
    _nowMs = 0;
  }
}
