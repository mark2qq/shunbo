package com.shunbo.legacy;

import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;

import java.util.Locale;

import tv.danmaku.ijk.media.player.IjkMediaPlayer;

/**
 * 运行时质量探针（研发计划 PQ-1 / M0-01）。
 *
 * <p><b>为什么要有这个类</b>：1.0.2 的所有保护都工作在「结果层」——
 * 要等 {@code BUFFERING_START} 事件、要等首帧超时、要等用户看见卡顿。
 * 而 ijkplayer 0.8.8 其实已经暴露了 5 个运行时读数（丢帧率、实测码率、
 * 音视频缓存时长、累计流量、实际解码分辨率），此前一个都没读。
 * 本类把它们按 1 秒一次采进环形缓冲，供后续闭环（B1 水位 / B2 让路 /
 * D1 缓存差 / A1 假高清）与诊断页使用。
 *
 * <p><b>本阶段是只读的</b>：不参与任何播放决策，不影响换台、不影响同步。
 * 因此 M0 产物可以随时发布出去收数据，行为与 1.0.2 完全一致。
 *
 * <p><b>三条保守约定</b>：
 * <ol>
 *   <li>每个读数单独 try/catch。内核不认某个属性时只把该列记 -1，
 *       不抛到播放线程，也不影响其它列；</li>
 *   <li>采样跑在主线程 Handler 上（单次调用是 native 属性读取，&lt;1 ms），
 *       避免再开线程与 player 生命周期竞态；</li>
 *   <li>所有派生指标都带「样本不够」的返回约定（-1 / {@link Long#MIN_VALUE}），
 *       由调用方决定怎么显示，绝不拿 0 冒充「正常」。</li>
 * </ol>
 */
public final class QualityProbe {

    /** 环形缓冲容量：1 秒 1 条 = 最近 60 秒。 */
    public static final int WINDOW = 60;
    /** 采样间隔。 */
    public static final long SAMPLE_MS = 1000L;
    /**
     * 起播后多久给「假高清」结论。
     *
     * <p>码率在起播阶段是爬升的（首分片小、后续才满速），过早判定会把
     * 真高清误判成假的；8 秒足以跨过 2～3 个分片。
     */
    public static final long FAKE_HD_SETTLE_MS = 8000L;
    /**
     * 低码率**提示**门槛（不参与真假判定）。
     *
     * <p>实测真机 1080P 约 1.95 Mbps 仍属正常，所以 1.5 Mbps 只用来在诊断页
     * 标一句「偏低」，绝不据此降权——M1 就是被这条判据误导的。
     */
    public static final long FAKE_HD_MIN_BPS = 1500000L;
    /**
     * 历史判据遗留（宽度绝对值）。已由 {@link Tuning#FAKE_HD_WIDTH_RATIO}
     * 的「标称比例」判据取代，保留常量仅为兼容门禁断言。
     */
    public static final int FAKE_HD_MIN_WIDTH = 1280;

    private final Handler handler = new Handler(Looper.getMainLooper());

    private final long[] tMs = new long[WINDOW];
    /** 丢帧率 ×1000 存成整数（float 在数组里不方便判「无效」）。-1 = 读不到。 */
    private final int[] dropMilli = new int[WINDOW];
    private final long[] bitRateBps = new long[WINDOW];
    private final long[] vCachedMs = new long[WINDOW];
    private final long[] aCachedMs = new long[WINDOW];
    private final long[] trafficBytes = new long[WINDOW];
    private final int[] widthPx = new int[WINDOW];
    private final int[] heightPx = new int[WINDOW];
    /**
     * 解码帧率 / 输出帧率（×100 存整数）。-1 = 读不到。
     *
     * <p>口径经 ijkplayer k0.8.8 源码核实（见 README §40）：解码帧率在
     * {@code avcodec_receive_frame()} 后采样，输出帧率在
     * {@code SDL_VoutDisplayYUVOverlay()} 后采样；上屏前的迟到帧丢弃既不进
     * 输出帧率、也不进「丢帧率」那一项。所以「解码明显高于输出」只说明
     * 帧在上屏阶段被抽掉，不能反推丢帧率失灵，也不能据此调 framedrop。
     */
    private final int[] decFpsCenti = new int[WINDOW];
    private final int[] outFpsCenti = new int[WINDOW];

    private int count;
    private int head;

