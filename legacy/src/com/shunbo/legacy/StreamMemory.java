package com.shunbo.legacy;

import android.content.Context;
import android.content.SharedPreferences;

import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;
import java.util.HashMap;
import java.util.Iterator;
import java.util.List;
import java.util.Map;

/**
 * 线路稳定度记忆（研发计划 PQ-1 / M3-02「A2」）。
 *
 * <p><b>为什么先做这一项，而不是先做「预热」</b>：计划里的 C1 是「起播时对次优
 * 线路静默预热」。在 ijkplayer 上这条路走不通——ffmpeg 的 http 连接由每个
 * player 实例私有，另起一个 player 预热拿到的 TLS 会话、DNS 结果都无法被下一个
 * player 复用；能省下的只有「排序决策」这一步，而代价是多一个解码上下文。
 * 老盒子只有 1.5 GB 内存，双 player 同时 prepare 会把本该给当前台的带宽和
 * CPU 抢走，反而让首帧更慢。
 *
 * <p>所以 M3 的提速不走「预热连接」，走「记住上一次哪条最快，下次直接开它」：
 * 收益是同一件事（首帧更短），成本是几十字节磁盘和一个 HashMap。
 *
 * <p><b>C2「相邻台预取」也不做</b>：频道与线路表本来就在内存里（{@code catalog}），
 * 预取的唯一有效形式是预连下一台的 m3u8，而这会在换台瞬间和当前台抢带宽——
 * 直播本来就带宽紧张，等于用当前的卡顿换下一台快 300 ms。
 *
 * <p><b>C3「关键帧对齐起播」不做</b>：直播源本来就从最近的可用位置起播，
 * 要「对齐关键帧」得改 demuxer 的 fflags，那会同时削弱抗抖动缓冲。它需要
 * 真机 A/B 才能定，不在没有对照数据的阶段动。
 *
 * <p><b>三条设计约束</b>：
 * <ol>
 *   <li>只影响「先试哪一条」，不改频道表、不改 UI 序号、不改用户手动选线；</li>
 *   <li>只在「优先清晰度＝自动」时生效。用户明确选了 1080P 优先，就不许记忆
 *       把他拽到一条更快的 576P 上；</li>
 *   <li>连续两次硬失败（内核报错 / 首帧超时）才降权，且降权只是排后，
 *       仍然会试（见 {@code findNext} 第二遍）——台账与实测都可能过期，
 *       任何线路都不该被永久判死。</li>
 * </ol>
 */
final class StreamMemory {

    /** 单独一个文件：主偏好里全是小键，塞几百条线路记录会拖慢每次 getInt。 */
    static final String FILE = "shunbo_legacy_streams";
    /** 记录上限：按最近使用时间淘汰，避免无限增长。 */
    static final int MAX_ENTRIES = 500;
    /** 连续失败多少次算「这条线路最近不行」。 */
    static final int DEMOTE_STREAK = 2;
    /**
     * 降权的有效期：14 天。
     *
     * <p>没有这一条，一条线路只要在某个下午失败两次就会被永久排在后面——
     * 而直播源站是换 CDN、换 token 的，两周前的失败对今天的判断没有意义。
     * 过期后自动恢复成普通线路（记录还在，只是不再降权）。
     */
    static final long DEMOTE_TTL_MS = 14L * 24L * 60L * 60L * 1000L;
    /** 记忆排序要比首条线路快这么多才值得跳过去，避免在两条差不多的线路上来回跳。 */
    static final int JUMP_GAIN_MS = 250;

    private final SharedPreferences sp;
    /** 内存镜像；null 表示还没加载。所有访问都在主线程。 */
    private HashMap<String, Entry> cache;

    /**
     * 硬解失败的记忆有效期：7 天。
     *
     * <p>硬解能不能用，除了机型差异，还取决于当时解码器有没有被别的应用占着、
     * 源站临时换了编码参数。所以这条记录不能永久生效，否则一条线路上的偶发失败
     * 会让它永远跑软解。7 天是「够久到不重复踩坑，又够短到能自愈」的折中。
     */
    static final long HARD_FAIL_TTL_MS = 7L * 24L * 60L * 60L * 1000L;

    /** 一条线路的记忆：上次首帧耗时、连续失败次数、最后更新时间、硬解是否失败过。 */
    private static final class Entry {
        int okMs = -1;
        int failStreak = 0;
        long ts = 0L;
        /** 该线路是否在硬解下失败过（1 = 是）。为 0 时整条记录与旧版格式兼容。 */
        int hardFail = 0;

        String encode() {
            return okMs + "|" + failStreak + "|" + ts + "|" + hardFail;
        }

        static Entry decode(String raw) {
            if (raw == null) return null;
            final String[] p = raw.split("\\|", -1);
            // 旧版本只有 3 段；第 4 段（硬解标记）是 1.0.4 加的，缺省按 0 处理，
            // 这样升级安装不会把已有记忆全部作废。
            if (p.length < 3 || p.length > 4) return null;
            final Entry e = new Entry();
            try {
                e.okMs = Integer.parseInt(p[0]);
                e.failStreak = Integer.parseInt(p[1]);
                e.ts = Long.parseLong(p[2]);
                e.hardFail = p.length == 4 ? Integer.parseInt(p[3]) : 0;
            } catch (NumberFormatException bad) {
                return null;
            }
            return e;
        }
    }

