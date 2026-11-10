/// 边缘伸缩控件的显隐 / 触发策略（纯 Dart，不依赖 flutter，可直接回归）。
///
/// 设计约束（2026-11-06 UI 调整）：
/// 1. **默认隐藏**：页面初始加载、鼠标未进入边缘热区时，左右两侧都不应有
///    可见的伸缩控件；
/// 2. **按需显示**：只有用户把鼠标移到对应边缘，手柄才淡入；
/// 3. **左右一致**：两侧共用同一个策略类与同一个渲染组件，不允许一边
///    「划过就弹开」另一边「必须点击」；
/// 4. **不重复触发**：悬停自动展开与点击展开是同一动作的两种触发方式，
///    必须互斥，否则会连续调用两次展开流程。
///
/// 原来的实现把「鼠标进入热区」直接当成「展开」信号，导致手柄永远来不及
/// 被看见（一 hover 就滑出侧栏），而且用户划过边缘就误弹面板。这里把
/// 「显示控件」与「执行切换」拆成两步，中间留一个短暂的悬停缓冲。
class EdgeHandlePolicy {
  EdgeHandlePolicy();

  bool _visible = false;

  /// 悬停自动展开的计时是否仍有效（尚未触发、且鼠标仍在热区内）。
  bool _hoverPending = false;

  /// 手柄当前是否可见。初值 false —— 这是「初始加载不显示」的唯一真值来源。
  bool get visible => _visible;

  bool get hoverPending => _hoverPending;

  /// 鼠标进入边缘热区：手柄淡入。
  ///
  /// 返回 true 表示调用方需要启动一次悬停计时；重复进入（热区重建时
  /// `onEnter` 可能重发）返回 false，避免堆叠多个 Timer。
  bool enter() {
    if (_visible && _hoverPending) return false;
    _visible = true;
    _hoverPending = true;
    return true;
  }

  /// 鼠标离开热区：手柄淡出，并撤销尚未触发的悬停计时。
  void exit() {
    _visible = false;
    _hoverPending = false;
  }

  /// 悬停计时到点：仅当鼠标仍在热区、且本轮还没触发过，才允许自动展开。
  bool onHoverElapsed() {
    if (!_visible || !_hoverPending) return false;
    _hoverPending = false;
    return true;
  }

  /// 点击手柄：立即执行切换，并撤销悬停计时，防止「点击 + 计时」双触发。
  /// 手柄隐藏时返回 false —— 透明热区里的误点不能唤出侧栏。
  bool tap() {
    if (!_visible) return false;
    _hoverPending = false;
    return true;
  }

  /// 侧栏切换完成后控件会被卸载；显式复位便于复用与回归。
  void reset() {
    _visible = false;
    _hoverPending = false;
  }
}
