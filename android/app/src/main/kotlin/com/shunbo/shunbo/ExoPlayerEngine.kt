package com.shunbo.shunbo

import android.content.Context
import android.os.Debug
import android.os.SystemClock
import android.view.Surface
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.analytics.AnalyticsListener
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * libmpv 缺失时的 Android 播放后端（ExoPlayer / media3）。
 *
 * 为什么不是 `android.media.MediaPlayer`：HLS(m3u8) 与自定义请求头在 MediaPlayer 上
 * 机型差异极大，而流媒体源这两项是刚需（源站普遍校验 Referer/UA）。
 *
 * 已知能力差距（对应设计稿风险「跨内核画质桥接」，UI 必须明示不可静默降级）：
 * - 无 libmpv 的硬解/倍速/精确 seek 语义，seek 精度受关键帧限制；
 * - 无法设置 libmpv 的 `cache-secs` 等选项，缓冲策略由 media3 默认值决定；
 * - 丢帧率只能靠 media3 的回调累加，与 libmpv 的 `drop-frame-count` 口径不完全一致。
 */
class ExoPlayerEngine(
    private val context: Context,
    private val events: PlaybackEventBridge,
) {

    private var player: ExoPlayer? = null

    /** 请求头可随时更新（换源后 Referer 会变），Factory 持有引用，load 前生效。 */
    private val headers = LinkedHashMap<String, String>()

    private val httpFactory = DefaultHttpDataSource.Factory()
        .setUserAgent("shunbo/1.0 (Android)")
        .setConnectTimeoutMs(15_000)
        .setReadTimeoutMs(15_000)
        // 跨协议重定向会绕过源站策略（https → http 降级），这里显式关掉。
        .setAllowCrossProtocolRedirects(false)

    private var loadStartedAt = 0L

    @Volatile
    private var firstFrameAt = 0L

    @Volatile
    private var firstFrameLatch = CountDownLatch(1)

    private var renderedFrames = 0L
    private var droppedFrames = 0L
    private var loadedEmitted = false
    private var released = false

    val isCreated: Boolean get() = player != null

    /**
     * 视频像素宽高变化回调（主线程）。渲染面按它重算缩放矩阵。
     *
     * 为什么必须暴露：`TextureView` 不知道视频的真实尺寸，默认会把画面
     * **拉伸**到视图大小。4:3 的台因此被人为拉宽成 16:9（人脸变形），
     * 只有拿到真实宽高才能实现「适应 / 铺满 / 拉伸」三档。
     */
    var onVideoSize: ((width: Int, height: Int) -> Unit)? = null

    fun create() {
        if (player != null) return
        val p = ExoPlayer.Builder(context)
            .setMediaSourceFactory(DefaultMediaSourceFactory(httpFactory))
            .setRenderersFactory(
                DefaultRenderersFactory(context).setEnableDecoderFallback(true)
            )
            .build()

        p.addListener(object : Player.Listener {
            override fun onPlaybackStateChanged(playbackState: Int) {
                when (playbackState) {
                    Player.STATE_READY -> {
                        if (!loadedEmitted) {
                            loadedEmitted = true
                            events.fileLoaded()
                            val d = durationSeconds()
                            if (d > 0) events.duration(d)
                        }
                    }
                    Player.STATE_ENDED -> events.endFile("eof")
                }
            }

            override fun onVideoSizeChanged(videoSize: androidx.media3.common.VideoSize) {
                val w = videoSize.width
                val h = videoSize.height
                if (w <= 0 || h <= 0) return
                onVideoSize?.invoke(w, h)
            }

            override fun onRenderedFirstFrame() {
                firstFrameAt = SystemClock.elapsedRealtime()
                firstFrameLatch.countDown()
                events.playbackRestart()
            }

            override fun onIsPlayingChanged(isPlaying: Boolean) {
                events.paused(!isPlaying)
            }

            override fun onPlayerError(error: PlaybackException) {
                // 失败必须上报：Dart 侧靠 end-file(error) 触发换源，
                // 吞掉就变成「黑屏但状态是播放中」的静默失败。
                events.error("${error.errorCodeName}: ${error.message}")
                events.endFile("error")
            }
        })

        p.addAnalyticsListener(object : AnalyticsListener {
            override fun onDroppedVideoFrames(
                eventTime: AnalyticsListener.EventTime,
                droppedFrames: Int,
                elapsedMs: Long,
            ) {
                this@ExoPlayerEngine.droppedFrames += droppedFrames
            }

            override fun onRenderedFirstFrame(
                eventTime: AnalyticsListener.EventTime,
                output: Any,
                renderTimeMs: Long,
            ) {
                renderedFrames += 1
            }
        })

        player = p
    }

    fun setHeaders(newHeaders: Map<String, String>) {
        headers.clear()
        headers.putAll(newHeaders)
        httpFactory.setDefaultRequestProperties(headers)
    }

    fun setSurface(surface: Surface?) {
        player?.setVideoSurface(surface)
    }

    fun load(url: String) {
        create()
        val p = player ?: return
        loadStartedAt = SystemClock.elapsedRealtime()
        firstFrameAt = 0L
        firstFrameLatch = CountDownLatch(1)
        loadedEmitted = false
        droppedFrames = 0
        renderedFrames = 0
        try {
            p.setMediaItem(MediaItem.fromUri(url))
            p.prepare()
        } catch (e: Exception) {
            events.error("load failed: ${e.message}")
            events.endFile("error")
        }
    }

    fun play() {
        player?.play()
    }

    fun pause() {
        player?.pause()
    }

    fun seek(seconds: Double) {
        val p = player ?: return
        if (!seconds.isFinite() || seconds < 0) return
        // prepare 之前 seek 会被 media3 排队，换源后立即定位是合法用法。
        p.seekTo((seconds * 1000.0).toLong())
    }

    fun positionSeconds(): Double {
        val p = player ?: return 0.0
        // STATE_IDLE 时 currentPosition 无意义，报 0 比报脏值安全：
        // 上层用「只进不退」兜住，但脏值（比如极大值）会把进度写坏。
        if (p.playbackState == Player.STATE_IDLE) return 0.0
        return p.currentPosition / 1000.0
    }

    fun durationSeconds(): Double {
        val p = player ?: return 0.0
        val ms = p.duration
        if (ms <= 0 || ms == androidx.media3.common.C.TIME_UNSET) return 0.0
        return ms / 1000.0
    }

    fun isPlaying(): Boolean = player?.isPlaying == true

    /**
     * 采样运行时指标。**会阻塞**直到首帧到达或超时，调用方必须在后台线程执行
     * （在主线程等 3 秒就是 ANR）。
     *
     * 首帧未到时报 999999 而不是 0：门禁是「越小越好」，报 0 会让没播起来的
     * 会话看起来完美达标。
     */
    fun metrics(waitFirstFrameMs: Long): Map<String, Any> {
        firstFrameLatch.await(waitFirstFrameMs, TimeUnit.MILLISECONDS)
        val first = if (firstFrameAt > 0 && loadStartedAt > 0) {
            (firstFrameAt - loadStartedAt).toInt()
        } else {
            999999
        }
        val memInfo = Debug.MemoryInfo()
        Debug.getMemoryInfo(memInfo)
        val total = renderedFrames + droppedFrames
        val dropRate = if (total > 0) droppedFrames.toDouble() / total.toDouble() else 0.0
        return mapOf(
            "firstFrameMs" to first,
            "memoryMb" to memInfo.totalPss / 1024.0,
            "droppedFrameRate" to dropRate,
        )
    }

    fun release() {
        if (released) return
        released = true
        firstFrameLatch.countDown()
        player?.release()
        player = null
        events.shutdown()
    }
}
