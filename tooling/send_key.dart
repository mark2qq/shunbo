// 给「顺播 shunbo」窗口发送按键（用于验收遥控器数字输入切台）。
//
// 用法：dart run tooling/send_key.dart <按键> [窗口标题]
//   按键：单个数字 0-9，或 ok / enter / esc / back
//
// 实现要点（三处都是实测踩出来的）：
//   1. **必须拿到前台焦点**。`PostMessage` 只是把消息塞进窗口队列，
//      Flutter 的 Windows 嵌入器在窗口**没有键盘焦点**时会忽略按键
//      （表现为「按了数字什么都没发生」）。
//   2. Windows 的**前台锁定**会让 `SetForegroundWindow` 失败，
//      用 `AttachThreadInput` 把本线程挂到前台线程上再设焦点即可绕过。
//   3. 键盘注入用 `keybd_event`（带扫描码），Flutter 用 lParam 里的
//      扫描码反查字符，只给虚拟键码会被当成「未知键」丢弃。
//
// 为什么自己调 FFI 而不是用 win32 包：工程只依赖 `package:ffi`，
// 截图 / 点击工具也是这套裸 FFI（见 capture_screen.dart / click_at.dart）。
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

const int _keyEventKeyUp = 0x0002;
const int _wmKeyDown = 0x0100;
const int _wmKeyUp = 0x0101;
const int _keyEventScanCode = 0x0008;

/// Win32 `INPUT`（x64：type 4 + 对齐 4 + 联合体 32 = **40 字节**）。
///
/// `SendInput` 会校验 `cbSize == sizeof(INPUT)`，所以结构体大小必须刚好 40。
/// 联合体里放的是 `KEYBDINPUT`，字段偏移按 Win32 定义直接写字节：
/// `wVk` @8、`wScan` @10、`dwFlags` @12、`time` @16、`dwExtraInfo` @24。
final class _Input extends Struct {
  @Int32()
  external int type;

  @Int32()
  external int padding;

  @Int64()
  external int word0;

  @Int64()
  external int word1;

  @Int64()
  external int word2;

  @Int64()
  external int word3;
}

/// 按键 → (虚拟键码, 扫描码)。
const Map<String, List<int>> _keys = <String, List<int>>{
  '0': [0x30, 0x0B],
  '1': [0x31, 0x02],
  '2': [0x32, 0x03],
  '3': [0x33, 0x04],
  '4': [0x34, 0x05],
  '5': [0x35, 0x06],
  '6': [0x36, 0x07],
  '7': [0x37, 0x08],
  '8': [0x38, 0x09],
  '9': [0x39, 0x0A],
  'ok': [0x0D, 0x1C],
  'enter': [0x0D, 0x1C],
  'return': [0x0D, 0x1C],
  'esc': [0x1B, 0x01],
  'escape': [0x1B, 0x01],
  'back': [0x08, 0x0E],
  'backspace': [0x08, 0x0E],
  'space': [0x20, 0x39],
};

List<int>? _keyOf(String key) {
  final v = _keys[key.toLowerCase()];
  if (v != null) return v;
  if (key.length == 1) {
    final c = key.codeUnitAt(0);
    if (c >= 0x41 && c <= 0x5A) {
      return <int>[c, c - 0x41 + 0x1E];
    }
  }
  return null;
}

