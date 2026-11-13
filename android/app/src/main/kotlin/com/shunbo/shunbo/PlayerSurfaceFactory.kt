package com.shunbo.shunbo

import android.content.Context
import android.graphics.SurfaceTexture
import android.view.Surface
import android.view.TextureView
import android.view.View
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

/**
 * 渲染表面（`shunbo/player_view`）。
 *
 * 为什么用 PlatformView + TextureView 而不用 Flutter Texture：
 * 视频画面要能被 Flutter 合成、也要能覆盖字幕/弹幕等 Flutter 图层，TextureView
 * 天然支持；同时它比 SurfaceView 少一层 z-order 麻烦（SurfaceView 会盖住 Flutter 组件）。
 *
 * 生命周期：surface 的可用/销毁与播放内核解耦 —— 谁先就绪都能工作，
 * 避免「先 create 后 attach 就黑屏」这类顺序 bug。
 */
class PlayerSurfaceFactory(
    private val host: MpvMethodHandler,
    private val scale: VideoScaleController,
) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {

    override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
        // 创建参数里带初始缩放模式：PlatformView 重建（切横竖屏、进出全屏）
        // 时通道调用可能还没到达，只靠通道会让重建后的画面回到默认拉伸。
        val mode = (args as? Map<*, *>)?.get("mode") as? String
        if (mode != null) scale.setMode(VideoScaleMode.fromName(mode))
        return PlayerSurface(context, host, scale)
    }
}

private class PlayerSurface(
    private val context: Context,
    private val host: MpvMethodHandler,
    private val scale: VideoScaleController,
) : PlatformView {

    private val textureView = TextureView(context)
    private var surface: Surface? = null

    /**
     * 布局监听必须存成字段才能注销。
     *
     * 旧实现用匿名 `OnLayoutChangeListener`，`dispose()` 时无法移除，于是
     * 视图销毁过程中（尺寸归零、脱离窗口）仍会回调 `scale.apply(v)`，
     * 对正在销毁的 `TextureView` 做 `setTransform` —— 这也是闪退的来源之一。
     */
    private val layoutListener = View.OnLayoutChangeListener { v, _, _, _, _, _, _, _, _ ->
        scale.apply(v as TextureView)
    }

    init {
        // 视频尺寸未知时矩阵无意义，但一旦内核报出宽高、或用户切了模式，
        // 都必须立刻重算——这两个时机都在 [VideoScaleController.refresh] 里。
        scale.attach(textureView)
        // 视图尺寸变化（旋转、进出全屏、分屏）会改变基准缩放，必须重算。
        textureView.addOnLayoutChangeListener(layoutListener)
        textureView.surfaceTextureListener = object : TextureView.SurfaceTextureListener {
            override fun onSurfaceTextureAvailable(
                surfaceTexture: SurfaceTexture,
                width: Int,
                height: Int,
            ) {
                val s = Surface(surfaceTexture)
                surface = s
                host.attachSurface(s)
            }

            override fun onSurfaceTextureSizeChanged(
                surfaceTexture: SurfaceTexture,
                width: Int,
                height: Int,
            ) = Unit

            override fun onSurfaceTextureDestroyed(surfaceTexture: SurfaceTexture): Boolean {
                // 顺序是硬要求：先把播放器从 Surface 上解绑，再 release。
                // 反序会让渲染线程往已释放的 buffer 写帧（native 崩溃）。
                host.detachSurface()
                surface?.release()
                surface = null
                // 返回 true：SurfaceTexture 由框架回收（我们已不再持有它）。
                return true
            }

            override fun onSurfaceTextureUpdated(surfaceTexture: SurfaceTexture) = Unit
        }
    }

    override fun getView(): View = textureView

    override fun dispose() {
        // 四步顺序都不能换：
        // 1) 注销布局监听 —— 否则销毁过程中仍会 apply 到已销毁视图；
        // 2) 注销缩放登记 —— 控制器不再持有这个 TextureView；
        // 3) 让播放器解绑 Surface —— 必须在 release 之前；
        // 4) 最后才 release —— 此后没有任何一方还引用它。
        textureView.removeOnLayoutChangeListener(layoutListener)
        scale.detach(textureView)
        host.detachSurface()
        surface?.release()
        surface = null
    }
}
