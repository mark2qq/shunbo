// 左右两侧「伸缩控件」默认隐藏 / 按需显示 / 行为一致的回归。
//
// 分两层：
//   ① 纯 Dart 策略状态机（EdgeHandlePolicy）——可直接实例化，验证初始隐藏、
//      进入淡入、离开淡出、悬停计时与点击互斥、隐藏时不可点；
//   ② 源码静态护栏——验证左右两侧确实共用同一组件、初始展开布局不变、
//      旧的「划过就弹开」已移除、全屏与窄屏分支不受影响、热区不抢点击。
// 这些是 UI 行为，裸 dart run 无法 import package:flutter，因此渲染侧用
// 静态检查 + 安装版实机走查（见 CHECKLIST.md）共同覆盖。
//
// 运行：dart run tooling/verify_edge_handles.dart
import 'dart:io';

import 'package:shunbo/ui/widgets/edge_handle_policy.dart';

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

/// Windows 工作区里 `live_page.dart` 是 CRLF、`app_shell.dart` 是 LF；
/// 统一成 LF 后再做多行匹配，避免跨平台 / 跨编辑器换行差异造成假失败。
String _src(String path) =>
    File(path).readAsStringSync().replaceAll('\r\n', '\n');

// ── ① 纯 Dart 状态机 ────────────────────────────────────────────

void testPolicy() {
  final p = EdgeHandlePolicy();

  check('初始状态手柄隐藏（页面加载不显示）', !p.visible);
  check('初始状态没有悬停计时', !p.hoverPending);
  check('隐藏时点击不生效', !p.tap());
  check('隐藏时悬停计时到点不生效', !p.onHoverElapsed());

  check('鼠标进入边缘热区需要启动悬停计时', p.enter());
  check('进入后手柄按需淡入', p.visible);
  check('进入后悬停计时有效', p.hoverPending);
  check('重复进入不重复启动计时', !p.enter());

  check('悬停计时到点允许自动展开', p.onHoverElapsed());
  check('自动展开后计时失效', !p.hoverPending);
  check('计时不会重复触发展开', !p.onHoverElapsed());
  check('自动展开后手柄仍可见（鼠标未离开）', p.visible);

  p.exit();
  check('鼠标离开后手柄淡出', !p.visible);
  check('鼠标离开后计时被撤销', !p.hoverPending);
  check('离开后计时到点不展开', !p.onHoverElapsed());
  check('离开后点击不展开', !p.tap());

  check('再次进入可重新按需显示', p.enter());
  check('再次进入后可见', p.visible);
  check('点击立即展开', p.tap());
  check('点击会撤销尚未触发的悬停计时', !p.hoverPending);
  check('点击后悬停计时不再二次展开', !p.onHoverElapsed());
  check('点击不需要鼠标离开就能收尾', p.visible);

  p.reset();
  check('复位后回到默认隐藏', !p.visible);
  check('复位后没有残留计时', !p.hoverPending);

  // 左右两侧共用同一个策略类，行为必须逐项一致。
  final left = EdgeHandlePolicy();
  final right = EdgeHandlePolicy();
  check('左右实例初始状态一致', left.visible == right.visible);
  check('左右实例进入结果一致', left.enter() == right.enter());
  check('左右实例显隐一致', left.visible == right.visible);
  check('左右实例点击结果一致', left.tap() == right.tap());
  left.exit();
  right.exit();
  check('左右实例离开后显隐一致', left.visible == right.visible);
}

// ── ② 源码静态护栏 ──────────────────────────────────────────────