    StreamMemory(Context context) {
        sp = context.getSharedPreferences(FILE, Context.MODE_PRIVATE);
    }

    /**
     * 键用「hash + 长度」。URL 太长不宜直接当键，而单纯 hashCode 有碰撞可能，
     * 加上长度后碰撞概率可以忽略，且不需要在播放线程里算 MD5。
     */
    private static String keyOf(String url) {
        if (url == null || url.length() == 0) return null;
        return "u" + Integer.toHexString(url.hashCode()) + "-" + url.length();
    }

    private HashMap<String, Entry> map() {
        if (cache != null) return cache;
        final HashMap<String, Entry> m = new HashMap<String, Entry>();
        try {
            for (Map.Entry<String, ?> e : sp.getAll().entrySet()) {
                if (!(e.getValue() instanceof String)) continue;
                Entry parsed = Entry.decode((String) e.getValue());
                if (parsed != null) m.put(e.getKey(), parsed);
            }
        } catch (Throwable ignored) {
            // 一份坏掉的 XML 只能让「排序变回默认」，绝不能影响播放。
        }
        cache = trim(m);
        return cache;
    }

    /** 超出上限时按 ts 淘汰一半，减少写盘次数。 */
    private HashMap<String, Entry> trim(HashMap<String, Entry> m) {
        if (m.size() <= MAX_ENTRIES) return m;
        final List<Map.Entry<String, Entry>> all =
                new ArrayList<Map.Entry<String, Entry>>(m.entrySet());
        Collections.sort(all, new Comparator<Map.Entry<String, Entry>>() {
            @Override
            public int compare(Map.Entry<String, Entry> a, Map.Entry<String, Entry> b) {
                return a.getValue().ts < b.getValue().ts ? 1
                        : a.getValue().ts > b.getValue().ts ? -1 : 0;
            }
        });
        final HashMap<String, Entry> kept = new HashMap<String, Entry>();
        final SharedPreferences.Editor ed = sp.edit();
        for (int i = 0; i < all.size(); i++) {
            if (i < MAX_ENTRIES / 2) {
                kept.put(all.get(i).getKey(), all.get(i).getValue());
            } else {
                ed.remove(all.get(i).getKey());
            }
        }
        try { ed.apply(); } catch (Throwable ignored) {}
        return kept;
    }

    private void put(String url, int okMs, int failStreak) {
        final String key = keyOf(url);
        if (key == null) return;
        final Entry old = map().get(key);
        put(url, okMs, failStreak, old == null ? 0 : old.hardFail);
    }

    /** 写一条完整记录：硬解标记必须原样带上，否则一次成功就把硬解结论冲掉了。 */
    private void put(String url, int okMs, int failStreak, int hardFail) {
        final String key = keyOf(url);
        if (key == null) return;
        final Entry e = new Entry();
        e.okMs = okMs;
        e.failStreak = failStreak;
        e.ts = System.currentTimeMillis();
        e.hardFail = hardFail;
        map().put(key, e);
        try { sp.edit().putString(key, e.encode()).apply(); } catch (Throwable ignored) {}
    }

    /** 上次首帧耗时（ms）；没记录返回 -1。 */
    int firstFrameMs(String url) {
        final String key = keyOf(url);
        if (key == null) return -1;
        final Entry e = map().get(key);
        return e == null ? -1 : e.okMs;
    }

    /** 连续失败次数。 */
    int failStreak(String url) {
        final String key = keyOf(url);
        if (key == null) return 0;
        final Entry e = map().get(key);
        return e == null ? 0 : e.failStreak;
    }

    /** 这条线路最近是否被降权（连续失败达到阈值，且失败没过期）。 */
    boolean isDemoted(String url) {
        final String key = keyOf(url);
        if (key == null) return false;
        final Entry e = map().get(key);
        if (e == null || e.failStreak < DEMOTE_STREAK) return false;
        return System.currentTimeMillis() - e.ts < DEMOTE_TTL_MS;
    }

    /** 首帧成功：记耗时并清空失败计数。 */
    void noteSuccess(String url, long firstFrameMs) {
        final String key = keyOf(url);
        if (key == null) return;
        final Entry old = map().get(key);
        final int prev = old == null ? -1 : old.okMs;
        // 取两次的较小值：偶发的一次慢（冷缓存 / 握手重传）不该把好线路的记忆拉长。
        final int now = (int) Math.max(1L, Math.min(Integer.MAX_VALUE, firstFrameMs));
        put(url, prev > 0 ? Math.min(prev, now) : now, 0);
    }

    /** 硬失败：内核报错或首帧超时。这类才计入降权，慢与抖动不算。 */
    void noteFailure(String url) {
        final String key = keyOf(url);
        if (key == null) return;
        final Entry old = map().get(key);
        final int streak = (old == null ? 0 : old.failStreak) + 1;
        put(url, old == null ? -1 : old.okMs, Math.min(streak, 9));
    }

