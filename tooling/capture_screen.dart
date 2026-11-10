// 全屏截图（纯 Dart FFI 调 Win32 GDI），供 UI 走查与回归留证。
//
// 为什么不用 PowerShell 的 CopyFromScreen：本机安全策略把 `Add-Type` 与
// `Reflection.Assembly` 加载都拦了（「编译并加载 .NET 代码」），
// 而 `flutter screenshot` 依赖 VM Service——本机 VM Service 握手失败（见 README）。
// 所以自己调 GDI：CreateCompatibleBitmap + StretchBlt + GetDIBits，直接写 BMP。
//
// 为什么输出 BMP 而不是 PNG：BMP 不需要压缩库，几十行就能写完；
// 看图工具（含本项目走查流程）都认 BMP。
//
// 运行：dart run tooling/capture_screen.dart [输出路径] [缩放百分比] [窗口标题]
//
// 传了窗口标题就按该窗口的矩形截屏幕区域，并把它置前。
// **不能用 PrintWindow**：Flutter 桌面端是 GPU 合成窗口，PrintWindow 会
// 「成功但留白」，实测拿到的是一张全白位图，比截到 IDE 更难排查。
// 所以走屏幕矩形 StretchBlt，前提是目标窗口在最上层。
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

const int _srcCopy = 0x00CC0020;
// SW_SHOW(5)：只保证窗口可见，**不改变最大化/还原状态**。
// 原来是 SW_RESTORE(9)，每截一张图就把最大化窗口缩回普通尺寸，
// 触发窄屏布局与 MouseRegion 的 enter/exit 抖动，hover 类验收会失真。
const int _swShow = 5;
const int _colorOnColor = 3;
const int _dibRgbColors = 0;

/// Win32 RECT（四个 LONG）。
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

