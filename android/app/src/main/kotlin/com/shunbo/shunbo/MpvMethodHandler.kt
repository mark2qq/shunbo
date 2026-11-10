package com.shunbo.shunbo

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.view.Surface
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/**
 * `shunbo/mpv` MethodChannel 的原生实现。
 *
 * 方法集与 Dart 侧 `MpvPlatformChannelNative` 一一对应：
 * create / setOption / load / play / pause / seek / getTime / getDuration /
 * sampleMetrics / dispose。
 *
 * 三条实现约定：
 * 1. **任何方法都不往上抛异常**。Dart 侧对这些调用没有 try/catch（它是按 libmpv 的
 *    同步 C API 语义写的），抛 PlatformException 会中断整条播放链路，
 *    把「读不到时长」变成「播放失败」。读不到就返回安全默认值。
 * 2. `sampleMetrics` **必须在后台线程**等首帧，Result 回主线程回调。
 * 3. 渲染表面由 PlatformView 提供（`shunbo/player_view`），与内核解耦：
 *    两者谁先就绪都能工作，不会出现「先 create 后 attach 就黑屏」。
 */
class MpvMethodHandler(
    private val context: Context,
    private val events: PlaybackEventBridge,
    private val scale: VideoScaleController,
) : MethodChannel.MethodCallHandler {

    private var engine: ExoPlayerEngine? = null
    private var surface: Surface? = null

    private val main = Handler(Looper.getMainLooper())
    private val sampler = Executors.newSingleThreadExecutor { r ->
        Thread(r, "shunbo-mpv-sample").apply { isDaemon = true }
    }

    private var ticking = false
    private val ticker = object : Runnable {
        override fun run() {
            val e = engine
            if (e != null && e.isPlaying()) {
                events.timePos(e.positionSeconds())
            }
            if (ticking) main.postDelayed(this, TICK_MS)
        }
    }

    // ---------------------------------------------------------------------
    // 渲染表面（由 PlayerSurface 的 PlatformView 调用，不走 MethodChannel）
    // ---------------------------------------------------------------------

    fun attachSurface(newSurface: Surface) {
        surface = newSurface
        engine?.setSurface(newSurface)
    }

    fun detachSurface() {
        surface = null
        // 不清 player 的 surface：Dart 侧可能正在换集，重新 attach 时会补上。
        // 真正的释放由 dispose 负责。
    }

    private fun ensureEngine(): ExoPlayerEngine {
        val existing = engine
        if (existing != null && existing.isCreated) return existing
        val created = ExoPlayerEngine(context, events)
        // 内核报出视频宽高后立刻交给缩放控制器：渲染面可能早就建好了，
        // 这里不主动刷新的话矩阵会一直停在「未知尺寸」的默认拉伸上。
        created.onVideoSize = { w, h -> scale.setVideoSize(w, h) }
        created.create()
        surface?.let { created.setSurface(it) }
        engine = created
        return created
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            handle(call, result)
        } catch (e: Exception) {
            events.error("${call.method} failed: ${e.message}")
            // 不抛给 Dart：见文件头第 1 条。返回类型不同，按方法给默认值。
            when (call.method) {
                "getTime", "getDuration" -> result.success(0.0)
                "sampleMetrics" -> result.success(null)
                else -> result.success(null)
            }
        }
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "create" -> {
                ensureEngine()
                result.success(null)
            }

            "setOption" -> {
                val key = call.argument<String>("key") ?: ""
                val value = call.argument<String>("value") ?: ""
                applyOption(key, value)
                result.success(null)
            }

            "load" -> {
                val url = call.argument<String>("url") ?: ""
                if (url.isEmpty()) {
                    result.success(null)
                    return
                }
                val e = ensureEngine()
                e.load(url)
                startTicking()
                result.success(null)
            }

            "play" -> {
                engine?.play()
                startTicking()
                result.success(null)
            }

            "pause" -> {
                engine?.pause()
                result.success(null)
            }

            "seek" -> {
                val seconds = (call.argument<Number>("seconds") ?: 0).toDouble()
                engine?.seek(seconds)
                result.success(null)
            }

            "getTime" -> result.success(engine?.positionSeconds() ?: 0.0)

            "getDuration" -> result.success(engine?.durationSeconds() ?: 0.0)

            "sampleMetrics" -> {
                val e = engine
                if (e == null) {
                    result.success(null)
                    return
                }
                sampler.execute {
                    val map = try {
                        e.metrics(FIRST_FRAME_WAIT_MS)
                    } catch (_: Exception) {
                        null
                    }
                    main.post { result.success(map) }
                }
            }

            "dispose" -> {
                stopTicking()
                engine?.release()
                engine = null
                surface = null
                result.success(null)
            }

            else -> result.notImplemented()
        }
    }

    /**
     * libmpv 选项 → ExoPlayer 能力映射。
     *
     * 只有 `http-header-fields` 有真实等价物（源站普遍校验 Referer/UA，缺了直接 403）。
     * 其余（缓存秒数、预解码帧数、硬解模式…）ExoPlayer 没有对应开关，
     * **明确忽略而不是假装设置成功** —— 假装成功会让指标门禁的结论失去意义。
     */
    private fun applyOption(key: String, value: String) {
        if (key != "http-header-fields") return
        val parsed = LinkedHashMap<String, String>()
        value.split("\n", "\r\n").forEach { raw ->
            val line = raw.trim()
            if (line.isEmpty()) return@forEach
            val idx = line.indexOf(':')
            if (idx <= 0) return@forEach
            val name = line.substring(0, idx).trim()
            val v = line.substring(idx + 1).trim()
            if (name.isNotEmpty()) parsed[name] = v
        }
        ensureEngine().setHeaders(parsed)
    }

    private fun startTicking() {
        if (ticking) return
        ticking = true
        main.postDelayed(ticker, TICK_MS)
    }

    private fun stopTicking() {
        ticking = false
        main.removeCallbacks(ticker)
    }

    fun dispose() {
        stopTicking()
        engine?.release()
        engine = null
        surface = null
        sampler.shutdownNow()
    }

    private companion object {
        const val TICK_MS = 250L
        const val FIRST_FRAME_WAIT_MS = 3_000L
    }
}
