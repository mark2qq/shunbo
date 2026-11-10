import 'player_controller.dart';

/// 可验证的播放器模拟实现（E3 占位 / MVP 演示）。
///
/// 不依赖原生 libmpv（其集成需完整桌面工具链，本沙箱环境无法运行），
/// 仅在内存中模拟「载入地址+集+原始秒数」「播放」「定位」等能力，
/// 用于验证播放编排链路与换源对齐，不引入平台相关依赖。
///
/// 真实 [PlayerController] 实现（libmpv 封装）将在 E3 内核集成阶段替换本类，
/// UI 与编排层依赖抽象接口，无需改动。
class MockPlayerController implements PlayerController {
  bool initialized = false;
  String? loadedUrl;

  /// 最近一次 load 携带的请求头（回归用：验证源配置的头真的到了播放层）。
  Map<String, String> loadedHeaders = <String, String>{};
  int? loadedRawEpisode;
  double loadedRawSeconds = 0.0;
  bool playing = false;

  /// 模拟媒体的总时长（源原始秒数）。
  ///
  /// 默认 0 = **时长未知**，与真实内核实现在「尚未 file-loaded」时的行为一致；
  /// 想验证片尾判定（E6）的用例必须显式设值，否则不该被判定成「已看完」。
  double durationSeconds = 0.0;

  /// 自 [load]/[seek] 以来播放器「认为」自己所在的位置（源原始秒数）。
  double _position = 0.0;

  @override
  Future<void> initialize() async {
    initialized = true;
  }

  @override
  Future<void> load(String url, int episode, double rawSeconds,
      {Map<String, String> headers = const <String, String>{}}) async {
    loadedUrl = url;
    loadedRawEpisode = episode;
    loadedRawSeconds = rawSeconds;
    loadedHeaders = Map<String, String>.of(headers);
    _position = rawSeconds;
  }

  @override
  Future<void> play() async => playing = true;

  @override
  Future<void> pause() async => playing = false;

  @override
  Future<void> seek(double rawSeconds) async => _position = rawSeconds;

  double _volume = 100;

  @override
  Future<void> setVolume(double volume) async =>
      _volume = volume.clamp(0, 100);

  @override
  double get volume => _volume;

  @override
  Stream<double> get volumeChanges => Stream<double>.value(_volume);

  @override
  Future<double> currentRawSeconds() async => _position;

  @override
  Future<double> duration() async => durationSeconds;

  @override
  Future<void> dispose() async {
    initialized = false;
    playing = false;
  }
}