void testSources() {
  final policy = _src('lib/ui/widgets/edge_handle_policy.dart');
  final handle = _src('lib/ui/widgets/edge_reveal_handle.dart');
  final shell = _src('lib/app/app_shell.dart');
  final page = _src('lib/ui/live/live_page.dart');

  check('显隐策略是默认隐藏', policy.contains('bool _visible = false;'));
  check('显隐策略不依赖 flutter（可裸 dart run 回归）',
      !policy.contains("package:flutter"));
  check('策略把显示与切换拆成两步',
      policy.contains('bool enter()') && policy.contains('bool onHoverElapsed()'));
  check('策略保证点击与悬停互斥', policy.contains('_hoverPending = false;'));

  check('共享组件同时提供左右方向',
      handle.contains('enum EdgeSide') &&
          handle.contains('left') &&
          handle.contains('right'));
  check('共享组件使用 AnimatedOpacity 淡入淡出',
      handle.contains('AnimatedOpacity('));
  // 触摸形态（persistent）没有 hover，手柄必须常驻可点；非触摸形态仍按
  // 「隐藏时不响应点击」处理——两种形态的可见性都由同一个 visible 变量决定。
  check('可见性由「常驻 or 策略」共同决定',
      handle.contains('final visible = widget.persistent || _policy.visible;'));
  check('非触摸形态隐藏时 IgnorePointer 不响应点击',
      handle.contains('IgnorePointer(') && handle.contains('ignoring: !visible'));
  check('触摸形态常驻半透明、悬停变实',
      handle.contains('widget.persistent ? (_policy.visible ? 1.0 : 0.62)'));
  check('触摸形态点击不看策略（常驻即可点）',
      handle.contains('if (!widget.persistent && !_policy.tap()) return;'));
  check('触摸形态不做悬停自动展开',
      handle.contains('if (widget.persistent) return;'));
  check('共享组件默认 400ms 悬停缓冲',
      handle.contains('this.hoverDelay = const Duration(milliseconds: 400)'));
  check('共享组件热区宽度保持 30px',
      handle.contains('static const double hitWidth = 30;'));
  check('共享组件保留原手柄垂直留白',
      handle.contains('EdgeInsets.symmetric(vertical: 80)'));
  // 透明热区不该抢点击（否则画面最右侧 30px 点不动）；但常驻形态下
  // 整块热区就是「打开侧栏」的按钮，必须整块可点，这是有意为之的差异。
  check('共享组件非触摸态不抢点击',
      handle.contains('visible ? HitTestBehavior.opaque : HitTestBehavior.deferToChild'));
  check('共享组件不使用会穿透的 translucent',
      !handle.contains('behavior: HitTestBehavior.translucent'));
  check('共享组件卸载时取消悬停计时', handle.contains('_cancelHover();'));
  check('按需收起按钮共用同一淡入时长',
      handle.contains('class OnDemandCollapseButton') &&
          handle.contains('duration: EdgeRevealHandle.fadeDuration'));
  check('按需收起按钮固定占位不引起布局跳动',
      handle.contains('width: 40') && handle.contains('height: 40'));

  check('左侧引入共享组件', shell.contains("import '../ui/widgets/edge_reveal_handle.dart';"));
  check('右侧引入共享组件', page.contains("import '../widgets/edge_reveal_handle.dart';"));
  check('左侧使用左缘手柄',
      shell.contains('EdgeRevealHandle(side: EdgeSide.left'));
  check('右侧使用右缘手柄',
      RegExp(r'EdgeRevealHandle\(\s*side: EdgeSide\.right,').hasMatch(page));
  check('左侧手柄只在收起态渲染',
      shell.contains('if (!_sideOpen)\n          EdgeRevealHandle('));
  check('右侧手柄只在收起态渲染',
      page.contains('if (!_railOpen)\n          EdgeRevealHandle('));
  check('旧的左侧「划过即展开」已移除',
      !shell.contains('onEnter: (_) => _openSide()'));
  check('旧的右侧「划过即展开」已移除',
      !page.contains('onEnter: (_) => _openRail()'));

  check('左侧仍有按需收起按钮',
      shell.contains('OnDemandCollapseButton(') &&
          shell.contains('side: EdgeSide.left'));
  check('右侧仍有按需收起按钮',
      page.contains('OnDemandCollapseButton(') &&
          page.contains('side: EdgeSide.right'));
  check('左侧收起按钮只在悬停时可见',
      shell.contains('visible: _sideHovering') ||
          shell.contains('collapseVisible: _sideHovering'));
  // 触摸形态没有悬停：收起按钮必须常驻，否则用户只能等 6 秒自动收起。
  check('右侧收起按钮悬停或触摸形态可见（内嵌列表除外）',
      RegExp(r'visible: !inline &&\s*\(_railHovering \|\| widget\.touchInput\)')
          .hasMatch(page));
  check('左侧悬停状态驱动重建',
      shell.contains('setState(() => _sideHovering = true)'));
  check('右侧悬停状态驱动重建',
      page.contains('setState(() => _railHovering = true)'));

  check('左侧初始仍展开（首屏布局不变）',
      shell.contains('bool _sideOpen = true;'));
  // 桌面/电视首屏「视频优先、频道栏默认收起」：右侧展开的深色面板
  // 曾让手机横屏首屏出现一大块「右边黑背景」。浮层默认收起后，
  // 手机横屏另走「左画面 + 右频道常驻双栏」（见 _buildLandscapeDualPane），
  // 桌面/电视继续沿用这里的浮层语义。
  check('右侧浮层初始收起（视频优先）',
      page.contains('bool _railOpen = false;'));
  check('左侧保留 6 秒自动隐藏',
      shell.contains('_scheduleSideHide(const Duration(seconds: 6))'));
  check('右侧保留 6 秒自动隐藏',
      page.contains('_scheduleRailHide(const Duration(seconds: 6))'));
  check('左侧离开 1.2 秒收起',
      shell.contains('Duration(milliseconds: 1200)'));
  check('右侧离开 1.2 秒收起',
      page.contains('Duration(milliseconds: 1200)'));
  check('左侧展开后重排自动隐藏（与右侧一致）',
      shell.indexOf('_scheduleSideHide(const Duration(seconds: 6))',
              shell.indexOf('void _openSide()')) <
          shell.indexOf('void _closeSide()'));
  check('右侧展开后重排自动隐藏（与左侧一致）',
      page.indexOf('_scheduleRailHide(const Duration(seconds: 6))',
              page.indexOf('void _openRail()')) <
          page.indexOf('void _closeRail()'));
  check('左侧有显式收起入口',
      shell.contains('void _closeSide()') && shell.contains('onCollapse: _closeSide'));
  check('右侧有显式收起入口',
      page.contains('void _closeRail()') && page.contains('onPressed: _closeRail'));

  // 全屏分支必须提前返回：左侧浮层（`_buildSideBarOverlay()`）不能渲染。
  //
  // 断言写成「允许任意缩进」而不是逐字匹配：这一层后来被 PopScope/LayoutBuilder
  // 包住，整体缩进右移了两格，文字匹配就会误报「功能坏了」。
  // 要校验的是「全屏时提前 return，不落到浮层分支」这个语义，不是空格数。
  check('全屏时左侧浮层整体不渲染',
      RegExp(r'if \(_fullscreen\) \{\s*return Scaffold\(body: content\);\s*\}')
          .hasMatch(shell));
  // 全屏仍不渲染「通用浮层」：手机横屏改走专门的全屏舞台（画面铺满 +
  // 右侧常驻频道入口/抽屉），桌面/TV 依旧是纯画面，左侧浮层绝不出现。
  check('全屏时右侧通用浮层整体不渲染',
      RegExp(r'if \(widget\.fullscreen\) \{\s*return _buildFullscreenStage\(c, w, h, kind\);\s*\}')
          .hasMatch(page));
  check('全屏舞台用 Positioned.fill 铺满画面（不套 16:9）',
      RegExp(r'final stage = Positioned\.fill\(child: _buildVideoStage\(c, kind: kind\)\);')
          .hasMatch(page) &&
          page.contains('fill: true'));
  check('左侧浮层只在宽屏分支出现一次',
      '_buildSideBarOverlay(),'.allMatches(shell).length == 1);
  // 浮层只在「宽屏」与「窄屏横屏」两处渲染：竖屏用的是内嵌列表，
  // 全屏则整块不渲染。三处分支各司其职，数量变化必须被人看见。
  check('右侧浮层只在宽屏与窄屏横屏两处渲染',
      '_buildRailOverlay(c,'.allMatches(page).length == 2);
  check('窄屏底栏导航未受影响',
      shell.contains('bottomNavigationBar: NavigationBar('));
  check('窄屏频道栏仍为上下布局',
      RegExp(r'Expanded\(child: _buildRailInner\(c, inline: true\)\)').hasMatch(page));
}

void main() {
  testPolicy();
  testSources();
  print('');
  if (_fail == 0) {
    print('回归通过：$_pass/$_pass 断言通过');
    exit(0);
  }
  print('回归失败：$_pass/${_pass + _fail} 断言通过');
  exit(1);
}
