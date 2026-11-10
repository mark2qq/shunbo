// 鼠标点击工具（纯 Dart FFI 调 Win32），供 UI 走查与「换线 / 切台」这类交互验证。
//
// 为什么不用 PowerShell 的 SendKeys / .NET：本机安全策略拦了 `Add-Type`
// 与程序集加载（见 capture_screen.dart 的说明），只能自己调 user32。
//
// 运行：dart run tooling/click_at.dart <x> <y> [窗口标题]
//   带窗口标题时，x/y 按**窗口内坐标**解释（会换算成屏幕坐标），
//   这样不必每次去算窗口在屏幕上的位置。
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

final class _Rect extends Struct {
  @Int32()
  external int left;
  @Int32()
  external int top;
  @Int32()
  external int right;
  @Int32()
  external int bottom;
}

void main(List<String> args) {
  if (args.length < 2) {
    stderr.writeln('用法：dart run tooling/click_at.dart <x> <y> [窗口标题]');
    exit(2);
  }
  final x = int.tryParse(args[0]);
  final y = int.tryParse(args[1]);
  if (x == null || y == null) {
    stderr.writeln('坐标必须是整数');
    exit(2);
  }
  var title = args.length > 2 && args[2].isNotEmpty ? args[2] : null;
  // `shunbo` 快捷参数：硬编码中文全名做精确匹配（命令行传中文会乱码），
  // 且避免命中标题含 "workbuddy:shunbo" 的浏览器标签页。
  if (title == 'shunbo') title = '顺播 shunbo';

  final user32 = DynamicLibrary.open('user32.dll');
  try {
    // 与截图工具一致：先声明 DPI 感知，坐标才是物理像素。
    user32.lookupFunction<Int32 Function(IntPtr), int Function(int)>(
        'SetProcessDpiAwarenessContext')(-4);
  } catch (_) {}

  var sx = x;
  var sy = y;
  if (title != null) {
    final find = user32.lookupFunction<IntPtr Function(IntPtr, Pointer<Utf16>),
        int Function(int, Pointer<Utf16>)>('FindWindowW');
    final ptr = title.toNativeUtf16();
    final hwnd = find(0, ptr);
    calloc.free(ptr);
    if (hwnd == 0) {
      stderr.writeln('找不到窗口「$title」');
      exit(1);
    }
    // SW_SHOW(5)：只保证窗口可见，不改变最大化/还原状态。
    // 原来是 SW_RESTORE(9)，会把最大化窗口缩回 854 宽，AppShell/LivePage
    // 随即走窄屏分支（底栏 + 上下布局），侧边伸缩控件根本不渲染。
    // 与 capture_screen.dart 保持一致，避免「点一下、截一张」时窗口来回跳。
    user32.lookupFunction<Int32 Function(IntPtr, Int32), int Function(int, int)>(
        'ShowWindow')(hwnd, 5);
    user32.lookupFunction<Int32 Function(IntPtr), int Function(int)>(
        'SetForegroundWindow')(hwnd);
    // 前台锁定会挡住 SetForegroundWindow，窗口仍在浏览器后面，点击就落空。
    // 临时 TOPMOST 不依赖前台权限；后续的 capture_screen.dart 截完会恢复。
    user32.lookupFunction<
        Int32 Function(IntPtr, IntPtr, Int32, Int32, Int32, Int32, Uint32),
        int Function(int, int, int, int, int, int, int)>('SetWindowPos')(
      hwnd, -1, 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0040,
    );

    final rectPtr = calloc<_Rect>();
    final ok = user32.lookupFunction<Int32 Function(IntPtr, Pointer<_Rect>),
        int Function(int, Pointer<_Rect>)>('GetWindowRect')(hwnd, rectPtr) != 0;
    if (ok) {
      sx = rectPtr.ref.left + x;
      sy = rectPtr.ref.top + y;
    }
    calloc.free(rectPtr);
    // 等窗口真正到前台，否则点击会落到别的窗口上。
    sleep(const Duration(milliseconds: 400));
  }

  final setCursor = user32.lookupFunction<Int32 Function(Int32, Int32),
      int Function(int, int)>('SetCursorPos');
  final mouseEvent = user32.lookupFunction<
      Void Function(Uint32, Uint32, Uint32, UintPtr),
      void Function(int, int, int, int)>('mouse_event');

  const leftDown = 0x0002;
  const leftUp = 0x0004;

  if (setCursor(sx, sy) == 0) {
    stderr.writeln('SetCursorPos 失败');
    exit(1);
  }
  sleep(const Duration(milliseconds: 120));
  mouseEvent(leftDown, 0, 0, 0);
  sleep(const Duration(milliseconds: 60));
  mouseEvent(leftUp, 0, 0, 0);

  print('已点击 ($sx, $sy)${title == null ? '' : '（窗口内 $x,$y）'}');
}
