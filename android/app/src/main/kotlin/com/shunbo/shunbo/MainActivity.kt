package com.shunbo.shunbo

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * 唯一注册点：把 `shunbo/mpv`（命令）、`shunbo/mpv/events`（事件）、
 * `shunbo/player_view`（渲染面）、`shunbo/system`（形态/构建/保活）、
 * `shunbo/network`（默认网络快照 + 变化事件）五条原生能力挂到 Flutter 引擎上。
 *
 * 通道名与 Dart 侧 `mpv_platform_channel_native.dart` / `mpv_event_channel.dart` /
 * `platform/system_channel.dart` 的常量**必须逐字一致** —— 写错的症状是
 * 「方法调用永不返回」：MethodChannel 落到 notImplemented，Dart 侧拿到
 * MissingPluginException。
 */
class MainActivity : FlutterActivity() {

    private var methodHandler: MpvMethodHandler? = null
    private var networkWatch: NetworkWatch? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        val bridge = PlaybackEventBridge()
        val scale = VideoScaleController()
        val handler = MpvMethodHandler(applicationContext, bridge, scale)
        methodHandler = handler

        MethodChannel(messenger, "shunbo/mpv").setMethodCallHandler(handler)
        EventChannel(messenger, "shunbo/mpv/events").setStreamHandler(bridge)

        // 画面缩放（适应 / 铺满 / 拉伸）。与 `shunbo/mpv` 分开：
        // 它作用在**渲染面**上而不是播放内核，且桌面端没有对应实现，
        // 混进主通道会让「通道缺失 → 播放失败」的排查变复杂。
        MethodChannel(messenger, SCALE_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "setScaleMode" -> {
                    scale.setMode(VideoScaleMode.fromName(call.argument<String>("mode")))
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        // R1/R8/R10/R11c：形态探测、构建信息、数据目录、播放保活。
        MethodChannel(messenger, SystemProbe.CHANNEL)
            .setMethodCallHandler(SystemProbe(applicationContext))

        // R14：精确网络变化（ConnectivityManager）。与 `shunbo/system` 分开，
        // 因为它是持续事件流，且桌面端不注册时 Dart 侧必须能确定性回落。
        val watch = NetworkWatch(applicationContext)
        networkWatch = watch
        MethodChannel(messenger, NetworkWatch.METHOD_CHANNEL)
            .setMethodCallHandler(watch)
        EventChannel(messenger, NetworkWatch.EVENT_CHANNEL).setStreamHandler(watch)

        flutterEngine.platformViewsController.registry.registerViewFactory(
            "shunbo/player_view",
            PlayerSurfaceFactory(handler, scale),
        )
    }

    companion object {
        /** 与 Dart 侧 `player_surface.dart` 的 `_scaleChannel` 必须逐字一致。 */
        const val SCALE_CHANNEL = "shunbo/player_view/scale"
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        methodHandler?.dispose()
        methodHandler = null
        networkWatch?.dispose()
        networkWatch = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
