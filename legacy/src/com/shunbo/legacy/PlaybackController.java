package com.shunbo.legacy;

import android.content.Context;
import android.net.Uri;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.view.SurfaceHolder;

import java.util.HashSet;
import java.util.Locale;
import java.util.Set;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.ThreadFactory;
import java.util.concurrent.atomic.AtomicInteger;

import tv.danmaku.ijk.media.player.IMediaPlayer;
import tv.danmaku.ijk.media.player.IjkMediaPlayer;

/**
 * 播放内核封装 + 换源决策（兼容分支的「唯一重试决策点」）。
 *
 * <p>内核用 ijkplayer 0.8.8 官方 Maven 制品（LGPL-2.1，仅 armeabi-v7a，
 * minSdk 9），而不是 Android 4.3 上 HLS 支持残缺的系统 MediaPlayer。
 *
 * <p><b>缓冲卡死的根因与修复（本轮）</b>：旧实现在主线程同步调用
 * {@code IjkMediaPlayer.stop/reset/release}。网络卡在缓冲时，native 读线程
 * 迟迟不退，{@code release()} 会 join 等它 → 主线程被卡住 → 遥控器按不动、
 * 换台没反应，看起来就是「缓冲时死机」。同时 ijkplayer 的 onInfo / onError
 * 来自 native 回调线程，旧实现在那里直接改 TextView（非 UI 线程操作 View）。
 *
 * <p>现在四条硬约束：
 * <ol>
 *   <li><b>释放不占主线程</b>：stop/reset/release 全部丢给单线程后台队列，
 *       主线程立刻返回，换台 / 换线 / 数字直达随时可抢占；</li>
 *   <li><b>回调只回主线程</b>：所有 onInfo / onError / onPrepared / onCompletion
 *       先 {@code handler.post}，再由主线程更新 UI；</li>
 *   <li><b>代际隔离</b>：每次起播递增 {@link #generation}，旧 player 迟到的
 *       回调一律丢弃，不会把「上一台的缓冲中」贴到新台上；</li>
 *   <li><b>缓冲可恢复</b>：首帧 12s 超时 + 首帧后缓冲 15s 看门狗 +
 *       FFmpeg 层 10s 网络超时，卡住就换下一条线路，而不是无限等。</li>
 * </ol>
 *
 * <p>换源规则与 Flutter 主程序 {@code source_failover.dart} 同思路：每次失败
 * 都从「当前台的候选线路列表」重新出发，不累积累计偏移；本轮已试失败的线路
 * 记入 {@link #attempted}，绕完一圈就明确报「全部线路不可用」。
 *
 * <p><b>HTTPS 只降级、不永久跳过（本轮修复）</b>：旧实现连续 3 条 https
 * 失败后把 {@code httpsUnavailable} 置位并永久跳过剩余加密线路。于是「只有
 * https 线路」的频道（真机反馈的苏州 7 台正是如此）会立刻得到
 * 「全部 1 条线路不可用」，而且手动 ←→ 换线也救不回来——因为被跳过的线路
 * 永远进不了候选集。现在改成两遍扫描：第一遍优先明文，第二遍仍把加密线路
 * 试完；{@link #retryAll()} 还能一键清空经验值从第一条重来。
 */
public final class PlaybackController {

    public interface Listener {
        /** 以下回调全部保证在主线程，界面可以安全地直接操作 View。 */
        void onState(String text);
        void onStreamChanged(int index, int total, ChannelCatalog.Stream stream);
        void onFirstFrame(long elapsedMs, ChannelCatalog.Stream stream);
        void onStreamFailed(int index, int what, String reason);
        /** reason 必须是可行动的诊断：TLS / 证书 / 已尝试条数 / 明文优先。 */
        void onAllStreamsFailed(ChannelCatalog.Channel channel, String reason);
        /**
         * 硬解在本机跑不起来，已自动切回软解（M4）。
         *
         * <p>界面负责把设置落盘成「软解」并提示用户——不落盘的话，下次启动还会
         * 先用硬解失败一次再回退，用户看到的就是「每次开机都要黑一下」。
         */
        void onDecodeFallback(String reason);
    }

    /** 默认 8 秒；设置页「首帧超时」可改成 8 / 12 / 18 秒。 */
    private static final long DEFAULT_FIRST_FRAME_TIMEOUT_MS = 8000L;
    /**
     * 快速失败：首帧迟迟不出时先跳到下一条候选，不要死等总超时。
     *
     * <p>只在**确实还有没试过的候选**时才挂（见 {@link #hasMoreCandidates(int)}）。
     * 上一版把「当前这条还没记进 attempted」误当成「还有候选」，于是单线路频道
     * （清单里 597 台）也会在 5 秒被杀、直接报「全部线路不可用」——这是上一版
     * 「换不了台」的直接原因。现在最后一条一律交给总超时。
     *
     * <p>6 秒而不是 5 秒：老盒子软解 + 跨境源的首帧经常落在 5～6 秒，5 秒会
     * 把「能出画但慢」的好线路误杀，反而更慢。
     */
    private static final long QUICK_FAIL_MS = 6000L;
    /**
     * 台账里整台一条可达线路都没有时，首帧只等这么久。
     *
     * <p>清单 1046 台里有 434 台（41%）没有任何 probeOk 线路；对这类台按正常
     * 8 秒去等，用户看到的就是「换台没反应」。压到 4 秒，失败提示也能早 4 秒出。
     */
    private static final long DEAD_CHANNEL_TIMEOUT_MS = 4000L;
    /**
     * 缓冲结束后的时钟再对齐：停顿超过这个时长才做，短抖动不做（避免
     * 频繁 seek 反而制造新的卡顿）。
     */
    private static final long BUFFER_ALIGN_MIN_STALL_MS = 1500L;
    /** 两次再对齐之间的最小间隔，避免缓冲抖动时连环 seek。 */
    private static final long BUFFER_ALIGN_COOLDOWN_MS = 8000L;
    /** 单条线路最多再对齐几次；超过就说明这条线路本身不稳，交给换线逻辑。 */
    private static final int BUFFER_ALIGN_LIMIT = 3;
    /** 首帧之后若连续缓冲超过 15 秒没恢复，判该线路 stalled，换下一条。 */
    private static final long BUFFER_WATCHDOG_MS = 15000L;
    /** 60 秒窗口内累计 3 次「缓冲中」就认定这条线路带宽不稳，主动换线。 */
    private static final int BUFFER_HIT_LIMIT = 3;
    private static final long BUFFER_WINDOW_MS = 60000L;
    /** FFmpeg AVFormatContext 的 IO 超时（微秒），避免 native 无限等网络。 */
    private static final long NETWORK_TIMEOUT_US = 10000000L;
    /** 连续 3 条 https 线路失败后，把加密线路降级为第二遍再试（不是丢弃）。 */
    private static final int HTTPS_FAILURE_STREAK_LIMIT = 3;
    /** 直播流反复 onCompletion 时不无限重连同一条线路。 */
    private static final int COMPLETION_RETRY_LIMIT = 3;

    // ---- 「缓冲中」提示去抖（M0 / E1）----
    /**
     * 缓冲开始后先等这么久再提示。
     *
     * <p>直播分片轮询与 TCP 抖动会制造 200～500 ms 的瞬时欠载，内核报
     * {@code BUFFERING_START} 但画面其实没停。旧实现一律弹「缓冲中…」，
     * 用户感受到的「老在缓冲」有一半来自这条提示本身，而不是真实卡顿。
     * 600 ms 是「真卡了会超过、假卡不会」的分界。
     */
    private static final long BUFFER_HINT_DELAY_MS = 600L;
    /** 提示一旦显示，至少停留这么久，避免闪一下就消失（比不显示更像故障）。 */
    private static final long BUFFER_HINT_MIN_SHOW_MS = 400L;

    /**
     * 后台释放队列（进程级单例、daemon 线程）。
     * 用单线程是为了不让多个 player 同时 stop/release 抢 native 全局状态；
     * 不 join、不等待，主线程永远不阻塞。
     */
    private static final ExecutorService RELEASE_EXECUTOR =
            Executors.newSingleThreadExecutor(new ThreadFactory() {
                @Override
                public Thread newThread(Runnable r) {
                    Thread t = new Thread(r, "shunbo-player-release");
                    t.setDaemon(true);
                    return t;
                }
            });

    private final Context context;
    private final SurfaceHolder holder;
    private final Listener listener;
    private final Handler handler = new Handler(Looper.getMainLooper());
    private final Set<Integer> attempted = new HashSet<Integer>();

    private IjkMediaPlayer player;
    private ChannelCatalog.Channel channel;
    private int streamIndex = 0;
    private long openedAtMs = 0L;
    private boolean firstFrameSeen = false;
    private boolean released = false;
    private boolean httpsUnavailable = false;
    private int httpsFailureStreak = 0;
    private int completionCount = 0;
    /** 每起播一条线路 +1；旧 player 的迟到回调据此作废。 */
    private int generation = 0;
    /**
     * 本次会话累计起播过多少条线路（含换台、换线、重试）。
     *
     * <p>刻意**不随 open() 重置**：14:42 真机反馈「起播正常、从别的频道切回来
     * 才音画不同步」，要判断是不是「换台次数越多越容易复现」，就必须有一个
     * 跨台的计数。诊断页「本次线路切换」每次换台会归零，回答不了这个问题。
     */
    private int sessionStarts;

    // ---- 换台释放时序读数（§41 嫌疑 A 的取证，纯读数，不改变释放策略）----
    /**
     * 后台仍在 stop/reset/release 的 player 数。单线程 executor，若换台比释放快
     * 就会堆积；>0 且持续不降，就是「运行期状态残留」最直接的证据。跨线程读写。
     */
    private final AtomicInteger releasePendingCount = new AtomicInteger(0);
    /** 新 player 绑定 Surface 时旧 player 尚未释放完的累计次数（跨台不清零）。 */
    private volatile int releaseOverlapCount = 0;
    /** 最近一次起播是否发生释放重叠，以及当时的待释放队列深度；0 = 那次没重叠。 */
    private volatile int lastOverlapDepth = 0;
    /** 最近一次后台释放耗时（ms）；-1 = 还没有释放完成过。 */
    private volatile long lastReleaseCostMs = -1L;
    /** 起播时观察到的最深待释放队列（跨台不清零）；0 = 从未重叠过。 */
    private volatile int maxOverlapDepth = 0;
    /** 真正发生过「等释放排空」的起播次数（跨台不清零）。 */
    private volatile int drainCount = 0;
    /** 等待超时、只好带着未释放的旧 player 继续起播的次数（跨台不清零）。 */
    private volatile int drainTimeoutCount = 0;
    /** 最近一次等释放排空的耗时（ms）；-1 = 还没等待过。 */
    private volatile long lastDrainCostMs = -1L;

