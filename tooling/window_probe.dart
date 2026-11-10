// 窗口度量探针：打印前台窗口的位置/尺寸与屏幕尺寸（Win32 GDI/User32）。
//
// 为什么需要：本机截图工具与 App 对 DPI 的感知不一致，窗口「看起来铺满屏幕」
// 到底是真最大化、还是被 DPI 放大到超出屏幕，靠截图判断会判断错
// （本项目就为此误判过一次：频道栏其实在屏幕外）。
// 这里直接读 GetWindowRect，和 GetSystemMetrics 的结果放在一起比，一目了然。
//
// 运行：dart run tooling/window_probe.dart
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

void main() {
  final user32 = DynamicLibrary.open('user32.dll');
  final getSystemMetrics =
      user32.lookupFunction<Int32 Function(Int32), int Function(int)>('GetSystemMetrics');
  final getForegroundWindow =
      user32.lookupFunction<IntPtr Function(), int Function()>('GetForegroundWindow');
  final getWindowRect =
      user32.lookupFunction<Int32 Function(IntPtr, Pointer<_Rect>), int Function(int, Pointer<_Rect>)>(
          'GetWindowRect');
  final getWindowTextW = user32.lookupFunction<Int32 Function(IntPtr, Pointer<Utf16>, Int32),
      int Function(int, Pointer<Utf16>, int)>('GetWindowTextW');
  final getDpiForWindow =
      user32.lookupFunction<Uint32 Function(IntPtr), int Function(int)>('GetDpiForWindow');

  // 与本工程的截图工具保持一致：声明 DPI 感知后再取尺寸，
  // 否则窗口矩形和屏幕尺寸都是被 200% 缩放过的虚拟坐标，看不出真实布局。
  try {
    user32.lookupFunction<Int32 Function(IntPtr), int Function(int)>(
        'SetProcessDpiAwarenessContext')(-4);
  } catch (_) {}

  final sw = getSystemMetrics(0);
  final sh = getSystemMetrics(1);
  print('屏幕（本进程看到的逻辑尺寸）：${sw}x$sh');

  final hwnd = getForegroundWindow();
  if (hwnd == 0) {
    stderr.writeln('拿不到前台窗口');
    exit(1);
  }
  final rect = calloc<_Rect>();
  final title = calloc<Uint16>(512);
  try {
    if (getWindowRect(hwnd, rect) == 0) {
      stderr.writeln('GetWindowRect 失败');
      exit(1);
    }
    final len = getWindowTextW(hwnd, title.cast<Utf16>(), 512);
    final name = title.cast<Utf16>().toDartString(length: len < 0 ? 0 : len);
    final dpi = getDpiForWindow(hwnd);
    print('前台窗口标题：$name');
    print('窗口矩形：left=${rect.ref.left} top=${rect.ref.top} '
        'right=${rect.ref.right} bottom=${rect.ref.bottom}');
    print('窗口尺寸：${rect.ref.right - rect.ref.left}x${rect.ref.bottom - rect.ref.top}');
    print('窗口 DPI：$dpi（缩放 ${(dpi / 96 * 100).toStringAsFixed(0)}%）');
    final overflowX = rect.ref.right - sw;
    final overflowY = rect.ref.bottom - sh;
    print('右侧溢出：$overflowX px，底部溢出：$overflowY px');
  } finally {
    calloc.free(rect);
    calloc.free(title);
  }
}
