package com.shunbo.legacy;

import android.content.Context;
import android.content.SharedPreferences;

import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Set;

/**
 * 本地偏好：收藏 + 上次观看。
 *
 * <p>只用 API 1 就有的 {@link SharedPreferences}（{@code getStringSet} 自 API 11 起，
 * 本包 minSdk 16），不申请任何权限、不落外部存储。键名一旦发布就不要改，
 * 否则升级会丢收藏——{@link #SCHEMA} 只用于诊断页展示。
 *
 * <p>读失败一律返回空集合 / -1，绝不抛异常：收藏是锦上添花的功能，
 * 不能因为一份坏掉的 XML 让整个播放器起不来。
 */
final class Prefs {

    static final String FILE = "shunbo_legacy";
    /** v2：新增设置项；旧键名一个没改，升级不丢收藏 / 上次观看 / 地区。 */
    static final int SCHEMA = 2;
    static final String K_LAST_NUM = "last_channel_num";
    static final String K_LAST_STREAM = "last_stream_index";
    static final String K_FAV = "favorites";
    static final String K_REGION_MODE = "region_mode";
    static final String K_REGION_PROVINCE = "region_province";
    static final String K_REGION_CITY = "region_city";
    /** 最近用过的地区（最多 5 个），格式 mode~province~city;… */
    static final String K_RECENT_REGIONS = "recent_regions";

    // ---- 设置项（v2）：键名发布后不再改，值统一存 int，开关用 0/1 ----
    static final String K_BOOT_AUTOSTART = "set_boot_autostart";
    static final String K_BOOT_DIRECT_PLAY = "set_boot_direct_play";
    static final String K_START_CHANNEL = "set_start_channel";
    static final String K_PANEL_IDLE_MS = "set_panel_idle_ms";
    static final String K_FAIL_FALLBACK = "set_fail_fallback";
    static final String K_FAIL_HINT_MS = "set_fail_hint_ms";
    static final String K_QUALITY_PRIORITY = "set_quality_priority";
    static final String K_NUMBER_COMMIT_MS = "set_number_commit_ms";
    static final String K_ZAP_COMMIT_MS = "set_zap_commit_ms";
    static final String K_FIRST_FRAME_TIMEOUT_MS = "set_first_frame_timeout_ms";
    static final String K_ASPECT = "set_aspect";
    static final String K_HARD_DECODE = "set_hard_decode";
    /**
     * 自动换线（M2）。默认开——用户 2026-11-10 明确决定。
     *
     * <p>关掉即 1.0.2 行为：只有「已经卡了 / 已经超时」才换线，不做预测性换线。
     * 键名从 v2 起就定下，后续不再改。
     */
    static final String K_AUTO_FAILOVER = "set_auto_failover";
    /**
     * 同步兼容模式：关掉 max-fps / video-pictq-size 两个「同步保护」参数。
     *
     * <p>默认关（= 1.0.2 行为）。只有个别 1080P 源出现「音画有延迟」时才需要试它，
     * 属于「用户按需打开」的兜底，不做默认值变更。
     */
    static final String K_SYNC_COMPAT = "set_sync_compat";
    // 已废弃：K_SHOW_TOP_BAR（"set_show_top_bar"）。顶部信息条按截图红标
    // 「不管什么时候都不要显示」整体删除，设置项同步下线；旧版本残留的这个键
    // 在恢复默认设置时会被清掉（见 resetSettings）。