    /** 换台成功后清空失败计数（用于线路又被证明可用的场合）。 */
    void clearFail(String url) {
        final String key = keyOf(url);
        if (key == null) return;
        final Entry old = map().get(key);
        if (old == null || old.failStreak == 0) return;
        put(url, old.okMs, 0);
    }

    int size() {
        return map().size();
    }

    // ------------------------------------------------------- 硬解适配（M4）

    /**
     * 记一笔「这条线路在硬解下失败」。
     *
     * <p><b>为什么按线路记而不是全局一个开关</b>：真机反馈「有的台可以硬解、
     * 有的台只能软解」——硬解能不能用取决于这条流的编码参数（H.264 / HEVC、
     * 分辨率、profile），用一个全局标记会把能硬解的台一起拖下水。
     */
    void noteHardDecodeFail(String url) {
        final String key = keyOf(url);
        if (key == null) return;
        final Entry old = map().get(key);
        put(url, old == null ? -1 : old.okMs,
                old == null ? 0 : old.failStreak, 1);
    }

    /** 这条线路是否应该直接用软解（硬解失败过，且记录没过期）。 */
    boolean hardDecodeUnfit(String url) {
        final String key = keyOf(url);
        if (key == null) return false;
        final Entry e = map().get(key);
        if (e == null || e.hardFail == 0) return false;
        return System.currentTimeMillis() - e.ts < HARD_FAIL_TTL_MS;
    }

    /** 诊断页：有多少条线路被记为「硬解不适配」。 */
    int hardUnfitCount() {
        final long now = System.currentTimeMillis();
        int n = 0;
        for (Entry e : map().values()) {
            if (e.hardFail != 0 && now - e.ts < HARD_FAIL_TTL_MS) n++;
        }
        return n;
    }

    /**
     * 清空全部硬解失败记录。
     *
     * <p>用户在设置里主动把解码方式切回「硬解」时调用：这是一次明确的重试意图，
     * 不该被几周前的旧结论挡住。
     */
    void clearHardDecodeFlags() {
        boolean changed = false;
        for (String key : new ArrayList<String>(map().keySet())) {
            final Entry e = map().get(key);
            if (e == null || e.hardFail == 0) continue;
            e.hardFail = 0;
            try { sp.edit().putString(key, e.encode()).apply(); } catch (Throwable ignored) {}
            changed = true;
        }
        if (changed) cache = map();
    }

    /** 判定用：这条线路的记忆是否比 {@code currentMs} 明显更快。 */
    boolean isFasterThan(String url, int currentMs) {
        final int ms = firstFrameMs(url);
        if (ms <= 0) return false;
        return currentMs <= 0 || ms + JUMP_GAIN_MS < currentMs;
    }

    /**
     * 找这台「上次出画最快、且没被降权」的线路下标。
     *
     * @param qualityFloor 只接受标称清晰度不低于它的线路；0 表示不限。
     * @param currentMs    首条线路的记忆耗时（-1 = 无记录），用于判断跳过去是否划算。
     * @return 下标；-1 表示没有更好的选择，调用方保持原顺序。
     */
    int bestIndex(List<ChannelCatalog.Stream> streams, int qualityFloor, int currentMs) {
        if (streams == null || streams.size() <= 1) return -1;
        int best = -1;
        int bestMs = Integer.MAX_VALUE;
        for (int i = 0; i < streams.size(); i++) {
            final ChannelCatalog.Stream s = streams.get(i);
            if (s == null || s.url == null) continue;
            if (s.resolver != null && s.resolver.length() > 0) continue;
            if (qualityFloor > 0 && s.quality > 0 && s.quality < qualityFloor) continue;
            if (isDemoted(s.url)) continue;
            final int ms = firstFrameMs(s.url);
            if (ms <= 0 || ms >= bestMs) continue;
            bestMs = ms;
            best = i;
        }
        if (best < 0) return -1;
        // 与当前首条比：没有改进就留在原地，避免为了几十毫秒在两条线路间来回跳。
        return isFasterThan(streams.get(best).url, currentMs) ? best : -1;
    }

    /** 诊断页一行：把「记住了什么」讲清楚，而不是只报个数字。 */
    String summary(List<ChannelCatalog.Stream> streams, int preferredIndex) {
        final StringBuilder b = new StringBuilder();
        b.append("记忆：").append(size()).append(" 条线路");
        if (streams == null || streams.isEmpty()) return b.toString();
        if (preferredIndex > 0 && preferredIndex < streams.size()) {
            b.append(" · 本台首选第 ").append(preferredIndex + 1).append(" 条（上次 ");
            b.append(firstFrameMs(streams.get(preferredIndex).url)).append(" ms）");
        } else {
            b.append(" · 本台无更快记录，按台账顺序");
        }
        int demoted = 0;
        final Iterator<ChannelCatalog.Stream> it = streams.iterator();
        while (it.hasNext()) {
            if (isDemoted(it.next().url)) demoted++;
        }
        if (demoted > 0) b.append(" · 降权 ").append(demoted).append(" 条");
        return b.toString();
    }
}
