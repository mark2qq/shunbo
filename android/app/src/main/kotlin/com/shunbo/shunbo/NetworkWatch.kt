package com.shunbo.shunbo

import android.content.Context
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.telephony.TelephonyManager
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * 默认网络的精确变化通知（`shunbo/network` + `shunbo/network/events`）。
 *
 * 为什么需要原生侧：Dart 的 `NetworkInterface.list` 在 Android 上常返回被虚拟化
 * 的接口名（如 `rmnet_data0` 在 Wi-Fi 下仍可能残留），「靠接口名猜蜂窝」会把
 * 一次 Wi-Fi 切换误判成蜂窝，进而把家宽内网源整批撤掉；反过来也会在蜂窝下
 * 继续发归属探测请求（14.8 明令蜂窝零请求）。ConnectivityManager 的
 * NetworkCapabilities 才是系统给出的权威答案。
 *
 * 三条边界：
 * 1. **不申请定位权限**。Android 8+ 读 SSID 需要 ACCESS_FINE_LOCATION，
 *    为一个缓存键去要定位权限不划算；缓存键用「传输类型 + 接口名 + 计费属性」，
 *    换网必然变化，重连同一网络不变化。
 * 2. **不尝试读取网络内容、不发起任何请求**。本类只上报系统状态，运营商归属
 *    服务仍由 Dart 侧 `CarrierDetector` 按既有策略调用（蜂窝/VPN 下根本不调用）。
 * 3. **失败一律降级**。定制 ROM 上注册回调可能抛 SecurityException；
 *    此时 `current` 的一次性快照仍然可用，Dart 侧另有 `DefaultNetworkStateProvider`。
 *
 * 用 `registerNetworkCallback`（API 21）而不是 `registerDefaultNetworkCallback`
 * （API 26）——本包 minSdk 24，后者会在旧设备上 NoSuchMethodError。
 * 回调用作**触发信号**，状态一律从 `activeNetwork` 现读，避免拿到非默认网络
 * （例如 VPN 子网络）的能力集把它当成主网络。
 */
class NetworkWatch(private val context: Context) :
    MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    companion object {
        const val METHOD_CHANNEL = "shunbo/network"
        const val EVENT_CHANNEL = "shunbo/network/events"

        private const val MAX_IFACE_LEN = 64
        private const val MAX_OPERATOR_LEN = 64
    }

    private val main = Handler(Looper.getMainLooper())
    private var sink: EventChannel.EventSink? = null
    private var callback: ConnectivityManager.NetworkCallback? = null
    private var lastSnapshot: Map<String, Any?>? = null

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            // 一次性快照：Dart 侧启动 / 回前台时主动取，不依赖事件流已建立。
            "current" -> {
                try {
                    result.success(snapshot())
                } catch (_: Exception) {
                    result.success(null)
                }
            }
            else -> result.notImplemented()
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
        register()
        // 立刻补一帧：设备已联网且此后没有网络切换时，Dart 侧也必须拿到初始态，
        // 否则「开机就是 Wi-Fi」会一直沿用 unknown 缓存键。
        emit(snapshot())
    }

    override fun onCancel(arguments: Any?) {
        unregister()
        sink = null
    }

    /** MainActivity.cleanUpFlutterEngine 调用，避免 Activity 重建后重复注册。 */
    fun dispose() {
        unregister()
        sink = null
        lastSnapshot = null
    }

    private fun connectivity(): ConnectivityManager? =
        context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager

    private fun register() {
        if (callback != null) return
        val cm = connectivity() ?: return
        val cb = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) = emit(snapshot())
            override fun onLost(network: Network) = emit(snapshot())
            override fun onCapabilitiesChanged(
                network: Network,
                capabilities: NetworkCapabilities,
            ) = emit(snapshot())
            override fun onLinkPropertiesChanged(network: Network, link: LinkProperties) =
                emit(snapshot())
            override fun onUnavailable() = emit(offline())
        }
        try {
            cm.registerNetworkCallback(NetworkRequest.Builder().build(), cb)
            callback = cb
        } catch (_: Exception) {
            // 注册失败不等于不能播：Dart 侧仍可轮询 current，并回落到接口名推断。
        }
    }

    private fun unregister() {
        val cb = callback ?: return
        callback = null
        try {
            connectivity()?.unregisterNetworkCallback(cb)
        } catch (_: Exception) {
            // 系统可能已经替我们注销了（网络服务重启），忽略即可。
        }
    }

    /** 事件必须回到主线程投递：ConnectivityManager 回调在 binder 线程上。 */
    private fun emit(state: Map<String, Any?>) {
        main.post {
            // 语义去重：onCapabilitiesChanged 可能连发多次（信号强度、计费变化），
            // 只有真正影响通道准入的字段变了才推给 Dart，避免重复触发归属探测。
            if (state == lastSnapshot) return@post
            lastSnapshot = state
            try {
                sink?.success(state)
            } catch (_: Exception) {
                // EventSink 已关闭时忽略；下一次 onListen 会重新补一帧。
            }
        }
    }

    private fun offline(): Map<String, Any?> = mapOf(
        "connected" to false,
        "kind" to "unknown",
        "key" to "offline",
        "iface" to "",
        "metered" to false,
        "vpn" to false,
        "restricted" to true,
        "carrierHint" to null,
    )

    private fun snapshot(): Map<String, Any?> {
        val cm = connectivity() ?: return offline()
        val net = try {
            cm.activeNetwork
        } catch (_: Exception) {
            null
        } ?: return offline()

        val caps = try {
            cm.getNetworkCapabilities(net)
        } catch (_: Exception) {
            null
        }
        val props = try {
            cm.getLinkProperties(net)
        } catch (_: Exception) {
            null
        }
        // 系统回调已经到达但没有能力集（极低概率的权限/时序问题）：按离线处理，
        // 宁可暂停内网通道，也不能在未知网络上沿用上一段网络的识别结论。
        if (caps == null) return offline()

        val isVpn = caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN) ||
            (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P &&
                !caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN))
        val cellular = caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR)
        val wifi = caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)
        val ethernet = caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)

        val kind = when {
            isVpn -> "vpn"
            cellular -> "cellular"
            wifi -> "wifi"
            ethernet -> "ethernet"
            else -> "unknown"
        }
        val iface = try {
            props?.interfaceName?.takeIf { it.isNotBlank() }?.take(MAX_IFACE_LEN) ?: ""
        } catch (_: Exception) {
            ""
        }
        val metered = !caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED)
        val carrierHint = if (cellular) {
            try {
                (context.getSystemService(Context.TELEPHONY_SERVICE) as? TelephonyManager)
                    ?.networkOperatorName
                    ?.takeIf { it.isNotBlank() }
                    ?.take(MAX_OPERATOR_LEN)
            } catch (_: Exception) {
                null
            }
        } else {
            null
        }
        val key = listOf(
            kind,
            iface.ifEmpty { "default" },
            if (metered) "metered" else "unmetered",
        ).joinToString(":")

        return mapOf(
            "connected" to true,
            "kind" to kind,
            "key" to key,
            "iface" to iface,
            "metered" to metered,
            "vpn" to isVpn,
            // VPN / 未知传输：出口归属不可信，Dart 侧会暂停内网通道且零探测请求。
            "restricted" to (isVpn || (!cellular && !wifi && !ethernet)),
            "carrierHint" to carrierHint,
        )
    }
}
