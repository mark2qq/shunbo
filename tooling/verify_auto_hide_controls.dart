// 底部控制区「自动隐藏 / 悬停唤出」回归。
//
// 分两层：
//   ① 纯 Dart 状态机（AutoHideControlsPolicy）——默认隐藏、短暂停留唤出、
//      快速划过不误触发、离开延迟隐藏、空闲隐藏、显示期间控制条可操作、
//      隐藏后不重复唤出、参数边界与复位；
//   ② 源码静态护栏——裸 dart run 不能 import flutter，渲染侧的
//      「滑出屏幕 / 淡入淡出 / IgnorePointer / 控制条自身 hover / 交互重置 /
//      形态开关 / dispose 清理」用源码断言锁住，防止后续改动悄悄回退。
//
// 运行：dart run tooling/verify_auto_hide_controls.dart
import 'dart:io';

import 'package:shunbo/ui/widgets/auto_hide_controls_policy.dart';

int _pass = 0;
int _fail = 0;

void check(String name, bool ok, [String? detail]) {
  if (!ok) {
    _fail++;
    print('FAIL: $name${detail == null ? '' : ' —— $detail'}');
    return;
  }
  _pass++;
  print('PASS: $name');
}

/// Windows 工作区部分文件是 CRLF，统一成 LF 后再做多行匹配。
String _src(String path) =>
    File(path).readAsStringSync().replaceAll('\r\n', '\n');

const double _h = 720;
const double _triggerY = _h - 10; // height=720 / triggerHeight=96 -> 底部带内
const double _outsideY = _h - 220; // 带外

// ── ① 纯 Dart 状态机 ────────────────────────────────────────────

void testInitial() {
  final p = AutoHideControlsPolicy();
  check('初始状态控制区隐藏', !p.visible);
  check('初始状态已武装（允许首次唤出）', p.armed);
  check('初始状态不在触发带', !p.inTrigger);
  check('初始状态不在控制条上', !p.overControls);
  check('初始状态没有待隐藏计时', !p.leavePending);
  check('初始状态停留计时为 0', p.hoverMs == 0);
  check('初始状态空闲计时为 0', p.idleMs == 0);
  check('初始状态离开计时为 0', p.leaveMs == 0);
  check('初始状态不需要喂时间', !p.needsTicking);
  check('默认停留阈值 260ms', p.hoverDelayMs == 260);
  check('默认空闲阈值 3200ms', p.idleTimeoutMs == 3200);
  check('默认离开延迟 300ms', p.leaveHideDelayMs == 300);
  check('默认触发带高 96', p.triggerHeight == 96);
  check('默认划过位移阈值 120', p.hoverMaxDrift == 120);
}

void testHoverDelay() {
  final p = AutoHideControlsPolicy();
  check('进入触发带前推进时间不会显示', !p.advance(500) && !p.visible);
  p.pointerMove(x: 320, y: _triggerY, height: _h);
  check('鼠标进入底部触发带', p.inTrigger);
  check('进入后进入待计时状态', p.needsTicking);
  check('停留 100ms 仍隐藏', !p.advance(100) && !p.visible);
  check('停留 200ms 仍隐藏', !p.advance(59) && !p.visible);
  check('累计停留 259ms 仍隐藏', !p.advance(100) && !p.visible);
  check('累计停留到 260ms 唤出', p.advance(1));
  check('唤出后 visible=true', p.visible);
  check('唤出后停留计时清零', p.hoverMs == 0);
  check('唤出后空闲计时清零', p.idleMs == 0);
  check('唤出后无待隐藏计时', !p.leavePending);
  check('重复推进不会重复唤出', !p.advance(50));
  check('重复推进后仍只显示一次', p.visible);
}