    private IjkMediaPlayer player;
    private ChannelCatalog.Stream stream;
    private long startedAtMs;
    private boolean running;
    /** 至少一个读数抛过异常：诊断页据此提示「本机内核不支持部分读数」。 */
    private boolean readFailed;
    private Runnable task;

    /** 起播一条线路时调用。会先停掉上一轮的采样。 */
    public void start(IjkMediaPlayer p, ChannelCatalog.Stream s) {
        stop();
        player = p;
        stream = s;
        startedAtMs = SystemClock.uptimeMillis();
        count = 0;
        head = 0;
        readFailed = false;
        running = true;
        schedule(SAMPLE_MS);
    }

    /** 换线 / 换台 / 释放时调用。可重复调用。 */
    public void stop() {
        running = false;
        if (task != null) {
            handler.removeCallbacks(task);
            task = null;
        }
        player = null;
        stream = null;
    }

    public boolean isRunning() {
        return running;
    }

    /** 是否有读数读取失败（内核属性缺失）。 */
    public boolean readFailed() {
        return readFailed;
    }

    private void schedule(long delayMs) {
        if (!running) return;
        task = new Runnable() {
            @Override
            public void run() {
                task = null;
                if (!running) return;
                sample();
                schedule(SAMPLE_MS);
            }
        };
        handler.postDelayed(task, delayMs);
    }

    private void sample() {
        final IjkMediaPlayer p = player;
        if (p == null) return;
        final int i = head;
        tMs[i] = SystemClock.uptimeMillis();
        try {
            dropMilli[i] = (int) (p.getDropFrameRate() * 1000f);
        } catch (Throwable t) {
            dropMilli[i] = -1;
            readFailed = true;
        }
        try {
            bitRateBps[i] = p.getBitRate();
        } catch (Throwable t) {
            bitRateBps[i] = -1;
            readFailed = true;
        }
        try {
            vCachedMs[i] = p.getVideoCachedDuration();
        } catch (Throwable t) {
            vCachedMs[i] = -1;
            readFailed = true;
        }
        try {
            aCachedMs[i] = p.getAudioCachedDuration();
        } catch (Throwable t) {
            aCachedMs[i] = -1;
            readFailed = true;
        }
        try {
            trafficBytes[i] = p.getTrafficStatisticByteCount();
        } catch (Throwable t) {
            trafficBytes[i] = -1;
            readFailed = true;
        }
        try {
            widthPx[i] = p.getVideoWidth();
            heightPx[i] = p.getVideoHeight();
        } catch (Throwable t) {
            widthPx[i] = -1;
            heightPx[i] = -1;
            readFailed = true;
        }
        try {
            decFpsCenti[i] = (int) (p.getVideoDecodeFramesPerSecond() * 100f);
        } catch (Throwable t) {
            decFpsCenti[i] = -1;
            readFailed = true;
        }
        try {
            outFpsCenti[i] = (int) (p.getVideoOutputFramesPerSecond() * 100f);
        } catch (Throwable t) {
            outFpsCenti[i] = -1;
            readFailed = true;
        }
        head = (head + 1) % WINDOW;
        if (count < WINDOW) count++;
    }

    /** back = 0 取最新一条，1 取上一条……；样本不足返回 -1。 */
    private int idx(int back) {
        if (count == 0) return -1;
        int i = (head - 1 - back) % WINDOW;
        if (i < 0) i += WINDOW;
        return i;
    }

    public int sampleCount() {
        return count;
    }

    // ------------------------------------------------------------ 单点读数

    /** 视频缓存时长（毫秒）；读不到返回 -1。直播下即「还能播多少」。 */
    public long videoCachedMs() {
        final int i = idx(0);
        return i < 0 ? -1L : vCachedMs[i];
    }

    public long audioCachedMs() {
        final int i = idx(0);
        return i < 0 ? -1L : aCachedMs[i];
    }

    /** 音视频缓存差（视频 − 音频）；任一侧无效返回 {@link Long#MIN_VALUE}。 */
    public long cachedGapMs() {
        final int i = idx(0);
        if (i < 0) return Long.MIN_VALUE;
        if (vCachedMs[i] < 0 || aCachedMs[i] < 0) return Long.MIN_VALUE;
        return vCachedMs[i] - aCachedMs[i];
    }

    public int width() {
        final int i = idx(0);
        return i < 0 ? -1 : widthPx[i];
    }

    public int height() {
        final int i = idx(0);
        return i < 0 ? -1 : heightPx[i];
    }

