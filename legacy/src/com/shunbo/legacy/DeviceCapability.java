package com.shunbo.legacy;

import android.app.ActivityManager;
import android.content.Context;
import android.graphics.Point;
import android.media.MediaCodecInfo;
import android.media.MediaCodecList;
import android.os.Build;
import android.view.Display;
import android.view.WindowManager;

/**
 * 本机视频能力探测：决定「要不要让 2160 线路进入候选」。
 *
 * <p>背景：目标机型是乐视 S50 Air（Android 4.3 / API 18 / armv7a / 1080p 面板），
 * 清单里却有 15 个 4K 台、39 条 2160 线路。这些线路在这类设备上只有三种结局：
 * 解不动（黑屏 / 花屏）、解得动但掉帧（音画越来越不同步）、或者解得动却被缩到
 * 1080p 输出（白烧解码算力，还把热和电耗上去）。三种都不该让用户碰上，
 * 所以**在候选层就把 4K 拿掉**，而不是等播放器去试错。
 *
 * <p>判定是**保守的与**：四个条件全过才认为可以做 4K 输出，任一不过就封顶 1080。
 *
 * <ol>
 *   <li>系统版本 ≥ {@link #MIN_API_4K}（24 / Android 7.0）。API 21 才有
 *       {@link MediaCodecList} 这个可以查询解码能力的入口，21 之前连「能不能解」
 *       都问不出来；再考虑 HLS 4K 的渲染与 HDMI 输出，门槛定在 24 比较实在。</li>
 *   <li>屏幕 / 输出宽度 ≥ 3840。1080p 面板上放 2160 流只是被缩放，
 *       清晰度不会有任何提升，代价却是解码算力与同步风险。</li>
 *   <li>存在**硬解**的 2160 解码器（HEVC 或 AVC）。名字里带
 *       {@code OMX.google.} / {@code c2.android.} 的是软件解码器，不计入——
 *       软解 2160 在电视盒子上跑不到 25fps，这条线本身就是「卡顿」的来源。</li>
 *   <li>物理内存 ≥ {@link #MIN_RAM_MB_4K}。4K 解码的帧缓冲与队列是 1080p 的四倍，
 *       1 GB 机型上开 4K 会直接把整机拖到 OOM 边缘。</li>
 * </ol>
 *
 * <p>结果只算一次并缓存：MediaCodecList 枚举在部分 ROM 上要几十毫秒，
 * 而且能力在进程生命周期内不会变。
 */
public final class DeviceCapability {

    /** 允许 4K 输出的最低系统版本（Android 7.0）。低于此值一律封顶 1080。 */
    public static final int MIN_API_4K = 24;
    /** 允许 4K 输出的最低屏幕 / HDMI 输出宽度。 */
    public static final int MIN_WIDTH_4K = 3840;
    /** 允许 4K 输出的最低物理内存（MB）。 */
    public static final int MIN_RAM_MB_4K = 2048;

    /** 4K 线路的清晰度分界值（与生成器写入的 quality 同口径）。 */
    public static final int QUALITY_4K = 2160;
    /** 封顶后允许的最高清晰度。 */
    public static final int QUALITY_1080 = 1080;

    private static Info cached;

    private DeviceCapability() {}

    /** 本机能力快照。{@code supported} 为 true 只代表「可以试 4K」，不代表一定流畅。 */
    public static final class Info {
        public final int apiLevel;
        public final String release;
        public final int displayWidth;
        public final int displayHeight;
        public final int ramMb;
        public final boolean hevc4k;
        public final boolean avc4k;
        /** 四条硬条件全过（不含「解码设置是否为硬解」这一项运行时开关）。 */
        public final boolean supported;
        /** 第一条不满足的条件，用于诊断页与日志；支持时为空串。 */
        public final String reason;

        Info(int apiLevel, String release, int displayWidth, int displayHeight,
             int ramMb, boolean hevc4k, boolean avc4k, boolean supported, String reason) {
            this.apiLevel = apiLevel;
            this.release = release;
            this.displayWidth = displayWidth;
            this.displayHeight = displayHeight;
            this.ramMb = ramMb;
            this.hevc4k = hevc4k;
            this.avc4k = avc4k;
            this.supported = supported;
            this.reason = reason;
        }

        /** 一行结论：4K 到底开没开、为什么。诊断页直接用。 */
        public String verdict(boolean hardDecode) {
            if (!supported) return "已关闭 · " + reason;
            if (!hardDecode) {
                // 硬解能力有，但用户或机型把它切成了软解：2160 软解在电视盒上
                // 跑不到 25fps，开 4K 只会换来掉帧与音画漂移。
                return "已关闭 · 解码当前为软解（2160 软解在电视盒上跑不到 25fps）";
            }
            return "已开启 · API " + apiLevel + " · " + displayWidth + "×" + displayHeight
                    + " · 2160 硬解";
        }

        /** 四条判据的实际读数，出问题时能直接看出是哪一条卡住。 */
        public String detail() {
            return "API " + apiLevel + "（Android " + release + "） · 屏幕 "
                    + displayWidth + "×" + displayHeight + " · 2160 硬解 "
                    + (hevc4k ? "HEVC" : (avc4k ? "AVC" : "无"))
                    + " · 内存 " + ramMb + " MB";
        }
    }

