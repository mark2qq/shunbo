// 原生通道契约回归（Dart ↔ Kotlin 的「接口对不上」防线）。
//
// 为什么需要它：`MethodChannel` 的名字或方法名写错，编译期一句话都不会报；
// 表现是运行期 `MissingPluginException` 或「调用永不返回」，而且往往要等到真机
// 上才发现。本机 `flutter test` 不可用（flutter_tester 握手失败），无法用
// TestDefaultBinaryMessenger 做真实通道测试，于是退一步做**文本级契约核对**：
// 把两侧的常量与方法名从源码里抽出来逐条比对，任何一侧改了名字都会红。
//
// 这不是替代真机验证，而是把「能静态发现的那一类错」提前到提交前。
//
// 运行：dart run tooling/verify_channel_contract.dart
import 'dart:io';

int _checkCount = 0;
int _failCount = 0;

void check(String name, bool ok, [String? detail]) {
  if (!ok) {
    _failCount++;
    print('FAIL: $name${detail == null ? '' : ' —— $detail'}');
    return;
  }
  _checkCount++;
  print('PASS: $name');
}

const _dartNative = 'lib/core/player/mpv/mpv_platform_channel_native.dart';
const _dartEvent = 'lib/core/player/mpv/mpv_event_channel.dart';
const _dartEventModel = 'lib/core/player/mpv/mpv_event.dart';
const _dartSurface = 'lib/ui/player_surface.dart';
const _ktMain = 'android/app/src/main/kotlin/com/shunbo/shunbo/MainActivity.kt';
const _ktHandler = 'android/app/src/main/kotlin/com/shunbo/shunbo/MpvMethodHandler.kt';
const _ktEvents = 'android/app/src/main/kotlin/com/shunbo/shunbo/PlaybackEventBridge.kt';
const _ktEngine = 'android/app/src/main/kotlin/com/shunbo/shunbo/ExoPlayerEngine.kt';

String _read(String path) {
  final f = File(path);
  if (!f.existsSync()) {
    throw StateError('缺少文件：$path');
  }
  return f.readAsStringSync();
}

Set<String> _all(RegExp re, String text) => re
    .allMatches(text)
    .map((m) => m.group(1)!)
    .toSet();

/// 单一捕获组：`MethodChannel('shunbo/mpv')` / `MethodChannel(messenger, "shunbo/mpv")`
String? _channelName(String text, String kind) {
  final re = RegExp('$kind\\([^)]*?[\'"]([a-z0-9/_-]+)[\'"]');
  return re.firstMatch(text)?.group(1);
}

