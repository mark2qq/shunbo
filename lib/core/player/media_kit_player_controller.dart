import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../features/live/decode_gate.dart';
import 'player_controller.dart';

/// 桌面端真实播放内核（`media_kit` + 随包分发的 libmpv）。
///
/// 为什么是它，而不是把 `mpv_ffi_native.dart` 直接接到桌面：
/// Flutter 的 Windows 嵌入层只暴露 **pixel-buffer 纹理注册**，没有 GPU 纹理共享接口；
/// 用 `dart:ffi` 调 `mpv_render_context_create` 必须先在 C++ 侧建 ANGLE/D3D 上下文再回读像素，
/// 那是另一个插件的工程量。`media_kit` 已经把「libmpv 渲染面 → Flutter 纹理」
/// 这段桥接封装好，并随包携带 `mpv-2.dll`，装到用户机器上不需要额外装任何东西。
///
/// 职责边界与 [LibMpvPlayerController] 完全一致：**只做物理播放**。
/// 传入的是源原始坐标（含广告），内容坐标换算仍归调度层（alignment.dart），
/// 所以换源/续播/片尾判定的语义不会因为换内核而变化。
///
/// 坐标与容错约定：
/// - `currentRawSeconds()` 读不到位置时返回 0，不抛异常（进度上报自己会判无效值）；
/// - `duration()` 对直播流 / 尚未解析出时长的情况返回 0，片尾判定因此自动跳过。
class MediaKitPlayerController
    implements PlayerController, PictureProbe, DecodeFaultSource {
  late final Player _player;
  VideoController? _video;
  bool _initialized = false;

  /// 解码门禁的事件出口。用 broadcast 而不是单订阅：诊断面板与直播控制器
  /// 可能同时监听，单订阅流被二次监听会直接抛异常。
  final StreamController<DecodeFaultEvent> _decodeFaults =
      StreamController<DecodeFaultEvent>.broadcast();

  /// 当前 load 的地址：事件里必须带上它，直播控制器才能把「上一条线路
  /// 的迟到日志」和当前线路区分开。
  String _loadedUrl = '';

  /// 与选源层共用同一个状态机，避免「播放器数到 3 条、回归里数到 4 条」
  /// 这种两套阈值漂移。刻意**不调用 tick 收口**：直播流可能先正常十几分钟
  /// 再切成加扰，观察窗一旦判健康就停止计数会漏掉后半程。
  final DecodeWatch _decodeWatch = DecodeWatch();

  @override
  Stream<DecodeFaultEvent> get decodeFaults => _decodeFaults.stream;

  void _onMpvLog(String text) {
    if (_loadedUrl.isEmpty) return;
    final verdict = _decodeWatch.onLog(text);
    if (verdict == null || !verdict.scrambled) return;
    _decodeFaults.add(DecodeFaultEvent(
      url: _loadedUrl,
      kind: DecodeFaultKind.scrambled,
      count: verdict.errorCount,
      sample: verdict.sample,
      at: DateTime.now(),
    ));
    debugPrint('[decode-gate] 检测到加扰流'
        '（${verdict.errorCount} 条）：$_loadedUrl');
  }

  /// 是否已完成 [initialize]（UI/诊断可据此判断内核是否可用）。
  bool get isInitialized => _initialized;

  @override
  bool get hasPicture {
    if (!_initialized) return false;
    final s = _player.state;
    return (s.width ?? 0) > 0 && (s.height ?? 0) > 0;
  }

  @override
  bool get isBuffering => _initialized && _player.state.buffering;

  int _pictureEpoch = 0;

  @override
  int get pictureEpoch => _pictureEpoch;

  /// 最近一次内核错误（[load] 时清空）。
  String? _lastError;

  @override
  String? get lastError => _lastError;

  /// 从内核错误文本判断「这条线路已经确定播不出来」。
  ///
  /// 只认**终态**错误。像 `tcp: Connection to ... failed` 这种是重试过程中的
  /// 中间态，内核还会换地址再试，不能据此判死——本项目实测一条能播的线路
  /// 前半段全是 tcp 失败日志，二十秒后画面正常出来。
  static bool isFatalError(String message) {
    final m = message.toLowerCase();
    return m.contains('failed to open') ||
        m.contains('failed to recognize file format') ||
        m.contains('invalid data found') ||
        m.contains('failed to resolve hostname') ||
        // http 4xx/5xx：源站拒绝或网关错误，重试也不会变好。
        RegExp(r'http error (4|5)\d\d').hasMatch(m);
  }

  /// 供 `Video` 组件使用的渲染控制器。
  ///
  /// **懒创建**：`VideoController` 一造出来就会给 mpv 设 `vo=libmpv`，
  /// 而 libmpv 的 vo 需要等真正挂载的渲染面才有 render context。
  /// 在还没有 surface 的场景（例如只看状态、或页面尚未布局）提前创建，
  /// 会让 mpv 卡在等待 vo 初始化：表现为 `playing=true buffering=true dur=0`、
  /// 且**一个网络连接都不建立**——很容易被误判成网络问题。
  VideoController get videoController =>
      _video ??= VideoController(
        _player,
        configuration: const VideoControllerConfiguration(
          // 软解优先：本机实测硬解路径会让 libmpv 卡在 vo 初始化
          // （`playing=true buffering=true dur=0`，且不建立任何网络连接）。
          // 硬解的性能收益要等真机三项指标校准后再开，正确性优先。
          enableHardwareAcceleration: false,
        ),
      );

  /// 最近一次载入的请求头（回归/诊断用，确认源配置的头真的到了播放层）。
  Map<String, String> lastHeaders = const <String, String>{};

  /// 内核状态快照（诊断用）。
  ///
  /// 为什么需要它：直播「播不出来」有四五种完全不同的成因（未初始化、缓冲、
  /// 解码失败、地址 404、播放完成），只看「位置是否前进」无法区分，
  /// 排查时会误以为是网络问题。日志里带上这一行就能一眼定位。
  String get debugSnapshot {
    if (!_initialized) return 'not-initialized';
    final s = _player.state;
    return 'playing=${s.playing} buffering=${s.buffering} '
        'completed=${s.completed} pos=${s.position} dur=${s.duration} '
        'picture=${s.width}x${s.height}';
  }

  @override
  Future<void> initialize() async {
    if (_initialized) return;
    // 必须在创建 Player 之前清：libmpv 的 ffmpeg 在**初始化时**就把
    // http_proxy/https_proxy 读进 httpproxy 模块，之后再改选项已经晚了。
    _clearProxyEnvFromProcess();
    // 必须在使用任何 Player/VideoController 之前调用一次；重复调用是幂等的，
    // 但 Player 只能建一个，所以这里自己再挡一层。
    MediaKit.ensureInitialized();
    _player = Player(
      configuration: const PlayerConfiguration(
        title: '顺播 shunbo',
        // 与 `KernelTradeoffModel` 的平衡解同量级（缓存 24MB）。真正的首帧/内存/卡顿
        // 三项达标值仍要用真机指标校准，不能拿这里的数字当验收结论。
        bufferSize: 24 * 1024 * 1024,
        logLevel: MPVLogLevel.info,
      ),
    );
    _initialized = true;
    // Player 建好之后、任何 open 之前把代理关死（见 _forceDirectNetwork 的说明）。
    await _forceDirectNetwork();
    // 直播起播调优：直播不像点播需要大预读，减一点前沿缓冲能让
    // 「切台 → 首帧」更快出现。两条都是低风险参数，失败静默（回默认值）。
    await _applyLiveStartTuning();
    // 把内核日志转出来：media_kit 默认把 mpv 的日志丢进 stream 而不打印，
    // 「一直 buffering 但没有任何报错」这种状态不看日志无法定位。
    _player.stream.log.listen((e) {
      debugPrint('[mpv] ${e.prefix}: ${e.text}');
      _onMpvLog(e.text);
    });
    // 视频参数每来一次就 +1：判定「换台后是不是真的出画面」只认这个信号。
    // 用 videoParams 而不是 width/height 流：后者带 distinct，
    // 同分辨率的台切换时不会重新发射，世代号就不动了。
    _player.stream.videoParams.listen((e) {
      final dw = e.dw;
      final dh = e.dh;
      if (dw is int && dh is int && dw > 0 && dh > 0) _pictureEpoch++;
    });
    _player.stream.error.listen((e) {
      _lastError = e;
      debugPrint('[mpv-error] $e');
    });
  }

  /// 清掉本进程的代理环境变量（仅 Windows）。
  ///
  /// 为什么必须做到这一步：libmpv 的 ffmpeg 在初始化时读取 `http_proxy`/`https_proxy`
  /// 环境变量并交给 httpproxy 模块，而本机代理会把播放请求返回 **502**
  /// （内核日志原话：`ffmpeg: httpproxy: HTTP error 502 Bad Gateway`）。
  /// 表现是「一直 buffering、时长 0、媒体打不开」，极像解码或渲染问题，其实是网络。
  ///
  /// 光清环境变量**不够**：mpv 在 Windows 上还会读注册表里的 WinINet 代理设置，
  /// 所以还要把 mpv 的 `http-proxy` 设成 `no`（见 [_forceDirectNetwork]）。
  ///
  /// 注意取值：`''`（空串）是**有害**的——mpv 会当成「有个空代理」，给请求加上
  /// `httpproxy://` 前缀，然后被 libavformat 的协议白名单拒掉，
  /// 表现为「一部分频道探测正常但播放打不开」。只有 `no` 才是真的不用代理。
  ///
  /// 影响面：只作用于本进程（及其子进程）。Dart 自己的 `findProxyFromEnvironment`
  /// 在 Windows 上读的是注册表 Internet 设置，不读环境变量，因此不受影响。
  void _clearProxyEnvFromProcess() {
    if (!Platform.isWindows) return;
    try {
      final kernel32 = DynamicLibrary.open('kernel32.dll');
      final setEnv = kernel32.lookupFunction<
          Int32 Function(Pointer<Utf16>, Pointer<Utf16>),
          int Function(Pointer<Utf16>, Pointer<Utf16>)>('SetEnvironmentVariableW');
      for (final name in const <String>[
        'http_proxy',
        'https_proxy',
        'all_proxy',
        'HTTP_PROXY',
        'HTTPS_PROXY',
        'ALL_PROXY',
      ]) {
        final key = name.toNativeUtf16();
        final rc = setEnv(key, nullptr);
        calloc.free(key);
        // ignore: avoid_print
        print('[mpv] clear proxy env $name -> ${rc != 0}');
      }
    } catch (e) {
      // ignore: avoid_print
      print('[mpv] 清理代理环境变量失败（继续跟随系统代理）: $e');
    }
  }

  /// 关闭 libmpv 的系统代理（环境变量已清，这里是第二道保险）。
  ///
  /// 这一步不是可选项：libmpv 的 ffmpeg 会读进程的 `http_proxy`/`https_proxy`
  /// 环境变量，而本机代理对播放请求返回 **502**（日志里 `httpproxy: HTTP error 502`），
  /// 表现为「一直 buffering、时长 0、媒体始终打不开」——看起来像解码问题，其实是网络。
  /// 空字符串在 mpv 的 `--http-proxy` 语义里就是「不使用代理」。
  ///
  /// 用 dynamic 调用而不是 import 内部实现：`setProperty` 挂在 `NativePlayer` 上，
  /// 而它没有从 `media_kit.dart` 导出。锁死内部路径会在升级时直接编译失败，
  /// 这里的动态调用失败也只是回到「跟随系统代理」，不会让播放崩溃。
  /// 让 mpv **彻底不走代理**。
  ///
  /// 为什么光清环境变量不够：mpv 在 Windows 上除了读 `http_proxy` 环境变量，
  /// 还会读注册表里的 WinINet 代理设置（HKCU\...\Internet Settings）。
  /// 本机就有 `ProxyEnable=1, ProxyServer=127.0.0.1:7897`，于是 mpv 会把请求
  /// 改写成 `httpproxy://...`，而 libavformat 的协议白名单不接受这个协议：
  ///   `httpproxy: Protocol 'httpproxy' not on whitelist 'udp,rtp,tcp,tls,data,
  ///    file,http,https,crypto'!`
  /// 结果是一部分频道「探测正常、播放打不开」，表现极像源站挂了。
  ///
  /// 取值必须是 `no`：`''`（空串）**有害**——mpv 会当成「有一个空代理」，
  /// 照样加 `httpproxy://` 前缀然后被白名单拒掉（本项目实测）。
  /// `no` 才是「不用代理」。
  Future<void> _forceDirectNetwork() async {
    try {
      final dynamic native = _player.platform;
      await native.setProperty('http-proxy', 'no');
    } catch (e) {
      // 设置失败不致命：清过环境变量后，多数情况下已经能直连。
      debugPrint('[mpv] 无法关闭系统代理：$e');
    }
  }

  /// 直播起播参数：把「前沿缓冲」从点播默认压到直播友好的量级。
  ///
  /// * `cache-secs` 10s → 6s：直播回看窗口没意义，6s 足够抗常规抖动，
  ///   少缓冲的数据量直接换成更早的首帧。
  /// * `demuxer-readahead-secs` → 4s：起播阶段只预读 4 秒就开始出帧。
  ///
  /// 刻意**不动** `bufferSize`（demuxer-max-bytes，24MB）：那是内存回归
  /// （KernelTradeoffModel 校准过的平衡解），4K 高码率下把它压小会引发
  /// 播放中卡顿——起播优化不能拿播放稳定性换。
  ///
  /// 同样走 dynamic setProperty：参数不被某个内核版本接受时静默回落默认值，
  /// 绝不让播放初始化失败。
  Future<void> _applyLiveStartTuning() async {
    const entries = <String, String>{
      'cache-secs': '6',
      'demuxer-readahead-secs': '4',
    };
    try {
      final dynamic native = _player.platform;
      for (final entry in entries.entries) {
        try {
          await native.setProperty(entry.key, entry.value);
        } catch (e) {
          debugPrint('[mpv] 起播参数 ${entry.key} 未生效（回默认值）：$e');
        }
      }
    } catch (e) {
      debugPrint('[mpv] 起播调优不可用：$e');
    }
  }

  void _ensureInitialized() {
    if (!_initialized) {
      throw StateError('MediaKitPlayerController 未初始化：先调用 initialize()');
    }
  }

  @override
  Future<void> load(String url, int episode, double rawSeconds,
      {Map<String, String> headers = const <String, String>{}}) async {
    _ensureInitialized();
    lastHeaders = Map<String, String>.of(headers);
    // 换线路时必须清掉上一条线路的错误：否则新线路刚 load 就被上一轮的
    // `Failed to open` 判死，看起来像「所有线路都播不了」。
    _lastError = null;
    // 解码门禁同样按「每次 load 重新计票」：加扰计数不能跨线路累积，
    // 否则三条各报 1 次瞬态错误的健康线路会被凑成一次误判。
    _loadedUrl = url;
    _decodeWatch.begin(url);
    await _player.open(
      // 源站普遍校验 Referer/UA，缺了直接 403；请求头必须在 open 时一起给出。
      Media(url, httpHeaders: headers.isEmpty ? null : headers),
      // play: true —— 让 media_kit 自己把「加载完成 → 开始播放」串起来。
      // 先 play:false 再 play() 在某些内核版本上会停在 buffering 不动。
      play: true,
    );
    if (rawSeconds > 0) {
      await _player.seek(
          Duration(milliseconds: (rawSeconds * 1000).round()));
    }
  }

  @override
  Future<void> play() async {
    _ensureInitialized();
    await _player.play();
  }

  @override
  Future<void> pause() async {
    _ensureInitialized();
    await _player.pause();
  }

  @override
  Future<void> seek(double rawSeconds) async {
    _ensureInitialized();
    final ms = (rawSeconds * 1000).round();
    await _player.seek(Duration(milliseconds: ms < 0 ? 0 : ms));
  }

  @override
  Future<double> currentRawSeconds() async {
    if (!_initialized) return 0.0;
    final ms = _player.state.position.inMilliseconds;
    return ms <= 0 ? 0.0 : ms / 1000.0;
  }

  @override
  Future<double> duration() async {
    if (!_initialized) return 0.0;
    final ms = _player.state.duration.inMilliseconds;
    if (ms <= 0) return 0.0;
    return ms / 1000.0;
  }

  @override
  Future<void> setVolume(double volume) async {
    if (!_initialized) return;
    await _player.setVolume(volume.clamp(0, 100));
  }

  @override
  double get volume => _initialized ? _player.state.volume : 100;

  @override
  Stream<double> get volumeChanges =>
      _initialized ? _player.stream.volume : Stream<double>.value(100);

  @override
  Future<void> dispose() async {
    if (!_initialized) return;
    _initialized = false;
    _loadedUrl = '';
    _decodeWatch.end();
    await _player.dispose();
    await _decodeFaults.close();
  }
}
