// 诊断脚本：直接调 libmpv 的 C API，判断「播不出来」是内核问题还是封装问题。
//
// 背景：media_kit 的 Player 一直停在 `playing=true buffering=true dur=0`，
// 且进程不建立任何网络连接。要么 libmpv 本身不可用，要么 media_kit 没把命令传下去。
// 这里绕过 media_kit 直接调 mpv_create / mpv_command / mpv_wait_event，
// 看事件流里到底有没有 file-loaded。
//
// 运行：dart run tooling/diag_mpv.dart [媒体地址]
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

typedef _CreateNative = Pointer<Void> Function();
typedef _Create = Pointer<Void> Function();

typedef _IntHandleNative = Int32 Function(Pointer<Void>);
typedef _IntHandle = int Function(Pointer<Void>);

typedef _SetOptNative = Int32 Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>);
typedef _SetOpt = int Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>);

typedef _CommandNative = Int32 Function(Pointer<Void>, Pointer<Pointer<Utf8>>);
typedef _Command = int Function(Pointer<Void>, Pointer<Pointer<Utf8>>);

typedef _GetStrNative = Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>);
typedef _GetStr = Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>);

typedef _WaitEventNative = Pointer<Void> Function(Pointer<Void>, Double);
typedef _WaitEvent = Pointer<Void> Function(Pointer<Void>, double);

void main(List<String> args) {
  final dll = Platform.environment['SHUNBO_MPV_DLL'] ??
      r'E:\TV\shunbo\build\windows\x64\runner\Release\libmpv-2.dll';
  final media = args.isNotEmpty
      ? args.first
      : 'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4';

  print('dll=$dll');
  final lib = DynamicLibrary.open(dll);

  final create = lib.lookupFunction<_CreateNative, _Create>('mpv_create');
  final init = lib.lookupFunction<_IntHandleNative, _IntHandle>('mpv_initialize');
  final setOpt = lib.lookupFunction<_SetOptNative, _SetOpt>('mpv_set_option_string');
  final command = lib.lookupFunction<_CommandNative, _Command>('mpv_command');
  final getStr = lib.lookupFunction<_GetStrNative, _GetStr>('mpv_get_property_string');
  final waitEvent = lib.lookupFunction<_WaitEventNative, _WaitEvent>('mpv_wait_event');

  final handle = create();
  print('mpv_create -> $handle');
  if (handle == nullptr) {
    print('FATAL: 无法创建 mpv 实例');
    exit(1);
  }

  final rc = init(handle);
  print('mpv_initialize -> $rc');
  if (rc < 0) exit(1);

  // 关掉音视频输出，纯网络 + 解复用，避免 vo/ao 干扰判断。
  print('set vo=null -> ${setOpt(handle, 'vo'.toNativeUtf8(), 'null'.toNativeUtf8())}');
  print('set ao=null -> ${setOpt(handle, 'ao'.toNativeUtf8(), 'null'.toNativeUtf8())}');
  print('set cache=yes -> ${setOpt(handle, 'cache'.toNativeUtf8(), 'yes'.toNativeUtf8())}');

  final argv = calloc<Pointer<Utf8>>(3);
  argv[0] = 'loadfile'.toNativeUtf8();
  argv[1] = media.toNativeUtf8();
  argv[2] = nullptr;
  print('mpv_command(loadfile) -> ${command(handle, argv)}');

  // mpv_event 的第一个字段是 mpv_event_id（int）。0 = NONE，1 = SHUTDOWN，
  // 6 = FILE_LOADED，8 = END_FILE，11 = START_FILE，21 = LOG_MESSAGE。
  for (var i = 0; i < 25; i++) {
    final ev = waitEvent(handle, 1.0);
    if (ev == nullptr) {
      print('event: (null)');
      continue;
    }
    final id = ev.cast<Int32>().value;
    print('event id=$id');
    if (id == 8) {
      final dur = getStr(handle, 'duration'.toNativeUtf8());
      print('END_FILE, duration=${dur == nullptr ? 'n/a' : dur.toDartString()}');
      break;
    }
  }

  final durPtr = getStr(handle, 'duration'.toNativeUtf8());
  final dur = durPtr == nullptr ? 'n/a' : durPtr.toDartString();
  print('final duration=$dur');
  final pathPtr = getStr(handle, 'path'.toNativeUtf8());
  print('path=${pathPtr == nullptr ? 'n/a' : pathPtr.toDartString()}');
  exit(0);
}