void testQuickSweep() {
  // 场景 1：进入后 80ms 就离开 —— 典型快速划过。
  final a = AutoHideControlsPolicy();
  a.pointerMove(x: 100, y: _triggerY, height: _h);
  a.advance(80);
  a.pointerMove(x: 100, y: _outsideY, height: _h);
  check('快速划过后离开触发带', !a.inTrigger);
  check('快速划过未触发显示', !a.visible);
  check('快速划过后再推进 1000ms 仍隐藏', !a.advance(1000) && !a.visible);

  // 场景 2：差 10ms 就到阈值时离开，临界值不得误触发。
  final b = AutoHideControlsPolicy();
  b.pointerMove(x: 100, y: _triggerY, height: _h);
  b.advance(250);
  b.pointerMove(x: 100, y: _outsideY, height: _h);
  check('临界 250ms 离开仍隐藏', !b.visible);
  check('临界离开后长时间推进仍隐藏', !b.advance(2000) && !b.visible);

  // 场景 3：停在底部但大幅横移（划过）——累计位移超阈值要重置停留计时。
  final c = AutoHideControlsPolicy();
  c.pointerMove(x: 100, y: _triggerY, height: _h);
  c.advance(200);
  c.pointerMove(x: 320, y: _triggerY, height: _h);
  check('大幅横移后停留计时被重置', c.hoverMs == 0);
  check('大幅横移后 drift 归零', c.drift == 0);
  check('大幅横移后推进 200ms 仍隐藏', !c.advance(200) && !c.visible);
  check('停下后再累计 60ms 才唤出', c.advance(60) && c.visible);

  // 场景 4：慢速小幅定位不应被误判成划过。
  final d = AutoHideControlsPolicy();
  d.pointerMove(x: 300, y: _triggerY, height: _h);
  d.advance(120);
  d.pointerMove(x: 330, y: _triggerY, height: _h);
  check('小幅位移不重置停留计时', d.hoverMs == 120);
  check('小幅位移后仍可正常唤出', d.advance(140) && d.visible);
}

void testControlsUsable() {
  final p = AutoHideControlsPolicy();
  p.pointerMove(x: 320, y: _triggerY, height: _h);
  p.advance(260);
  check('前置：控制区已唤出', p.visible);

  p.enterControls();
  check('鼠标进入控制条被记录', p.overControls);
  check('进入控制条取消待隐藏', !p.leavePending);
  check('进入控制条后空闲计时清零', p.idleMs == 0);
  check('悬停在控制条上超过空闲阈值仍显示',
      !p.advance(3200 * 2) && p.visible);
  check('悬停控制条时空闲计时被暂停', p.idleMs == 0);

  p.interaction();
  check('点击控制项后仍显示', p.visible);
  check('点击控制项后空闲计时为 0', p.idleMs == 0);
  check('点击后不再有待隐藏计时', !p.leavePending);

  // 从触发带移到控制条：两者都落在底部带内，不应触发隐藏。
  p.pointerMove(x: 320, y: _h - 40, height: _h);
  check('移到控制条上仍在触发带内', p.inTrigger);
  check('移到控制条上不启动隐藏', !p.leavePending);
  check('移到控制条上仍显示', p.visible);

  p.pointerMove(x: 320, y: _triggerY, height: _h);
  p.exitControls();
  check('从控制条回到触发带不启动隐藏', !p.leavePending);
  check('从控制条回到触发带仍显示', p.visible);
}

void testLeaveHide() {
  final p = AutoHideControlsPolicy();
  p.pointerMove(x: 320, y: _triggerY, height: _h);
  p.advance(260);
  p.pointerMove(x: 320, y: _outsideY, height: _h);
  check('离开触发带后启动待隐藏', p.leavePending);
  check('离开触发带后仍暂时显示', p.visible);
  check('离开延迟 299ms 仍显示', !p.advance(299) && p.visible);
  check('离开延迟到 300ms 自动隐藏', p.advance(1) && !p.visible);
  check('隐藏后待隐藏计时清零', !p.leavePending && p.leaveMs == 0);

  // 离开 → 又立刻回来：延迟隐藏应被撤销。
  final q = AutoHideControlsPolicy();
  q.pointerMove(x: 320, y: _triggerY, height: _h);
  q.advance(260);
  q.pointerMove(x: 320, y: _outsideY, height: _h);
  q.advance(100);
  q.pointerMove(x: 320, y: _triggerY, height: _h);
  check('离开后回来撤销待隐藏', !q.leavePending);
  check('离开后回来保持显示', q.visible);
  check('回来后继续推进仍显示', !q.advance(100) && q.visible);
}

