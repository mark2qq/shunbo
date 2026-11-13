import 'package:flutter/services.dart';

/// 桌面端窗口全屏通道（`shunbo/window`）。
///
/// 为什么必须另开一条通道：`SystemChrome.setEnabledSystemUIMode` 在 Windows 上
/// **不隐藏任务栏、也不去掉标题栏**——它只影响 Flutter 自己认为的「系统 UI 区域」。
/// 于是点「全屏」的实际效果只是内容区变大一点，任务栏照样压在画面底部，
/// 用户看到的是「假全屏」。
///
/// 真全屏必须由 runner 改窗口本身：去掉 `WS_OVERLAPPEDWINDOW`（无标题栏/边框）、
/// 覆盖整块显示器矩形、再让 shell 把窗口标记为全屏
/// （`ITaskbarList2::MarkFullscreenWindow`，任务栏自动让位）。
///
/// 未注册该通道时（Android / 浏览器 / 未更新的旧包）静默返回 false：
/// 全屏是「尽量做到」的能力，拿不到不该让按钮报错或卡住。
class WindowChannel {
  const WindowChannel({
    MethodChannel channel = const MethodChannel('shunbo/window'),
  }) : _channel = channel;

  final MethodChannel _channel;

  /// 进入 / 退出真全屏。返回 runner 是否真的执行了（false = 该平台不支持）。
  Future<bool> setFullscreen(bool enabled) async {
    try {
      final ok = await _channel.invokeMethod<bool>(
        'setFullscreen',
        <String, dynamic>{'enabled': enabled},
      );
      return ok == true;
    } on MissingPluginException {
      // 桌面端以外的平台没有这条通道，属于正常分支而不是错误。
      return false;
    } catch (_) {
      // 窗口操作失败（例如被组策略限制）同样不该冒泡到 UI。
      return false;
    }
  }

  /// 接收 runner 侧的 `toggleFullscreen`（Alt+Enter）。
  ///
  /// 为什么不让原生自己切窗口状态：全屏是个**跨层**状态——Dart 侧要靠它决定
  /// 是否渲染侧栏、是否让点播页进影院模式。原生单独把窗口切了，Dart 还认为
  /// 自己在窗口模式，画面就会「铺满了但侧栏还在」。所以原生只上报意图，
  /// 真正的状态翻转统一由 `AppShell` 做。
  void onToggleFullscreen(VoidCallback? callback) {
    if (callback == null) {
      _channel.setMethodCallHandler(null);
      return;
    }
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'toggleFullscreen') callback();
      return null;
    });
  }
}