    /** 设置项的默认值。新装机按主流电视播放软件的习惯给值。 */
    static int defaultOf(String key) {
        if (K_BOOT_AUTOSTART.equals(key)) return 0;
        if (K_BOOT_DIRECT_PLAY.equals(key)) return 1;
        if (K_START_CHANNEL.equals(key)) return 0;      // 上次观看
        if (K_PANEL_IDLE_MS.equals(key)) return 30000;  // 30 秒（默认，适配遥控器选台节奏）
        if (K_FAIL_FALLBACK.equals(key)) return 1;      // 自动回退
        if (K_FAIL_HINT_MS.equals(key)) return 3000;
        if (K_QUALITY_PRIORITY.equals(key)) return 0;   // 自动
        if (K_NUMBER_COMMIT_MS.equals(key)) return 2000;
        if (K_ZAP_COMMIT_MS.equals(key)) return 280;
        if (K_FIRST_FRAME_TIMEOUT_MS.equals(key)) return 8000;
        if (K_ASPECT.equals(key)) return 0;
        if (K_HARD_DECODE.equals(key)) return 0;        // 软解
        if (K_AUTO_FAILOVER.equals(key)) return 1;      // 自动换线（默认开）
        if (K_SYNC_COMPAT.equals(key)) return 0;        // 同步兼容模式（默认关）
        return 0;
    }

    private final SharedPreferences sp;

    Prefs(Context context) {
        sp = context.getSharedPreferences(FILE, Context.MODE_PRIVATE);
    }

    /** 收藏台 id 集合（返回可写副本，避免直接改 SP 缓存对象）。 */
    Set<String> favorites() {
        try {
            Set<String> raw = sp.getStringSet(K_FAV, null);
            return raw == null ? new HashSet<String>() : new HashSet<String>(raw);
        } catch (Throwable t) {
            return new HashSet<String>();
        }
    }

    boolean isFavorite(String id) {
        if (id == null || id.length() == 0) return false;
        return favorites().contains(id);
    }

    /** 返回切换后的状态；写盘失败时仍返回预期值，不影响本次交互。 */
    boolean toggleFavorite(String id) {
        if (id == null || id.length() == 0) return false;
        Set<String> set = favorites();
        boolean now;
        if (set.contains(id)) {
            set.remove(id);
            now = false;
        } else {
            set.add(id);
            now = true;
        }
        try {
            sp.edit().putStringSet(K_FAV, set).apply();
        } catch (Throwable ignored) {
        }
        return now;
    }

    int favoriteCount() {
        return favorites().size();
    }

    int lastNum() {
        try {
            return sp.getInt(K_LAST_NUM, -1);
        } catch (Throwable t) {
            return -1;
        }
    }

    int lastStream() {
        try {
            return sp.getInt(K_LAST_STREAM, 0);
        } catch (Throwable t) {
            return 0;
        }
    }

    /** 记录「上次观看」：台号 + 线路序号，下次启动直接续到这台。 */
    void saveLast(int num, int streamIndex) {
        try {
            sp.edit()
                    .putInt(K_LAST_NUM, num)
                    .putInt(K_LAST_STREAM, Math.max(0, streamIndex))
                    .apply();
        } catch (Throwable ignored) {
        }
    }

    // ---- 地区选择（默认苏州；null 表示「用清单里的默认值」）----

    String regionMode() { return stringOrNull(K_REGION_MODE); }

    String regionProvince() { return stringOrNull(K_REGION_PROVINCE); }

    String regionCity() { return stringOrNull(K_REGION_CITY); }

    void saveRegion(String mode, String province, String city) {
        try {
            final String key = mode + "~" + province + "~" + city;
            final List<String> kept = new ArrayList<String>();
            kept.add(key);
            for (String[] old : recentRegions()) {
                final String prev = old[0] + "~" + old[1] + "~" + old[2];
                if (!prev.equals(key) && kept.size() < 5) kept.add(prev);
            }
            final StringBuilder b = new StringBuilder();
            for (String k : kept) {
                if (b.length() > 0) b.append(';');
                b.append(k);
            }
            sp.edit()
                    .putString(K_REGION_MODE, mode)
                    .putString(K_REGION_PROVINCE, province)
                    .putString(K_REGION_CITY, city)
                    .putString(K_RECENT_REGIONS, b.toString())
                    .apply();
        } catch (Throwable ignored) {
        }
    }

    /** 最近使用地区：每项 {mode, province, city}，最新的排最前。 */
    List<String[]> recentRegions() {
        final List<String[]> out = new ArrayList<String[]>();
        try {
            final String raw = sp.getString(K_RECENT_REGIONS, "");
            if (raw == null || raw.length() == 0) return out;
            for (String item : raw.split(";")) {
                final String[] parts = item.split("~", -1);
                if (parts.length != 3) continue;
                if (parts[0].length() == 0) continue;
                out.add(new String[]{parts[0], parts[1], parts[2]});
                if (out.size() >= 5) break;
            }
        } catch (Throwable ignored) {
        }
        return out;
    }

