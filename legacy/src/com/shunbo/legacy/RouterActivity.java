package com.shunbo.legacy;

import android.app.Activity;
import android.content.Intent;
import android.os.Build;
import android.os.Bundle;

/**
 * 单包入口：按系统 API 等级把用户分流到两套界面。
 *
 * <p>背景：Flutter 引擎的下限是 API 24，`flutter build` 会把 minSdk 强行拉回 24
 * （实测改 16 会被改写回 `flutter.minSdkVersion`，产物 badging 仍是 24）。要让
 * 一个 APK 同时装进 API 18 的乐视 S50 Air 和现代设备，只能手工组装：主 dex 放
 * 原生内核，Flutter 的 dex 作为 classes2/3。于是启动时必须先判断该走哪套。
 *
 * <p>本类刻意只用 API 1 的接口，且**不 import 任何 Flutter / androidx 类**：
 * 编译期不依赖，运行期用字符串 + 反射触达，避免 API 18 上因类验证失败而崩。
 * 主题用系统 `Theme.NoDisplay`（不绘制、跳完即 finish），不会闪一下白屏。
 */
public final class RouterActivity extends Activity {

    /** Flutter 入口：与 android/app/src/main/AndroidManifest.xml 里的全限定名一致。 */
    static final String FLUTTER_ACTIVITY = "com.shunbo.shunbo.MainActivity";

    /** 与 LegacyVersionCompat.MIN_SUPPORTED_API 同源，改动必须两边一起改。 */
    static final int FLUTTER_MIN_API = 24;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        // 开机自启标记（BootReceiver 写入）必须透传到目标界面，否则单包里
        // RouterActivity 重新构造 Intent 时会把它丢掉。
        final Bundle extras = getIntent() == null ? null : getIntent().getExtras();
        Intent next = null;
        if (supportsFlutter()) {
            next = flutterIntent();
        }
        if (next == null) {
            next = new Intent(this, LegacyPlayerActivity.class);
        }
        if (extras != null) next.putExtras(extras);
        boolean started = false;
        try {
            startActivity(next);
            started = true;
        } catch (Throwable t) {
            CrashReport.record(this, "RouterActivity.start", t);
        }
        if (!started) {
            // Flutter 入口起不来时退回原生：宁可少功能，也不要黑屏或闪退。
            try {
                Intent fallback = new Intent(this, LegacyPlayerActivity.class);
                if (extras != null) fallback.putExtras(extras);
                startActivity(fallback);
            } catch (Throwable ignored) {
                // 连原生都起不来，只能留给桌面；崩溃已由 CrashReport 留痕。
            }
        }
        finish();
    }

    /** 只读 SDK_INT；读失败按「不支持 Flutter」处理（保守走原生）。 */
    private boolean supportsFlutter() {
        try {
            return Build.VERSION.SDK_INT >= FLUTTER_MIN_API;
        } catch (Throwable t) {
            return false;
        }
    }

    /**
     * 反射构造 Flutter 入口 Intent。
     *
     * <p>在 API 18 上 MainActivity 位于 classes2.dex，而系统不带 multidex 时只加载
     * classes.dex，`Class.forName` 必然抛 ClassNotFoundException —— 这正是我们要的
     * 「探针」：类找不到就不跳，不会触发任何 Flutter 类的加载与验证。
     */
    private Intent flutterIntent() {
        try {
            Class.forName(FLUTTER_ACTIVITY);
        } catch (Throwable t) {
            return null;
        }
        try {
            Intent i = new Intent();
            i.setClassName(this, FLUTTER_ACTIVITY);
            i.addFlags(Intent.FLAG_ACTIVITY_NO_ANIMATION);
            return i;
        } catch (Throwable t) {
            return null;
        }
    }
}
