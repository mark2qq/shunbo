package com.shunbo.shunbo

import android.app.UiModeManager
import android.content.Context
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.os.Build
import android.os.SystemClock
import android.view.InputDevice
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * 系统能力探测（`shunbo/system` 通道）：形态判定、构建信息、数据目录、播放保活。
 *
 * 为什么形态判定必须在原生侧做：
 * Dart 侧没有任何 API 能读到 `UiModeManager`、输入设备列表或 `FEATURE_TOUCHSCREEN`。
 * 用屏幕分辨率猜「是不是电视」正是要求 R1 明令禁止的做法（4K 手机会被误判）。
 *
 * 该通道与 `shunbo/mpv` 分开：它是**能力探测**，与播放内核无关；
 * 桌面端不注册它也要能跑（Dart 侧对 MissingPluginException 有确定性兜底）。
 */
class SystemProbe(private val context: Context) : MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL = "shunbo/system"
        private const val APP_DIR_NAME = "shunbo"
    }

    // 期望频道名与 Dart 侧 `SystemChannel` 常量逐字一致；
    // 写错的症状是「方法调用永不返回」（Dart 侧拿到 MissingPluginException）。
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "probeFormFactor" -> result.success(probeFormFactor())
            "buildInfo" -> result.success(buildInfo())
            "dataDir" -> result.success(dataDirPath())
            "setKeepAlive" -> {
                val enabled = call.argument<Boolean>("enabled") ?: false
                // 保活是「尽量不被杀」，失败不该打断播放：一律回 true/false 而不抛。
                val ok = if (enabled) {
                    KeepAliveService.start(context)
                } else {
                    KeepAliveService.stop(context)
                }
                result.success(ok)
            }
            // 首次交互耗时：用于诊断「遥控器按键没有反应」是输入没到还是渲染没到。
            else -> result.notImplemented()
        }
    }

    /**
     * 形态信号。字段名与 Dart `FormFactorSignal` 一一对应，改写要两边同改。
     */
    private fun probeFormFactor(): Map<String, Any> {
        val uiModeManager = context.getSystemService(Context.UI_MODE_SERVICE) as? UiModeManager
        // UI_MODE_TYPE_TELEVISION 是系统级声明（Android TV / Google TV / 部分智慧屏）。
        val uiModeTelevision =
            uiModeManager?.currentModeType == Configuration.UI_MODE_TYPE_TELEVISION

        val touchscreen = hasTouchscreen()
        val dpad = hasDpad()

        val detail = mutableListOf<String>()
        detail.add("uiMode=${uiModeManager?.currentModeType ?: "unknown"}")
        detail.add(
            "navigation=" + when (context.resources.configuration.navigation) {
                Configuration.NAVIGATION_DPAD -> "dpad"
                Configuration.NAVIGATION_TRACKBALL -> "trackball"
                Configuration.NAVIGATION_WHEEL -> "wheel"
                Configuration.NAVIGATION_NONAV -> "none"
                else -> "other"
            }
        )
        detail.add("inputDevices=${describeInputDevices()}")
        detail.add("sdk=${Build.VERSION.SDK_INT} model=${Build.MODEL}")

        return mapOf(
            "uiModeTelevision" to uiModeTelevision,
            "hasTouchscreen" to touchscreen,
            "hasDpad" to dpad,
            "source" to "android-probe",
            "detail" to detail,
        )
    }

    /**
     * 是否有触摸屏。
     *
     * 只看 `FEATURE_TOUCHSCREEN` 不够：部分电视盒子的厂商 ROM 会**误报**该特性，
     * 也有机型把它声明成可选。这里同时扫一遍输入设备，任一来源声称有触摸就算有
     * ——「有触摸」判错只会让电视按手机形态跑（遥控器仍可用方向键），
     * 而「无触摸」判错会让手机用户失去全部触摸交互，代价不对称。
     */
    private fun hasTouchscreen(): Boolean {
        val byFeature = context.packageManager.hasSystemFeature(PackageManager.FEATURE_TOUCHSCREEN)
        if (byFeature) return true
        val ids = InputDevice.getDeviceIds()
        for (id in ids) {
            val device = InputDevice.getDevice(id) ?: continue
            val sources = device.sources
            if (sources and InputDevice.SOURCE_TOUCHSCREEN != 0) return true
            if (sources and InputDevice.SOURCE_STYLUS != 0 &&
                sources and InputDevice.SOURCE_TOUCHSCREEN != 0
            ) {
                return true
            }
        }
        return false
    }

    /**
     * 是否存在方向键输入。
     *
     * 三条来源任一成立即可：
     * 1. 系统配置声明导航方式为 dpad / trackball；
     * 2. 输入设备里有 SOURCE_DPAD 或带 DPAD 的运动源（手柄）；
     * 3. 有按键型输入设备（键盘/遥控器）—— 遥控器几乎都会把自己声明成键盘。
     */
    private fun hasDpad(): Boolean {
        val nav = context.resources.configuration.navigation
        if (nav == Configuration.NAVIGATION_DPAD || nav == Configuration.NAVIGATION_TRACKBALL) {
            return true
        }
        for (id in InputDevice.getDeviceIds()) {
            val device = InputDevice.getDevice(id) ?: continue
            val sources = device.sources
            if (sources and InputDevice.SOURCE_DPAD != 0) return true
            if (sources and InputDevice.SOURCE_GAMEPAD != 0) return true
            if (sources and InputDevice.SOURCE_KEYBOARD != 0) {
                // 虚拟键盘（软键盘）不算「方向键输入」，否则所有手机都会命中。
                val isVirtual = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    device.isVirtual
                } else {
                    false
                }
                if (!isVirtual && device.keyboardType != InputDevice.KEYBOARD_TYPE_ALPHABETIC) {
                    return true
                }
            }
        }
        return false
    }

    private fun describeInputDevices(): String {
        val parts = mutableListOf<String>()
        for (id in InputDevice.getDeviceIds()) {
            val d = InputDevice.getDevice(id) ?: continue
            parts.add("${d.name}(${d.sources})")
            if (parts.size >= 4) break
        }
        return if (parts.isEmpty()) "none" else parts.joinToString("|")
    }

    /**
     * 构建信息（R10：当前渠道与版本号）。
     *
     * 渠道不额外注入 BuildConfig 字段，直接由包名后缀推断：
     * 这样渠道与「能否同机并存」用的是同一个事实来源（applicationId），
     * 不会出现「改后缀忘了改渠道常量」的错位。
     */
    private fun buildInfo(): Map<String, Any> {
        val pkg = context.packageName
        val pm = context.packageManager
        var versionName = "unknown"
        var versionCode = 0L
        try {
            val info = pm.getPackageInfo(pkg, 0)
            versionName = info.versionName ?: "unknown"
            versionCode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                info.longVersionCode
            } else {
                @Suppress("DEPRECATION")
                info.versionCode.toLong()
            }
        } catch (_: Exception) {
            // 取不到版本号不该让启动失败，诊断页显示 unknown 即可。
        }
        // 版本兼容分支的**唯一比较对象**：设备 Android API 等级（整数）。
        // 与 Dart 侧 version_compat.dart 的 kMinSupportedAndroidApi = 24 对应；
        // release 只是给用户看的展示字符串（如「4.3」），绝不参与比较。
        // 两个字段都是增量添加：已有字段名/类型/调用方式一律不变。
        return mapOf(
            "applicationId" to pkg,
            "versionName" to versionName,
            "versionCode" to versionCode,
            "channel" to if (pkg.endsWith(".lite")) "lite" else "full",
            "abis" to Build.SUPPORTED_ABIS.toList(),
            "source" to "android-buildinfo",
            "sdkInt" to Build.VERSION.SDK_INT,
            "release" to Build.VERSION.RELEASE,
        )
    }

    /**
     * 应用私有数据目录（R8：升级必须保留用户数据）。
     *
     * 用 `filesDir` 而不是 `cacheDir`：缓存目录可被系统随时清空，
     * 播放进度、收藏、频道号绑会一起消失。两个渠道包各自拥有独立的 files 目录，
     * 因此天然满足「同机并存、数据互不影响」。
     */
    private fun dataDirPath(): String {
        val dir = File(context.filesDir, APP_DIR_NAME)
        if (!dir.exists()) dir.mkdirs()
        return dir.absolutePath
    }

    /** 诊断用：进程启动至今的毫秒数（Dart 侧可对照首帧耗时）。 */
    fun uptimeMs(): Long = SystemClock.elapsedRealtime()
}