    /** 探测并缓存本机能力。可在任意线程调用，结果不变。 */
    public static Info inspect(Context context) {
        Info local = cached;
        if (local != null) return local;

        final int api = Build.VERSION.SDK_INT;
        final String release = Build.VERSION.RELEASE == null ? "?" : Build.VERSION.RELEASE;
        final Point size = screenSize(context);
        final int ram = totalRamMb(context);
        final boolean hevc = supports2160("video/hevc");
        final boolean avc = supports2160("video/avc");

        String reason = "";
        if (api < MIN_API_4K) {
            reason = "系统 Android " + release + "（API " + api + "）< 门槛 API " + MIN_API_4K;
        } else if (size.x < MIN_WIDTH_4K) {
            reason = "屏幕 / 输出 " + size.x + "×" + size.y + " 不足 3840 宽（4K 流只会被缩放）";
        } else if (!hevc && !avc) {
            reason = "没有可用的 2160 硬解（HEVC / AVC 均不支持）";
        } else if (ram < MIN_RAM_MB_4K) {
            reason = "内存 " + ram + " MB < " + MIN_RAM_MB_4K + " MB";
        }

        local = new Info(api, release, size.x, size.y, ram, hevc, avc,
                reason.length() == 0, reason);
        cached = local;
        return local;
    }

    /**
     * 清晰度上限：0 表示不限（4K 可以进候选），否则为允许的最高清晰度。
     *
     * <p>调用方把它交给 {@code ChannelCatalog.load(context, ceiling)}，
     * 由清单层直接剥离 2160 线路、隐藏 4K 专用台——**不是**播放时降级：
     * 让 4K 线路进候选再失败，等于每次换台白等 6 秒，还会把「线路切换次数」
     * 与「台账不可达」的判断一起污染。
     */
    public static int qualityCeiling(Context context, boolean hardDecode) {
        if (!inspect(context).supported) return QUALITY_1080;
        if (!hardDecode) return QUALITY_1080;
        return 0;
    }

    // ------------------------------------------------------------ 判据细节

    private static Point screenSize(Context context) {
        Point p = new Point(0, 0);
        try {
            WindowManager wm = (WindowManager) context.getSystemService(Context.WINDOW_SERVICE);
            Display d = wm == null ? null : wm.getDefaultDisplay();
            if (d == null) return p;
            if (Build.VERSION.SDK_INT >= 17) {
                d.getRealSize(p);
            } else {
                p.x = d.getWidth();
                p.y = d.getHeight();
            }
        } catch (Throwable ignored) {
            // 拿不到就按 0 处理：0 < 3840，结论是「不做 4K」，方向是安全的。
        }
        return p;
    }

    private static int totalRamMb(Context context) {
        try {
            ActivityManager am =
                    (ActivityManager) context.getSystemService(Context.ACTIVITY_SERVICE);
            if (am == null) return 0;
            ActivityManager.MemoryInfo mi = new ActivityManager.MemoryInfo();
            am.getMemoryInfo(mi);
            long mb = mi.totalMem / (1024L * 1024L);
            return mb > Integer.MAX_VALUE ? Integer.MAX_VALUE : (int) mb;
        } catch (Throwable ignored) {
            return 0;
        }
    }

    /**
     * 是否存在能解 3840×2160 的**硬件**解码器。
     *
     * <p>API 21 以下没有 {@link MediaCodecList}，直接返回 false——这也是门槛定在 24
     * 的原因之一：老系统连「问一句」的接口都没有。
     */
    private static boolean supports2160(String mime) {
        if (Build.VERSION.SDK_INT < 21) return false;
        try {
            MediaCodecList list = new MediaCodecList(MediaCodecList.REGULAR_CODECS);
            MediaCodecInfo[] codecs = list.getCodecInfos();
            if (codecs == null) return false;
            for (int i = 0; i < codecs.length; i++) {
                MediaCodecInfo info = codecs[i];
                if (info == null || info.isEncoder()) continue;
                if (isSoftwareCodec(info.getName())) continue;
                if (!supportsType(info, mime)) continue;
                MediaCodecInfo.CodecCapabilities caps = info.getCapabilitiesForType(mime);
                if (caps == null) continue;
                MediaCodecInfo.VideoCapabilities vc = caps.getVideoCapabilities();
                if (vc == null) continue;
                boolean okSize;
                try {
                    // 同时要求「能解 2160」与「至少 24fps」：只能解但只出 10fps 的
                    // 编码器，结果还是幻灯片，不该算作支持 4K。24 而不是 25/30，
                    // 是因为部分盒子对 25/30 的边界值报不支持，但实际能跑到。
                    okSize = vc.areSizeAndRateSupported(3840, 2160, 24.0);
                } catch (Throwable ignored) {
                    // 个别 ROM 对这两个参数抛异常，退回只判尺寸。
                    okSize = vc.isSizeSupported(3840, 2160);
                }
                if (!okSize) continue;
                return true;
            }
        } catch (Throwable ignored) {
            return false;
        }
        return false;
    }

    private static boolean supportsType(MediaCodecInfo info, String mime) {
        String[] types = info.getSupportedTypes();
        if (types == null) return false;
        for (int i = 0; i < types.length; i++) {
            if (mime.equalsIgnoreCase(types[i])) return true;
        }
        return false;
    }

    /**
     * 软解判定：Android 的软件解码器命名固定（Google 的 OMX 软解、Codec2 软解），
     * 按名字排除比按 CPU 型号猜可靠。软解 2160 不参与「支持 4K」的结论。
     */
    private static boolean isSoftwareCodec(String name) {
        if (name == null) return false;
        return name.startsWith("OMX.google.") || name.startsWith("c2.android.");
    }
}
