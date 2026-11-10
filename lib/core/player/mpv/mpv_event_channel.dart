import 'package:flutter/services.dart';

import 'mpv_event_loop.dart';

/// Android / 原生侧事件入口（E3 真机集成契约）。
///
/// 原生侧需实现 `shunbo/mpv/events` **EventChannel**，推送「一行一个 JSON」的
/// libmpv 事件（或 ExoPlayer 等价事件），例如：
/// ```json
/// {"event":"property-change","name":"time-pos","data":12.3}
/// {"event":"playback-restart"}
/// {"event":"property-change","name":"drop-frame-count","data":5}
/// ```
///
/// 与 `shunbo/mpv` MethodChannel（命令下发）配套：一个下发命令，一个上抛事件，
/// 共同构成完整的双向内核通道。降级到 ExoPlayer 时，原生侧需把播放器回调
/// 映射为同形状事件，Dart 层无需改动。
class MpvEventChannelSource implements MpvEventSource {
  static const EventChannel _channel = EventChannel('shunbo/mpv/events');

  @override
  Stream<String> get rawLines => _channel
      .receiveBroadcastStream()
      .map((dynamic e) => e.toString());
}
