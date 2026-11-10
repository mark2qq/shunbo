import '../player_controller.dart';
import 'mpv_native.dart';
import 'player_metrics.dart';

/// 基于 libmpv 的播放控制器（E3 真实封装骨架）。
///
/// 通过 [MpvNative] 抽象与原生内核解耦：真实环境注入 FFI / 平台通道实现，
/// 纯逻辑或单元测试环境注入 [FakeMpvNative]。
///
/// 职责边界：只负责「物理播放」。接收播放地址(url)与源原始坐标(episode, rawSeconds)，
/// 引擎直接 seek 到 rawSeconds。换源对齐后「内容坐标→原始坐标」的换算由调度层完成
/// （见 alignment.dart），不在此层。
///
/// 每次 [load] 后采样指标并即时跑 [gate] 门禁，便于 E3 集成阶段在真机/CI 上卡住退化。
class LibMpvPlayerController implements PlayerController {
  final MpvNative native;
  final PlayerMetricGate gate;

  PlayerMetrics? _metrics;
  GateResult? _lastGate;

  LibMpvPlayerController({
    required this.native,
    this.gate = const PlayerMetricGate(),
  });

  /// 最近一次采样指标（null 表示尚未 load）。
  PlayerMetrics? get lastMetrics => _metrics;

  /// 最近一次门禁结果（null 表示尚未 load）。
  GateResult? get lastGate => _lastGate;

  @override
  Future<void> initialize() async => await native.create();

  @override
  Future<void> load(String url, int episode, double rawSeconds,
      {Map<String, String> headers = const <String, String>{}}) async {
    // 请求头必须在 loadfile 之前设置：libmpv 的 http-header-fields 只在
    // 打开 URL 的那一刻读取，载入之后再设对当前流无效。
    if (headers.isNotEmpty) {
      final fields =
          headers.entries.map((e) => '${e.key}: ${e.value}').join('\n');
      await native.setOption('http-header-fields', fields);
    }
    await native.load(url);
    await native.seek(rawSeconds);
    _metrics = await native.sampleMetrics();
    _lastGate = gate.evaluate(_metrics!);
  }

  @override
  Future<void> play() async => await native.play();

  @override
  Future<void> pause() async => await native.pause();

  @override
  Future<void> seek(double rawSeconds) async => await native.seek(rawSeconds);

  /// 音量透传：Android 端 Media3 的音量走系统通道，这里先把值存住，
  /// 真机接入时在 [MpvNative] 里再落到 ExoPlayer 的 `volume`。
  double _volume = 100;

  @override
  Future<void> setVolume(double volume) async =>
      _volume = volume.clamp(0, 100);

  @override
  double get volume => _volume;

  @override
  Stream<double> get volumeChanges => Stream<double>.value(_volume);

  @override
  Future<double> currentRawSeconds() async => await native.getTime();

  /// 总时长：内核读不到 / 尚未 file-loaded / 直播流时一律归零。
  ///
  /// 这里**不能**把异常往上抛：片尾判定是「有更好、没有也能播」的增强能力，
  /// 一次 `property unavailable` 就中断进度落盘，等于为了让功能 B 弄坏功能 A。
  @override
  Future<double> duration() async {
    try {
      final d = await native.getDuration();
      if (!d.isFinite || d <= 0) return 0.0;
      return d;
    } catch (_) {
      return 0.0;
    }
  }

  @override
  Future<void> dispose() async => await native.dispose();
}
