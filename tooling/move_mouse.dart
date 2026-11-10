// 鼠标移动工具（不点击），与 click_at.dart / capture_screen.dart 配套。
//
// 用途：验证「默认隐藏、按需显示」这类纯 hover 交互 —— 把指针移到边缘热区
// 会触发 MouseRegion，移回画面中央会触发 onExit；click_at.dart 一移动就点击，
// 无法单独验证 hover，也容易误触发播放器控制条。
//
// 运行：dart run tooling/move_mouse.dart <x> <y> [窗口标题]
//   带窗口标题时 x/y 按窗口内坐标解释；`shunbo` 为「顺播 shunbo」快捷名。
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
    stderr.writeln('用法：dart run tooling/move_mouse.dart <x> <y> [窗口标题]');
    exit(2);
  }
  final x = int.tryParse(args[0]);
  final y = int.tryParse(args[1]);
  if (x == null || y == null) {
    stderr.writeln('坐标必须是整数');
    exit(2);
  }
  var title = args.length > 2 && args[2].isNotEmpty ? args[2] : null;
  if (title == 'shunbo') title = '顺播 shunbo';

  final user32 = DynamicLibrary.open('user32.dll');
  try {
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
    // 与 click_at.dart / capture_screen.dart 一致：只显示、不改窗口状态。
    user32.lookupFunction<Int32 Function(IntPtr, Int32), int Function(int, int)>(
        'ShowWindow')(hwnd, 5);
    user32.lookupFunction<Int32 Function(IntPtr), int Function(int)>(
        'SetForegroundWindow')(hwnd);
    // 前台锁定会挡住 SetForegroundWindow；临时置顶保证指针确实落在目标窗口上。
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
    sleep(const Duration(milliseconds: 400));
  }

  final setCursor = user32.lookupFunction<Int32 Function(Int32, Int32),
      int Function(int, int)>('SetCursorPos');
  if (setCursor(sx, sy) == 0) {
    stderr.writeln('SetCursorPos 失败');
    exit(1);
  }
  print('已移动指针到 ($sx, $sy)${title == null ? '' : '（窗口内 $x,$y）'}');
}