    // ---------------------------------------------------------------- 设置

    /** 读坏了的 XML / 类型不匹配一律落回默认值，绝不让设置把启动拖崩。 */
    int setting(String key) {
        try {
            return sp.getInt(key, defaultOf(key));
        } catch (Throwable t) {
            return defaultOf(key);
        }
    }

    void setSetting(String key, int value) {
        try {
            sp.edit().putInt(key, value).apply();
        } catch (Throwable ignored) {
        }
    }

    boolean settingOn(String key) { return setting(key) != 0; }

    boolean bootAutostart() { return settingOn(K_BOOT_AUTOSTART); }

    boolean bootDirectPlay() { return settingOn(K_BOOT_DIRECT_PLAY); }

    /** 0 上次观看 / 1 第 1 台 / 2 收藏首台。 */
    int startChannelMode() { return setting(K_START_CHANNEL); }

    /** 0 表示「不自动隐藏」。 */
    int panelIdleMs() {
        int v = setting(K_PANEL_IDLE_MS);
        return v < 0 ? 0 : v;
    }

    boolean failFallback() { return settingOn(K_FAIL_FALLBACK); }

    int failHintMs() {
        int v = setting(K_FAIL_HINT_MS);
        return v < 500 ? 500 : v;
    }

    /** 0 自动 / 1 1080P 优先 / 2 720P 优先 / 3 标清优先。 */
    int qualityPriority() { return setting(K_QUALITY_PRIORITY); }

    int numberCommitMs() { return setting(K_NUMBER_COMMIT_MS); }

    int zapCommitMs() { return setting(K_ZAP_COMMIT_MS); }

    int firstFrameTimeoutMs() { return setting(K_FIRST_FRAME_TIMEOUT_MS); }

    /** 0 铺满 / 1 16:9 信箱 / 2 4:3 信箱。 */
    int aspect() { return setting(K_ASPECT); }

    boolean hardDecode() { return settingOn(K_HARD_DECODE); }

    boolean autoFailover() { return settingOn(K_AUTO_FAILOVER); }

    boolean compatSync() { return settingOn(K_SYNC_COMPAT); }

    /** 只清收藏；上次观看、地区、设置都不动。 */
    void clearFavorites() {
        try {
            sp.edit().putStringSet(K_FAV, new HashSet<String>()).apply();
        } catch (Throwable ignored) {
        }
    }

    /** 恢复默认设置：只移除设置键，收藏 / 上次观看 / 地区一概保留。 */
    void resetSettings() {
        try {
            SharedPreferences.Editor e = sp.edit();
            e.remove(K_BOOT_AUTOSTART);
            e.remove(K_BOOT_DIRECT_PLAY);
            e.remove(K_START_CHANNEL);
            e.remove(K_PANEL_IDLE_MS);
            e.remove(K_FAIL_FALLBACK);
            e.remove(K_FAIL_HINT_MS);
            e.remove(K_QUALITY_PRIORITY);
            e.remove(K_NUMBER_COMMIT_MS);
            e.remove(K_ZAP_COMMIT_MS);
            e.remove(K_FIRST_FRAME_TIMEOUT_MS);
            e.remove(K_ASPECT);
            e.remove(K_HARD_DECODE);
            e.remove(K_AUTO_FAILOVER);
            e.remove(K_SYNC_COMPAT);
            // 旧版本遗留：顶部信息条设置已下线，顺带清掉残留键。
            e.remove("set_show_top_bar");
            e.apply();
        } catch (Throwable ignored) {
        }
    }

    private String stringOrNull(String key) {
        try {
            String v = sp.getString(key, null);
            return (v == null || v.length() == 0 || v.length() > 32) ? null : v;
        } catch (Throwable t) {
            return null;
        }
    }
}