void testIdleHideAndRearm() {
  final p = AutoHideControlsPolicy();
  p.pointerMove(x: 320, y: _triggerY, height: _h);
  p.advance(260);
  check('前置：控制区已唤出', p.visible);
  check('空闲 3199ms 仍显示', !p.advance(3199) && p.visible);
  check('空闲到 3200ms 自动隐藏', p.advance(1) && !p.visible);
  check('空闲隐藏后取消武装', !p.armed);
  check('鼠标仍在触发带内', p.inTrigger);
  check('隐藏后继续推进 5000ms 不会自动重显', !p.advance(5000) && !p.visible);
  check('隐藏后重复 pointerMove 同位置也不重显', () {
    p.pointerMove(x: 320, y: _triggerY, height: _h);
    p.advance(1000);
    return !p.visible;
  }());

  p.pointerMove(x: 320, y: _outsideY, height: _h);
  check('鼠标离开触发带后重新武装', p.armed);
  p.pointerMove(x: 320, y: _triggerY, height: _h);
  check('重新进入后仍隐藏', !p.visible);
  check('重新进入后累计 260ms 可再次唤出', p.advance(260) && p.visible);

  // 移动会重置空闲计时：连续小幅移动时不应中途隐藏。
  final q = AutoHideControlsPolicy();
  q.pointerMove(x: 320, y: _triggerY, height: _h);
  q.advance(260);
  for (var i = 0; i < 10; i++) {
    q.advance(300);
    q.pointerMove(x: 320 + i.toDouble(), y: _triggerY, height: _h);
  }
  check('持续鼠标操作不会被空闲隐藏', q.visible);
}

void testIdempotence() {
  final p = AutoHideControlsPolicy();
  for (var i = 0; i < 8; i++) {
    p.pointerMove(x: 320 + i.toDouble(), y: _triggerY, height: _h);
  }
  check('重复进入不会反复重置停留计时', p.hoverMs == 0 && p.inTrigger);
  check('重复进入后一次推进即可唤出', p.advance(260) && p.visible);
  check('显示后重复 pointerMove 不会二次唤出', () {
    for (var i = 0; i < 8; i++) {
      p.pointerMove(x: 320 + i.toDouble(), y: _triggerY, height: _h);
    }
    return !p.advance(1000);
  }());

  p.enterControls();
  p.enterControls();
  check('重复 enterControls 不叠加状态', p.overControls && !p.leavePending);
  p.exitControls();
  p.exitControls();
  check('重复 exitControls 不叠加待隐藏', !p.overControls && !p.leavePending);

  final q = AutoHideControlsPolicy();
  q.pointerMove(x: 320, y: _triggerY, height: _h);
  q.advance(260);
  q.pointerLeave();
  q.pointerLeave();
  check('重复 pointerLeave 只保留一次待隐藏', q.leavePending);
  check('重复 pointerLeave 后仍会隐藏', q.advance(300) && !q.visible);
}

void testBoundaries() {
  final p = AutoHideControlsPolicy();
  p.pointerMove(x: 320, y: _h - 96, height: _h);
  check('恰好在触发带上边界算进入', p.inTrigger);
  p.pointerMove(x: 320, y: _h - 97, height: _h);
  check('触发带上边界外 1px 算离开', !p.inTrigger);

  final q = AutoHideControlsPolicy();
  q.pointerMove(x: 320, y: _triggerY, height: _h);
  q.advance(100);
  q.pointerMove(x: 320, y: _triggerY, height: 0);
  check('高度为 0 时忽略坐标更新', q.inTrigger && q.hoverMs == 100);
  q.pointerMove(x: 320, y: _triggerY, height: double.infinity);
  check('无界高度时忽略坐标更新', q.inTrigger);
  q.pointerMove(x: 320, y: _triggerY, height: double.nan);
  check('NaN 高度时忽略坐标更新', q.inTrigger);
  final clockBefore = q.nowMs;
  check('advance(0) 不改变状态', !q.advance(0));
  check('advance(-1) 不改变状态', !q.advance(-1));
  check('非法推进不增加时钟', q.nowMs == clockBefore);
  check('累计 160ms 后可唤出', q.advance(160) && q.visible);

  final r = AutoHideControlsPolicy(
    hoverDelayMs: 100,
    idleTimeoutMs: 500,
    leaveHideDelayMs: 80,
    triggerHeight: 40,
    hoverMaxDrift: 30,
  );
  r.pointerMove(x: 10, y: _h - 20, height: _h);
  check('自定义触发带高度生效', r.inTrigger);
  check('自定义停留阈值：100ms 即唤出', r.advance(100) && r.visible);
  check('自定义空闲阈值：499ms 仍显示', !r.advance(499) && r.visible);
  check('自定义空闲阈值：500ms 隐藏', r.advance(1) && !r.visible);

  final s = AutoHideControlsPolicy();
  s.pointerMove(x: 320, y: _triggerY, height: _h);
  s.advance(260);
  s.reset();
  check('reset 回到默认隐藏', !s.visible);
  check('reset 重新武装', s.armed);
  check('reset 清除触发带状态', !s.inTrigger && !s.overControls);
  check('reset 清除全部计时',
      s.hoverMs == 0 && s.idleMs == 0 && s.leaveMs == 0 && !s.leavePending);
  check('reset 清零时钟', s.nowMs == 0);
  check('reset 后仍可重新唤出', () {
    s.pointerMove(x: 320, y: _triggerY, height: _h);
    return s.advance(260) && s.visible;
  }());
}