    /** 解码帧率（×100）；读不到返回 -1。 */
    public int decodeFpsCenti() {
        final int i = idx(0);
        return i < 0 ? -1 : decFpsCenti[i];
    }

    /** 输出帧率（×100）；读不到返回 -1。 */
    public int outputFpsCenti() {
        final int i = idx(0);
        return i < 0 ? -1 : outFpsCenti[i];
    }

    /**
     * {@code seconds} 秒前的输出帧率（×100）；样本不足或读不到返回 -1。
     *
     * <p>用于回答「切台回来后是起播就低，还是播放一段时间才掉下来」——
     * 14:42 真机反馈「开始播放没有延迟，切回来才不同步」，单点帧率无法
     * 区分这两种，必须给出同一探针窗口内的历史值。采样间隔 1 秒，
     * 所以 back 直接等于秒数；不新开采样、不读播放器，纯数组回放。
     */
    public int outputFpsCentiAgo(int seconds) {
        if (seconds <= 0 || count <= seconds) return -1;
        final int i = idx(seconds);
        return i < 0 ? -1 : outFpsCenti[i];
    }

    /** 当前丢帧率（×1000，即 12 = 1.2%）；读不到返回 -1。 */
    public int dropMilliNow() {
        final int i = idx(0);
        return i < 0 ? -1 : dropMilli[i];
    }

    /**
     * 近 20 秒的丢帧率增量（×1000）。
     *
     * <p>单次读数无法判断「现在是否正在掉帧」——它是累计量。用首尾差值
     * 才能看出这一段有没有恶化；样本不足返回 {@link Integer#MIN_VALUE}。
     */
    public int dropDeltaMilli() {
        final int n = Math.min(count, 20);
        if (n < 4) return Integer.MIN_VALUE;
        final int a = idx(0);
        final int b = idx(n - 1);
        if (dropMilli[a] < 0 || dropMilli[b] < 0) return Integer.MIN_VALUE;
        return dropMilli[a] - dropMilli[b];
    }

    /** 实测码率（bps）：优先内核读数，读不到时用流量差分折算。 */
    public long bitrateBps() {
        final int i = idx(0);
        if (i >= 0 && bitRateBps[i] > 0) return bitRateBps[i];
        return trafficBps();
    }

    /** 码率来源：true = 内核 getBitRate()，false = 流量/时长折算。 */
    public boolean bitrateFromKernel() {
        final int i = idx(0);
        return i >= 0 && bitRateBps[i] > 0;
    }

    /** 用最近 ≤10 秒的累计流量差折算码率；无效返回 -1。 */
    public long trafficBps() {
        return trafficBps(11);
    }

    /**
     * 用最近 {@code window} 个采样（1 秒 1 个）的累计流量差折算码率。
     *
     * <p>B1 需要两个口径：8 秒判「现在是否在塌」、30 秒当基线。窗口拉长会把
     * 分片拉取的锯齿抹平（实测同一台 1080P 线路在 10 秒窗口下读数会在
     * 1.6～2.4 Mbps 之间跳），因此基线必须用长窗口。
     *
     * <p>返回 -1 表示样本不足或流量没涨（例如暂停、源站限速到 0）。
     */
    public long trafficBps(int window) {
        final int n = Math.min(count, Math.max(2, window));
        if (n < 2) return -1L;
        final int last = idx(0);
        final int first = idx(n - 1);
        if (trafficBytes[last] < 0 || trafficBytes[first] < 0) return -1L;
        final long db = trafficBytes[last] - trafficBytes[first];
        final long dt = tMs[last] - tMs[first];
        if (db <= 0L || dt <= 0L) return -1L;
        return db * 8000L / dt;
    }

    /**
     * 最近 {@code window} 个采样里「最忙的 8 秒窗口」码率（bps）。
     *
     * <p><b>为什么 B1 的基线不能用「30 秒平均」</b>：真机 10:31 的读数直接暴露了
     * 这个坑——画面卡住时吞吐趋零，30 秒均值也跟着塌到接近 0，于是
     * 「现在 < 基线的 40%」永远不成立，最该触发的场景反而永远不触发。
     * 用窗口内的峰值当基线，「从 2 Mbps 掉到 0」才会被看见。
     *
     * <p>返回 -1 表示样本不足或窗口内没有任何一次有效流量。
     */
    public long peakTrafficBps(int window) {
        final int n = Math.min(count, Math.max(2, window));
        if (n < 2) return -1L;
        long peak = -1L;
        for (int end = 0; end < n - 1; end++) {
            for (int len = 1; len <= 8 && end + len < n; len++) {
                final int a = idx(end);
                final int b = idx(end + len);
                if (trafficBytes[a] < 0 || trafficBytes[b] < 0) continue;
                final long db = trafficBytes[a] - trafficBytes[b];
                final long dt = tMs[a] - tMs[b];
                if (db <= 0L || dt <= 0L) continue;
                final long bps = db * 8000L / dt;
                if (bps > peak) peak = bps;
            }
        }
        return peak;
    }

