package com.shunbo.shunbo

import android.graphics.Matrix
import android.view.TextureView

/**
 * 视频缩放模式（与 Dart 侧 `BoxFit` 一一对应）。
 *
 * 为什么需要它：`TextureView` 的默认行为是**把视频缓冲拉伸到视图大小**，
 * 等价于 `BoxFit.fill`。于是 4:3 的台会被拉成 16:9、竖屏短片会被拉扁——
 * 用户看到「人脸变形」却以为是源的问题。只有按视频真实宽高重算变换矩阵，
 * 才能分别实现「适应（留边）/ 铺满（裁切）/ 拉伸」三档。
 */
enum class VideoScaleMode {
    /** 适应：完整显示，比例不对时留黑边（`BoxFit.contain`）。 */
    FIT,

    /** 铺满：等比放大到铺满视图，超出部分裁掉（`BoxFit.cover`）。 */
    CROP,

    /** 拉伸：铺满视图且不保持比例（`BoxFit.fill`）。 */
    STRETCH;

    companion object {
        /** 名字与 Dart 侧 `PlayerSurface._modeOf` 严格一致，写错会静默退回 FIT。 */
        fun fromName(name: String?): VideoScaleMode = when (name) {
            "cover" -> CROP
            "fill" -> STRETCH
            else -> FIT
        }
    }
}

/**
 * 缩放状态的唯一持有者：视频宽高 + 当前模式 + 所有活跃渲染面。
 *
 * 三者必须放在一处，否则「先出画面后切模式」和「中途换台分辨率变了」两条
 * 路径都会漏更新：视频尺寸来自播放内核（ExoPlayer 的 `onVideoSizeChanged`），
 * 模式来自 Flutter（控制条按钮），渲染面由 PlatformView 创建——三方各自
 * 拿不到另外两方的状态，只有集中持有才能随时重算矩阵。
 *
 * 线程：所有 `TextureView` 操作必须在主线程。`setVideoSize` / `setMode`
 * 可能被播放回调线程调用，内部统一切主线程再刷新。
 */
class VideoScaleController {

    @Volatile
    var mode: VideoScaleMode = VideoScaleMode.FIT
        private set

    @Volatile
    private var videoWidth: Int = 0

    @Volatile
    private var videoHeight: Int = 0

    /** 活跃渲染面。仅主线程访问（注册/注销都发生在 PlatformView 生命周期里）。 */
    private val views = mutableSetOf<TextureView>()

    private val main = android.os.Handler(android.os.Looper.getMainLooper())

    fun setMode(newMode: VideoScaleMode) {
        if (mode == newMode) return
        mode = newMode
        refresh()
    }

    /** 播放内核报告视频像素宽高。0 表示未知（回到默认拉伸）。 */
    fun setVideoSize(width: Int, height: Int) {
        if (width <= 0 || height <= 0) return
        if (videoWidth == width && videoHeight == height) return
        videoWidth = width
        videoHeight = height
        refresh()
    }

    fun attach(view: TextureView) {
        views.add(view)
        apply(view)
    }

    fun detach(view: TextureView) {
        views.remove(view)
    }

    /** 重算并应用所有渲染面的变换。 */
    fun refresh() {
        main.post {
            // 拷贝一份再遍历：`apply` 可能触发布局变化引起回调重入。
            for (v in views.toList()) apply(v)
        }
    }

    /**
     * 把当前模式应用到一个渲染面。
     *
     * 数学基础：`TextureView` 的默认映射已经把视频**拉伸**到视图大小
     * （基准缩放 `baseX = 视图宽/视频宽`、`baseY = 视图高/视频高`）。
     * 所以这里只需要在这个基准上再乘一个相对缩放：
     *   * 拉伸 → 相对缩放 (1, 1)，即不动；
     *   * 适应 → 目标缩放 `s = min(baseX, baseY)`，相对 (s/baseX, s/baseY)；
     *   * 铺满 → 目标缩放 `s = max(baseX, baseY)`，相对 (s/baseX, s/baseY)。
     * 缩放锚点取视图中心，于是画面自然居中、两侧/上下对称留边。
     *
     * 视频尺寸未知时 `setTransform(null)`：回到默认拉伸，至少能出画面，
     * 不会出现「矩阵算错导致黑屏」。
     */
    fun apply(view: TextureView) {
        // 已脱离窗口（PlatformView 正在销毁、或 Flutter 刚摘掉渲染面）时
        // 直接放弃：`setTransform` 会走 native SurfaceTexture 层，对已销毁的
        // 视图调用会 ANR 甚至崩溃。这是 `dispose` 之外的最后一道闸。
        if (!view.isAttachedToWindow) return
        val vw = view.width
        val vh = view.height
        val w = videoWidth
        val h = videoHeight
        if (vw <= 0 || vh <= 0 || w <= 0 || h <= 0) {
            view.setTransform(null)
            return
        }
        val baseX = vw.toFloat() / w
        val baseY = vh.toFloat() / h

        val rel: Pair<Float, Float> = when (mode) {
            VideoScaleMode.STRETCH -> 1f to 1f
            VideoScaleMode.FIT -> {
                val s = minOf(baseX, baseY)
                (s / baseX) to (s / baseY)
            }
            VideoScaleMode.CROP -> {
                val s = maxOf(baseX, baseY)
                (s / baseX) to (s / baseY)
            }
        }

        if (rel.first >= 0.999f && rel.second >= 0.999f) {
            view.setTransform(null)
            return
        }
        val matrix = Matrix()
        matrix.setScale(rel.first, rel.second, vw / 2f, vh / 2f)
        view.setTransform(matrix)
    }
}