// ── ② 源码静态护栏 ──────────────────────────────────────────────

void testSources() {
  const policyPath = 'lib/ui/widgets/auto_hide_controls_policy.dart';
  const overlayPath = 'lib/ui/live/player_overlay.dart';
  const pagePath = 'lib/ui/live/live_page.dart';

  check('策略文件存在', File(policyPath).existsSync());
  final policy = _src(policyPath);
  final overlay = _src(overlayPath);
  final page = _src(pagePath);

  // 策略本身：纯 Dart、无 flutter 依赖、关键方法齐全。
  check('策略只依赖 dart:math，不引 flutter/dart:ui',
      policy.contains("import 'dart:math' as math;") &&
          !policy.contains("import 'package:flutter") &&
          !policy.contains('import "package:flutter') &&
          !policy.contains("import 'dart:ui") &&
          !policy.contains('import "dart:ui'));
  for (final method in [
    'void pointerMove(',
    'void enterControls(',
    'void exitControls(',
    'void interaction(',
    'void pointerLeave(',
    'bool advance(int ms)',
    'void reset()',
    'bool get needsTicking',
  ]) {
    check('策略包含 $method', policy.contains(method));
  }
  check('策略含防重复唤出的 armed 机制',
      policy.contains('_armed = false') && policy.contains('_armed = true'));
  check('策略含划过位移阈值', policy.contains('hoverMaxDrift') &&
      policy.contains('_drift > hoverMaxDrift'));
  check('策略悬停控制条时暂停空闲隐藏',
      policy.contains('if (_visible && !_overControls)'));
  check('策略注释说明隐藏后必须离开触发带',
      policy.contains('不重新武装') || policy.contains('必须先离开触发带'));

  // 控制层接入。
  check('控制层 import 策略',
      overlay.contains("import '../widgets/auto_hide_controls_policy.dart';"));
  check('控制层含 autoHide 参数', overlay.contains('this.autoHide = false,'));
  check('autoHide 默认关闭（不改变其它形态行为）',
      overlay.contains('this.autoHide = false,'));
  check('控制层含 autoHide 字段说明',
      overlay.contains('final bool autoHide;') &&
          overlay.contains('遥控器与手指不产生 hover'));
  check('控制层持有策略实例',
      overlay.contains('AutoHideControlsPolicy? _autoHidePolicy;'));
  check('控制层用单个周期 Timer 推进状态机',
      overlay.contains('Timer.periodic(') && overlay.contains('_autoHideTickMs'));
  check('只有 needsTicking 时才喂时间',
      overlay.contains('!policy.needsTicking'));
  check('只有 visibility 变化才 setState',
      overlay.contains('if (policy.advance(_autoHideTickMs)) setState(() {});'));
  check('dispose 会停止自动隐藏计时',
      RegExp(r'void dispose\(\) \{[\s\S]{0,200}_stopAutoHide\(\)').hasMatch(overlay));
  check('_stopAutoHide 取消 Timer 并复位策略',
      overlay.contains('_autoHideTicker?.cancel();') &&
          overlay.contains('_autoHidePolicy?.reset();'));
  check('didUpdateWidget 处理形态切换',
      overlay.contains('widget.autoHide != oldWidget.autoHide'));
  check('didUpdateWidget 处理全屏切换后坐标失效',
      overlay.contains('widget.fullscreen != oldWidget.fullscreen') &&
          overlay.contains('_autoHidePolicy?.pointerLeave();'));

  // 触发区检测：全幅 MouseRegion + LayoutBuilder 高度，不新增可见热区。
  check('控制层用 LayoutBuilder 取播放区高度',
      overlay.contains('LayoutBuilder(') && overlay.contains('_stageHeight ='));
  check('无界高度安全回退', overlay.contains('constraints.maxHeight.isFinite'));
  check('MouseRegion 监听 onHover',
      overlay.contains('onHover: _onHover,'));
  check('onHover 把局部坐标交给策略',
      RegExp(r'void _onHover\(PointerHoverEvent e\) \{[\s\S]{0,260}pointerMove\(')
          .hasMatch(overlay));
  check('onExit 通知策略 pointerLeave',
      overlay.contains('_autoHidePolicy?.pointerLeave();'));
  check('非自动隐藏形态仍走原 hover 展开',
      overlay.contains('if (widget.autoHide) return;'));

  // 显隐：滑出 + 淡出 + 不拦截，三者缺一不可。
  check('chromeVisible 兜底含钉住与暂停/无信号',
      overlay.contains('_pinned ||') && overlay.contains('_needsControls;'));
  check('自动隐藏形态唤出即完整展开',
      overlay.contains('bool get _expanded => widget.autoHide'));
  check('底部控制条隐藏时滑出屏幕',
      overlay.contains('bottom: chromeVisible ? 0 : -82,'));
  check('底部控制条隐藏时 IgnorePointer',
      overlay.contains('ignoring: !chromeVisible,'));
  check('底部控制条用 AnimatedOpacity 平滑淡入淡出',
      overlay.contains('opacity: chromeVisible ? 1 : 0,'));
  check('显隐共用同一动画时长',
      overlay.contains('static const Duration _autoHideAnim') &&
          RegExp(r'duration: _autoHideAnim').allMatches(overlay).length >= 2);
  check('滑入滑出用 easeOutCubic',
      overlay.contains('curve: Curves.easeOutCubic'));
  check('Stack 显式裁切防止画面外残影',
      overlay.contains('clipBehavior: Clip.hardEdge'));
  check('顶部信息条随控制层一起隐藏',
      overlay.contains('top: (expanded && chromeVisible) ? 0 : -72,'));
  check('频道号标签接收 chromeVisible',
      overlay.contains('_buildChannelTag(c, expanded, chromeVisible)'));

  // 显示期间控制项可操作：控制条自身 hover + 每次交互重置空闲。
  check('控制条自身监听 MouseRegion 进出',
      overlay.contains('onEnter: _onControlsEnter,') &&
          overlay.contains('onExit: _onControlsExit,'));
  check('进入控制条调用 enterControls',
      overlay.contains('_autoHidePolicy?.enterControls();'));
  check('离开控制条调用 exitControls',
      overlay.contains('_autoHidePolicy?.exitControls();'));
  check('所有 ctrl 按钮点击都重置空闲计时',
      RegExp(r'onPressed: onPressed == null[\s\S]{0,180}_noteInteraction\(\);')
          .hasMatch(overlay));
  check('音量滑块拖动也重置空闲计时',
      RegExp(r'onChanged: \(v\) \{[\s\S]{0,140}_noteInteraction\(\);')
          .hasMatch(overlay));
  check('频道入口按钮点击也重置空闲计时',
      overlay.contains('widget.onChannelListPressed!();') &&
          overlay.contains('_noteInteraction();'));

  // 形态开关：只在有鼠标的桌面启用，电视/触摸保持常驻。
  check('直播页传入 autoHide 形态开关',
      page.contains('autoHide: !widget.tvMode && !widget.touchInput,'));
  check('直播页注释说明遥控器/手指不启用原因',
      page.contains('否则自动隐藏后用户再也唤不出来'));
}

void main() {
  testInitial();
  testHoverDelay();
  testQuickSweep();
  testControlsUsable();
  testLeaveHide();
  testIdleHideAndRearm();
  testIdempotence();
  testBoundaries();
  testSources();
  print('');
  if (_fail == 0) {
    print('回归通过：$_pass/$_pass 断言通过');
    exit(0);
  }
  print('回归失败：$_pass/${_pass + _fail} 断言通过');
  exit(1);
}