/// 发一个按键（按下或抬起）。
void _sendKey(
  int Function(int, Pointer<_Input>, int) sendInput,
  int vk,
  int scan,
  int flags,
  int size,
) {
  final input = calloc<_Input>();
  try {
    input.ref.type = 1; // INPUT_KEYBOARD
    final bytes = input.cast<Uint8>().asTypedList(size);
    bytes[8] = vk & 0xFF;
    bytes[9] = (vk >> 8) & 0xFF;
    bytes[10] = scan & 0xFF;
    bytes[11] = (scan >> 8) & 0xFF;
    bytes[12] = flags & 0xFF;
    bytes[13] = (flags >> 8) & 0xFF;
    bytes[14] = (flags >> 16) & 0xFF;
    bytes[15] = (flags >> 24) & 0xFF;
    // time(@16) 与 dwExtraInfo(@24) 保持 0。
    sendInput(1, input, size);
  } finally {
    calloc.free(input);
  }
}

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('用法：dart run tooling/send_key.dart <按键...> [窗口标题]');
    stderr.writeln('例：dart run tooling/send_key.dart 1 3 shunbo   # 连按 1、3（验证多位数累积）');
    exit(2);
  }
  // 末尾参数如果是窗口标题就取走，其余都当按键。
  // `--shot <路径>`：发键后立刻同进程拉起截图（省掉另起一个 Dart VM 的
  // 1.5 秒启动延迟，OSD 只显示几秒，差这一点就拍不到了）。
  var keys = <String>[];
  var title = '顺播 shunbo';
  String? shot;
  var restore = false;
  var postOnly = false;
  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    if (a == '--restore') {
      restore = true;
      continue;
    }
    if (a == '--post-only') {
      postOnly = true;
      continue;
    }
    if (a == '--shot' && i + 1 < args.length) {
      shot = args[i + 1];
      i++;
      continue;
    }
    if (a == 'shunbo' || a == '顺播 shunbo') {
      // 命令行传中文会乱码，`shunbo` 是快捷写法，内部换成精确全名。
      title = '顺播 shunbo';
      continue;
    }
    keys.add(a);
  }
  if (keys.isEmpty) {
    stderr.writeln('没有要发送的按键');
    exit(2);
  }
  final specs = <List<int>>[];
  for (final k in keys) {
    final spec = _keyOf(k);
    if (spec == null) {
      stderr.writeln('不支持的按键：$k');
      exit(2);
    }
    specs.add(spec);
  }

  final user32 = DynamicLibrary.open('user32.dll');
  final kernel32 = DynamicLibrary.open('kernel32.dll');

  final findWindow = user32.lookupFunction<
      IntPtr Function(Pointer<Utf16>, Pointer<Utf16>),
      int Function(Pointer<Utf16>, Pointer<Utf16>)>('FindWindowW');
  final showWindow = user32
      .lookupFunction<Int32 Function(IntPtr, Int32), int Function(int, int)>(
          'ShowWindow');
  final getForeground = user32
      .lookupFunction<IntPtr Function(), int Function()>('GetForegroundWindow');
  final setForeground = user32
      .lookupFunction<Int32 Function(IntPtr), int Function(int)>(
          'SetForegroundWindow');
  final setFocus = user32
      .lookupFunction<IntPtr Function(IntPtr), int Function(int)>('SetFocus');
  final setActiveWindow = user32
      .lookupFunction<IntPtr Function(IntPtr), int Function(int)>('SetActiveWindow');
  final getFocus = user32
      .lookupFunction<IntPtr Function(), int Function()>('GetFocus');
  final attachThreadInput = user32.lookupFunction<
      Int32 Function(Int32, Int32, Int32),
      int Function(int, int, int)>('AttachThreadInput');
  final getWindowThreadProcessId = user32.lookupFunction<
      Int32 Function(IntPtr, Pointer<Int32>),
      int Function(int, Pointer<Never>)>('GetWindowThreadProcessId');
  final setWindowPos = user32.lookupFunction<
      Int32 Function(IntPtr, IntPtr, Int32, Int32, Int32, Int32, Int32),
      int Function(int, int, int, int, int, int, int)>('SetWindowPos');
  final sendInput = user32.lookupFunction<
      Int32 Function(Int32, Pointer<_Input>, Int32),
      int Function(int, Pointer<_Input>, int)>('SendInput');
  final postMessage = user32.lookupFunction<
      Int32 Function(IntPtr, Int32, IntPtr, IntPtr),
      int Function(int, int, int, int)>('PostMessageW');
  final getCurrentThreadId = kernel32
      .lookupFunction<Int32 Function(), int Function()>('GetCurrentThreadId');

  final titlePtr = title.toNativeUtf16();
  final hwnd = findWindow(nullptr.cast<Utf16>(), titlePtr);
  if (hwnd == 0) {
    stderr.writeln('找不到窗口：$title');
    exit(3);
  }

  // 先置顶（绕过点击被抢），再把键盘焦点抢过来。
  const int hwndTopmost = -1;
  const int hwndNoTopmost = -2;
  const int swpNoMove = 0x0002;
  const int swpNoSize = 0x0001;
  const int swpShow = 0x0040;
  setWindowPos(hwnd, hwndTopmost, 0, 0, 0, 0,
      swpNoMove | swpNoSize | swpShow);
  if (restore) {
    // SW_RESTORE(9)：把最大化窗口还原成普通窗口。
    showWindow(hwnd, 9);
    sleep(const Duration(milliseconds: 200));
  }
  sleep(const Duration(milliseconds: 150));

  var attached = 0;
  var ourThread = 0;
  var fgThread = 0;
  if (!postOnly) {
    final fg = getForeground();
    fgThread = getWindowThreadProcessId(fg, nullptr);
    ourThread = getCurrentThreadId();
    attached = fgThread != 0 && fgThread != ourThread
        ? attachThreadInput(ourThread, fgThread, 1)
        : 0;
    setForeground(hwnd);
    setActiveWindow(hwnd);
    // **必须保持线程附着直到按键发完**：跨线程的 SetFocus 只在附着期间有效，
    // 一旦解除附着，键盘焦点会立刻回到原来的窗口（IDE），
    // Flutter 的 Windows 嵌入器收不到 WM_KEYDOWN —— 表现就是「焦点在前台，
    // 但按键毫无反应」。
    setFocus(hwnd);
    sleep(const Duration(milliseconds: 250));
    print('键盘焦点窗口=${getFocus()} 目标窗口=$hwnd');
    // 前台锁定会让 SetForegroundWindow 偶发失败（IDE 会立刻抢回焦点），
    // 这里重试到「窗口确实在前台」为止，否则按键会被发给 IDE。
    var attempts = 0;
    while (getForeground() != hwnd && attempts < 8) {
      attempts++;
      setForeground(hwnd);
      setActiveWindow(hwnd);
      setFocus(hwnd);
      sleep(const Duration(milliseconds: 150));
    }
    print('前台确认：${getForeground() == hwnd ? "已是目标窗口" : "失败（重试 $attempts 次）"}');
  }

  final focused = getForeground() == hwnd;
  print('窗口句柄=$hwnd 焦点状态=${focused ? "已在前台" : "未在前台"}');

  // 按键投递走**两条**路径，任何一条生效即可：
  // ① `PostMessage` 直接把 WM_KEYDOWN 投到目标窗口 —— 与焦点无关；
  //    lParam 必须带扫描码，否则 Flutter 的嵌入器按「未知键」丢弃。
  // ② `SendInput` 写进**系统**输入队列，由系统派发给前台窗口 ——
  //    模拟真实遥控器，但要求窗口此刻确实是前台（本机 IDE 会抢焦点）。
  // （`keybd_event` 只写调用线程自己的队列，前台窗口收不到，已弃用。）
  final size = sizeOf<_Input>();
  if (size != 40) {
    stderr.writeln('INPUT 结构体大小异常：$size（应为 40）');
    exit(4);
  }
  for (final spec in specs) {
    final vk = spec[0];
    final scan = spec[1];
    final lParamDown = 1 | (scan << 16) | (1 << 31);
    final lParamUp = 1 | (scan << 16);
    // **两种投递方式二选一，绝不能同时用**。
    //
    // 实测踩到的坑：原先这里既 `PostMessage` 又 `SendInput`，等于每个按键被
    // 投递两次。单键切台看不出来（重复的同一个数字仍指向同一台），但多位数
    // 频道号会被吃乱——按「1 4 2」实际收到「1 1 4 4 2 2」，于是切到了 43
    // 「CCTV-第一剧场」而不是 142「浙江卫视4K」。
    //
    // * 默认（有焦点）：只用 `SendInput`，它发给系统前台窗口，只投一次。
    // * `--post-only`：只用 `PostMessage`，直接塞进目标窗口队列，不依赖焦点
    //   （但 Flutter 在窗口未获键盘焦点时会忽略按键，所以仍需窗口在前台）。
    if (postOnly) postMessage(hwnd, _wmKeyDown, vk, lParamDown);
    // 扫描码标志必须**按下与抬起成对**：按下用 SCANCODE、抬起用
    // SCANCODE|KEYUP。只在抬起时带 SCANCODE 会被系统当成无效序列丢弃。
    if (!postOnly) _sendKey(sendInput, vk, scan, _keyEventScanCode, size);
    sleep(const Duration(milliseconds: 60));
    if (postOnly) postMessage(hwnd, _wmKeyUp, vk, lParamUp);
    if (!postOnly) {
      _sendKey(sendInput, vk, scan, _keyEventScanCode | _keyEventKeyUp, size);
    }
    sleep(const Duration(milliseconds: 190));
  }

  if (!postOnly && attached != 0) attachThreadInput(ourThread, fgThread, 0);

  setWindowPos(hwnd, hwndNoTopmost, 0, 0, 0, 0,
      swpNoMove | swpNoSize | swpShow);

  print('已发送按键：${keys.join(' → ')}');

  if (shot != null) {
    // 同进程拉起截图：VM 启动延迟与发键并行，截图正好落在 OSD 显示窗口内。
    final result = Process.runSync(Platform.resolvedExecutable, <String>[
      'run',
      'tooling/capture_screen.dart',
      shot,
      '50',
      title,
    ]);
    if (result.exitCode != 0) {
      stderr.writeln('截图失败：${result.stderr}');
    } else {
      print('已截图：$shot');
    }
  }
}
