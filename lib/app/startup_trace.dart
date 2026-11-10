import 'package:flutter/foundation.dart';

/// 冷启动耗时打点（R7 性能门槛的**可验收**前提）。
///
/// 「冷启动 ≤ 2/3 秒进入首页」如果没有埋点，就只能靠人掐秒表，
/// 而且换了设备无从对比。这里只在内存里记几个时间点，不写盘、不上报，
/// 由「关于与诊断」页读出来展示——用户报障时能直接说出数字。
///
/// 计时从 `main()` 第一行开始（[start]），到首帧渲染完成为止（[markFirstFrame]）。
class StartupTrace {
  StartupTrace._();

  static final Stopwatch _clock = Stopwatch();

  /// 首帧耗时（毫秒），null 表示还没渲染出首帧。
  static int? _firstFrameMs;

  /// 频道表基线（[canStartPlaying] 之前的那一步）耗时。
  static int? _catalogBaseMs;

  /// 从 `main()` 入口开始计时。
  static void start() {
    if (_clock.isRunning) return;
    _clock.start();
  }

  /// 首帧完成（在 `addPostFrameCallback` 里调用，只记第一次）。
  static void markFirstFrame() {
    if (_firstFrameMs != null) return;
    if (!_clock.isRunning) _clock.start();
    _firstFrameMs = _clock.elapsedMilliseconds;
  }

  /// 记录频道表基线装载耗时（`loadBase` 完成时刻）。
  static void markCatalogBase() {
    if (_catalogBaseMs != null) return;
    _catalogBaseMs = _clock.elapsedMilliseconds;
  }

  static int? get firstFrameMs => _firstFrameMs;

  static int? get catalogBaseMs => _catalogBaseMs;

  /// 诊断页展示用的一行摘要。
  ///
  /// 门槛按文档：电视（1 GB 盒子）≤ 3 s，手机 ≤ 2 s。这里只给实测值，
  /// 达标与否交给读者对照——把「是否达标」写死会在不同档位设备上误导。
  static String summary() {
    final f = _firstFrameMs;
    if (f == null) return '首帧耗时：测量中';
    final base = _catalogBaseMs;
    return '首帧耗时：$f ms'
        '${base == null ? '' : ' · 频道表基线：$base ms'}'
        '（门槛：电视 ≤ 3000 ms / 手机 ≤ 2000 ms）';
  }

  /// 回归脚本可重置（生产路径不会调用）。
  @visibleForTesting
  static void reset() {
    _clock
      ..reset()
      ..start();
    _firstFrameMs = null;
    _catalogBaseMs = null;
  }
}