Future<void> main(List<String> args) async {
  final out = args.isNotEmpty ? args[0] : 'build/screen.bmp';
  final percent = args.length > 1 ? (int.tryParse(args[1]) ?? 50) : 50;
  var windowTitle = args.length > 2 && args[2].isNotEmpty ? args[2] : null;
  // `shunbo` 是本项目窗口的快捷参数：内部换成硬编码的中文全名做**精确匹配**。
  // 两个原因：① Windows 命令行传中文会乱码；② 浏览器标签页常叫
  // "workbuddy:shunbo"，按子串枚举会先命中浏览器，截到完全无关的网页。
  final bool exactTitle = windowTitle == 'shunbo';
  if (exactTitle) windowTitle = '顺播 shunbo';

  final user32 = DynamicLibrary.open('user32.dll');
  final gdi32 = DynamicLibrary.open('gdi32.dll');

  // 必须先声明 DPI 感知，再取屏幕尺寸／建 DC。
  try {
    final setCtx = user32.lookupFunction<Int32 Function(IntPtr), int Function(int)>(
        'SetProcessDpiAwarenessContext');
    // -4 = DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2
    setCtx(-4);
  } catch (_) {
    // 老系统没有这个 API：退化为不感知，用户可以显式传缩放比例。
  }

  final getDc = user32.lookupFunction<IntPtr Function(IntPtr), int Function(int)>('GetDC');
  final releaseDc =
      user32.lookupFunction<Int32 Function(IntPtr, IntPtr), int Function(int, int)>('ReleaseDC');
  final getSystemMetrics =
      user32.lookupFunction<Int32 Function(Int32), int Function(int)>('GetSystemMetrics');
  final findWindow = user32.lookupFunction<IntPtr Function(IntPtr, Pointer<Utf16>),
      int Function(int, Pointer<Utf16>)>('FindWindowW');
  final setWindowPos = user32.lookupFunction<
      Int32 Function(IntPtr, IntPtr, Int32, Int32, Int32, Int32, Uint32),
      int Function(int, int, int, int, int, int, int)>('SetWindowPos');
  // HWND_TOPMOST / HWND_NOTOPMOST，SWP_NOMOVE | SWP_NOSIZE | SWP_SHOWWINDOW。
  const int hwndTopmost = -1;
  const int hwndNoTopmost = -2;
  const int swpFlags = 0x0001 | 0x0002 | 0x0040;
  const int swpRestoreFlags = 0x0001 | 0x0002;

  final createCompatibleDc =
      gdi32.lookupFunction<IntPtr Function(IntPtr), int Function(int)>('CreateCompatibleDC');
  final createCompatibleBitmap = gdi32.lookupFunction<IntPtr Function(IntPtr, Int32, Int32),
      int Function(int, int, int)>('CreateCompatibleBitmap');
  final selectObject =
      gdi32.lookupFunction<IntPtr Function(IntPtr, IntPtr), int Function(int, int)>('SelectObject');
  final setStretchBltMode =
      gdi32.lookupFunction<Int32 Function(IntPtr, Int32), int Function(int, int)>(
          'SetStretchBltMode');
  final stretchBlt = gdi32.lookupFunction<
      Int32 Function(IntPtr, Int32, Int32, Int32, Int32, IntPtr, Int32, Int32, Int32, Int32, Int32),
      int Function(int, int, int, int, int, int, int, int, int, int,
          int)>('StretchBlt');
  final getDibits = gdi32.lookupFunction<
      Int32 Function(IntPtr, IntPtr, Int32, Int32, Pointer<Void>, Pointer<Void>, Int32),
      int Function(int, int, int, int, Pointer<Void>, Pointer<Void>,
          int)>('GetDIBits');
  final deleteObject =
      gdi32.lookupFunction<Int32 Function(IntPtr), int Function(int)>('DeleteObject');
  final deleteDc = gdi32.lookupFunction<Int32 Function(IntPtr), int Function(int)>('DeleteDC');

  const smCxScreen = 0;
  const smCyScreen = 1;

  // 目标窗口句柄（传了标题才找）。
  int hwnd = 0;
  if (windowTitle != null) {
    if (exactTitle) {
      final titlePtr = windowTitle.toNativeUtf16();
      hwnd = findWindow(0, titlePtr);
      calloc.free(titlePtr);
    } else {
      // 模糊匹配：标题里包含给定串就算命中。
      hwnd = _findWindowBySubstring(user32, findWindow, windowTitle);
    }
    if (hwnd == 0) {
      stderr.writeln('找不到窗口「$windowTitle」，退回整屏截图');
    } else {
      // 按屏幕矩形拷贝，目标窗口必须在最上层，否则截到的是 IDE。
      user32
          .lookupFunction<Int32 Function(IntPtr, Int32), int Function(int, int)>(
              'ShowWindow')(
        hwnd,
        _swShow,
      );
      user32
          .lookupFunction<Int32 Function(IntPtr), int Function(int)>(
              'SetForegroundWindow')(hwnd);
      user32
          .lookupFunction<Int32 Function(IntPtr), int Function(int)>(
              'BringWindowToTop')(hwnd);
      // Windows 有前台锁定：独立截图进程调 SetForegroundWindow 常被拒，
      // 实测仍会截到覆盖在上面的浏览器。TOPMOST 不依赖前台权限，
      // 截完立刻恢复（见文末），不会把用户窗口一直钉在最上层。
      setWindowPos(hwnd, hwndTopmost, 0, 0, 0, 0, swpFlags);
      // 给 GPU 合成窗口一帧时间重绘，否则可能截到上一帧或空白。
      sleep(const Duration(milliseconds: 350));
    }
  }

  // 源矩形：整屏或窗口矩形。
  int x0 = 0;
  int y0 = 0;
  int sw = getSystemMetrics(smCxScreen);
  int sh = getSystemMetrics(smCyScreen);
  if (hwnd != 0) {
    final rectPtr = calloc<_Rect>();
    final got = user32.lookupFunction<Int32 Function(IntPtr, Pointer<_Rect>),
            int Function(int, Pointer<_Rect>)>('GetWindowRect')(
          hwnd, rectPtr,
        ) !=
        0;
    if (got) {
      final r = rectPtr.ref;
      x0 = r.left < 0 ? 0 : r.left;
      y0 = r.top < 0 ? 0 : r.top;
      sw = (r.right - x0).clamp(16, getSystemMetrics(smCxScreen) - x0);
      sh = (r.bottom - y0).clamp(16, getSystemMetrics(smCyScreen) - y0);
    }
    calloc.free(rectPtr);
  }

  // 缩放后尺寸。
  final w = (sw * percent ~/ 100).clamp(16, sw);
  final h = (sh * percent ~/ 100).clamp(16, sh);

  final screenDc = getDc(0);
  if (screenDc == 0) {
    stderr.writeln('GetDC 失败');
    exit(1);
  }

  // 第一张位图：源尺寸（窗口自身内容或屏幕矩形）。
  final memDc = createCompatibleDc(screenDc);
  final bitmap = createCompatibleBitmap(screenDc, sw, sh);
  final old = selectObject(memDc, bitmap);
  setStretchBltMode(memDc, _colorOnColor);

  if (hwnd != 0) {
    // 按窗口矩形直接拷屏幕区域。注意：Flutter 桌面端是 GPU 合成窗口，
    // PrintWindow 会「成功但留白」，所以这里**不用** PrintWindow，只做屏幕矩形拷贝。
    // 前提是目标窗口在当前最上层（刚启动 / 刚被点过的 shunbo 都满足条件）。
    stretchBlt(memDc, 0, 0, sw, sh, screenDc, x0, y0, sw, sh, _srcCopy);
  } else {
    stretchBlt(memDc, 0, 0, sw, sh, screenDc, x0, y0, sw, sh, _srcCopy);
  }

  // 第二张位图：缩放后输出。
  final outDc = createCompatibleDc(screenDc);
  final outBitmap = createCompatibleBitmap(screenDc, w, h);
  final outOld = selectObject(outDc, outBitmap);
  setStretchBltMode(outDc, _colorOnColor);
  final ok2 = stretchBlt(outDc, 0, 0, w, h, memDc, 0, 0, sw, sh, _srcCopy);
  if (ok2 == 0) {
    stderr.writeln('StretchBlt 缩放失败');
    exit(1);
  }

  // BITMAPINFOHEADER：40 字节。高度给负值 → 自顶向下的像素，写 BMP 时不用翻转。
  final bmi = calloc<Uint8>(40);
  final i32 = bmi.cast<Int32>();
  final i16 = bmi.cast<Int16>();
  final imageSize = w * h * 4;
  i32[0] = 40; // biSize
  i32[1] = w; // biWidth
  i32[2] = -h; // biHeight（负 = top-down）
  i16[6] = 1; // biPlanes
  i16[7] = 32; // biBitCount
  i32[4] = 0; // biCompression = BI_RGB
  i32[5] = imageSize; // biSizeImage

  final pixels = calloc<Uint8>(imageSize);
  final lines = getDibits(outDc, outBitmap, 0, h, pixels.cast<Void>(), bmi.cast<Void>(), _dibRgbColors);
  if (lines == 0) {
    stderr.writeln('GetDIBits 失败');
    exit(1);
  }

  final file = File(out);
  file.parent.createSync(recursive: true);
  final sink = file.openSync(mode: FileMode.write);
  try {
    // BITMAPFILEHEADER：14 字节 + 40 字节 INFOHEADER。
    final header = calloc<Uint8>(54);
    final hb = header.asTypedList(54);
    hb[0] = 0x42; // 'B'
    hb[1] = 0x4D; // 'M'
    final fileSize = 54 + imageSize;
    hb.buffer.asByteData().setUint32(2, fileSize, Endian.little);
    hb.buffer.asByteData().setUint32(10, 54, Endian.little); // 像素数据偏移
    hb.buffer.asByteData().setUint32(14, 40, Endian.little);
    hb.buffer.asByteData().setInt32(18, w, Endian.little);
    hb.buffer.asByteData().setInt32(22, -h, Endian.little);
    hb.buffer.asByteData().setUint16(26, 1, Endian.little);
    hb.buffer.asByteData().setUint16(28, 32, Endian.little);
    hb.buffer.asByteData().setUint32(30, 0, Endian.little);
    hb.buffer.asByteData().setUint32(34, imageSize, Endian.little);
    sink.writeFromSync(hb);
    sink.writeFromSync(pixels.asTypedList(imageSize));
    calloc.free(header);
  } finally {
    sink.closeSync();
    calloc.free(pixels);
    calloc.free(bmi);
    selectObject(memDc, old);
    deleteObject(bitmap);
    deleteDc(memDc);
    selectObject(outDc, outOld);
    deleteObject(outBitmap);
    deleteDc(outDc);
    releaseDc(0, screenDc);
    // 无论成功失败都撤销临时置顶，避免给用户留下一个永远在最前的窗口。
    if (hwnd != 0) {
      setWindowPos(hwnd, hwndNoTopmost, 0, 0, 0, 0, swpRestoreFlags);
    }
  }

  print('截图已保存：$out（${w}x$h，源 ${sw}x$sh @ $x0,$y0）');
}

