package com.shunbo.shunbo

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.EventChannel
import org.json.JSONObject

/**
 * `shunbo/mpv/events` EventChannel 的原生侧实现。
 *
 * 契约（与 Dart 侧 `mpv_event_channel.dart` 严格一致）：**一行一个 JSON**，
 * 事件名沿用 libmpv 的命名，让 Android 端的 ExoPlayer 回退与桌面端 FFI
 * 走同一套解析，Dart 层无需分支。
 *
 * 线程约束：播放器回调可能来自任意线程，而 `EventSink` 只能在主线程调用。
 * 所以这里统一 `Handler(mainLooper).post`，调用方不必关心自己在哪个线程。
 */
class PlaybackEventBridge : EventChannel.StreamHandler {

    private val main = Handler(Looper.getMainLooper())

    @Volatile
    private var sink: EventChannel.EventSink? = null

    /** 没有监听方时的事件直接丢弃：Flutter 还没建好 UI 时不该积压。 */
    val hasListener: Boolean get() = sink != null

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }

    private fun emit(json: JSONObject) {
        val payload = json.toString()
        main.post { sink?.success(payload) }
    }

    fun fileLoaded() = emit(JSONObject().put("event", "file-loaded"))

    /** 首帧已渲染。Dart 侧用它算首帧耗时。 */
    fun playbackRestart() = emit(JSONObject().put("event", "playback-restart"))

    fun timePos(seconds: Double) = emit(
        JSONObject()
            .put("event", "property-change")
            .put("name", "time-pos")
            .put("data", seconds)
    )

    fun duration(seconds: Double) = emit(
        JSONObject()
            .put("event", "property-change")
            .put("name", "duration")
            .put("data", seconds)
    )

    fun paused(isPaused: Boolean) = emit(
        JSONObject()
            .put("event", "property-change")
            .put("name", "pause")
            .put("data", isPaused)
    )

    fun endFile(reason: String) = emit(
        JSONObject().put("event", "end-file").put("reason", reason)
    )

    fun shutdown() = emit(JSONObject().put("event", "shutdown"))

    /**
     * 错误。用 `log-message` 而不是自造事件名：Dart 侧只认 libmpv 那几种事件，
     * 自造事件会被静默丢弃 —— 那等于把失败吞掉（E7 反复修的就是这类静默失败）。
     */
    fun error(message: String) = emit(
        JSONObject()
            .put("event", "log-message")
            .put("level", "error")
            .put("prefix", "android")
            .put("text", message)
    )
}