    private long firstFrameTimeoutMs = DEFAULT_FIRST_FRAME_TIMEOUT_MS;
    /** 硬解开关：API 18 的 MediaCodec 行为不稳，默认软解。 */
    private boolean hardDecode = false;
    /**
     * 同步兼容模式：关掉本程序加的两个「同步保护」参数。
     *
     * <p>1.0.2 为了让老盒子稳，加了 {@code max-fps=30}（防 1080i 场率硬顶）和
     * {@code video-pictq-size=3}（防解码慢导致延迟累加）。这两项对多数台是好事，
     * 但对个别 1080P 源可能反而制造延迟——12:19 苏州台1套就是候选：
     * 时钟 1.000、不缓冲、丢帧 0.5%，唯独视频缓存比音频多 2.4 秒。
     *
     * <p>到底是不是这两项导致的，只能靠用户切换一次对比。所以做成开关，
     * 默认**关**（= 保持 1.0.2 的行为），不做任何默认行为变更。
     */
    private boolean compatSync = false;
    /** 诊断页：用户手动做过几次「音画立即对齐」（**跨起播累计**，仅进程重启归零）。 */
    private int reanchorCount = 0;
    /** 冷却用时刻：跨线路不清零，避免连按。 */
    private long lastReanchorAt = 0L;

    // ---- 手动对齐的 A/B 读数（只记数，不触发任何动作） ----
    /**
     * 上次按下「音画立即对齐」时探针**最近一次采样**的输出帧率（×100）。
     * -1 = 本线路没按过，或按下时读不到。
     *
     * <p>用于和「现在」的输出帧率并排显示，回答「frame_timer 落后能否被 seek
     * 重锚修好」。此前只记次数，用户按完 3 次仍无法从诊断页看出有没有效果，
     * 这是 14:42 那轮取证设计的缺口，本轮补上。探针 1 秒采样，所以这个值是
     * 「按下前 0~1 秒」的读数，不是严格瞬时值，文案里不许说成瞬时。
     */
    private int reanchorBeforeFpsCenti = -1;
    /** 本线路上次按下对齐的时刻（uptimeMillis）；0 = 本线路没按过。 */
    private long lastReanchorAtThisStream = 0L;
    /** 本线路按下次数；与 reanchorCount（累计）口径不同，诊断页要分开写。 */
    private int reanchorThisStream = 0;

    /**
     * **当前这条线路**实际用的解码方式（硬解 true / 软解 false）。
     *
     * <p>与 {@link #hardDecode} 的区别：后者是用户在设置里的意图，前者是这条线路
     * 真正跑起来的方案。真机上「有的台能硬解、有的台只能软解」，所以两者会不一致，
     * 诊断页必须分别显示。
     */
    private boolean currentUseHard = false;
    private Runnable timeoutTask;
    private Runnable bufferWatchdogTask;
    private Runnable quickFailTask;
    /** 起播静音兜底：首帧迟迟不到也要把声音放出来，否则会变成「有画无声」。 */
    private Runnable unmuteTask;
    private boolean mutedForStart = false;

    /**
     * 本轮频道的台账是否整台无一条可达线路。只影响首帧等待时长与提示，
     * 不影响「仍然去试」——台账是 PC 侧探测，可能滞后，不能当成判决书。
     */
    private boolean channelLikelyDead = false;
    /** 上次成功出画的耗时；诊断页用它对比「这一台为什么慢」。 */
    private long lastFirstFrameMs = -1L;
    /** 本次播放会话里换过多少次线路（含快速失败 / 错误 / 卡顿换线）。 */
    private int failoverCount = 0;

    // ---- 缓冲结束后的时钟再对齐（音画一致性） ----
    /** 本次 BUFFERING_START 的时刻；0 = 当前不在缓冲。 */
    private long bufferStartAt = 0L;
    /** 上次再对齐的时刻，用于冷却。 */
    private long lastAlignSeekAt = 0L;
    /** 当前线路已再对齐的次数。 */
    private int alignSeekCount = 0;
    /** 这个时刻之前的缓冲不计入「频繁卡顿」——seek 自己会引发一次 buffering。 */
    private long suppressBufferHitUntil = 0L;

    /**
     * 缓冲计数（滑动窗口）：播放中频繁「缓冲中」是线路带宽不足最可靠的信号，
     * 比等 15 秒看门狗更早、也比用户手动换线更及时。
     */
    private long bufferWindowStart = 0L;
    private int bufferHits = 0;

    // ---- 「缓冲中」提示去抖（E1）----
    private Runnable bufferHintTask;
    private long bufferHintShownAt = 0L;
    private boolean bufferHintVisible = false;

    /** 运行时质量探针（只读）。采样与判定分离：判定在本类，采样在探针。 */
    private final QualityProbe probe = new QualityProbe();

    // ---- M2 三闭环（A1 假高清降权 / B1 带宽塌陷 / D2 时钟偏快）----
    /**
     * 自动换线总开关，默认开（用户 2026-11-10 决定）。
     *
     * <p>关掉后行为等同 1.0.2：只保留「6 秒无首帧换线 / 15 秒缓冲看门狗 /
     * 60 秒 3 次卡顿换线」这三条结果层规则，探针只显示不决策。留这个开关
     * 是为了出问题时能一步退回已知行为，而不必回退整个安装包。
     */
    private boolean autoFailover = true;
    /**
     * 本次会话里被证实「实测宽度够不上标称」的线路 URL。
     *
     * <p>只降权、不拉黑：标注是源站写的，可能只是这一场低码率；真到没有别的
     * 线路可试时，它仍然必须能被播出来（{@link #findNext(boolean, boolean)} 第二遍）。
     */
    private final Set<String> fakeHdUrls = new HashSet<String>();
    private Runnable qualityWatchTask;
    /** 诊断页读数：被判假高清的线路条数。 */
    private int fakeHdCount = 0;
    /** 诊断页读数：因带宽塌陷换线次数。 */
    private int bandwidthSwitchCount = 0;
    /** 诊断页读数：因音频时钟偏快换线次数。 */
    private int syncSwitchCount = 0;
    private int bwCollapseSamples = 0;
    private long lastBwSwitchAt = 0L;
    private long lastSyncSwitchAt = 0L;
    private int syncFastWindows = 0;
    /** 上一次参与判读的时钟窗口序号，避免同一个 10 秒窗口被反复计入。 */
    private int lastSyncWindow = 0;

    // ---- M3（A2）：线路稳定度记忆 ----
    /**
     * 跨会话记忆：哪条线路上次出画最快、哪条连续硬失败。
     *
     * <p>它替代了计划里的 C1「次优线路预热」——在 ijkplayer 上预热连接无法被
     * 复用（见 {@link StreamMemory} 类注释），而「记住上次最快的那条、下次直接
     * 开它」用的是同一份收益、零额外连接、零额外内存。
     */
    private final StreamMemory memory;
    /**
     * 记忆排序开关：只有「优先清晰度＝自动」时才允许记忆决定先试哪条。
     *
     * <p>用户明确选了「1080P 优先」就说明画质优先于起播速度，这时候按记忆
     * 跳到一条更快的 576P 上，是对用户意图的直接违背。
     */
    private boolean adaptiveOrder = true;
    /** 本台这次的「记忆首选」下标；-1 表示按台账顺序。诊断页要显示。 */
    private int preferredStreamIndex = -1;
    /**
     * 用户是否按了暂停。
     *
     * <p>暂停时必须停掉质量巡检：暂停后吞吐为 0、播放位置不动，B1 会判「带宽塌陷」、
     * D3 会判「画面停滞」——两个都会把一条好线路换掉。这是巡检类功能最典型的误伤。
     */
    private boolean paused = false;
    /** 样本：停滞处置次数（换线或单线路重连）。 */
    private int stallActionCount = 0;
    private int stallWindows = 0;
    private long lastStallActionAt = 0L;
    /**
     * 本次会话里「已经因停滞重连过一次」的线路 URL。
     *
     * <p>不设这个上限，一条真的废掉但 TCP 仍可连的源会每 30 秒重连一次、无限循环，
     * 而用户看到的是画面反复重连——比停在那一帧更糟。重连一次仍停就交给用户
     * 换台 / 换线路，并在提示里说清楚该按什么键。
     */
    private final Set<String> stallGaveUp = new HashSet<String>();

    // ---- 音画同步探针（诊断页读数） ----
    /**
     * 采样窗口：太短会被 GC / 调度抖动带偏，10 秒是「能看出 1% 漂移」又
     * 「用户愿意等」的折中。
     */
    private static final long CLOCK_SAMPLE_MS = 10000L;
    /** 上一次采样的墙钟时刻；0 表示还没有基准点。 */
    private long clockSampleAt = 0L;
    /** 上一次采样的播放位置（ms）；-1 表示没有基准点。 */
    private long clockSamplePos = -1L;
    /** 最近一个窗口的 Δ位置/Δ墙钟，1.0 为正。 */
    private double clockRateValue = 0.0;
    /** 已经采到的窗口数：0 表示「采样中」，诊断页据此换文案。 */
    private int clockSampleCount = 0;

    public PlaybackController(Context context, SurfaceHolder holder, Listener listener) {
        this.context = context.getApplicationContext();
        this.holder = holder;
        this.listener = listener;
        this.memory = new StreamMemory(context);
    }

