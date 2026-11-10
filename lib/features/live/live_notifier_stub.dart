/// 纯 Dart 回归环境下 `package:flutter/foundation.dart` 的最小替身。
///
/// `foundation.dart` 顶层会拉进 `dart:ui` 的 `Picture` / `Image` 等类型，
/// 裸 `dart run` 里没有这些类型，[LiveController] 就无法被状态机回归加载。
/// 生产构建通过 `dart.library.ui` 条件导入走 Flutter 官方实现，
/// 应用行为完全不变；这里只提供控制器实际用到的三个符号，且刻意保持
/// `ChangeNotifier` 的监听器语义（dispose 后不再通知）。
library;

typedef VoidCallback = void Function();

abstract class Listenable {
  void addListener(VoidCallback listener);
  void removeListener(VoidCallback listener);
}

class ChangeNotifier implements Listenable {
  final List<VoidCallback> _listeners = <VoidCallback>[];
  bool _disposed = false;

  @override
  void addListener(VoidCallback listener) {
    if (!_disposed) _listeners.add(listener);
  }

  @override
  void removeListener(VoidCallback listener) => _listeners.remove(listener);

  void notifyListeners() {
    if (_disposed) return;
    // 遍历快照：监听器里 dispose 或增删监听器都不能改到正在迭代的列表。
    for (final listener in List<VoidCallback>.of(_listeners)) {
      listener();
    }
  }

  void dispose() {
    _disposed = true;
    _listeners.clear();
  }
}

/// 回归里刻意静默：门禁会扫描输出里的 `FAIL` 字样，内核日志既不需要
/// 也不该把「Failed to open」这类正常失败噪声灌进验证输出。
void debugPrint(String? message, {int? wrapWidth}) {}

class _VisibleForTesting {
  const _VisibleForTesting();
}

/// 与 `package:meta/meta.dart` 同名的注解常量；测试环境里注解只需能求值。
const Object visibleForTesting = _VisibleForTesting();