/// 按标题子串找窗口（枚举所有顶层窗口匹配）。
int _findWindowBySubstring(
  DynamicLibrary user32,
  int Function(int, Pointer<Utf16>) findWindow,
  String substring,
) {
  // FindWindowW 只支持精确/前缀，不够用；这里用 EnumWindows 枚举再比对。
  final results = <int>[];
  final enumProc = Pointer.fromFunction<Int32 Function(IntPtr, IntPtr)>(
    _enumWindowsProc,
    1,
  );
  final ctxPtr = calloc<EnumCtx>();
  ctxPtr.ref.target = substring.toNativeUtf16();
  ctxPtr.ref.found = 0;
  // LPARAM 在 64 位 Windows 是 LONG_PTR（8 字节）。早期这里写成 Int32，
  // `ctxPtr.address` 被截成 32 位，回调里 `Pointer.fromAddress(lParam)` 拿到野地址，
  // 于是窗口枚举永远匹配不到、静默退回整屏截图（截到的全是 IDE）。
  // 回调签名里的第二个参数本来就用的 IntPtr，只有这处 lookup 写错了。
  final enumWindows = user32.lookupFunction<
      Int32 Function(Pointer<NativeFunction<Int32 Function(IntPtr, IntPtr)>>, IntPtr),
      int Function(Pointer<NativeFunction<Int32 Function(IntPtr, IntPtr)>>, int)>('EnumWindows');
  enumWindows(enumProc, ctxPtr.address);
  results.add(ctxPtr.ref.found);
  calloc.free(ctxPtr);
  return results.first;
}