    /**
     * 必须在使用 IjkMediaPlayer 之前调用。
     *
     * <p>返回 null 表示成功；否则返回真实异常（UnsatisfiedLinkError /
     * VerifyError / ExceptionInInitializerError 等）的类名与消息，交给界面显示。
     * 绝不把异常抛到 Activity。
     */
    public static String loadNativeLibraries() {
        try {
            IjkMediaPlayer.loadLibrariesOnce(null);
            return null;
        } catch (Throwable t) {
            return t.getClass().getName() + ": " + safeMessage(t);
        }
    }

    public int currentStreamIndex() { return streamIndex; }

    /** 设置页接入：首帧超时限在 5–30 秒，避免误设成 0 导致一进台就换线。 */
    public void setFirstFrameTimeoutMs(long ms) {
        if (ms < 5000L) ms = 5000L;
        if (ms > 30000L) ms = 30000L;
        firstFrameTimeoutMs = ms;
    }

    /**
     * 解码方式切换，**即时生效**。
     *
     * <p>解码器是在 {@link #configure} 里选定的，只有重建 player 才能真的换过来，
     * 所以这里重开当前线路——用户改完设置画面会闪一下，但不用自己去换台。
     *
     * <p>切回「硬解」时清空所有硬解失败记录：这是一次明确的重试意图，
     * 不该被几周前的旧结论挡住。
     */
    public void setHardDecode(boolean on) {
        if (hardDecode == on) return;
        hardDecode = on;
        if (on) memory.clearHardDecodeFlags();
        if (!released && player != null && channel != null) {
            listener.onState(on ? "已切换硬解，重建解码器…" : "已切换软解，重建解码器…");
            retryCurrentStream();
        }
    }

    /**
     * 同步兼容模式开关，**即时生效**（重建当前线路）。
     *
     * <p>关掉 max-fps 与 video-pictq-size，把同步交回内核自己调度。
     */
    public void setCompatSync(boolean on) {
        if (compatSync == on) return;
        compatSync = on;
        if (!released && player != null && channel != null) {
            listener.onState(on ? "已开同步兼容模式，重建…" : "已关同步兼容模式，重建…");
            retryCurrentStream();
        }
    }

    public boolean compatSyncEnabled() { return compatSync; }

    /** 诊断页读数：用户手动对齐过几次（跨起播累计）。 */
    public int reanchorCount() { return reanchorCount; }

    /** 诊断页：本线路上次按下对齐时的输出帧率（×100）；没按过/读不到返回 -1。 */
    public int reanchorBeforeFpsCenti() { return reanchorBeforeFpsCenti; }

    /** 诊断页：本线路手动对齐次数（与累计口径分开）。 */
    public int reanchorThisStreamCount() { return reanchorThisStream; }

    /** 诊断页：距本线路上次对齐过了多少秒；本线路没按过返回 -1。 */
    public long reanchorSinceSeconds() {
        if (lastReanchorAtThisStream <= 0L) return -1L;
        return (SystemClock.uptimeMillis() - lastReanchorAtThisStream) / 1000L;
    }

    /**
     * 手动「音画立即对齐」：按当前播放位置 seek 一次，让内核把 frame_timer 重锚到音频时钟。
     *
     * <p>这就是 1.0.2 里「长缓冲后再对齐」用的同一招，只是触发权交给用户——
     * 因为「视频缓存 − 音频缓存」这个量在两份真机读数里给出了相反结论，
     * 拿它自动触发会在好画面上瞎 seek。
     *
     * @return 失败原因文案；null 表示已经执行
     */
    public String reanchorNow() {
        if (released || player == null || !firstFrameSeen) return "还没出画，无法对齐";
        final long now = SystemClock.uptimeMillis();
        if (lastReanchorAt != 0L && now - lastReanchorAt < Tuning.REANCHOR_COOLDOWN_MS) {
            return "刚对齐过，请稍等";
        }
        try {
            final long pos = player.getCurrentPosition();
            if (pos <= 0L) return "当前位置无效，无法对齐";
            lastReanchorAt = now;
            reanchorCount++;
            // A/B 取证：记下按下时探针最近一次采样的输出帧率，诊断页拿它和
            // 几秒后的读数对比。纯读数，不改变这次 seek 的任何行为。
            reanchorThisStream++;
            lastReanchorAtThisStream = now;
            reanchorBeforeFpsCenti = probe == null ? -1 : probe.outputFpsCenti();
            // 这次 seek 自己会引发一次 buffering，不能算进「频繁卡顿」。
            suppressBufferHitUntil = now + 3000L;
            player.seekTo(pos);
            return null;
        } catch (Throwable t) {
            return "本线路不支持跳转（" + safeMessage(t) + "）";
        }
    }

    /** 诊断页：**当前这条线路**实际用的是不是硬解（可能因该线路不适配而退成软解）。 */
    public boolean usingHardDecode() { return currentUseHard; }

    /** 设置里选的是不是硬解（用户意图，与实际使用可能不同）。 */
    public boolean hardDecodePreferred() { return hardDecode; }

    /** 诊断页：有多少条线路被记为「硬解不适配」。 */
    public int hardUnfitCount() { return memory.hardUnfitCount(); }

    /**
     * 硬解跑不起来时的一次性回退（**按线路**，不按整机）。
     *
     * <p><b>真机教训</b>：上一版把回退做成全局、并且把设置也改成软解，于是
     * 「一个台硬解失败」会让后面所有能硬解的台也跟着跑软解，重启后依然是软解。
     * 用户实测「有的台可以硬解、有的台只能软解」，说明粒度必须落到线路。
     *
     * <p>注意这里**不换线路**：一条线路播不出来，可能是源的问题，也可能是这台
     * 机器的解码器的问题。硬解失败时先假定是后者的错，用软解把同一条线路再试一次，
     * 免得「解码器不支持 → 把一条能播的线路白白换掉」。
     *
     * @return true 表示刚刚完成回退（调用方应重开当前线路并 return）
     */
    private boolean fallbackToSoftDecode(String reason, ChannelCatalog.Stream s) {
        if (!currentUseHard || s == null) return false;
        currentUseHard = false;
        // 只记这一条线路：别的台该用硬解还继续用。
        memory.noteHardDecodeFail(s.url);
        listener.onDecodeFallback(reason);
        return true;
    }

    /** true = 本机 HTTPS 曾连续失败，当前只作为「明文优先」的排序提示。 */
    public boolean isHttpsSkipped() { return httpsUnavailable; }

    /**
     * 切换频道：清空本轮失败记录，从「记忆里的最快线路」开始。
     *
     * <p>记忆只在「自动换线 + 优先清晰度＝自动」同时成立时才参与选线；
     * 否则老老实实从第 1 条开始（= 1.0.2 行为）。注意这里只改「先试哪一条」，
     * 频道表顺序、UI 里的线路序号、用户手动 ←→ 选线都不受影响。
     */
    public void open(ChannelCatalog.Channel channel) {
        open(channel, preferredIndex(channel));
    }

    /** 记忆首选下标；-1 / 0 都表示「按台账顺序」。 */
    private int preferredIndex(ChannelCatalog.Channel channel) {
        preferredStreamIndex = -1;
        if (channel == null || channel.streams.size() <= 1) return 0;
        if (!autoFailover || !adaptiveOrder) return 0;
        final ChannelCatalog.Stream first = channel.streams.get(0);
        final int currentMs = first == null ? -1 : memory.firstFrameMs(first.url);
        // 画质地板取「台账首条」的标称清晰度：记忆可以跳到更快的同级线路，
        // 但不许跳到更低一档——那是拿清晰度换速度，得由用户自己选。
        final int floor = first == null ? 0 : first.quality;
        final int idx = memory.bestIndex(channel.streams, floor, currentMs);
        if (idx <= 0) return 0;
        preferredStreamIndex = idx;
        return idx;
    }

    /** 手动换线路时从指定序号开始，仍保留本轮 attempted 以免绕圈。 */
    public void open(ChannelCatalog.Channel channel, int startIndex) {
        if (released) return;
        this.channel = channel;
        this.streamIndex = Math.max(0, Math.min(startIndex, channel.streams.size() - 1));
        attempted.clear();
        httpsFailureStreak = 0;
        // 换台即重置「停滞已重连」记录：上一台那条线的结论不适用于新台。
        stallGaveUp.clear();
        stallWindows = 0;
        // 换台时把上一台所有待执行的回调（快速失败 / 总超时 / 看门狗 / 延迟
        // openNext）全部作废：否则旧回调会在新台刚起播时插进来，把新 player
        // 释放掉重开一遍——用户看到的就是「换了台又黑屏、反复连接」。
        invalidatePending();
        channelLikelyDead = !channel.hasReachableStream();
        failoverCount = 0;
        // httpsUnavailable 只是「明文优先」的排序提示，不再是丢弃开关：
        // openNext() 第二遍仍会把加密线路试完，因此换台不会误判全死。
        if (!openNext()) {
            listener.onAllStreamsFailed(channel, failureReason());
        }
    }

    /** 手动切到第 index 条线路（左右键）：点名的线路必须真的去试。 */
    public void switchTo(int index) {
        if (channel == null || released) return;
        if (index < 0 || index >= channel.streams.size()) return;
        streamIndex = index;
        attempted.clear();
        // 用户明确指定了一条 https 线路时，不能被进程的 TLS 经验值挡掉。
        httpsUnavailable = false;
        httpsFailureStreak = 0;
        if (!openNext()) listener.onAllStreamsFailed(channel, failureReason());
    }

    public void retryCurrentStream() {
        if (channel == null || released) return;
        attempted.clear();
        if (!openNext()) listener.onAllStreamsFailed(channel, failureReason());
    }

    /**
     * 异常态一键恢复：清空本轮记录与 TLS 经验值，从第一条线路重来。
     * 遥控器 OK（播放态且已报「全部线路不可用」）与控制条「重试」共用此入口。
     */
    public void retryAll() {
        if (channel == null || released) return;
        attempted.clear();
        httpsUnavailable = false;
        httpsFailureStreak = 0;
        streamIndex = 0;
        listener.onState("正在重试全部线路…");
        if (!openNext()) listener.onAllStreamsFailed(channel, failureReason());
    }

