package com.shunbo.legacy;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

/**
 * 开机自启入口（设置页「开机自启」开关）。
 *
 * <p>只做一件事：开关打开时，用系统给的桌面启动 Intent 把应用拉起来，并带上
 * {@link LegacyPlayerActivity#EXTRA_AUTOSTART} 标记。用
 * {@code getLaunchIntentForPackage} 而不是写死 Activity 名，是因为同一个源码
 * 同时打进两个包：单包的 LAUNCHER 是 {@code RouterActivity}（再按 API 分流），
 * 独立兼容包的 LAUNCHER 是 {@code LegacyPlayerActivity}。
 *
 * <p><b>系统限制如实说明</b>：Android 3.1+ 对从未被用户手动打开过的应用处于
 * stopped 状态、收不到 BOOT_COMPLETED；部分电视 ROM 还有自己的「自启管理」
 * 白名单。这两种情况应用侧无法绕过，设置页的说明里已经写明，不把系统拦截
 * 伪装成「已自启」。BOOT_COMPLETED / QUICKBOOT_POWERON 都是 API 1 起就有的
 * 广播，接收器里没有 androidx / Flutter 依赖，API 18 上不会被 classes2.dex 拖崩。
 */
public final class BootReceiver extends BroadcastReceiver {

    /** 部分 MTK / Amlogic 电视盒子快速开机时只发这条。 */
    private static final String ACTION_QUICKBOOT =
            "android.intent.action.QUICKBOOT_POWERON";

    @Override
    public void onReceive(Context context, Intent intent) {
        if (context == null || intent == null || intent.getAction() == null) return;
        final String action = intent.getAction();
        if (!Intent.ACTION_BOOT_COMPLETED.equals(action)
                && !ACTION_QUICKBOOT.equals(action)) {
            return;
        }
        final Prefs prefs;
        try {
            prefs = new Prefs(context);
        } catch (Throwable t) {
            return;     // 偏好读不出来就安静退出，绝不在开机广播里抛异常
        }
        if (!prefs.bootAutostart()) return;

        Intent launch = null;
        try {
            launch = context.getPackageManager()
                    .getLaunchIntentForPackage(context.getPackageName());
        } catch (Throwable ignored) {
        }
        if (launch == null) return;
        launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        launch.putExtra(LegacyPlayerActivity.EXTRA_AUTOSTART, true);
        try {
            context.startActivity(launch);
        } catch (Throwable ignored) {
            // 高版本系统限制后台起 Activity 时静默失败，用户手动点图标仍可用。
        }
    }
}