final class EnumCtx extends Struct {
  external Pointer<Utf16> target;
  @IntPtr()
  external int found;
}

int _enumWindowsProc(int hwnd, int lParam) {
  final ctx = Pointer<EnumCtx>.fromAddress(lParam);
  // 跳过不可见窗口。
  final user32 = DynamicLibrary.open('user32.dll');
  final isWindowVisible = user32.lookupFunction<Int32 Function(IntPtr), int Function(int)>(
    'IsWindowVisible',
  );
  if (isWindowVisible(hwnd) == 0) return 1;
  final getWindowTextLen = user32.lookupFunction<Int32 Function(IntPtr), int Function(int)>(
    'GetWindowTextLengthW',
  );
  final len = getWindowTextLen(hwnd);
  if (len <= 0) return 1;
  final buf = calloc<Uint16>(len + 1);
  final getWindowText = user32.lookupFunction<Int32 Function(IntPtr, Pointer<Uint16>, Int32),
      int Function(int, Pointer<Uint16>, int)>('GetWindowTextW');
  getWindowText(hwnd, buf, len + 1);
  final title = buf.cast<Utf16>().toDartString();
  calloc.free(buf);
  if (title.contains(ctx.ref.target.toDartString())) {
    ctx.ref.found = hwnd;
    return 0; // 停止枚举
  }
  return 1;
}
