package com.shunbo.legacy;

import android.content.Context;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;
import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * 内置频道清单读取 + 「当前地区可见视图」。
 *
 * <p>数据由 {@code tooling/gen_legacy_catalog.dart} 从主程序运行时导出的
 * {@code unified_channels.json} 生成，两条链路共用同一份线路，不重新解析 M3U。
 *
 * <p><b>地区视图是这一层的核心</b>：{@link #size()} / {@link #get(int)} /
 * {@link #indexOfNumber(int)} 返回的都是「当前地区可见」的频道，于是频道面板、
 * 检索、方向键换台、数字直达全都自动遵守同一条规则——默认只显示本地（苏州）
 * 地方台，切省加载本省全部地方台，切市加载本市台。央视 / 卫视 / 其它频道不属于
 * 地方台，任何地区下都始终可见。
 *
 * <p>解析只用 Android 自带的 {@code org.json}（API 1 起就有），不引第三方库。
 * 单台 / 单线路解析失败只跳过该条，绝不让整份清单加载失败变成黑屏无提示。
 */
public final class ChannelCatalog {

    public static final String ASSET = "channels.json";

    public static final String LOCAL_GROUP = "地方频道";
    public static final String MODE_CITY = "city";
    public static final String MODE_PROVINCE = "province";
    public static final String MODE_OTHER = "other";
    public static final String OTHER_LABEL = "其它城市";

    /** 地区面板的一行：{名称, 台数}。台数由数据层算好，老机器不重算归属。 */
    public static final class RegionOption {
        public final String name;
        public final int count;

        RegionOption(String name, int count) {
            this.name = name;
            this.count = count;
        }
    }

    public static final class Stream {
        public final String url;
        public final String label;
        public final int rank;
        public final boolean verified;
        public final boolean https;
        /** 同路径 https→http 的实测镜像线路（API 18 老 TLS 兜底用）。 */
        public final boolean mirror;
        public final Map<String, String> headers;
        /** 需要起播前 302 换 token 的线路；兼容分支当前不跟随，见生成器注释。 */
        public final String resolver;
        /** 台账可达性：TRUE/FALSE 为实测，null 为未探测。 */
        public final Boolean probeOk;
        /** 台账耗时（毫秒）；未探测为 -1。 */
        public final int probeMs;
        /** 标称清晰度：2160 / 1080 / 720 / 576，未知为 0。由生成器写入。 */
        public final int quality;
        /** 由 collect_extra_streams.dart 实测补进来的扩展线路。 */
        public final boolean extra;

        Stream(String url, String label, int rank, boolean verified, boolean https,
               boolean mirror, Map<String, String> headers, String resolver,
               Boolean probeOk, int probeMs, int quality, boolean extra) {
            this.url = url;
            this.label = label;
            this.rank = rank;
            this.verified = verified;
            this.https = https;
            this.mirror = mirror;
            this.headers = headers;
            this.resolver = resolver;
            this.probeOk = probeOk;
            this.probeMs = probeMs;
            this.quality = quality;
            this.extra = extra;
        }
    }

    public static final class Channel {
        public final int num;
        public final String id;
        public final String name;
        public final String group;
        /** 所属分类集合：主分类 + 叠加的内容分类（新闻/体育/影视/少儿/纪实/生活）。
         *  分类可叠加——「苏州新闻综合」既是「地方频道」也是「新闻」，在两类导航下都出现。
         *  与 Flutter 端 {@link LiveChannel#categories} 同口径（{@link #thematicOf} 用台名关键词判定）。 */
        public final List<String> cats;
        public final String badge;
        /** 4K / 超高清台：只用于列表归集置顶，不参与台号与线路排序。 */
        public final boolean is4K;
        /** 地方台的省 / 市归属；非地方台与未识别台都是空串。 */
        public final String province;
        public final String city;
        /** 拼音首字母串（cctv1 / zjws），遥控器检索用。 */
        public final String pyi;
        /** 全拼串（cctv1 / zhejiangweishi）。 */
        public final String py;
        /** 台账可达线路数；0 表示本机探测全失败（仍保留线路可尝试）。 */
        public final int reachable;
        /** 线路顺序可被设置里的「优先清晰度」重排，所以不是 final。 */
        public List<Stream> streams;

        /** 包内可见：只由 {@link #applyQualityPriority(int)} 调用。 */
        void setStreams(List<Stream> next) {
            streams = Collections.unmodifiableList(next);
        }

        /** 是否属于某个分类（分类栏过滤用）；分类可叠加，与 Flutter 端 inCategory 同义。 */
        boolean inCategory(String category) {
            return cats.contains(category);
        }

        /**
         * 台账里是否至少有一条「探测过且通」的线路。
         *
         * <p>清单 1046 台里有 434 台一条都没有（probeOk 全 false）——点进去注定
         * 是 8 秒黑屏再报「全部线路不可用」。换台时据此跳过，能把这段无谓等待
         * 从 8 秒压到 0；进台后仍会按线路顺序逐条尝试，因为台账是 PC 侧探测，
         * 可能滞后，不能当成判决书。
         */
        public boolean hasReachableStream() {
            if (reachable > 0) return true;
            for (int i = 0; i < streams.size(); i++) {
                if (Boolean.TRUE.equals(streams.get(i).probeOk)) return true;
            }
            return false;
        }

        Channel(int num, String id, String name, String group, String badge,
                boolean is4K, String province, String city,
                String pyi, String py, int reachable, List<Stream> streams) {
            this.num = num;
            this.id = id;
            this.name = name;
            this.group = group;
            this.cats = computeCats(group, name);
            this.badge = badge;
            this.is4K = is4K;
            this.province = province;
            this.city = city;
            this.pyi = pyi;
            this.py = py;
            this.reachable = reachable;
            this.streams = Collections.unmodifiableList(streams);
        }
    }

    /**
     * 内容分类判定（与 lib/features/live/channel_taxonomy.dart#thematicOf 同关键词口径）。
     * 顺序即优先级：少儿 / 体育 / 影视 / 纪实 / 生活 / 新闻（新闻最后，吃 CGTN 这类
     * 无栏目词的台名）。仅用台名关键词——兼容分支的清单已归一（"CCTV-13 新闻"→"CCTV-13"），
     * 后缀栏目词丢失，故个别「后缀含栏目词」的台可能不被归到对应内容栏（与手机端极少量
     * 差异，属可接受范围）。
     */
    static String thematicOf(String name) {
        if (name == null) return null;
        String n = name.toLowerCase();
        if (n.contains("少儿") || n.contains("卡通") || n.contains("动画")
                || n.contains("kids") || n.contains("children") || n.contains("cartoon")
                || n.contains("anime")) return "少儿";
        if (n.contains("体育") || n.contains("足球") || n.contains("篮球")
                || n.contains("sport")) return "体育";
        if (n.contains("影视") || n.contains("电影") || n.contains("电视剧")
                || n.contains("剧场") || n.contains("movie")) return "影视";
        if (n.contains("纪实") || n.contains("纪录") || n.contains("documentary")) return "纪实";
        if (n.contains("生活") || n.contains("综艺") || n.contains("娱乐")
                || n.contains("旅游")) return "生活";
        if (n.contains("新闻") || n.contains("news") || n.contains("cgtn")) return "新闻";
        return null;
    }

    /** 主分类 + 叠加的内容分类，构成本频道的分类集合（不可变）。 */
    private static List<String> computeCats(String group, String name) {
        List<String> list = new ArrayList<String>();
        list.add(group);
        String t = thematicOf(name);
        if (t != null && !t.equals(group)) list.add(t);
        return Collections.unmodifiableList(list);
    }

    private final List<Channel> all;
    private List<Channel> visible;
    public final String verifiedAt;
    /** 台账探测时间；空串表示清单未带台账。 */
    public final String probeAt;
    public final int declaredChannelCount;
    public final int declaredStreamCount;
    /** 解析过程中被跳过的坏条目数，用于自检页提示。 */
    public final int skipped;

    /**
     * 本机允许的最高线路清晰度：0 = 不限，{@link DeviceCapability#QUALITY_1080} = 已封顶。
     *
     * <p>封顶发生在**载入期**而不是播放期：4K 线路一旦进了候选，换台就要为它等
     * 6 秒首帧、失败后还会被计入「线路切换」，把「换台慢」和「本台台账不可达」
     * 两个判断一起污染。载入期剥离之后，上层所有逻辑（排序、跳台、诊断计数）
     * 看到的都是本机真能放的线路。
     */
    public final int qualityCeiling;
    /** 因清晰度封顶被剥离的 2160 线路数。 */
    public final int dropped4KStreams;
    /** 因清晰度封顶被整台隐藏的 4K 专用台数（剥完一条不剩）。 */
    public final int hidden4KChannels;
    /** 普通台被剥到只剩 2160 线路时保留的兜底线路数（宁可试一次，也不藏台）。 */
    public final int kept4KFallbacks;

    private final List<RegionOption> provinces;
    private final Map<String, List<RegionOption>> citiesByProvince;
    private final int otherCount;
    private final String defaultMode;
    private final String defaultProvince;
    private final String defaultCity;

    private String regionMode;
    private String regionProvince;
    private String regionCity;

    private ChannelCatalog(List<Channel> channels, String verifiedAt, String probeAt,
                           int declaredChannelCount, int declaredStreamCount,
                           int skipped, List<RegionOption> provinces,
                           Map<String, List<RegionOption>> citiesByProvince,
                           int otherCount, String defaultMode,
                           String defaultProvince, String defaultCity,
                           int qualityCeiling, int dropped4KStreams,
                           int hidden4KChannels, int kept4KFallbacks) {
        this.all = Collections.unmodifiableList(channels);
        this.visible = this.all;
        this.verifiedAt = verifiedAt;
        this.probeAt = probeAt;
        this.declaredChannelCount = declaredChannelCount;
        this.declaredStreamCount = declaredStreamCount;
        this.skipped = skipped;
        this.qualityCeiling = qualityCeiling;
        this.dropped4KStreams = dropped4KStreams;
        this.hidden4KChannels = hidden4KChannels;
        this.kept4KFallbacks = kept4KFallbacks;
        this.provinces = Collections.unmodifiableList(provinces);
        this.citiesByProvince = Collections.unmodifiableMap(citiesByProvince);
        this.otherCount = otherCount;
        this.defaultMode = defaultMode;
        this.defaultProvince = defaultProvince;
        this.defaultCity = defaultCity;
        this.regionMode = defaultMode;
        this.regionProvince = defaultProvince;
        this.regionCity = defaultCity;
        applyRegion();
    }

    /** 当前地区下可见的频道数。 */
    public int size() { return visible.size(); }

    public Channel get(int index) { return visible.get(index); }

    public int allCount() { return all.size(); }

    /** 遥控器数字选台：num 从 1 开始；当前地区不可见的台号找不到，返回 -1。 */
    public int indexOfNumber(int num) {
        if (num < 1) return -1;
        for (int i = 0; i < visible.size(); i++) {
            if (visible.get(i).num == num) return i;
        }
        return -1;
    }

    /** 台号提示用的最大值（清单是连续编号，但地区过滤后不是 1..size）。 */
    public int maxNumber() {
        int max = 0;
        for (int i = 0; i < visible.size(); i++) {
            if (visible.get(i).num > max) max = visible.get(i).num;
        }
        return max;
    }

    public int streamCount() {
        int n = 0;
        for (int i = 0; i < visible.size(); i++) n += visible.get(i).streams.size();
        return n;
    }

    public int reachableStreamCount() {
        int n = 0;
        for (int i = 0; i < visible.size(); i++) {
            for (int j = 0; j < visible.get(i).streams.size(); j++) {
                if (Boolean.TRUE.equals(visible.get(i).streams.get(j).probeOk)) n++;
            }
        }
        return n;
    }

    public int reachableChannelCount() {
        int n = 0;
        for (int i = 0; i < visible.size(); i++) {
            if (visible.get(i).reachable > 0) n++;
        }
        return n;
    }

    public String summary() {
        return visible.size() + " 台 / " + streamCount() + " 线路（全量清单 "
                + all.size() + " 台）"
                + (skipped > 0 ? "（跳过 " + skipped + " 条坏数据）" : "")
                + " · 地区 " + regionLabel()
                + " · 解码实测 " + verifiedAt
                + (probeAt == null || probeAt.length() == 0
                    ? " · 无台账"
                    : " · 台账 " + reachableChannelCount() + " 台/" + reachableStreamCount()
                      + " 线路可达")
                + (qualityCeiling > 0
                    ? " · 4K 输出已关闭（隐藏 " + hidden4KChannels + " 个 4K 台 / 剥离 "
                      + dropped4KStreams + " 条 2160 线路"
                      + (kept4KFallbacks > 0 ? "，保留 " + kept4KFallbacks + " 条兜底" : "") + "）"
                    : "");
    }

    /**
     * 按设置里的「优先清晰度」重排所有频道的线路**尝试顺序**。
     *
     * <p>只改顺序，不删线路、不改台号、不动清单数据；用稳定排序，同分线路
     * 仍保持生成器排好的「台账可达 &gt; 耗时 &gt; 解码实测 &gt; rank &gt; 明文」
     * 次序。自动档（0）先按实测起播耗时分档、同档内再按画质排：央视实测里
     * 2 秒才响应的跨境 1080P 源会排到 100~300ms 的官方源后面，换台更快、
     * 播放中也更少反复缓冲；想强制高清就在设置里选「1080P 优先」。
     */
    public void applyQualityPriority(int mode) {
        if (mode < 0 || mode > 3) mode = 0;
        final int pref = mode;
        for (int i = 0; i < all.size(); i++) {
            final Channel c = all.get(i);
            final List<Stream> sorted = new ArrayList<Stream>(c.streams);
            Collections.sort(sorted, new Comparator<Stream>() {
                @Override
                public int compare(Stream a, Stream b) {
                    final int ka = probeKey(a.probeOk);
                    final int kb = probeKey(b.probeOk);
                    if (ka != kb) return ka - kb;
                    // 自动档先按**实测起播耗时**分档：央视那批台里探测要 1.5~2.2 秒的
                    // 跨境 1080P 源原本被排在最前，100~300ms 的官方源反而沉到第 3 位，
                    // 「换台慢」和「播放中频繁缓冲」主要就是这么来的。
                    // 手动档（1080P / 720P / 标清优先）保持纯画质语义，不受影响。
                    if (pref == 0) {
                        final int sa = speedKey(a.probeMs);
                        final int sb = speedKey(b.probeMs);
                        if (sa != sb) return sa - sb;
                    }
                    final int qa = pref == 0 ? a.quality : score(a.quality, pref);
                    final int qb = pref == 0 ? b.quality : score(b.quality, pref);
                    if (qa != qb) return qb - qa;
                    return 0;   // 同分保持生成器原顺序（Collections.sort 稳定）
                }
            });
            c.setStreams(sorted);
        }
    }

    private static int probeKey(Boolean ok) {
        return Boolean.TRUE.equals(ok) ? 0 : (ok == null ? 1 : 2);
    }

    /** 兜底线路择优：先看台账可达，再看实测耗时，最后看标称清晰度。 */
    private static boolean betterFallback(Stream a, Stream b) {
        final int ka = probeKey(a.probeOk);
        final int kb = probeKey(b.probeOk);
        if (ka != kb) return ka < kb;
        final int ma = a.probeMs <= 0 ? Integer.MAX_VALUE : a.probeMs;
        final int mb = b.probeMs <= 0 ? Integer.MAX_VALUE : b.probeMs;
        if (ma != mb) return ma < mb;
        return a.quality > b.quality;
    }

    /**
     * 实测起播耗时分档：0 快（≤1.2 秒）/ 1 中（≤2.2 秒）/ 2 慢或未知。
     *
     * <p>1.2 秒是「官方 CDN 与跨境 IP 的分界」：本户台账里 kankanlive 那批
     * 官方源集中在 100~650ms，跨境 1080P 那批集中在 1.4~2.3 秒。阈值只影响
     * 自动档的先后顺序，不删任何线路，也不改台号。
     */
    private static int speedKey(int probeMs) {
        if (probeMs <= 0) return 2;
        if (probeMs <= 1200) return 0;
        if (probeMs <= 2200) return 1;
        return 2;
    }

    /** 越高越优先；未知画质（0）始终排最后，避免把没标清的线路挤到前面。 */
    private static int score(int quality, int mode) {
        if (mode == 1) {                 // 1080P 优先
            return quality >= 1080 ? 3 : (quality >= 720 ? 2 : (quality > 0 ? 1 : 0));
        }
        if (mode == 2) {                 // 720P 优先
            return quality >= 720 && quality < 1080 ? 3
                    : (quality >= 1080 ? 2 : (quality > 0 ? 1 : 0));
        }
        return quality > 0 && quality < 720 ? 3   // 标清优先
                : (quality >= 720 ? 2 : 0);
    }

    /** 标了清晰度的线路数；诊断页展示「高清源有多少」。 */
    public int qualityStreamCount() {
        int n = 0;
        for (int i = 0; i < all.size(); i++) {
            for (int j = 0; j < all.get(i).streams.size(); j++) {
                if (all.get(i).streams.get(j).quality > 0) n++;
            }
        }
        return n;
    }

    public int highDefinitionStreamCount() {
        int n = 0;
        for (int i = 0; i < all.size(); i++) {
            for (int j = 0; j < all.get(i).streams.size(); j++) {
                if (all.get(i).streams.get(j).quality >= 720) n++;
            }
        }
        return n;
    }

    public int extraStreamCount() {
        int n = 0;
        for (int i = 0; i < all.size(); i++) {
            for (int j = 0; j < all.get(i).streams.size(); j++) {
                if (all.get(i).streams.get(j).extra) n++;
            }
        }
        return n;
    }

    // ------------------------------------------------------------ 地区视图

    public String regionMode() { return regionMode; }
    public String regionProvince() { return regionProvince; }
    public String regionCity() { return regionCity; }
    public String defaultMode() { return defaultMode; }
    public String defaultProvince() { return defaultProvince; }
    public String defaultCity() { return defaultCity; }

    public String regionLabel() {
        if (MODE_PROVINCE.equals(regionMode)) return regionProvince + "全省";
        if (MODE_OTHER.equals(regionMode)) return OTHER_LABEL;
        return regionCity;
    }

    public List<RegionOption> provinceOptions() { return provinces; }

    public List<RegionOption> cityOptions(String province) {
        List<RegionOption> list = citiesByProvince.get(province);
        return list == null ? Collections.<RegionOption>emptyList() : list;
    }

    public int otherRegionCount() { return otherCount; }

    /** 当前地区下可见的「地方频道」台数（切换提示与面板状态用）。 */
    public int localCount() {
        int n = 0;
        for (int i = 0; i < visible.size(); i++) {
            if (LOCAL_GROUP.equals(visible.get(i).group)) n++;
        }
        return n;
    }

    /**
     * 切换地区并重算可见列表。传入空 / 未知 mode 时退回清单里的默认地区。
     * 调用方负责把 {@code channelIndex} 重新定位（旧下标可能已越界）。
     */
    public void setRegion(String mode, String province, String city) {
        if (mode == null || mode.length() == 0) mode = defaultMode;
        if (province == null) province = defaultProvince;
        if (city == null) city = defaultCity;
        regionMode = mode;
        regionProvince = province;
        regionCity = city;
        applyRegion();
    }

    private void applyRegion() {
        List<Channel> next = new ArrayList<Channel>();
        for (int i = 0; i < all.size(); i++) {
            if (visibleUnderRegion(all.get(i))) next.add(all.get(i));
        }
        // 极端情况（清单缺 regions 字段 / 选了一个没有台的地区）不能给空列表，
        // 否则用户连 CCTV-1 都看不到，会以为播放器坏了。
        visible = next.isEmpty() ? all : Collections.unmodifiableList(next);
    }

    private boolean visibleUnderRegion(Channel c) {
        if (!LOCAL_GROUP.equals(c.group)) return true;
        if (MODE_PROVINCE.equals(regionMode)) {
            return c.province.length() > 0 && c.province.equals(regionProvince);
        }
        if (MODE_OTHER.equals(regionMode)) {
            return c.province.length() == 0 && c.city.length() == 0;
        }
        // MODE_CITY：只显示本市台；省级台（无 city）不混进市级列表。
        return c.city.length() > 0 && c.city.equals(regionCity);
    }

    // ---------------------------------------------------------------- 载入

    public static ChannelCatalog load(Context context) throws IOException {
        return load(context, 0);
    }

    /**
     * 带清晰度上限载入：{@code maxQuality} 取 0 表示不限制，取
     * {@link DeviceCapability#QUALITY_1080} 表示「本机不做 4K 输出」。
     *
     * <p>封顶时做三件事，都在载入期一次算完：
     * <ol>
     *   <li>剥离 quality ≥ 2160 的线路；</li>
     *   <li>4K 专用台（is4K）连带「未知清晰度」线路一起剥，剥完为空就<b>整台隐藏</b>
     *       —— 留着只会是「点进去必然失败」的台，还会拖慢连续换台；</li>
     *   <li>普通台剥完为空时<b>保留一条最划算的 2160 线路兜底</b>：台账里
     *       玉林 / 乐山 / 武汉一台这几台的 quality 标着 2160、标签却写 1080P，
     *       属于生成器的误标，真实分辨率未必是 4K；宁可让老设备试一次，
     *       也不要把一个其实能播的台藏起来。</li>
     * </ol>
     */
    public static ChannelCatalog load(Context context, int maxQuality) throws IOException {
        String json = readAsset(context, ASSET);
        JSONObject root;
        try {
            root = new JSONObject(json);
        } catch (Exception e) {
            throw new IOException("频道清单不是合法 JSON: " + e.getMessage());
        }
        String verifiedAt = root.optString("verifiedAt", "未知");
        String probeAt = root.optString("probeAt", "");
        int declaredChannels = root.optInt("channelCount", 0);
        int declaredStreams = root.optInt("streamCount", 0);
        JSONArray arr = root.optJSONArray("channels");
        if (arr == null) throw new IOException("频道清单缺少 channels 数组");

        List<Channel> result = new ArrayList<Channel>();
        int skipped = 0;
        // 清晰度封顶只在「明确要求 1080」时生效；0 / 2160 都按不限处理。
        final boolean gate4K = maxQuality > 0 && maxQuality < DeviceCapability.QUALITY_4K;
        final int ceiling = gate4K ? maxQuality : 0;
        int dropped4KStreams = 0;
        int hidden4KChannels = 0;
        int kept4KFallbacks = 0;
        for (int i = 0; i < arr.length(); i++) {
            try {
                JSONObject c = arr.getJSONObject(i);
                JSONArray ss = c.getJSONArray("streams");
                List<Stream> streams = new ArrayList<Stream>();
                for (int j = 0; j < ss.length(); j++) {
                    try {
                        JSONObject s = ss.getJSONObject(j);
                        String url = s.getString("url").trim();
                        if (url.length() == 0) { skipped++; continue; }
                        Map<String, String> headers = new LinkedHashMap<String, String>();
                        JSONObject h = s.optJSONObject("headers");
                        if (h != null) {
                            Iterator<String> keys = h.keys();
                            while (keys.hasNext()) {
                                String key = keys.next();
                                headers.put(key, String.valueOf(h.opt(key)));
                            }
                        }
                        String resolver = s.optString("resolver", null);
                        Boolean probeOk = s.has("probeOk") ? Boolean.valueOf(s.optBoolean("probeOk")) : null;
                        int probeMs = s.optInt("probeMs", -1);
                        streams.add(new Stream(
                                url,
                                s.optString("label", "线路 " + (j + 1)),
                                s.optInt("rank", 0),
                                s.optBoolean("verified", false),
                                s.optBoolean("https", false),
                                s.optBoolean("mirror", false),
                                Collections.unmodifiableMap(headers),
                                resolver, probeOk, probeMs,
                                s.optInt("quality", 0),
                                s.optBoolean("extra", false)));
                    } catch (Exception badStream) {
                        skipped++;
                    }
                }
                if (gate4K) {
                    final boolean is4kChannel = c.optBoolean("is4K", false);
                    final List<Stream> kept = new ArrayList<Stream>(streams.size());
                    Stream fallback = null;
                    for (int k = 0; k < streams.size(); k++) {
                        final Stream s = streams.get(k);
                        // 4K 专用台上的「未知清晰度」线路也按 4K 处理：这类台的线路本就是
                        // 2160 源，只是生成器没标出来（北京卫视4K 就只有一条 quality=0）。
                        final boolean line4k = s.quality >= DeviceCapability.QUALITY_4K
                                || (is4kChannel && s.quality == 0);
                        if (!line4k) { kept.add(s); continue; }
                        dropped4KStreams++;
                        if (fallback == null || betterFallback(s, fallback)) fallback = s;
                    }
                    if (kept.isEmpty()) {
                        if (is4kChannel) { hidden4KChannels++; continue; }
                        // 普通台剥完为空：保留一条兜底，不藏台（见方法注释第 3 条）。
                        if (fallback != null) { kept.add(fallback); kept4KFallbacks++; }
                    }
                    streams = kept;
                }
                if (streams.isEmpty()) { skipped++; continue; }
                result.add(new Channel(
                        c.optInt("num", result.size() + 1),
                        c.optString("id", ""),
                        c.optString("name", "未命名"),
                        c.optString("group", ""),
                        c.optString("badge", ""),
                        c.optBoolean("is4K", false),
                        c.optString("province", ""),
                        c.optString("city", ""),
                        c.optString("pyi", ""),
                        c.optString("py", ""),
                        c.optInt("reachable", 0),
                        streams));
            } catch (Exception badChannel) {
                skipped++;
            }
        }
        if (result.isEmpty()) throw new IOException("频道清单解析后没有任何可播频道");

        // regions 由 gen_legacy_catalog.dart 生成：省 / 市选项 + 默认地区。
        // 缺字段时保守回退苏州，不让老清单把整个界面变成空列表。
        List<RegionOption> provinces = new ArrayList<RegionOption>();
        Map<String, List<RegionOption>> cities = new LinkedHashMap<String, List<RegionOption>>();
        int otherCount = 0;
        String defMode = MODE_CITY, defProvince = "江苏", defCity = "苏州";
        JSONObject regions = root.optJSONObject("regions");
        if (regions != null) {
            defMode = regions.optString("defaultMode", MODE_CITY);
            defProvince = regions.optString("defaultProvince", "江苏");
            defCity = regions.optString("defaultCity", "苏州");
            otherCount = regions.optInt("otherCount", 0);
            JSONArray ps = regions.optJSONArray("provinces");
            if (ps != null) {
                for (int i = 0; i < ps.length(); i++) {
                    JSONObject p = ps.optJSONObject(i);
                    if (p == null) continue;
                    provinces.add(new RegionOption(p.optString("name", ""), p.optInt("count", 0)));
                }
            }
            JSONObject cs = regions.optJSONObject("cities");
            if (cs != null) {
                Iterator<String> keys = cs.keys();
                while (keys.hasNext()) {
                    String key = keys.next();
                    JSONArray list = cs.optJSONArray(key);
                    if (list == null) continue;
                    List<RegionOption> options = new ArrayList<RegionOption>();
                    for (int i = 0; i < list.length(); i++) {
                        JSONObject o = list.optJSONObject(i);
                        if (o == null) continue;
                        options.add(new RegionOption(o.optString("name", ""), o.optInt("count", 0)));
                    }
                    cities.put(key, options);
                }
            }
        }
        return new ChannelCatalog(result, verifiedAt, probeAt, declaredChannels,
                declaredStreams, skipped, provinces, cities, otherCount,
                defMode, defProvince, defCity,
                ceiling, dropped4KStreams, hidden4KChannels, kept4KFallbacks);
    }

    private static String readAsset(Context context, String name) throws IOException {
        InputStream in = null;
        try {
            in = context.getAssets().open(name);
            ByteArrayOutputStream out = new ByteArrayOutputStream();
            byte[] buf = new byte[8192];
            int n;
            while ((n = in.read(buf)) > 0) out.write(buf, 0, n);
            return new String(out.toByteArray(), "UTF-8");
        } finally {
            if (in != null) {
                try { in.close(); } catch (IOException ignored) {}
            }
        }
    }
}