    /**
     * 最近 {@code window} 个采样里流量是否完全没涨。
     *
     * <p>与 {@link #trafficBps(int)} 返回 -1 的区别很重要：-1 说的是「算不出来」，
     * 这里说的是「算得出来，答案就是 0」。直播里吞吐为 0 就是卡死，
     * 不能因为「除以零没法算」就当成没事发生。
     */
    public boolean bytesStalled(int window) {
        final int n = Math.min(count, Math.max(2, window));
        if (n < 2) return false;
        final int last = idx(0);
        final int first = idx(n - 1);
        if (trafficBytes[last] < 0 || trafficBytes[first] < 0) return false;
        return trafficBytes[last] - trafficBytes[first] <= 0L;
    }

    /** 窗口内视频缓存最小值（毫秒）；无有效样本返回 -1。 */
    public long minVideoCachedMs(int window) {
        final int n = Math.min(count, Math.max(1, window));
        long min = -1L;
        for (int back = 0; back < n; back++) {
            final long v = vCachedMs[idx(back)];
            if (v < 0) continue;
            if (min < 0 || v < min) min = v;
        }
        return min;
    }

    /** 窗口内视频缓存均值（毫秒）；无有效样本返回 -1。 */
    public long avgVideoCachedMs(int window) {
        final int n = Math.min(count, Math.max(1, window));
        long sum = 0L;
        int used = 0;
        for (int back = 0; back < n; back++) {
            final long v = vCachedMs[idx(back)];
            if (v < 0) continue;
            sum += v;
            used++;
        }
        return used == 0 ? -1L : sum / used;
    }

    // ------------------------------------------------------------ 假高清判定

    /** 台账 / 标签是否声称 1080P 及以上。 */
    public boolean hdClaimed() {
        final ChannelCatalog.Stream s = stream;
        if (s == null) return false;
        if (s.quality >= 1080) return true;
        final String label = s.label == null ? "" : s.label;
        return label.indexOf("1080") >= 0 || label.indexOf("2160") >= 0;
    }

    /** 是否已经攒够样本可以下「假高清」结论。 */
    public boolean fakeHdChecked() {
        return running && count >= 4
                && SystemClock.uptimeMillis() - startedAtMs >= FAKE_HD_SETTLE_MS;
    }

    /**
     * 台账声称的标称宽度（2160→3840 / 1080→1920 / 720→1280 / 576→720）。
     *
     * <p>返回 -1 表示「这条线路没声称任何清晰度」，此时不做真假判断——
     * 把一条没标清一档的源判成假高清没有任何意义。
     */
    public int claimedWidth() {
        final ChannelCatalog.Stream s = stream;
        if (s == null) return -1;
        switch (s.quality) {
            case 2160: return 3840;
            case 1080: return 1920;
            case 720: return 1280;
            case 576: return 720;
            default: break;
        }
        // 台账没写 quality 时退回看标签文字：中文源常见「1080P」「4K」写法。
        final String label = s.label == null ? "" : s.label;
        if (label.indexOf("2160") >= 0 || label.indexOf("4K") >= 0) return 3840;
        if (label.indexOf("1080") >= 0) return 1920;
        if (label.indexOf("720") >= 0) return 1280;
        return -1;
    }

    /**
     * 假高清：实测宽度够不上标称宽度的 {@link Tuning#FAKE_HD_WIDTH_RATIO}。
     *
     * <p><b>为什么不再看码率</b>（M1 实测修正）：真机上有两条典型线路——
     * 标称 1080P 实测 1920×1080 但只有 1.95 Mbps，标称标清实测 800×600、
     * 0.56 Mbps。若沿用「&lt;1.5 Mbps 即假高清」，前者这种真高清会被误判，
     * 降权后用户被推到更糊的线路上；而流量折算本身的噪声有 ±30%，也分不清
     * 「1080P 低码率」和「720P 上采样」。宽度是解码器直出的硬读数，只看它。
     *
     * <p>只做判定，不做动作——降权发生在 {@link PlaybackController}（A1），
     * 本类仍然只读。
     */
    public boolean isFakeHd() {
        if (!fakeHdChecked()) return false;
        final int w = width();
        final int claim = claimedWidth();
        if (w <= 0 || claim <= 0) return false;
        return w < (int) (claim * Tuning.FAKE_HD_WIDTH_RATIO);
    }