    /** 全失败时给用户的可行动说明，绝不只说一句「不可用」。 */
    private String failureReason() {
        final int total = channel == null ? 0 : channel.streams.size();
        int plain = 0;
        int encrypted = 0;
        if (channel != null) {
            for (ChannelCatalog.Stream s : channel.streams) {
                if (s.https) encrypted++; else plain++;
            }
        }
        if (httpsUnavailable && plain > 0) {
            return "本机 HTTPS 连续失败（TLS / 证书链），已优先尝试 "
                    + plain + " 条明文线路，共 " + total + " 条均未出画";
        }
        if (httpsUnavailable) {
            return "本机 HTTPS 连续失败（TLS / 证书链），本台 "
                    + encrypted + " 条线路均为加密源";
        }
        return "已逐条尝试 " + total + " 条线路（明文 "
                + plain + " / 加密 " + encrypted + "）";
    }

    /** 遥控器播放/暂停键；返回 true 表示当前处于暂停态。 */
    public boolean togglePause() {
        if (released || player == null) return false;
        try {
            if (player.isPlaying()) {
                player.pause();
                paused = true;
                // 暂停期间不巡检：吞吐归零会被误判成「带宽塌陷」或「画面停滞」。
                cancelQualityWatch();
                bwCollapseSamples = 0;
                stallWindows = 0;
                return true;
            }
            player.start();
            paused = false;
            scheduleQualityWatch(generation, streamIndex, currentStream());
            return false;
        } catch (Throwable t) {
            return false;
        }
    }

    /**
     * 播放位置增速比 = Δ播放位置 / Δ墙钟（最近一个 ≥10 秒窗口）。
     *
     * <p>ijkplayer 以音频为 master，所以这里的「播放位置」就是音频时钟。判读：
     * <ul>
     *   <li>1.000 ± 0.01：音频按真实时间推进，偏差只可能出在视频侧；</li>
     *   <li>&gt; 1.01：音频真的在快播（采样率 / 时钟错配），与解码无关；</li>
     *   <li>&lt; 0.99：位置推进被缓冲拖住，属于网络侧。</li>
     * </ul>
     * 返回 0 表示样本还不够，诊断页显示「采样中」。暂停期间不刷新，
     * 直接回上次的值——否则一暂停读数就变成 0，反而误导。
     */
    public double clockRate() {
        final IMediaPlayer p = player;
        if (p == null || !firstFrameSeen || released) return 0.0;
        try {
            if (!p.isPlaying()) return clockRateValue;
            final long now = SystemClock.uptimeMillis();
            final long pos = p.getCurrentPosition();
            if (pos < 0L) return clockRateValue;
            if (clockSamplePos < 0L || clockSampleAt <= 0L) {
                clockSampleAt = now;
                clockSamplePos = pos;
                return 0.0;
            }
            final long dt = now - clockSampleAt;
            if (dt < CLOCK_SAMPLE_MS) return clockRateValue;
            final long dp = pos - clockSamplePos;
            clockSampleAt = now;
            clockSamplePos = pos;
            // 直播切分片时 pts 可能回退，这一窗直接丢弃，不算进读数。
            if (dp < 0L) return clockRateValue;
            clockRateValue = dp / (double) dt;
            clockSampleCount++;
        } catch (Throwable ignored) {
            // 内核在 reset 附近读位置会抛 IllegalStateException，按本窗无样本处理。
        }
        return clockRateValue;
    }

    /** 已采到几个 10 秒窗口；0 表示仍在采样。 */
    public int clockSampleCount() {
        return clockSampleCount;
    }

    /** 换线路 / 重新起播时清空探针基准，避免跨线路算出一个假比值。 */
    private void resetClockProbe() {
        clockSampleAt = 0L;
        clockSamplePos = -1L;
        clockRateValue = 0.0;
        clockSampleCount = 0;
        // 窗口序号也要归零：否则新线路的第一个窗口会被当成「旧窗口」跳过。
        lastSyncWindow = 0;
        syncFastWindows = 0;
    }

    /**
     * 两遍扫描找下一条可试线路。第一遍在 TLS 已被证实不稳时优先明文，
     * 第二遍**无条件**把加密线路也纳入候选——这是「不永久跳过 HTTPS」的
     * 关键。第二遍不会重复第一遍已试失败的线路（attempted 已经记下）。
     */
    private boolean openNext() {
        if (channel == null || released) return false;
        if (findNext(httpsUnavailable)) return true;
        // 只有降级态才需要第二遍；正常态第一遍已经覆盖全部线路。
        return httpsUnavailable && findNext(false);
    }

    private boolean findNext(boolean skipHttps) {
        // A1（假高清）+ A2（连续硬失败）降权：第一遍跳过被降权的线路，
        // 第二遍无条件收回。只在自动换线打开时生效——关掉就是 1.0.2 的选线顺序。
        if (autoFailover && !fakeHdUrls.isEmpty() && findNext(skipHttps, true)) {
            return true;
        }
        return findNext(skipHttps, autoFailover);
    }

    private boolean findNext(boolean skipHttps, boolean skipDemoted) {
        final int total = channel.streams.size();
        for (int step = 0; step < total; step++) {
            int idx = (streamIndex + step) % total;
            if (attempted.contains(Integer.valueOf(idx))) continue;
            ChannelCatalog.Stream s = channel.streams.get(idx);
            // 带 resolver 的线路需要在线 302 换 token，兼容分支未实现该链路，
            // 直接跳过比播一个必然过期的地址更诚实。
            if (s.resolver != null && s.resolver.length() > 0) {
                attempted.add(Integer.valueOf(idx));
                continue;
            }
            // 降权只 skip、不写 attempted——第二遍还要把它们捡回来。
            if (skipDemoted && (fakeHdUrls.contains(s.url) || memory.isDemoted(s.url))) {
                continue;
            }
            // 注意：这里只 skip，不写 attempted——第二遍还要把它们捡回来。
            if (skipHttps && s.https) continue;
            streamIndex = idx;
            return startStream(idx, s, total);
        }
        return false;
    }

    private boolean startStream(final int idx, final ChannelCatalog.Stream s,
                                final int total) {
        // 后台释放旧 player，立即返回；换台不会被上一台的缓冲拖住。
        releaseCurrentPlayer();
        // 16:48 真机 31.jpg：重叠 83/86 次（96.5%）、最深队列 3 个、单次释放
        // 仅 62 ms。既然释放不慢、也不会长期堆积，就在绑新 holder 之前有上限地
        // 等它排空，让后续每次换台都接近「进程第一次起播」的干净态（§41 正常页
        // 25.00/25.00）。超时照常继续，绝不阻塞换台；详细依据见 Tuning。
        awaitReleaseDrain();
        // 会话级计数：只在真正起播一条线路时累加，换台不清零。
        sessionStarts++;
        // 探针基准必须随线路重建，否则会把上一台的位置差算进这一台。
        resetClockProbe();
        // 缓冲计数按线路重置：上一台的抖动不能算到这一台头上。
        resetBufferProbe();
        alignSeekCount = 0;
        lastAlignSeekAt = 0L;
        // 对齐 A/B 是**本线路**读数：换台后不能把上一条线路的按前值/次数带过来。
        reanchorThisStream = 0;
        lastReanchorAtThisStream = 0L;
        reanchorBeforeFpsCenti = -1;
        bufferStartAt = 0L;
        suppressBufferHitUntil = 0L;
        bwCollapseSamples = 0;
        stallWindows = 0;
        paused = false;
        final int gen = generation;
        listener.onStreamChanged(idx, total, s);
        listener.onState("正在连接 " + (idx + 1) + "/" + total + " · " + s.label);
        firstFrameSeen = false;
        completionCount = 0;
        openedAtMs = SystemClock.uptimeMillis();

        try {
            final IjkMediaPlayer p = new IjkMediaPlayer();
            player = p;
            // 逐线路决定解码方式：设置要硬解 **且** 这条线路没被记为「硬解不适配」。
            // 后者来自真机（有的台能硬解、有的台只能软解），记录在 StreamMemory 里。
            currentUseHard = hardDecode && !memory.hardDecodeUnfit(s.url);
            configure(p);
            // 探针挂在 player 之后：它只读属性，不参与起播，失败也不影响播放。
            probe.start(p, s);
            p.setOnErrorListener(new IMediaPlayer.OnErrorListener() {
                @Override
                public boolean onError(final IMediaPlayer mp, final int what,
                                       final int extra) {
                    if (!isCurrent(gen, mp)) return true;
                    postToUi(new Runnable() {
                        @Override public void run() {
                            if (!isCurrent(gen, mp)) return;
                            // 硬解报错时先假定是解码器的问题：用软解把**同一条线路**
                            // 再试一次，别把一条能播的线路当成坏线路换掉。
                            if (fallbackToSoftDecode("解码错误 " + what + "/" + extra, s)) {
                                retryCurrentStream();
                                return;
                            }
                            failCurrent(idx, s, what, "播放错误 " + what + "/" + extra);
                        }
                    });
                    return true;
                }
            });
            p.setOnPreparedListener(new IMediaPlayer.OnPreparedListener() {
                @Override
                public void onPrepared(final IMediaPlayer mp) {
                    if (!isCurrent(gen, mp)) return;
                    postToUi(new Runnable() {
                        @Override public void run() {
                            if (!isCurrent(gen, mp)) return;
                            try { mp.start(); } catch (IllegalStateException ignored) {}
                            // 兜底：1.2 秒还没收到首帧也要把声音放出来。有的流
                            // 不报 VIDEO_RENDERING_START，只靠首帧解锁会变成
                            // 「有画无声」——那比一开始就出声更糟。
                            scheduleUnmuteFallback(gen, mp, 1200L);
                        }
                    });
                }
            });
            p.setOnInfoListener(new IMediaPlayer.OnInfoListener() {
                @Override
                public boolean onInfo(final IMediaPlayer mp, final int what,
                                      final int extra) {
                    if (!isCurrent(gen, mp)) return true;
                    if (what == IMediaPlayer.MEDIA_INFO_VIDEO_RENDERING_START) {
                        postToUi(new Runnable() {
                            @Override public void run() { onFirstFrame(gen, mp, idx, s); }
                        });
                    } else if (what == IMediaPlayer.MEDIA_INFO_BUFFERING_START) {
                        postToUi(new Runnable() {
                            @Override public void run() {
                                if (!isCurrent(gen, mp)) return;
                                onBufferingStart(gen, idx, s);
                            }
                        });
                    } else if (what == IMediaPlayer.MEDIA_INFO_BUFFERING_END) {
                        postToUi(new Runnable() {
                            @Override public void run() {
                                if (!isCurrent(gen, mp)) return;
                                onBufferingEnd(mp);
                            }
                        });
                    }
                    return true;
                }
            });
            p.setOnCompletionListener(new IMediaPlayer.OnCompletionListener() {
                @Override
                public void onCompletion(final IMediaPlayer mp) {
                    if (!isCurrent(gen, mp)) return;
                    // 直播流异常结束：重连当前线路，不换台、不跳到下一条；
                    // 但反复结束说明这条线路已经废了，交给换源逻辑换线。
                    postToUi(new Runnable() {
                        @Override public void run() {
                            if (!isCurrent(gen, mp)) return;
                            completionCount++;
                            if (completionCount > COMPLETION_RETRY_LIMIT) {
                                failCurrent(idx, s, -4, "直播流反复结束");
                            } else {
                                retryCurrentStream();
                            }
                        }
                    });
                }
            });

            // 换台释放时序取证：主线程在这里把新 player 绑到**同一个 holder**。
            // 前面已经 awaitReleaseDrain() 过，正常情况这里应当是 0；若仍 >0
            // 说明等待超时（或恰好有并发提交），如实记一次「重叠」+ 队列深度。
            // 这个数不再增长，就证明新旧 player 的交接窗口已被消掉。
            final int pendingBeforeBind = releasePendingCount.get();
            p.setDisplay(holder);
            if (pendingBeforeBind > 0) {
                releaseOverlapCount++;
                lastOverlapDepth = pendingBeforeBind;
                if (pendingBeforeBind > maxOverlapDepth) maxOverlapDepth = pendingBeforeBind;
            } else {
                lastOverlapDepth = 0;
            }
            if (s.headers.isEmpty()) {
                p.setDataSource(context, Uri.parse(s.url));
            } else {
                p.setDataSource(context, Uri.parse(s.url), s.headers);
            }
            // 起播先静音：换台时音频往往比首帧早到几百毫秒，先出声后出画
            // 在观感上就是「音画不同步」。首帧（或 1.2 秒兜底）再放开。
            muteForStart(p);
            p.prepareAsync();

            cancelTimeout();
            // 整台台账无一条可达时只等 4 秒：这类台在清单里有 434 个，
            // 按 8 秒等就是「换台没反应」。
            final long waitMs = channelLikelyDead
                    ? Math.min(firstFrameTimeoutMs, DEAD_CHANNEL_TIMEOUT_MS)
                    : firstFrameTimeoutMs;
            timeoutTask = new Runnable() {
                @Override public void run() {
                    if (!firstFrameSeen && !released && gen == generation) {
                        // 硬解在 API 18 上「连得上但不出画」是最常见的失败形态：
                        // 先回退软解重开同一条，再谈换线路。
                        if (fallbackToSoftDecode("硬解首帧超时", s)) {
                            retryCurrentStream();
                            return;
                        }
                        failCurrent(idx, s, -1,
                                "首帧超时（" + (waitMs / 1000L) + " 秒）"
                                        + (channelLikelyDead ? "，该台台账无可用线路" : ""));
                    }
                }
            };
            handler.postDelayed(timeoutTask, waitMs);
            // 还有**别的**候选线路时，6 秒不出画就先跳下一条；只剩这一条就
            // 老实等总超时，免得把唯一可能出画的线路提前杀掉。
            scheduleQuickFail(gen, idx, s);
            return true;
        } catch (Throwable t) {
            // setDataSource / prepareAsync 抛异常也按「该线路不可用」处理，
            // 不把异常抛到 Activity 导致整机闪退。
            failCurrent(idx, s, -2, "起播失败：" + safeMessage(t));
            return true;
        }
    }

