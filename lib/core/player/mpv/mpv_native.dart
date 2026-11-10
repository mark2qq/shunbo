import 'player_metrics.dart';

/// libmpv 原生绑定抽象（E3）。
///
/// 真实实现有两条路线：
/// ① Dart FFI 直接链接 libmpv 动态库（桌面/TV 首选，零桥接开销）；
/// ② 平台通道（Platform Channel）调用各端原生封装（Android 端 ExoPlayer 回退时必要）。
///
/// 抽象出来使 [LibMpvPlayerController] 可在**纯 Dart** 下用 [FakeMpvNative] 验证逻辑，
/// 而不依赖原生编译（本沙箱环境无法运行 flutter_tester / 原生构建）。
///
/// 坐标约定：本层一切 `seconds` 均为**源原始坐标（含广告）**，
/// 去广告的内容坐标换算在调度层（alignment.dart）完成。
abstract class MpvNative {
  /// 创建内核实例、绑定渲染表面（surface/texture）。
  Future<void> create();

  /// 设置 libmpv 选项（解码/缓存/渲染相关）。
  Future<void> setOption(String key, String value);

  /// 载入播放地址。
  Future<void> load(String url);

  Future<void> play();
  Future<void> pause();

  /// 跳转到源原始秒数。
  Future<void> seek(double seconds);

  /// 当前源原始秒数。
  Future<double> getTime();

  /// 总时长（源原始秒数）。
  Future<double> getDuration();

  /// 采样当前运行时指标（首帧/内存/卡顿）。
  Future<PlayerMetrics> sampleMetrics();

  Future<void> dispose();
}