    /** 假高清的现场描述，供失败原因与诊断页共用。 */
    public String resolutionDetail() {
        final int claim = claimedWidth();
        return "实测 " + width() + "×" + height()
                + (claim > 0 ? " / 标称 " + claim : "");
    }

    /** 当前线路标签，供诊断页显示。 */
    public String streamLabel() {
        final ChannelCatalog.Stream s = stream;
        return s == null || s.label == null ? "" : s.label;
    }

    // ------------------------------------------------------------ 诊断页文本

    /**
     * 诊断页 4 行读数。文案刻意写「判读」而不是只报数字——现场拿到截图的人
     * 应该能直接判断是带宽、解码还是标签问题，不必回来问怎么读。
     */
    public String summary() {
        final StringBuilder b = new StringBuilder();
        if (count == 0) {
            b.append("读数：采样中（每 1 秒 1 次，环形 60 秒）\n");
            return b.toString();
        }

        // 行 1：码率
        final long bps = bitrateBps();
        b.append("码率：");
        if (bps > 0L) {
            b.append(String.format(Locale.US, "%.2f Mbps", bps / 1000000.0));
            b.append(bitrateFromKernel() ? "（内核）" : "（流量折算）");
            // 提示文案必须和 FAKE_HD_MIN_BPS 用同一个数，否则「判据 1.5 却说需 2.5」
            // 会让人以为阈值设错了。真机实测 1080P 约 1.95 Mbps 仍属正常，
            // 所以这里只说「偏低、留意」，不下结论、更不据此降权。
            if (bps < FAKE_HD_MIN_BPS) {
                b.append(String.format(Locale.US, " · 偏低（低于 %.1f Mbps），留意是否已被降码率",
                        FAKE_HD_MIN_BPS / 1000000.0));
            }
        } else {
            // 区分「算不出来」与「算出来就是 0」：真机上画面卡住时正是后者，
            // 旧文案一律说「样本不足」，会让人以为是采样问题而不是线路断了。
            b.append(bytesStalled(8)
                    ? "读不到（近 8 秒没有任何流量增长——画面可能已卡住）"
                    : "读不到（内核未返回，且流量样本不足）");
        }
        b.append('\n');

        // 行 2：缓存水位（B1 的判据来源）
        final long v = videoCachedMs();
        final long a = audioCachedMs();
        final long min = minVideoCachedMs(30);
        final long avg = avgVideoCachedMs(30);
        b.append("缓存：视频 ").append(v >= 0 ? (v + " ms") : "—");
        if (min >= 0 && avg >= 0) {
            b.append("（30 秒最低 ").append(min).append(" / 均 ").append(avg).append("）");
        }
        b.append(" · 音频 ").append(a >= 0 ? (a + " ms") : "—");
        final long gap = cachedGapMs();
        if (gap != Long.MIN_VALUE) {
            b.append(" · 差 ").append(gap >= 0 ? "+" : "").append(gap).append(" ms");
            // M1 实测修正：真机上 1080P 台差 +14152 ms，而同一时刻时钟读数是
            // 1.000（完全同步）。原因是两路统计口径不同——视频侧是解码帧队列，
            // 音频侧只是包队列，差值与音画偏差没有对应关系。旧文案写「偏大，
            // 视频侧积压」，会把排障的人直接引去调视频参数，属于纯误报。
            if (Math.abs(gap) > 3000L) {
                b.append("（两路统计口径不同，此差值与音画同步无关，勿据此调参）");
            }
        }
        b.append('\n');

        // 行 3：丢帧
        final int drop = dropMilliNow();
        final int delta = dropDeltaMilli();
        b.append("丢帧：");
        if (drop >= 0) {
            b.append(String.format(Locale.US, "%.1f%%", drop / 1000.0));
        } else {
            b.append("读不到");
        }
        // 口径必须写清楚，否则下一行「帧率」会被当成读数打架。
        // ijkplayer k0.8.8 的 drop_frame_rate = drop_frame_count / decode_frame_count，
        // 只在 get_video_frame() 的「解码后、入队前」early drop 分支里累计；
        // video_refresh() 里因迟到被丢的帧既不递增这个计数，也不会触发
        // SDL_VoutDisplayYUVOverlay。真机 13:52 读数「丢帧 0.5%」配上
        // 「解码 19.80 / 输出 7.81」看似矛盾，其实是同一现象的上下游。
        b.append("（不含上屏前丢帧）");
        if (delta != Integer.MIN_VALUE) {
            b.append(String.format(Locale.US, " · 近 20 秒 %+.1f 个百分点", delta / 1000.0));
            // 标注阈值必须和显示精度对齐：这里只显示 1 位小数（0.1 个百分点），
            // 旧代码阈值只有 30（0.03 个百分点）就写「正在恶化」，16:48 真机
            // 31.jpg 因此出现「+0.0 个百分点（正在恶化）」这种自相矛盾的页面。
            // 只有 |delta| >= 100 时显示值才可能真的不是 0.0。
            if (delta >= 100) b.append("（正在恶化）");
            else if (delta <= -100) b.append("（在好转）");
        }
        b.append('\n');

        // 行 4：分辨率与「假高清」结论（M1 后按标称宽度比例判，不看码率）
        final int w = width();
        final int h = height();
        final int claim = claimedWidth();
        b.append("画面：");
        b.append(w > 0 && h > 0 ? (w + "×" + h) : "分辨率未就绪");
        if (claim > 0) {
            b.append(" · 标称 ").append(claim >= 3840 ? "2160P"
                    : claim >= 1920 ? "1080P" : claim >= 1280 ? "720P" : "576P");
            if (isFakeHd()) {
                b.append(" · 判为假高清（宽度不足标称的 ")
                        .append((int) (Tuning.FAKE_HD_WIDTH_RATIO * 100)).append("%）");
            } else if (fakeHdChecked()) {
                b.append(" · 实测相符");
            } else {
                b.append(" · 判定中（满 8 秒给结论）");
            }
        }
        b.append('\n');

        // 行 5：解码帧率 vs 输出帧率 —— 区分「解码跟不上」与「显示端延迟」。
        // 口径（ijkplayer k0.8.8 源码逐行核实，勿凭印象改判读文案）：
        //   vdps = avcodec_receive_frame 成功后 SDL_SpeedSamplerAdd（解码帧数/秒）
        //   vfps = SDL_VoutDisplayYUVOverlay 后 SDL_SpeedSamplerAdd（上屏帧数/秒）
        //   两者共用 samples[10] 速度采样器（窗口≈最近 9 次调用），公式相同、事件不同。
        //   video_refresh() 的迟到帧分支是 frame_queue_next + goto retry，
        //   既不更新 drop_frame_rate，也不调用 SDL_VoutDisplayYUVOverlay，
        //   ⇒ 被丢的帧只进 vdps、不进 vfps，更不进「丢帧」那一行。
        // 所以「解码明显高于输出」= 帧在上屏前被抽掉了，是解码/显示链路跟不上，
        // 不是恒定相位偏移，也不是「丢帧率失灵」。这里只陈述事实：
        // 旧文案把这一支写成「主动追赶音频」，会让人以为调大 framedrop 有用，
        // framedrop=N 只是「最多连续 early drop N 帧」，调大只会丢得更多；
        // late drop 的开关条件是 framedrop>0，1 和 10 完全等价。
        final int dec = decodeFpsCenti();
        final int out = outputFpsCenti();
        if (dec >= 0 || out >= 0) {
            b.append("帧率：解码 ");
            b.append(dec >= 0 ? String.format(Locale.US, "%.2f", dec / 100.0) : "—");
            b.append(" · 输出 ");
            b.append(out >= 0 ? String.format(Locale.US, "%.2f", out / 100.0) : "—");
            if (dec >= 0 && out >= 0 && out > 0) {
                final int diffCenti = dec - out;
                if (diffCenti > 200) {
                    b.append("（输出比解码少 ")
                            .append(String.format(Locale.US, "%.2f", diffCenti / 100.0))
                            .append("，上屏前被丢；与上行丢帧率口径不同）");
                } else if (diffCenti < -200) {
                    b.append("（输出高于解码，正常）");
                } else {
                    b.append("（两者相当，解码链路没有积压）");
                }
            }
            b.append('\n');
        }

        if (readFailed) {
            b.append("    本机内核对部分读数返回异常，缺的项显示为「—」，不影响播放。\n");
        }
        return b.toString();
    }
}