    private void configure(IjkMediaPlayer p) {
        // API 18 的 MediaCodec / OpenSL ES 行为不稳，默认一律 FFmpeg 软解 +
        // AudioTrack；「解码方式」设置打开后才会尝试硬解（老机型仍建议软解）。
        // 用 currentUseHard 而不是 hardDecode：这条线路若被记为「硬解不适配」，
        // 即便设置里选的是硬解，这里也必须直接上软解，不能每次都先撞一次。
        p.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "mediacodec",
                currentUseHard ? 1 : 0);
        p.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "mediacodec-auto-rotate", 0);
        p.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "opensles", 0);
        p.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "framedrop", 1);
        // ---- 音画同步三项 ----
        // 此前 12 个参数里与时钟相关的为 0：起播相位不对齐、视频队列无上限、
        // 高场率源没保护，于是「视频按相对时间累加推进 + 音频主时钟不回头」
        // 会把每帧的唤醒误差一路攒下去（25fps 每帧晚 1ms ≈ 每分钟 1.5 秒）。
        // 这三项都在本包 libijkplayer.so 里核实过名称，内核不接受时静默回落。
        //
        // sync-av-start：让音频首采样与视频首帧按同一基准起算，消掉起播固定偏差。
        // 真机若出现「起播变慢 / 首帧迟迟不出」，把这一项改回 0 即可单独回退。
        p.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "sync-av-start", 1);
        if (!compatSync) {
            // max-fps：限制喂给渲染的帧率上限，避免把 1080i 的场率当帧率硬顶。
            p.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "max-fps", 30);
            // video-pictq-size：视频帧队列上限，掐断「解码慢 → 队列积压 → 延迟越攒越多」。
            p.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "video-pictq-size", 3);
        }
        // 兼容模式：以上两项都不设，回到 ijk 的默认值（交给内核自己调度）。
        // ---- 计划里的 B2「丢帧 >5% 则 skip_loop_filter=nonref」不做 ----
        // M1 真机实测：1080P 软解丢帧率 0.5%、近 20 秒增量 +0.0 个百分点。
        // 也就是说这台机器的解码不是瓶颈，「给解码让路」要解决的问题不存在；
        // 为此引入一个需要在 CODEC 类别透传、且无法在运行中验证的 FFmpeg 选项，
        // 只会多一条不可控的变量。等真出现丢帧再回来开，判据留在诊断页。
        // 保留 packet-buffering=1（直播靠内核缓冲抗抖动）。缓冲卡死不靠关掉
        // 缓冲来「绕过」——那会引入音画不同步；靠下面的 IO 超时 + 看门狗换线。
        p.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "packet-buffering", 1);
        p.setOption(IjkMediaPlayer.OPT_CATEGORY_FORMAT, "http-detect-range-support", 0);
        p.setOption(IjkMediaPlayer.OPT_CATEGORY_FORMAT, "reconnect", 1);
        // 关键：网络读挂死时让 FFmpeg 自己超时报错，而不是让 native 线程
        // 永远停在 recv()，进而把 release() 的 join 也一起拖死。
        p.setOption(IjkMediaPlayer.OPT_CATEGORY_FORMAT, "timeout", NETWORK_TIMEOUT_US);
        // 起播阶段只读 1.5 秒 / 1 MB 就够识别 HLS 里的 H.264 / HEVC。
        // 上一轮曾压到 1 秒 / 512 KB，那不是换台耗时的主要来源（真正的开销在
        // 建连 + 拉播放列表 + 首个分片），反而会让部分高码率 / HEVC 源
        // 「识别不出编码 → prepared 失败」，表现就是换台后一直黑屏。
        // 这里回到稳妥值，换台速度交给「快速失败 + 跳过无可用线路的台」。
        p.setOption(IjkMediaPlayer.OPT_CATEGORY_FORMAT, "analyzeduration", 1500000L);
        p.setOption(IjkMediaPlayer.OPT_CATEGORY_FORMAT, "probesize", 1024000L);
        p.setOption(IjkMediaPlayer.OPT_CATEGORY_FORMAT, "fflags", "fastseek");
        p.setScreenOnWhilePlaying(true);
    }

    /**
     * 起播静音：只影响音量，不动解码。
     *
     * <p>换台时音频轨往往比首个视频帧早到 200～600 ms，先出声后出画在观感上
     * 就是「音画不同步」。官方播放器普遍也是「出画即出声」。
     */
    private void muteForStart(IjkMediaPlayer p) {
        mutedForStart = true;
        cancelUnmute();
        try { p.setVolume(0f, 0f); } catch (Throwable ignored) {}
    }

    private void unmute(IMediaPlayer p) {
        if (!mutedForStart) return;
        mutedForStart = false;
        cancelUnmute();
        try { p.setVolume(1f, 1f); } catch (Throwable ignored) {}
    }

    /** 首帧没来时也要出声：1.2 秒兜底，避免「有画无声」。 */
    private void scheduleUnmuteFallback(final int gen, final IMediaPlayer mp,
                                        long delayMs) {
        cancelUnmute();
        unmuteTask = new Runnable() {
            @Override public void run() {
                unmuteTask = null;
                if (!isCurrent(gen, mp)) return;
                unmute(mp);
            }
        };
        handler.postDelayed(unmuteTask, delayMs);
    }

    private void cancelUnmute() {
        if (unmuteTask != null) {
            handler.removeCallbacks(unmuteTask);
            unmuteTask = null;
        }
    }

    private void onFirstFrame(int gen, IMediaPlayer mp, int idx,
                              ChannelCatalog.Stream s) {
        if (firstFrameSeen || !isCurrent(gen, mp)) return;
        firstFrameSeen = true;
        cancelTimeout();
        cancelQuickFail();
        cancelBufferWatchdog();
        // 首帧已到：任何「缓冲中」提示都必须立刻作废，否则它会在出画之后
        // 才被延迟任务贴上来（用户看到的就是「画面有了但还在缓冲」）。
        resetBufferHint();
        // 出画即出声：静音只覆盖「连接 → 首帧」这一段，之后音量恢复正常。
        unmute(mp);
        httpsFailureStreak = 0;
        bufferStartAt = 0L;
        lastFirstFrameMs = SystemClock.uptimeMillis() - openedAtMs;
        // A2：记下这条线路的首帧耗时，下次进这台直接开它（取两次较小值）。
        memory.noteSuccess(s.url, lastFirstFrameMs);
        listener.onFirstFrame(lastFirstFrameMs, s);
        listener.onState("");
        // 出画之后才开质量巡检：起播阶段的缓存 / 码率都在爬升，此时判读
        // 只会把好线路误判成假高清或带宽塌陷。
        scheduleQualityWatch(gen, idx, s);
    }

    /**
     * 质量巡检：每 {@link Tuning#QUALITY_WATCH_MS} 看一次环形缓冲，跑三个闭环。
     *
     * <p>只在前台出画后运行；暂停、换线、释放都会停掉。巡检本身不读网络、
     * 不阻塞，读的是探针已经采好的样本，所以不会因为「诊断拖慢播放」。
     */
    private void scheduleQualityWatch(final int gen, final int idx,
                                      final ChannelCatalog.Stream s) {
        cancelQualityWatch();
        if (!autoFailover) return;
        qualityWatchTask = new Runnable() {
            @Override public void run() {
                qualityWatchTask = null;
                if (released || gen != generation) return;
                evaluateQuality(gen, idx, s);
                if (!released && gen == generation && player != null && firstFrameSeen) {
                    scheduleQualityWatch(gen, idx, s);
                }
            }
        };
        handler.postDelayed(qualityWatchTask, Tuning.QUALITY_WATCH_MS);
    }

    private void cancelQualityWatch() {
        if (qualityWatchTask != null) {
            handler.removeCallbacks(qualityWatchTask);
            qualityWatchTask = null;
        }
    }

    /**
     * 三个闭环的判读与动作。全部以「有别的候选线路」为前提——单线路台换线
     * 只会把唯一能播的线路也烧掉（1.0.2 上一版就栽在这上面）。
     */
    private void evaluateQuality(final int gen, final int idx,
                                 final ChannelCatalog.Stream s) {
        if (released || gen != generation || !firstFrameSeen || channel == null
                || s == null) return;
        // 暂停时不判：吞吐为 0、位置不动，B1 会判「塌陷」、D3 会判「停滞」，
        // 两个都会把一条正在正常播放的线路换掉。
        if (paused) return;

        // A1：只记账、不动播放。换线本身有代价，而「假高清」只是观感排序问题，
        // 不值得为一个标注问题打断正在看的画面；降权在下次选线时生效。
        if (probe.isFakeHd() && fakeHdUrls.add(s.url)) {
            fakeHdCount++;
        }

        final long now = SystemClock.uptimeMillis();

        // B1：带宽塌陷。三重约束缺一不可——
        // ① 基线够高（标清线路本来就只有 0.5 Mbps，跌一半是噪声不是事件）；
        // ② 近 60 秒已经卡过至少一次（纯预防性换线会把好线路换掉，
        //    而用户对「无故换线」的容忍度低于「卡一下」）；
        // ③ 冷却期内不重复触发（防止在新线路上立刻再打一枪）。
        //
        // M1 实测修正：原计划的判据是「视频缓存 <1.5 秒」，但真机读数长期稳定
        // 在 17～21 秒且 30 秒最低值 17.4 秒——这个量根本不是「还能播多久」，
        // 而是预取深度。所以改用「相对本线路自身峰值的吞吐塌陷」。
        //
        // 10:31 真机修正（第二版）：基线不能再用「30 秒平均」。画面卡住时吞吐趋零，
        // 30 秒均值跟着塌到接近 0，「现在 < 基线的 40%」就永远不成立——最该触发的
        // 场景反而永远不触发。改成窗口内峰值当基线，并且把「流量一点没涨」单独
        // 认定为塌陷（旧代码因为 `fast > 0` 把它当成「算不出来」直接放过）。
        if (now - lastBwSwitchAt >= Tuning.BW_COOLDOWN_MS
                && bufferHitsInWindow() >= 1
                && hasMoreCandidates(idx)) {
            final long peak = probe.peakTrafficBps(60);
            final long fast = probe.trafficBps(Tuning.BW_FAST_WINDOW_SAMPLES);
            final boolean starved = probe.bytesStalled(Tuning.BW_FAST_WINDOW_SAMPLES);
            final boolean collapsed = peak >= Tuning.BW_MIN_BASE_BPS
                    && (starved || (fast > 0L
                            && fast < (long) (peak * Tuning.BW_COLLAPSE_RATIO)));
            bwCollapseSamples = collapsed ? bwCollapseSamples + 1 : 0;
            if (bwCollapseSamples >= Tuning.BW_COLLAPSE_SAMPLES) {
                bwCollapseSamples = 0;
                lastBwSwitchAt = now;
                bandwidthSwitchCount++;
                failCurrent(idx, s, -7, "带宽塌陷（实测 "
                        + (fast > 0L ? Tuning.mbps(fast) : "0")
                        + " / 峰值 " + Tuning.mbps(peak) + " Mbps）");
                return;
            }
        } else {
            bwCollapseSamples = 0;
        }

        // D2 / D3：用「播放位置增速」把两种病分开。
        //   > 1.02：音频在快播，seek 救不了，只能换线（D2）；
        //   < 0.50：画面基本不动，但可能没有持续缓冲事件，15 秒看门狗踩不到（D3）。
        // 10:31 真机读数 0.169 就是后者：缓存 280 ms、音频 0 ms、码率读不到，
        // 而「最近 60 秒缓冲」只有 1 次——旧的保护一条都没触发。
        final double rate = clockRate();
        final int windows = clockSampleCount();
        // 缓存是两个判据的共同前提：
        //  · 缓存充足时的「位置不动」几乎都是分片边界重置的读数假象（10:58 实测
        //    0.004 配 13040 ms 缓存），不能据此换线；
        //  · 缓存见底时的「位置暴涨」也不可信，那是饥饿引起的跳变，该交给 D3。
        final long cachedMs = probe.videoCachedMs();
        final boolean cacheBottom = cachedMs >= 0 && cachedMs < Tuning.STALL_MAX_CACHE_MS;
        if (windows > lastSyncWindow) {
            lastSyncWindow = windows;
            syncFastWindows = rate > Tuning.SYNC_FAST_RATE && !cacheBottom
                    ? syncFastWindows + 1 : 0;
            if (syncFastWindows >= Tuning.SYNC_FAST_WINDOWS
                    && now - lastSyncSwitchAt >= Tuning.SYNC_COOLDOWN_MS
                    && hasMoreCandidates(idx)) {
                syncFastWindows = 0;
                lastSyncSwitchAt = now;
                syncSwitchCount++;
                failCurrent(idx, s, -8, String.format(Locale.US,
                        "音频时钟偏快 %.3f（连续 %d 个窗口 > %.2f）",
                        rate, Tuning.SYNC_FAST_WINDOWS, Tuning.SYNC_FAST_RATE));
                return;
            }

            // 停滞 = 位置几乎不动 **且** 缓存见底。缺任何一个都不动手。
            if (rate < Tuning.STALL_RATE && cacheBottom) {
                stallWindows++;
            } else {
                stallWindows = 0;
            }
            if (stallWindows >= Tuning.STALL_WINDOWS
                    && now - lastStallActionAt >= Tuning.STALL_COOLDOWN_MS) {
                stallWindows = 0;
                lastStallActionAt = now;
                stallActionCount++;
                if (hasMoreCandidates(idx)) {
                    failCurrent(idx, s, -9, String.format(Locale.US,
                            "画面停滞（位置增速 %.2f×，视频缓存 %d ms）",
                            rate, probe.videoCachedMs()));
                } else if (stallGaveUp.add(s.url)) {
                    // 只有这一条线路时换线只会绕回原点，直接重连同一条：
                    // 卡住的 HTTP 读经常重连一次就好了，比干坐着等强。
                    listener.onState("画面停滞，正在重连…");
                    retryCurrentStream();
                } else {
                    // 重连过一次仍停：不再折腾，把该按的键告诉用户。
                    listener.onState("画面停滞 · 按 ←→ 换线路或 ↑↓ 换台");
                }
                return;
            }
        }
    }

    /**
     * 首帧快速失败：总超时之前先给一次「换条路」的机会。
     *
     * <p>只在还有没试过的候选时才挂：最后一条线路要留给总超时兜底，
     * 否则会把唯一可能出画的线路杀掉，直接掉进「全部线路不可用」。
     */
    private void scheduleQuickFail(final int gen, final int idx,
                                   final ChannelCatalog.Stream s) {
        cancelQuickFail();
        // 关键：要问「除当前这条，还有没有没试过的」。旧实现问的是
        // attempted.size() < streams.size()，而当前这条此刻还没记进 attempted，
        // 于是单线路频道也满足条件 → 5 秒被杀，直接全灭。
        if (!hasMoreCandidates(idx)) return;
        quickFailTask = new Runnable() {
            @Override public void run() {
                if (released || gen != generation || firstFrameSeen) return;
                // 硬解不出画时先回退软解重开同一条：否则会在几条好线路上
                // 依次撞 6 秒，白白把候选试光，最后报「全部线路不可用」。
                if (fallbackToSoftDecode("硬解 6 秒无首帧", s)) {
                    retryCurrentStream();
                    return;
                }
                failCurrent(idx, s, -5, "首帧 6 秒未出，先换下一条");
            }
        };
        handler.postDelayed(quickFailTask, QUICK_FAIL_MS);
    }

    /**
     * 除 {@code currentIdx} 之外，是否还有**真的会被尝试**的候选线路。
     *
     * <p>带 resolver 的线路在 {@code findNext} 里被直接跳过（兼容分支没实现
     * 在线换 token），不能算作候选；已失败的线路也不算。这样「只有一条线路」
     * 和「只剩一条没试」都会老老实实等总超时，不会提前宣布全灭。
     */
    private boolean hasMoreCandidates(int currentIdx) {
        if (channel == null) return false;
        final int total = channel.streams.size();
        for (int step = 1; step < total; step++) {
            final int idx = (currentIdx + step) % total;
            if (attempted.contains(Integer.valueOf(idx))) continue;
            final ChannelCatalog.Stream s = channel.streams.get(idx);
            if (s.resolver != null && s.resolver.length() > 0) continue;
            return true;
        }
        return false;
    }

    private void cancelQuickFail() {
        if (quickFailTask != null) {
            handler.removeCallbacks(quickFailTask);
            quickFailTask = null;
        }
    }

    /**
     * 缓冲开始。区分三种情况，只有一种会真的弹提示（M0 / E1）。
     *
     * <ol>
     *   <li>起播阶段（首帧之前）：照旧立刻显示「缓冲中…」——此时屏幕本来就是
     *       黑的或只剩「正在连接」，压延迟反而让用户以为没反应；</li>
     *   <li>再对齐 seek 引发的缓冲：完全不提示。这类缓冲由我们自己制造，
     *       每 8 秒提示一次「缓冲中」比真实卡顿更烦；</li>
     *   <li>播放中的普通缓冲：延迟 {@link #BUFFER_HINT_DELAY_MS} 再决定，
     *       600 ms 内恢复就当作没发生。</li>
     * </ol>
     */
    private void onBufferingStart(final int gen, final int idx,
                                  final ChannelCatalog.Stream s) {
        final long now = SystemClock.uptimeMillis();
        bufferStartAt = now;
        final boolean selfInflicted = now < suppressBufferHitUntil;
        if (!selfInflicted) {
            if (!firstFrameSeen) {
                listener.onState("缓冲中…");
            } else {
                scheduleBufferHint(gen);
            }
        }
        // 频繁缓冲先记账：60 秒内够 3 次就直接换线，
        // 不用等 15 秒看门狗，用户也少看几次「缓冲中」。
        noteBufferHit(gen, idx, s);
        if (gen == generation) scheduleBufferWatchdog(gen, idx, s);
    }

    private void onBufferingEnd(IMediaPlayer mp) {
        cancelBufferWatchdog();
        settleBufferHint(firstFrameSeen);
        alignClockAfterStall(mp);
    }

    /** 延迟 600 ms 才提示；期间若缓冲结束，任务会被撤掉，提示根本不出现。 */
    private void scheduleBufferHint(final int gen) {
        cancelBufferHint();
        bufferHintTask = new Runnable() {
            @Override public void run() {
                bufferHintTask = null;
                if (released || gen != generation || !firstFrameSeen) return;
                bufferHintVisible = true;
                bufferHintShownAt = SystemClock.uptimeMillis();
                listener.onState("缓冲中…");
            }
        };
        handler.postDelayed(bufferHintTask, BUFFER_HINT_DELAY_MS);
    }

    private void cancelBufferHint() {
        if (bufferHintTask != null) {
            handler.removeCallbacks(bufferHintTask);
            bufferHintTask = null;
        }
    }

    /**
     * 缓冲结束时的收尾：没提示过就按原逻辑清文案；提示过就保证它至少
     * 停留 {@link #BUFFER_HINT_MIN_SHOW_MS}，避免「闪一下」。
     */
    private void settleBufferHint(final boolean firstFrame) {
        cancelBufferHint();
        final String next = firstFrame ? "" : "正在出画…";
        if (!bufferHintVisible) {
            listener.onState(next);
            return;
        }
        final long shown = SystemClock.uptimeMillis() - bufferHintShownAt;
        final long remain = BUFFER_HINT_MIN_SHOW_MS - shown;
        if (remain <= 0L) {
            bufferHintVisible = false;
            listener.onState(next);
            return;
        }
        handler.postDelayed(new Runnable() {
            @Override public void run() {
                if (!bufferHintVisible) return;
                bufferHintVisible = false;
                if (!released) listener.onState(next);
            }
        }, remain);
    }

    /** 首帧到达 / 换线 / 释放：把提示状态整体复位，不留残影。 */
    private void resetBufferHint() {
        cancelBufferHint();
        bufferHintVisible = false;
        bufferHintShownAt = 0L;
    }

    /**
     * 记一次「缓冲中」。60 秒窗口内攒够 3 次就认定这条线路带宽不稳，
     * 主动换下一条——这比等 15 秒看门狗更早止损，也避免用户手动换线。
     *
     * <p>只在首帧之后计数：起播阶段的缓冲属于正常预热，算进去会把好线路也换掉。
     */
    private void noteBufferHit(final int gen, final int idx,
                               final ChannelCatalog.Stream s) {
        if (!firstFrameSeen || released || gen != generation) return;
        final long now = SystemClock.uptimeMillis();
        // 再对齐自己引发的 seek 也会报一次 BUFFERING_START，不能算进「频繁卡顿」，
        // 否则每做一次对齐就会把好线路往换线阈值上推。
        if (now < suppressBufferHitUntil) return;
        if (bufferWindowStart == 0L || now - bufferWindowStart > BUFFER_WINDOW_MS) {
            bufferWindowStart = now;
            bufferHits = 0;
        }
        bufferHits++;
        if (bufferHits >= BUFFER_HIT_LIMIT) {
            // 不在这里喊话：紧接着的 onStreamFailed 会显示「线路 N 失败：… 正在切换」，
            // 两条提示叠在一起反而互相覆盖。
            failCurrent(idx, s, -6, "卡顿频繁（60 秒 3 次）");
        }
    }

    /**
     * 缓冲结束后的时钟再对齐。
     *
     * <p>ijkplayer 的视频出帧按 {@code frame_timer} 相对推进：缓冲期间音频
     * 缓冲继续排空、音频主时钟往前走，视频帧定时器却停在原处；缓冲一结束，
     * 画面就从「旧时刻」追，一次抖动就是一次阶跃式的音画偏差，多次叠加就是
     * 用户说的「越看越不同步」。这里在长停顿后按当前播放位置 seek 一次，
     * 让内核把 frame_timer 重置到音频时钟上。
     *
     * <p>三条护栏：只处理 ≥1.5 秒的停顿（短抖动交给内核自己纠）、同一线路
     * 最多 3 次、两次之间至少隔 8 秒；seek 引发的 buffering 不计入卡顿计数。
     */
    private void alignClockAfterStall(IMediaPlayer mp) {
        final long now = SystemClock.uptimeMillis();
        final long stall = bufferStartAt == 0L ? 0L : now - bufferStartAt;
        bufferStartAt = 0L;
        if (!firstFrameSeen) return;              // 起播阶段由 sync-av-start 负责
        if (stall < BUFFER_ALIGN_MIN_STALL_MS) return;
        if (alignSeekCount >= BUFFER_ALIGN_LIMIT) return;
        if (lastAlignSeekAt != 0L && now - lastAlignSeekAt < BUFFER_ALIGN_COOLDOWN_MS) {
            return;
        }
        try {
            final long pos = mp.getCurrentPosition();
            if (pos <= 0L) return;
            lastAlignSeekAt = now;
            alignSeekCount++;
            suppressBufferHitUntil = now + 3000L;
            mp.seekTo(pos);
        } catch (Throwable ignored) {
            // 不支持 seek 的直播源保持原样：宁可有一点偏差，也不要因此黑屏。
        }
    }

    private void resetBufferProbe() {
        bufferWindowStart = 0L;
        bufferHits = 0;
        bufferStartAt = 0L;
        suppressBufferHitUntil = 0L;
    }

    /** 诊断页读数：当前窗口内的缓冲次数。 */
    public int bufferHitsInWindow() {
        if (bufferWindowStart == 0L) return 0;
        if (SystemClock.uptimeMillis() - bufferWindowStart > BUFFER_WINDOW_MS) return 0;
        return bufferHits;
    }

    /** 诊断页读数：上次出画耗时（ms），-1 表示本次会话还没出过画。 */
    public long lastFirstFrameMs() { return lastFirstFrameMs; }

    /**
     * 运行时质量探针（只读）。
     *
     * <p>M0 阶段只给诊断页用；M2 的闭环（水位 / 丢帧 / 缓存差）也从同一个
     * 采样层取数，避免各自去读内核导致读数口径不一致。
     */
    public QualityProbe quality() { return probe; }

    /** 诊断页：本次会话累计起播次数（跨台不清零）。 */
    public int sessionStartCount() { return sessionStarts; }

    /** 诊断页：后台仍在 stop/reset/release 的 player 数；>0 表示释放队列堆积。 */
    public int releasePendingCount() { return releasePendingCount.get(); }

    /** 诊断页：新 player 绑定时旧 player 未释放完的累计次数（跨台不清零）。 */
    public int releaseOverlapCount() { return releaseOverlapCount; }

    /** 诊断页：最近一次起播是否重叠，及当时的队列深度；0 = 那次没重叠。 */
    public int lastOverlapDepth() { return lastOverlapDepth; }

    /** 诊断页：最近一次后台释放耗时（ms）；-1 = 还没有释放完成过。 */
    public long lastReleaseCostMs() { return lastReleaseCostMs; }

    /** 诊断页：起播时观察到的最深待释放队列（跨台不清零）。 */
    public int maxOverlapDepth() { return maxOverlapDepth; }

    /** 诊断页：真正发生过「等释放排空」的起播次数（跨台不清零）。 */
    public int drainCount() { return drainCount; }

    /** 诊断页：等释放排空超时、只能带病继续的次数（跨台不清零）。 */
    public int drainTimeoutCount() { return drainTimeoutCount; }

    /** 诊断页：最近一次等释放排空的耗时（ms）；-1 = 还没等待过。 */
    public long lastDrainCostMs() { return lastDrainCostMs; }

    /** 诊断页：当前这条线路已经播了多少秒；尚未起播返回 -1。 */
    public long streamElapsedSeconds() {
        if (openedAtMs <= 0L) return -1L;
        return (SystemClock.uptimeMillis() - openedAtMs) / 1000L;
    }

    /**
     * 自动换线开关（设置页「自动换线」）。
     *
     * <p>关掉后只停三条新闭环（A1 降权 / B1 塌陷 / D2 时钟），
     * 1.0.2 的 6 秒快失败、15 秒看门狗、60 秒 3 次卡顿照常工作——
     * 那些是「已经出问题后的止损」，不属于「预测性换线」。
     */
    public void setAutoFailover(boolean on) {
        autoFailover = on;
        if (!on) {
            cancelQualityWatch();
            bwCollapseSamples = 0;
            syncFastWindows = 0;
            return;
        }
        final ChannelCatalog.Stream s = currentStream();
        if (firstFrameSeen && player != null && s != null) {
            scheduleQualityWatch(generation, streamIndex, s);
        }
    }

    public boolean autoFailover() { return autoFailover; }

    private ChannelCatalog.Stream currentStream() {
        if (channel == null) return null;
        if (streamIndex < 0 || streamIndex >= channel.streams.size()) return null;
        return channel.streams.get(streamIndex);
    }

    /** 诊断页读数：被判为假高清、已降权的线路条数。 */
    public int fakeHdCount() { return fakeHdCount; }

    /** 诊断页读数：因带宽塌陷换线次数。 */
    public int bandwidthSwitchCount() { return bandwidthSwitchCount; }

    /** 诊断页读数：因音频时钟偏快换线次数。 */
    public int syncSwitchCount() { return syncSwitchCount; }

    /** 诊断页读数：因画面停滞换线 / 重连次数。 */
    public int stallActionCount() { return stallActionCount; }

    public boolean isPaused() { return paused; }

    /**
     * 记忆排序开关：{@code false} 时完全按台账顺序试线路（= 1.0.2 行为）。
     * Activity 按「优先清晰度＝自动」为它取值。
     */
    public void setAdaptiveOrder(boolean on) { adaptiveOrder = on; }

    public boolean adaptiveOrder() { return adaptiveOrder; }

    /** 本台这次是否被记忆改了首选线路；-1 表示按台账顺序。 */
    public int preferredStreamIndex() { return preferredStreamIndex; }

    /** 诊断页「记忆」一行。 */
    public String memorySummary() {
        if (channel == null) return "记忆：本次会话尚未进台";
        return memory.summary(channel.streams, preferredStreamIndex);
    }

    /** 诊断页读数：本次会话换过几次线路。 */
    public int failoverCount() { return failoverCount; }

    /** 诊断页读数：当前线路做过几次缓冲后时钟再对齐。 */
    public int alignSeekCount() { return alignSeekCount; }

    /** 诊断页读数：本轮频道的台账是否整台无一条可达线路。 */
    public boolean isChannelLikelyDead() { return channelLikelyDead; }

    /** 首帧之后长时间停在 BUFFERING_START：主动换线，保证「可恢复」。 */
    private void scheduleBufferWatchdog(final int gen, final int idx,
                                        final ChannelCatalog.Stream s) {
        cancelBufferWatchdog();
        bufferWatchdogTask = new Runnable() {
            @Override public void run() {
                if (released || gen != generation) return;
                // 首帧之前由总超时负责，别重复判一次。
                if (!firstFrameSeen) return;
                failCurrent(idx, s, -3, "缓冲超时（15 秒）");
            }
        };
        handler.postDelayed(bufferWatchdogTask, BUFFER_WATCHDOG_MS);
    }

    private void failCurrent(final int idx, final ChannelCatalog.Stream s,
                             final int what, final String reason) {
        if (released) return;
        // 同一条线路只判一次失败：旧 player 可能连发多个 error，
        // 否则会把候选线路一次性烧光。
        if (attempted.contains(Integer.valueOf(idx))) return;
        attempted.add(Integer.valueOf(idx));
        failoverCount++;
        // A2 记忆：只有「内核报错」(what≥0) 和「首帧超时」(-1) 算硬失败。
        // 快速失败(-5) 只说明这条线路慢、卡顿计数(-6) 说明网络抖，
        // 都不该让它在下次被降权——所有线路都慢的时候，慢但能播的那条就是最优解。
        if (what >= 0 || what == -1) memory.noteFailure(s.url);
        // 只有内核真的报错（what >= 0）才算「加密线路在这台机器上不可用」。
        // 首帧超时(-1)、缓冲看门狗(-3)、快速失败(-5)、卡顿换线(-6) 都只说明
        // 「这条线路慢 / 抖」，与 TLS 无关；上一版把它们也计进 streak，三次
        // 超时就会误报「本机 HTTPS 连续失败」，还顺带改掉线路排序。
        if (s.https && what >= 0) {
            httpsFailureStreak++;
            if (httpsFailureStreak >= HTTPS_FAILURE_STREAK_LIMIT && !httpsUnavailable) {
                httpsUnavailable = true;
                listener.onState("本机 HTTPS 连续失败（TLS / 证书链），"
                        + "先把明文线路排前面；若仍无画面会自动重试加密线路");
            }
        } else if (!s.https) {
            httpsFailureStreak = 0;
        }
        listener.onStreamFailed(idx, what, reason);
        // 回到主线程消息循环的下一轮再重建 player，避免在 native 回调栈里
        // 直接释放/重建内核（ijkplayer 不允许在回调里 release 自己）。
        //
        // 代际 + 频道双校验：用户在这条消息排队期间换了台，旧回调必须作废。
        // 否则它会去释放「新台刚起播的 player」、从旧下标重新开一条线路，
        // 表现就是「换了台又黑屏、一直连不上」。
        final int gen = generation;
        final ChannelCatalog.Channel target = channel;
        handler.post(new Runnable() {
            @Override public void run() {
                if (released || gen != generation || target == null
                        || channel != target) {
                    return;
                }
                streamIndex = (idx + 1) % target.streams.size();
                if (!openNext()) listener.onAllStreamsFailed(target, failureReason());
            }
        });
    }

    private static String safeMessage(Throwable t) {
        String m = t.getMessage();
        if (m == null || m.length() == 0) return t.getClass().getSimpleName();
        return m.length() > 80 ? m.substring(0, 80) : m;
    }

    /** native 回调线程 → 主线程；已经在主线程就直接执行。 */
    private void postToUi(Runnable action) {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            action.run();
        } else {
            handler.post(action);
        }
    }

    /** 回调是否是「当前这一代 player」的，旧 player 的迟到回调一律丢弃。 */
    private boolean isCurrent(int gen, IMediaPlayer mp) {
        return !released && gen == generation && mp == player && player != null;
    }

    private void cancelTimeout() {
        if (timeoutTask != null) {
            handler.removeCallbacks(timeoutTask);
            timeoutTask = null;
        }
    }

    private void cancelBufferWatchdog() {
        if (bufferWatchdogTask != null) {
            handler.removeCallbacks(bufferWatchdogTask);
            bufferWatchdogTask = null;
        }
    }

    /**
     * 换台时等后台释放队列排空，让新 player 在一个「没有旧 player」的时刻
     * 绑定 SurfaceHolder。
     *
     * <p>16:48 真机 31.jpg：重叠 83 / 起播 86（96.5%）、最深队列 3 个、
     * 单次释放 62 ms、现存待释放 0 个 ⇒ 释放既不慢也不长期堆积，只是几乎
     * 每次换台都恰好落在新旧 player 的交接窗口里。等它排空的代价是几十
     * 毫秒，且有 {@link Tuning#RELEASE_DRAIN_TIMEOUT_MS} 硬上限：超时立刻
     * 继续，不 join executor、不无限阻塞主线程。
     *
     * <p>这是可证伪的干预：消掉重叠后若仍出现「起播即带病」，嫌疑 A 当场
     * 排除；若不再复现，则换台交接窗口就是病因。
     */
    private void awaitReleaseDrain() {
        if (releasePendingCount.get() <= 0) return;
        final long start = SystemClock.uptimeMillis();
        final long deadline = start + Tuning.RELEASE_DRAIN_TIMEOUT_MS;
        while (releasePendingCount.get() > 0 && SystemClock.uptimeMillis() < deadline) {
            try {
                Thread.sleep(2L);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                break;
            }
        }
        drainCount++;
        lastDrainCostMs = SystemClock.uptimeMillis() - start;
        if (releasePendingCount.get() > 0) drainTimeoutCount++;
    }

    /**
     * 让旧 player 立刻失效，把真正的 stop/reset/release 丢到后台线程。
     * 主线程只做 setDisplay(null)（轻量、不 join native 线程）。
     */
    private void releaseCurrentPlayer() {
        generation++;
        cancelTimeout();
        cancelBufferWatchdog();
        cancelQuickFail();
        cancelUnmute();
        resetBufferHint();
        cancelQualityWatch();
        probe.stop();
        final IjkMediaPlayer p = player;
        player = null;
        if (p == null) return;
        try { p.setDisplay(null); } catch (Throwable ignored) {}
        // 只记时序，不 join、不等待：换台仍然不被上一台的缓冲拖住。
        // 计数在 finally 里减，即使 stop/reset/release 抛异常也不会让读数卡住。
        final long submitAt = SystemClock.uptimeMillis();
        releasePendingCount.incrementAndGet();
        RELEASE_EXECUTOR.execute(new Runnable() {
            @Override public void run() {
                try {
                    try { p.stop(); } catch (Throwable ignored) {}
                    try { p.reset(); } catch (Throwable ignored) {}
                    try { p.release(); } catch (Throwable ignored) {}
                } finally {
                    lastReleaseCostMs = SystemClock.uptimeMillis() - submitAt;
                    releasePendingCount.decrementAndGet();
                }
            }
        });
    }

    /**
     * 作废所有「针对上一台 / 上一条线路」的待执行回调。
     *
     * <p>{@link #generation} 一加，{@code isCurrent} 与 {@code failCurrent} 里
     * 排队中的重建都会被丢掉。换台时不做这件事，旧回调就会在新台起播后插进来，
     * 把新 player 释放掉重开——用户看到的是「换了台又黑屏」。
     */
    private void invalidatePending() {
        generation++;
        cancelTimeout();
        cancelQuickFail();
        cancelBufferWatchdog();
        cancelUnmute();
        resetBufferHint();
        cancelQualityWatch();
    }

    /** Activity.onPause / onDestroy 调用；之后本实例不再可用。 */
    public void release() {
        released = true;
        releaseCurrentPlayer();
        attempted.clear();
    }
}
