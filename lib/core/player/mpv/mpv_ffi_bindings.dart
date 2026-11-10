import 'dart:ffi';
import 'dart:io' show Platform;

import 'package:ffi/ffi.dart';

import 'mpv_backend_resolver.dart';

/// libmpv client.h C API 的真实 FFI 绑定（E3 桌面/TV 零桥接路径）。
///
/// 只绑定确定存在的最小命令集，覆盖「创建/初始化/命令下发/选项/属性读取/释放」。
/// 渲染表面绑定（mpv_render_context_create）、事件循环（mpv_wait_event）、
/// property 观察属真机集成范畴，需配合各端纹理/ Surface 在原生侧补齐，此处不虚构。
///
/// 注意：本类只做**符号解析**，不会在本沙箱链接 libmpv（无原生库）；
/// 是否可用由 [FfiMpvLibraryProbe] 探测，缺失时经后端工厂降级到平台通道。

// --- mpv_create / mpv_initialize ---
typedef _CreateC = Pointer<Void> Function();
typedef _CreateDart = Pointer<Void> Function();
typedef _InitializeC = Int32 Function(Pointer<Void> ctx);
typedef _InitializeDart = int Function(Pointer<Void> ctx);

// --- mpv_command_string(ctx, const char* args) ---
typedef _CommandStringC = Int32 Function(Pointer<Void> ctx, Pointer<Utf8> args);
typedef _CommandStringDart = int Function(Pointer<Void> ctx, Pointer<Utf8> args);

// --- mpv_set_option_string(ctx, const char* name, const char* data) ---
typedef _SetOptionStringC = Int32 Function(
    Pointer<Void> ctx, Pointer<Utf8> name, Pointer<Utf8> data);
typedef _SetOptionStringDart = int Function(
    Pointer<Void> ctx, Pointer<Utf8> name, Pointer<Utf8> data);

// --- char* mpv_get_property_string(ctx, const char* name) ---
typedef _GetPropertyStringC = Pointer<Utf8> Function(
    Pointer<Void> ctx, Pointer<Utf8> name);
typedef _GetPropertyStringDart = Pointer<Utf8> Function(
    Pointer<Void> ctx, Pointer<Utf8> name);

// --- void mpv_free(void*) / void mpv_terminate_destroy(mpv_handle*) ---
typedef _FreeC = Void Function(Pointer<Void> data);
typedef _FreeDart = void Function(Pointer<Void> data);

class MpvFfiBindings {
  final DynamicLibrary lib;

  MpvFfiBindings(this.lib);

  late final _CreateDart create =
      lib.lookupFunction<_CreateC, _CreateDart>('mpv_create');
  late final _InitializeDart initialize =
      lib.lookupFunction<_InitializeC, _InitializeDart>('mpv_initialize');
  late final _CommandStringDart commandString =
      lib.lookupFunction<_CommandStringC, _CommandStringDart>(
          'mpv_command_string');
  late final _SetOptionStringDart setOptionString =
      lib.lookupFunction<_SetOptionStringC, _SetOptionStringDart>(
          'mpv_set_option_string');
  late final _GetPropertyStringDart getPropertyString =
      lib.lookupFunction<_GetPropertyStringC, _GetPropertyStringDart>(
          'mpv_get_property_string');
  late final _FreeDart free =
      lib.lookupFunction<_FreeC, _FreeDart>('mpv_free');
  late final _FreeDart terminateDestroy =
      lib.lookupFunction<_FreeC, _FreeDart>('mpv_terminate_destroy');
}

/// 按平台探测 libmpv 动态库是否真实存在（实现 [MpvLibraryProbe]）。
class FfiMpvLibraryProbe implements MpvLibraryProbe {
  /// 候选库名（按优先级）。可注入以便不同发行版/IoT TV 定制。
  final List<String> candidates;

  DynamicLibrary? _opened;
  bool _checked = false;

  FfiMpvLibraryProbe({List<String>? candidates})
      : candidates = candidates ?? _defaultCandidates;

  static List<String> get _defaultCandidates {
    if (Platform.isWindows) {
      return const ['libmpv-2.dll', 'mpv-2.dll', 'libmpv.dll'];
    }
    if (Platform.isMacOS) {
      return const ['libmpv.dylib', 'libmpv.2.dylib'];
    }
    // Linux 桌面 / Android TV 常见 soname
    return const ['libmpv.so.1', 'libmpv.so.2', 'libmpv.so'];
  }

  @override
  String get libraryName => candidates.first;

  void _probe() {
    if (_checked) return;
    _checked = true;
    for (final name in candidates) {
      try {
        _opened = DynamicLibrary.open(name);
        return;
      } catch (_) {
        // 继续尝试下一个候选名
      }
    }
  }

  /// 已成功打开的库（供后端工厂构造真实绑定）；null 表示不可用。
  DynamicLibrary? get opened {
    _probe();
    return _opened;
  }

  @override
  bool get isAvailable {
    _probe();
    return _opened != null;
  }
}
