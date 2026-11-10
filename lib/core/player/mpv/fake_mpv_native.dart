import 'mpv_native.dart';
import 'player_metrics.dart';

/// 用于纯 Dart 逻辑验证的 [MpvNative] 假实现。
///
/// 指标可在构造时指定，便于覆盖「门禁通过」与「门禁失败」两种场景，
/// 无需原生 libmpv 即可验证 [LibMpvPlayerController] 的载入/定位/门禁逻辑。
class FakeMpvNative implements MpvNative {
  double time = 0.0;
  double duration = 1000.0;

  /// 构造时注入的指标；默认处于门禁通过区间。
  final PlayerMetrics metrics;

  FakeMpvNative({
    this.metrics = const PlayerMetrics(
      firstFrameMs: 300,
      memoryMb: 80.0,
      droppedFrameRate: 0.005,
    ),
  });

  bool loaded = false;
  bool playing = false;
  String? lastUrl;

  @override
  Future<void> create() async {}

  @override
  Future<void> setOption(String key, String value) async {}

  @override
  Future<void> load(String url) async {
    lastUrl = url;
    loaded = true;
  }

  @override
  Future<void> play() async => playing = true;

  @override
  Future<void> pause() async => playing = false;

  @override
  Future<void> seek(double seconds) async => time = seconds;

  @override
  Future<double> getTime() async => time;

  @override
  Future<double> getDuration() async => duration;

  @override
  Future<PlayerMetrics> sampleMetrics() async => metrics;

  @override
  Future<void> dispose() async {
    loaded = false;
    playing = false;
  }
}
