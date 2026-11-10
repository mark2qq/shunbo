package com.shunbo.shunbo

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/**
 * 播放期间的前台服务保活（R11c）。
 *
 * 为什么必须有：酷开、小米、乐视等系统在内存紧张时会主动 `kill -9` 后台进程，
 * 而且这类清理往往**不区分是否正在播放**。前台服务带常驻通知，是 Android 上
 * 唯一被系统承认的「我正在干正事，别杀我」的声明。
 *
 * 边界：
 * - 只在播放期间启用（进入播放 start，停止播放 stop），不做常驻后台；
 * - 通知不可点进二级页，只把用户带回应用（避免引入第二个入口 / 第二套路由）；
 * - 失败静默：保活是「降低被杀概率」，拿不到不该让播放报错。
 */
class KeepAliveService : Service() {

    companion object {
        private const val CHANNEL_ID = "shunbo-playback"
        private const val NOTIFICATION_ID = 0x5b01

        /** 启动保活；返回是否成功（API 或权限不允许时返回 false，不抛）。 */
        fun start(context: Context): Boolean = try {
            val intent = Intent(context, KeepAliveService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
            true
        } catch (_: Exception) {
            false
        }

        fun stop(context: Context): Boolean = try {
            context.stopService(Intent(context, KeepAliveService::class.java))
            true
        } catch (_: Exception) {
            false
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        try {
            ensureChannel()
            val notification = buildNotification()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK,
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        } catch (_: Exception) {
            // 前台服务被系统拒绝（缺权限 / 已经被清理）：直接结束自己，
            // 不要留下一个没有通知的「后台服务」把应用拖进 ANR。
            stopSelf()
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // 被系统杀掉后不自动重建：重建时没有播放会话，常驻通知会变成骚扰。
        return START_NOT_STICKY
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "播放保活",
            NotificationManager.IMPORTANCE_MIN,
        ).apply {
            description = "播放期间保持进程存活，避免被系统清理"
            setShowBadge(false)
            enableVibration(false)
        }
        manager.createNotificationChannel(channel)
    }

    private fun buildNotification(): Notification {
        val launch = packageManager.getLaunchIntentForPackage(packageName)
        val pending = launch?.let {
            PendingIntent.getActivity(
                this,
                0,
                it,
                PendingIntent.FLAG_UPDATE_CURRENT or
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        PendingIntent.FLAG_IMMUTABLE
                    } else {
                        0
                    },
            )
        }
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        builder
            .setContentTitle("顺播正在播放")
            .setContentText("保持后台运行，避免被系统清理")
            .setSmallIcon(applicationInfo.icon)
            .setOngoing(true)
            .setShowWhen(false)
        if (pending != null) builder.setContentIntent(pending)
        return builder.build()
    }
}