void main() {
  final dartNative = _read(_dartNative);
  final dartEvent = _read(_dartEvent);
  final dartEventModel = _read(_dartEventModel);
  final dartSurface = _read(_dartSurface);
  final ktMain = _read(_ktMain);
  final ktHandler = _read(_ktHandler);
  final ktEvents = _read(_ktEvents);
  final ktEngine = _read(_ktEngine);

  // ------------------------------------------------------------------ 通道名
  final dartMethodChannel = _channelName(dartNative, 'MethodChannel');
  final ktMethodChannel = _channelName(ktMain, 'MethodChannel');
  check('MethodChannel 名两侧一致', dartMethodChannel != null &&
      dartMethodChannel == ktMethodChannel,
      'dart=$dartMethodChannel kt=$ktMethodChannel');

  final dartEventChannel = _channelName(dartEvent, 'EventChannel');
  final ktEventChannel = _channelName(ktMain, 'EventChannel');
  check('EventChannel 名两侧一致', dartEventChannel != null &&
      dartEventChannel == ktEventChannel,
      'dart=$dartEventChannel kt=$ktEventChannel');

  final dartViewType = RegExp("viewType = '([a-z0-9/_-]+)'").firstMatch(dartSurface)?.group(1);
  final ktViewType = RegExp('registerViewFactory\\(\\s*"([a-z0-9/_-]+)"')
      .firstMatch(ktMain)?.group(1);
  check('PlatformView 类型名两侧一致',
      dartViewType != null && dartViewType == ktViewType,
      'dart=$dartViewType kt=$ktViewType');

  // -------------------------------------------------------------- 方法名集合
  // Dart 侧所有 `_invoke<T>('method'` 的 method 名。
  // 泛型里可能带嵌套尖括号（`Map<dynamic, dynamic>`），所以不能用 `[^>]*`：
  // 那样会在第一个 `>` 处截断，`sampleMetrics` 这类返回值复杂的方法会被漏掉，
  // 而漏掉的后果是「Dart 侧方法集少了它 → 判原生侧多余」，两头都是假结论。
  final dartMethods =
      _all(RegExp("_invoke<[^(]{0,80}\\('([a-zA-Z]+)'"), dartNative);
  check('Dart 侧方法名不少于 10 个（防止正则失效后假通过）',
      dartMethods.length >= 10, '${dartMethods.toList()}');

  // Kotlin 侧 `when (call.method)` 的分支："create" -> ...
  final ktMethods = _all(RegExp('"([a-zA-Z]+)"\\s*->'), ktHandler);
  check('Kotlin 侧分支名不少于 10 个', ktMethods.length >= 10,
      '${ktMethods.toList()}');

  final missingOnNative = dartMethods.difference(ktMethods);
  check('Dart 调用的每个方法原生侧都有分支',
      missingOnNative.isEmpty, '缺：${missingOnNative.toList()}');
  check('原生侧没有多余到连 Dart 都不认识的必调方法',
      ktMethods.difference(dartMethods).isEmpty,
      '多：${ktMethods.difference(dartMethods).toList()}');

  // ------------------------------------------------------------- 事件名集合
  final ktEventNames = _all(RegExp('put\\("event",\\s*"([a-z-]+)"\\)'), ktEvents);
  check('Kotlin 侧至少推送 4 类事件', ktEventNames.length >= 4,
      '${ktEventNames.toList()}');

  final dartKnown = _all(RegExp("case '([a-z-]+)':"), dartEventModel);
  final unknownOnDart = ktEventNames.difference(dartKnown);
  check('Kotlin 推送的事件名都在 Dart 解析表内',
      unknownOnDart.isEmpty, '未识别：${unknownOnDart.toList()}');

  // property-change 的属性名要与 Dart 侧消费的对应。
  final ktProps = _all(RegExp('put\\("name",\\s*"([a-z-]+)"\\)'), ktEvents);
  check('property-change 带 name 字段', ktProps.isNotEmpty, '${ktProps.toList()}');
  check('time-pos 属性存在（续播采样依赖它）', ktProps.contains('time-pos'));

  // ------------------------------------------------- 指标字典的键名必须对齐
  // Dart 侧 `sampleMetrics` 读这三个键，Kotlin 侧少写一个就会静默变成默认值
  // （firstFrameMs=999999 → 门禁永远判失败，或反过来永远达标）。
  for (final key in <String>['firstFrameMs', 'memoryMb', 'droppedFrameRate']) {
    check('指标键 $key 在 Kotlin 侧存在',
        ktEngine.contains('"$key" to'), '未找到 "$key" to');
  }

  // ------------------------------------------------------- 渲染面的注册链路
  check('MainActivity 注册了 PlatformView 工厂',
      ktMain.contains('registerViewFactory'));
  check('MainActivity 挂了 MethodChannel handler',
      ktMain.contains('setMethodCallHandler'));
  check('MainActivity 挂了 EventChannel streamHandler',
      ktMain.contains('setStreamHandler'));
  check('引擎清理时释放原生资源（避免 Activity 重建后句柄泄漏）',
      ktMain.contains('cleanUpFlutterEngine') && ktMain.contains('dispose()'));

  // -------------------------------------------------------- 原生侧不得抛异常
  // Dart 侧对这些调用没有 try/catch（按 libmpv 同步 C API 语义写的），
  // 抛 PlatformException 会把「读不到时长」升级成「播放失败」。
  check('原生 handler 有兜底 try/catch（不向 Dart 抛异常）',
      ktHandler.contains('catch (e: Exception)'));

  final total = _checkCount + _failCount;
  print('\n$_checkCount/$total 断言通过'
      '${_failCount == 0 ? '' : '（失败 $_failCount 项）'}');
  if (_failCount > 0) exitCode = 1;
  exit(exitCode);
}
