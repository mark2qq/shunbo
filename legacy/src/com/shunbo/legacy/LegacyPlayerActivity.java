package com.shunbo.legacy;

import android.app.Activity;
import android.graphics.Color;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.util.DisplayMetrics;
import android.view.Gravity;
import android.view.KeyEvent;
import android.view.SurfaceHolder;
import android.view.SurfaceView;
import android.view.View;
import android.view.WindowManager;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.TextView;

import java.util.Locale;

/**
 * 顺播原生兼容分支主界面（路线 B）。
 *
 * <p>面向 Android 4.3 / API 18 / 1280x720 / 只有遥控器的电视：全屏 SurfaceView 出画，
 * 所有交互走 {@link #onKeyDown}，不依赖触摸、不依赖 Material / AppCompat / Leanback，
 * 也不依赖 WebView。
 *
 * <p><b>交互模型参照主流电视直播软件</b>，而不是「一堆隐式快捷键」：
 * <ul>
 *   <li>按 OK / ↓ 唤出<b>可聚焦底部控制条</b>（频道 / 上一台 / 暂停 / 下一台 / 换线路 /
 *       收藏 / 检索 / 信息），←→ 移焦、OK 执行、↑ 或返回收起，5 秒不动自动收起；</li>
 *   <li>频道栏是<b>分组 + 焦点列表</b>：←→ 切分组（全部 / 收藏 / 各频道分组）、
 *       ↑↓ 选台、OK 切换、菜单键收藏；</li>
 *   <li>数字键<b>台号直达</b>，底部浮层实时显示输入与目标台名，2 秒后自动提交；</li>
 *   <li>「检索」用<b>26 字母网格 + 拼音首字母</b>（zjws → 浙江卫视）；</li>
 *   <li>连续按 ↑↓ 会合并成一次起播（280ms 内的连按只起最后一台），避免一路上
 *       反复 prepare 把内核拖死；</li>
 *   <li>收藏与「上次观看」落 SharedPreferences，下次开机直接续到上次那台。</li>
 * </ul>
 *
 * <p>版本兼容分支在启动时判定一次并锁存（{@link LegacyVersionCompat}），结果展示在
 * 信息页；判定语义与 Flutter 主程序 {@code version_compat.dart} 一致。
 */
public class LegacyPlayerActivity extends Activity
        implements SurfaceHolder.Callback, PlaybackController.Listener,
        ControlBar.Listener, ChannelPanel.Listener, SearchPanel.Listener,
        RegionPanel.Listener, SettingsPanel.Listener {

    private static final int MODE_PLAY = 0;
    private static final int MODE_CONTROL = 1;
    private static final int MODE_PANEL = 2;
    private static final int MODE_SEARCH = 3;
    private static final int MODE_HELP = 4;
    private static final int MODE_REGION = 5;
    private static final int MODE_SETTINGS = 6;

    /** BootReceiver 写入、RouterActivity 透传的开机自启标记。 */
    public static final String EXTRA_AUTOSTART = "shunbo.autostart";

    private static final long BACK_DOUBLE_MS = 2000L;
    private static final long HINT_IDLE_MS = 6000L;
    private static final long TOAST_MS = 1800L;

    /** 三个手感参数由设置页动态改写，默认值与 Prefs.defaultOf 保持一致。 */
    private long zapCommitMs = 280L;
    private long numberCommitMs = 2000L;
    /** 浮层（控制条 / 频道栏 / 地区 / 检索）空闲多久自动收起；0 = 不隐藏。 */
    private long idleHideMs = 30000L;

    private final Handler ui = new Handler(Looper.getMainLooper());

    private SurfaceView surfaceView;
    /**
     * 换台过渡黑幕（M0 / E2）。
     *
     * <p>SurfaceView 的最后一帧会一直留在 surface 上，直到新流的第一帧画上去。
     * 换台时音频往往先到，于是「上一台的画面 + 新台的声音」看起来正是
     * 「画面滞后、声音超前」——一类典型的假不同步。盖上黑幕到首帧为止，
     * 比解释「其实没不同步」有效得多。
     */
    private View blackoutView;
    private Runnable blackoutTask;
    private TextView centerStatus;
    private TextView numberDigits;
    private TextView numberTarget;
    private LinearLayout numberPanel;
    private TextView toastView;
    private TextView hintView;
    private TextView helpView;
    /** 诊断页分页：内容已经超过一屏（真机 1080p 实测被裁掉 7 行），改成按页翻。 */
    private int helpPage = 0;
    private int helpPages = 1;

    private ControlBar controlBar;
    private ChannelPanel channelPanel;
    private SearchPanel searchPanel;
    private RegionPanel regionPanel;
    private SettingsPanel settingsPanel;
    private Prefs prefs;

    private ChannelCatalog catalog;
    private PlaybackController playback;
    private LegacyVersionCompat.Decision decision;
    private boolean nativeLibrariesOk = false;
    /** 内核加载失败的真实原因；null 表示加载成功。 */
    private String nativeLibraryError = null;
    /** 启动失败兜底态：只响应菜单 / 返回，避免连锁 NPE 覆盖原始堆栈。 */
    private boolean fatal = false;
    private Throwable lastFatal = null;
    private boolean surfaceReady = false;

    private int mode = MODE_PLAY;
    private int channelIndex = 0;
    private int currentStreamIndex = 0;
    private int currentStreamTotal = 0;
    private long firstFrameMs = -1L;
    private boolean paused = false;
    /** 当前台全部线路已试完仍无画面：OK 变成「一键重试」而不是打开控制条。 */
    private boolean allStreamsFailed = false;
    /** 真正正在播的频道对象：切地区过滤掉它时也不打断画面。 */
    private ChannelCatalog.Channel playingChannel = null;
    /** 播放态文案（播放中 / 缓冲中 / 连接中 / 线路不可用），频道栏会显示。 */
    private String playbackStateText = "准备中";
    /** 上一个真正出过画的频道：切台全失败时回退到它，画面不会被错误 OSD 占死。 */
    private ChannelCatalog.Channel lastGoodChannel = null;
    private int lastGoodStreamIndex = 0;
    /** 本次启动是否由开机自启拉起。 */
    private boolean autostart = false;

    private String numberBuffer = "";
    private int zapTarget = -1;
    /** 上一次 resolvePlayable 跳过了几个「无可用线路」的台。 */
    private int deadSkipCount = 0;
    /** 连按合并期间累计的跳过数，提交时提示一次。 */
    private int zapSkippedDead = 0;
    private long lastBackMs = 0L;

    /** 通用浮层空闲计时器：控制条 / 频道栏 / 地区 / 检索共用同一个。 */
    private Runnable controlHideTask;
    private Runnable bannerHideTask;
    private Runnable hintHideTask;
    private Runnable numberCommitTask;
    private Runnable toastHideTask;
    /** 诊断页实时刷新（读数每秒在变，静态快照看不出水位趋势）。 */
    private Runnable helpRefreshTask;
    /** 切台失败提示的定时消失 + 自动回退。 */
    private Runnable failHintTask;
    private final Runnable zapCommitTask = new Runnable() {
        @Override
        public void run() {
            int target = zapTarget;
            zapTarget = -1;
            int skipped = zapSkippedDead;
            zapSkippedDead = 0;
            if (target >= 0) {
                startChannel(target);
                if (skipped > 0) {
                    showToast("已跳过 " + skipped + " 个无可用线路的频道");
                }
            }
        }
    };

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        // 必须最先装：后面任何一步抛异常都要留下堆栈，供菜单页拍照回传。
        CrashReport.install(this);
        try {
            super.onCreate(savedInstanceState);
            getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
            autostart = getIntent() != null
                    && getIntent().getBooleanExtra(EXTRA_AUTOSTART, false);

            prefs = new Prefs(this);
            decision = probeVersion();
            nativeLibraryError = PlaybackController.loadNativeLibraries();
            nativeLibrariesOk = (nativeLibraryError == null);
            try {
                // 4K 输出先过设备门槛：API < 24、输出不足 3840 宽、无 2160 硬解、
                // 内存 < 2 GB、或当前是软解，任一成立就封顶 1080——由清单层在载入期
                // 剥离 2160 线路并隐藏 4K 专用台，播放链路根本不会看到 4K。
                catalog = ChannelCatalog.load(this,
                        DeviceCapability.qualityCeiling(this,
                                prefs != null && prefs.hardDecode()));
                // 地区偏好先于「上次观看」定位：可见列表变了，旧下标可能越界。
                // 没存过就用清单默认（江苏·苏州·市模式）。
                catalog.setRegion(prefs == null ? null : prefs.regionMode(),
                        prefs == null ? null : prefs.regionProvince(),
                        prefs == null ? null : prefs.regionCity());
            } catch (Throwable e) {
                catalog = null;
                CrashReport.record(this, "ChannelCatalog.load", e);
            }
            channelIndex = preferredChannelIndex();
            currentStreamTotal = catalog == null ? 0
                    : currentChannel().streams.size();

            setContentView(buildRootView());
            surfaceView.getHolder().addCallback(this);
            applySettings();
            if (catalog == null) {
                showStatus("频道清单加载失败：assets/channels.json 缺失或损坏\n"
                        + "按菜单键查看异常记录，返回退出");
            } else if (!nativeLibrariesOk) {
                showStatus("播放内核加载失败：\n" + nativeLibraryError
                        + "\n按菜单键查看完整记录");
            } else {
                showStatus("正在准备画面…");
            }
            showHint(true);
            // 「启动直接进入播放」关掉时，开机先给频道栏（主流电视直播软件的
            // 默认行为）；打开时保持 MODE_PLAY，surface 一就绪就全屏出画。
            // 开机自启与手动点图标走同一套启动策略，行为一致。
            if (!prefs.bootDirectPlay() && catalog != null) setMode(MODE_PANEL);
        } catch (Throwable t) {
            // 启动期任何异常都不再向上抛：直接把原因显示在屏幕上，
            // 而不是让系统弹「已停止运行」后什么都看不到。
            lastFatal = t;
            CrashReport.record(this, "onCreate", t);
            showFatal(t);
        }
    }

    /** 按「启动频道」设置定位：上次观看 / 第 1 台 / 收藏首台。 */
    private int preferredChannelIndex() {
        int idx = rawPreferredIndex();
        if (catalog == null || catalog.size() == 0) return 0;
        // 上次看的台可能已经整台失效（清单里 41% 的台没有任何可达线路）。
        // 开机直接进这种台，用户看到的就是「一直黑屏」，所以沿顺序顺延到
        // 第一条可达台；用户仍可从频道栏手动进入。
        return resolvePlayable(idx, 1);
    }

    private int rawPreferredIndex() {
        if (catalog == null || catalog.size() == 0) return 0;
        final int startMode = prefs == null ? 0 : prefs.startChannelMode();
        if (startMode == 1) return 0;
        if (startMode == 2 && prefs != null) {
            for (int i = 0; i < catalog.size(); i++) {
                if (prefs.isFavorite(catalog.get(i).id)) return i;
            }
        }
        int num = prefs == null ? -1 : prefs.lastNum();
        if (num > 0) {
            int idx = catalog.indexOfNumber(num);
            if (idx >= 0) return idx;
        }
        return 0;
    }

    // ---------------------------------------------------------------- 设置

    /** 把设置项应用到运行时：任一项改动后都会重跑，不重启 Activity。 */
    private void applySettings() {
        if (prefs == null) return;
        zapCommitMs = prefs.zapCommitMs();
        numberCommitMs = prefs.numberCommitMs();
        idleHideMs = prefs.panelIdleMs();
        if (catalog != null) catalog.applyQualityPriority(prefs.qualityPriority());
        // 解码方式会改变 4K 门槛：4K 台是在载入期剥离的，改了要重载清单才生效。
        // 这里只提示、不偷偷重载——重载会重建可见列表与当前台下标，播放中做这件事
        // 反而会打断正在看的台。
        if (catalog != null && DeviceCapability.qualityCeiling(this, prefs.hardDecode())
                != catalog.qualityCeiling) {
            showToast("解码方式已改，4K 台需重启后生效");
        }
        applyAspect();
        applyPlaybackSettings();
        // 顶部信息条已整体删除，设置改动只需按「是否已出画」收敛底部提示。
        if (firstFrameMs >= 0 && mode == MODE_PLAY) hideOsdForPlayback();
        if (mode != MODE_PLAY) scheduleControlHide();
    }

    private void applyPlaybackSettings() {
        if (playback == null || prefs == null) return;
        playback.setFirstFrameTimeoutMs(prefs.firstFrameTimeoutMs());
        playback.setHardDecode(prefs.hardDecode());
        playback.setAutoFailover(prefs.autoFailover());
        // 记忆排序只在「优先清晰度＝自动」时开启：用户明确选了画质档，
        // 就不能让记忆把他拽到一条更快的低清线路上。
        playback.setAdaptiveOrder(prefs.qualityPriority() == 0);
        // 同步兼容模式：关掉 max-fps / video-pictq-size，交给内核自己调度。
        playback.setCompatSync(prefs.compatSync());
    }

    /** 画面比例：铺满 / 16:9 信箱 / 4:3 信箱，只改 SurfaceView 布局，不拉伸解码。 */
    private void applyAspect() {
        if (surfaceView == null) return;
        FrameLayout.LayoutParams lp =
                (FrameLayout.LayoutParams) surfaceView.getLayoutParams();
        if (lp == null) return;
        lp.gravity = Gravity.CENTER;
        final int aspect = prefs == null ? 0 : prefs.aspect();
        if (aspect == 0) {
            lp.width = FrameLayout.LayoutParams.MATCH_PARENT;
            lp.height = FrameLayout.LayoutParams.MATCH_PARENT;
        } else {
            final DisplayMetrics dm = getResources().getDisplayMetrics();
            final float ratio = aspect == 1 ? 16f / 9f : 4f / 3f;
            final float screen = dm.widthPixels
                    / (float) Math.max(1, dm.heightPixels);
            if (screen > ratio) {
                lp.height = FrameLayout.LayoutParams.MATCH_PARENT;
                lp.width = (int) (dm.heightPixels * ratio);
            } else {
                lp.width = FrameLayout.LayoutParams.MATCH_PARENT;
                lp.height = (int) (dm.widthPixels / ratio);
            }
        }
        surfaceView.setLayoutParams(lp);
    }

    // ---------------------------------------------------------------- 界面

    private View buildRootView() {
        FrameLayout root = new FrameLayout(this);
        root.setBackgroundColor(Color.BLACK);
        root.setLayoutParams(new FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT));

        surfaceView = new SurfaceView(this);
        root.addView(surfaceView, new FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT));

        // 换台黑幕：紧贴 SurfaceView 之上、其余浮层之下。纯展示，
        // 绝不接收焦点/点击——它一旦可聚焦就会像旧版状态卡那样吞掉 OK 键。
        blackoutView = new View(this);
        blackoutView.setBackgroundColor(Color.BLACK);
        blackoutView.setVisibility(View.GONE);
        blackoutView.setClickable(false);
        blackoutView.setFocusable(false);
        blackoutView.setFocusableInTouchMode(false);
        root.addView(blackoutView, new FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT));

        // ---- 顶部信息条已整体移除 ----
        // 截图红标「地方频道 · 线路 1/2 · 首帧 720ms · API 18/legacyCompat」
        // 批注「不管什么时候都不要显示」：这条诊断条既是画面上的常驻遮挡，也把
        // 内核/首帧这类开发信息暴露给了普通用户，因此不再建视图、不再有任何显示
        // 路径。换台反馈由画面中央的「台号 + 台名」横幅承担（showChannelBanner），
        // 诊断信息仍可在菜单键的信息页里完整查看。
        //
        // ---- 中央状态（连接中 / 失败原因）----
        centerStatus = new TextView(this);
        centerStatus.setTextColor(Ui.TEXT);
        centerStatus.setTextSize(19);
        centerStatus.setGravity(Gravity.CENTER);
        centerStatus.setBackgroundColor(0xCC000000);
        centerStatus.setPadding(dp(28), dp(18), dp(28), dp(18));
        centerStatus.setVisibility(View.GONE);
        root.addView(centerStatus, new FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.WRAP_CONTENT,
                FrameLayout.LayoutParams.WRAP_CONTENT, Gravity.CENTER));

        // ---- 台号直达浮层（底部居中）----
        numberPanel = new LinearLayout(this);
        numberPanel.setOrientation(LinearLayout.VERTICAL);
        numberPanel.setGravity(Gravity.CENTER);
        numberPanel.setBackground(Ui.rect(this, 0xD9000000, 12, 0, 0));
        numberPanel.setPadding(dp(26), dp(12), dp(26), dp(12));
        numberPanel.setVisibility(View.GONE);

        numberDigits = new TextView(this);
        // 频道号：白色大号（与顶部条一致，主流电视换台数字均为中性白）。
        numberDigits.setTextColor(Ui.TEXT);
        numberDigits.setTextSize(42);
        numberDigits.setTypeface(android.graphics.Typeface.DEFAULT_BOLD);
        numberDigits.setGravity(Gravity.CENTER);
        numberPanel.addView(numberDigits);

        numberTarget = new TextView(this);
        numberTarget.setTextColor(Ui.TEXT);
        numberTarget.setTextSize(15);
        numberTarget.setGravity(Gravity.CENTER);
        numberPanel.addView(numberTarget);

        FrameLayout.LayoutParams numberLp = new FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.WRAP_CONTENT,
                FrameLayout.LayoutParams.WRAP_CONTENT,
                Gravity.BOTTOM | Gravity.CENTER_HORIZONTAL);
        numberLp.bottomMargin = dp(160);
        root.addView(numberPanel, numberLp);

        // ---- 底部提示条（几秒后自动隐藏）----
        hintView = new TextView(this);
        hintView.setTextColor(0xFF8FA3B8);
        hintView.setTextSize(13);
        hintView.setGravity(Gravity.CENTER);
        hintView.setBackgroundColor(0x99000000);
        hintView.setPadding(dp(16), dp(7), dp(16), dp(7));
        hintView.setText("OK 控制条   ↑↓ 换台   数字 直达   菜单 信息");
        hintView.setVisibility(View.GONE);
        FrameLayout.LayoutParams hintLp = new FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.WRAP_CONTENT, Gravity.BOTTOM);
        hintLp.bottomMargin = dp(6);
        root.addView(hintView, hintLp);

        // ---- 瞬时提示（收藏、换线结果等）----
        toastView = new TextView(this);
        toastView.setTextColor(Ui.TEXT);
        toastView.setTextSize(15);
        toastView.setGravity(Gravity.CENTER);
        toastView.setBackground(Ui.rect(this, 0xCC000000, 10, 0, 0));
        toastView.setPadding(dp(18), dp(8), dp(18), dp(8));
        toastView.setVisibility(View.GONE);
        FrameLayout.LayoutParams toastLp = new FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.WRAP_CONTENT,
                FrameLayout.LayoutParams.WRAP_CONTENT,
                Gravity.BOTTOM | Gravity.CENTER_HORIZONTAL);
        toastLp.bottomMargin = dp(112);
        root.addView(toastView, toastLp);

        // ---- 底部可聚焦控制条 ----
        controlBar = new ControlBar(this, this);
        root.addView(controlBar.getView(), new FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.WRAP_CONTENT, Gravity.BOTTOM));

        // ---- 右侧频道面板 / 全屏检索（依赖清单，缺失时不创建）----
        if (catalog != null) {
            channelPanel = new ChannelPanel(this, catalog, prefs, this);
            root.addView(channelPanel.getView(), new FrameLayout.LayoutParams(
                    dp(400), FrameLayout.LayoutParams.MATCH_PARENT, Gravity.RIGHT));

            searchPanel = new SearchPanel(this, catalog, prefs, this);
            root.addView(searchPanel.getView(), new FrameLayout.LayoutParams(
                    FrameLayout.LayoutParams.MATCH_PARENT,
                    FrameLayout.LayoutParams.MATCH_PARENT));

            regionPanel = new RegionPanel(this, catalog, prefs, this);
            root.addView(regionPanel.getView(), new FrameLayout.LayoutParams(
                    FrameLayout.LayoutParams.MATCH_PARENT,
                    FrameLayout.LayoutParams.MATCH_PARENT));
        }

        // ---- 信息 / 诊断页 ----
        helpView = new TextView(this);
        helpView.setTextColor(Ui.TEXT);
        helpView.setTextSize(16);
        helpView.setBackgroundColor(0xF00B1220);
        helpView.setPadding(dp(30), dp(22), dp(30), dp(22));
        helpView.setVisibility(View.GONE);
        helpView.setLineSpacing(dp(4), 1f);
        root.addView(helpView, new FrameLayout.LayoutParams(
                dp(760), FrameLayout.LayoutParams.WRAP_CONTENT, Gravity.CENTER));

        // ---- 设置页（全屏浮层，放在最上层；设置页本身不做空闲自动隐藏）----
        settingsPanel = new SettingsPanel(this, prefs, this);
        root.addView(settingsPanel.getView(), new FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT));

        return root;
    }

    private int dp(int v) {
        return Ui.dp(this, v);
    }

    private void showStatus(String text) {
        if (centerStatus == null) return;
        if (text == null || text.length() == 0) {
            centerStatus.setVisibility(View.GONE);
        } else {
            centerStatus.setText(text);
            centerStatus.setVisibility(View.VISIBLE);
        }
    }

    private void showToast(String text) {
        if (toastView == null) return;
        toastView.setText(text);
        toastView.setVisibility(View.VISIBLE);
        if (toastHideTask != null) ui.removeCallbacks(toastHideTask);
        toastHideTask = new Runnable() {
            @Override
            public void run() {
                if (toastView != null) toastView.setVisibility(View.GONE);
            }
        };
        ui.postDelayed(toastHideTask, TOAST_MS);
    }

    /** 底部快捷键提示：操作后显示几秒，然后自动隐藏，避免常驻挡画面。 */
    private void showHint(boolean visible) {
        if (hintView == null) return;
        if (hintHideTask != null) ui.removeCallbacks(hintHideTask);
        hintView.setVisibility(visible ? View.VISIBLE : View.GONE);
        if (!visible) return;
        hintHideTask = new Runnable() {
            @Override
            public void run() {
                if (hintView != null && mode == MODE_PLAY) hintView.setVisibility(View.GONE);
            }
        };
        ui.postDelayed(hintHideTask, HINT_IDLE_MS);
    }

    /** 把「当前台 / 线路 / 播放状态 / 地区」同步给频道栏的底部状态卡。 */
    private void updatePanelState() {
        if (channelPanel == null || catalog == null) return;
        ChannelCatalog.Channel c = currentChannel();
        channelPanel.setPlaybackState(
                c == null ? "" : (c.num + "  " + c.name),
                "线路 " + (currentStreamIndex + 1) + "/"
                        + Math.max(1, currentStreamTotal),
                playbackStateText,
                allStreamsFailed,
                catalog.regionLabel(),
                catalog.localCount());
    }

    /** 异常态一键重试：不起新 Activity、不重建内核，直接清空记录重来。 */
    private void retryAllStreams() {
        if (playback == null) return;
        cancelFailureTasks();
        showStatus("");
        allStreamsFailed = false;
        playbackStateText = "正在重试";
        showToast("正在重试全部线路（含加密线路）");
        playback.retryAll();
        updatePanelState();
    }

    /** 取消尚未执行的「提示消失 / 自动回退」：用户一操作就以用户为准。 */
    private void cancelFailureTasks() {
        if (failHintTask != null) {
            ui.removeCallbacks(failHintTask);
            failHintTask = null;
        }
    }

    /**
     * 切到播不出的频道时，主流播放软件不会把错误框永久钉在画面中央：
     * 提示只停留「失败提示停留」设置的时间，随后自动回到上一个正常出画的
     * 频道继续播放；关闭自动回退时则收起提示，把原因留在频道栏状态卡与
     * 信息页，用户按 OK 仍可一键重试全部线路。
     */
    private void scheduleFailureDismiss(final ChannelCatalog.Channel channel) {
        cancelFailureTasks();
        final long hintMs = prefs == null ? 3000L : prefs.failHintMs();
        failHintTask = new Runnable() {
            @Override
            public void run() {
                failHintTask = null;
                showStatus("");
                if (prefs != null && prefs.failFallback()
                        && lastGoodChannel != null
                        && channel != null
                        && lastGoodChannel.num != channel.num) {
                    returnToLastGood();
                } else {
                    showToast("全部线路不可用 · 按 OK 重试 / 频道键换台");
                }
            }
        };
        ui.postDelayed(failHintTask, hintMs);
    }

    private void returnToLastGood() {
        if (catalog == null || lastGoodChannel == null) return;
        int idx = catalog.indexOfNumber(lastGoodChannel.num);
        if (idx < 0) idx = 0;
        showToast("已回到 " + lastGoodChannel.name + "（目标台全部线路不可用）");
        startChannel(idx);
    }

    // ---------------------------------------------------------------- 模式

    private void setMode(int next) {
        if (mode == next) return;
        mode = next;
        cancelControlHide();
        if (controlBar != null) controlBar.setVisible(next == MODE_CONTROL);
        if (channelPanel != null) {
            if (next == MODE_PANEL) {
                ChannelCatalog.Channel cur = currentChannel();
                int at = (catalog == null || cur == null)
                        ? -1 : catalog.indexOfNumber(cur.num);
                channelPanel.setPlayingChannel(at);
                updatePanelState();
                channelPanel.show(at >= 0 ? at : channelIndex);
            } else {
                channelPanel.hide();
            }
        }
        if (searchPanel != null) {
            if (next == MODE_SEARCH) {
                searchPanel.show();
            } else {
                searchPanel.hide();
            }
        }
        if (regionPanel != null) {
            if (next == MODE_REGION) {
                ChannelCatalog.Channel c = currentChannel();
                regionPanel.setStateText((c == null ? "" : c.name + " · ")
                        + playbackStateText);
                regionPanel.show();
            } else {
                regionPanel.hide();
            }
        }
        if (helpView != null) {
            if (next == MODE_HELP) {
                // 每次打开都从第 1 页开始：用户按菜单是为了看「当前状况」，
                // 停在上次翻到的第 2 页会让人以为页面缺了半截。
                if (mode != MODE_HELP) helpPage = 0;
                buildHelp();
                helpView.setVisibility(View.VISIBLE);
                // 读数每秒在变：静态快照看不出水位在降还是在回升，
                // 2 秒刷新一次，既有趋势感又不会让文字抖得读不清。
                scheduleHelpRefresh();
            } else {
                helpView.setVisibility(View.GONE);
                cancelHelpRefresh();
            }
        }
        if (settingsPanel != null) {
            if (next == MODE_SETTINGS) {
                settingsPanel.show();
            } else {
                settingsPanel.hide();
            }
        }
        if (hintView != null) {
            hintView.setText(next == MODE_CONTROL
                    ? "←→ 选择   OK 执行   ↑/返回 收起"
                    : next == MODE_HELP
                            ? "←→ 翻页   OK/返回 关闭   · 读数每 2 秒刷新"
                            : "OK 控制条   ↑↓ 换台   数字 直达   菜单 信息");
            // 面板与检索页自带按键提示，底部提示条再显示就会和面板页脚叠在一起。
            boolean hintWanted = next == MODE_CONTROL || next == MODE_HELP;
            hintView.setVisibility(hintWanted ? View.VISIBLE : View.GONE);
            // 控制条展开时把提示抬到它上面，否则会被按钮行盖住。
            FrameLayout.LayoutParams lp =
                    (FrameLayout.LayoutParams) hintView.getLayoutParams();
            lp.bottomMargin = next == MODE_CONTROL ? dp(68) : dp(6);
            hintView.setLayoutParams(lp);
        }
        if (next == MODE_CONTROL) {
            if (controlBar != null) {
                controlBar.setPaused(paused);
                controlBar.setFavorite(isCurrentFavorite());
            }
        }
        if (next == MODE_PLAY) {
            showHint(true);
            // 切台成功后让屏幕全屏播放：首帧已到就收掉所有 OSD。
            if (firstFrameMs >= 0) hideOsdForPlayback();
        }
        // 频道栏 / 地区 / 检索 / 控制条按同一个「浮层自动隐藏」时长收起；
        // 信息页与设置页是要读内容的界面，不做空闲自动隐藏。
        if (next == MODE_CONTROL || next == MODE_PANEL || next == MODE_SEARCH
                || next == MODE_REGION) {
            scheduleControlHide();
        }
    }

    /**
     * 首帧渲染成功后进入纯净播放：底部快捷键提示与瞬时 toast 都不再显示，
     * 画面占满整屏。
     *
     * <p>顶部信息条（截图里那条「苏州社会经济 · 地方频道 · 线路 1/2 ·
     * 首帧 720ms · API 18/legacyCompat」）已按红标批注「不管什么时候都不要
     * 显示」整体删除，不参与这里的状态收敛；诊断信息没有丢：菜单键的信息页
     * 仍然展示完整分支 / 首帧 / 清单摘要。
     */
    private void hideOsdForPlayback() {
        if (hintView != null) hintView.setVisibility(View.GONE);
        if (toastView != null) toastView.setVisibility(View.GONE);
    }

    /**
     * 通用浮层空闲计时器：控制条 / 频道栏 / 地区 / 检索共用。默认 30 秒无操作
     * 就收回全屏播放（遥控器选台节奏慢，留足时间）；设置可改成 5/10/15/20/30/60 秒
     * 或关闭。用户在任一浮层里按键时由 {@link #resetOverlayHide()} 重新计时。
     */
    private void scheduleControlHide() {
        cancelControlHide();
        if (idleHideMs <= 0) return;
        final int target = mode;
        controlHideTask = new Runnable() {
            @Override
            public void run() {
                if (mode == target) setMode(MODE_PLAY);
            }
        };
        ui.postDelayed(controlHideTask, idleHideMs);
    }

    private void resetOverlayHide() {
        if (mode == MODE_CONTROL || mode == MODE_PANEL || mode == MODE_SEARCH
                || mode == MODE_REGION) {
            scheduleControlHide();
        }
    }

    private void cancelControlHide() {
        if (controlHideTask != null) {
            ui.removeCallbacks(controlHideTask);
            controlHideTask = null;
        }
    }

    /**
     * 真正正在播的频道。地区切换会把「当前地区不可见的台」从可见列表里拿掉，
     * 但播放不该因此被打断：下标 channelIndex 只用于列表/换台定位，
     * 画面、收藏、续播、顶部信息一律以 playingChannel 为准。
     */
    private ChannelCatalog.Channel currentChannel() {
        if (playingChannel != null) return playingChannel;
        if (catalog == null || catalog.size() == 0) return null;
        return catalog.get(Math.max(0, Math.min(channelIndex, catalog.size() - 1)));
    }

    private boolean isCurrentFavorite() {
        if (catalog == null || prefs == null) return false;
        return prefs.isFavorite(currentChannel().id);
    }

    // ---------------------------------------------------------------- 播放

    private void startChannel(int index) {
        if (catalog == null || catalog.size() == 0) return;
        final int n = catalog.size();
        index = ((index % n) + n) % n;   // 循环换台，避免到头卡住
        channelIndex = index;
        playingChannel = catalog.get(index);
        currentStreamIndex = 0;
        currentStreamTotal = playingChannel.streams.size();
        firstFrameMs = -1L;
        paused = false;
        // 换台即结束上一台的失败流程：错误 OSD 与待执行的自动回退一并撤销。
        cancelFailureTasks();
        // 先盖黑幕再起播：上一台最后一帧不能出现在新台的声音里。
        showBlackout();
        showStatus("");
        allStreamsFailed = false;
        playbackStateText = "正在连接";
        numberBuffer = "";
        cancelNumberCommit();
        hideNumberPanel();
        // 换台不弹任何顶部信息条（红标：不管什么时候都不要显示），
        // 换台反馈交给画面中央的「台号 + 台名」横幅（showChannelBanner）。
        if (prefs != null) prefs.saveLast(playingChannel.num, 0);
        if (surfaceReady && playback != null && nativeLibrariesOk) {
            playback.open(playingChannel);
        } else if (nativeLibrariesOk) {
            showStatus("画面未就绪…");
        }
        showHint(true);
        showChannelBanner();
    }

    /**
     * 连续换台（控制条上/下台、频道键）：跳过台账里无可用线路的台。
     *
     * <p>与频道栏点选 / 数字直达区分开：那两条是「用户明确点名」，即使台账
     * 不可达也照常进入并逐条试线，不能用「自动跳过」把用户的意图吞掉。
     */
    private void startChannelSkippingDead(int index, int dir) {
        int target = resolvePlayable(index, dir);
        int skipped = deadSkipCount;
        startChannel(target);
        if (skipped > 0) showToast("已跳过 " + skipped + " 个无可用线路的频道");
    }

    /**
     * 换台 / 换线时盖黑幕，首帧到达再撤（M0 / E2）。
     *
     * <p>兜底 2.5 秒：有的流不报 {@code VIDEO_RENDERING_START}，如果只靠首帧
     * 撤幕，遇到这类源就会永远黑屏——那比留一帧旧画面更糟。2.5 秒覆盖了
     * 本机绝大多数起播（CCTV-1 实测约 0.7 秒），超时后宁可露出旧帧。
     */
    private void showBlackout() {
        if (blackoutView == null) return;
        blackoutView.setVisibility(View.VISIBLE);
        cancelBlackout();
        blackoutTask = new Runnable() {
            @Override
            public void run() {
                blackoutTask = null;
                hideBlackout();
            }
        };
        ui.postDelayed(blackoutTask, 2500L);
    }

    private void hideBlackout() {
        cancelBlackout();
        if (blackoutView != null) blackoutView.setVisibility(View.GONE);
    }

    private void cancelBlackout() {
        if (blackoutTask != null) {
            ui.removeCallbacks(blackoutTask);
            blackoutTask = null;
        }
    }

    /**
     * 换台横幅：主流电视端换台都会在画面中央短暂显示「台号 + 台名」，
     * 否则用户连按几次之后不知道自己停在哪一台。1.5 秒自动消失。
     */
    private void showChannelBanner() {
        if (numberPanel == null || catalog == null || catalog.size() == 0) return;
        if (numberBuffer.length() > 0) return;   // 正在输入台号时不抢浮层
        // 连按换台时先把**目标台**显示出来（起播延后提交），遥控器手感靠这个。
        ChannelCatalog.Channel c = zapTarget >= 0 && zapTarget < catalog.size()
                ? catalog.get(zapTarget) : currentChannel();
        numberDigits.setText(String.valueOf(c.num));
        numberTarget.setText(c.name);
        numberPanel.setVisibility(View.VISIBLE);
        if (bannerHideTask != null) ui.removeCallbacks(bannerHideTask);
        bannerHideTask = new Runnable() {
            @Override
            public void run() {
                // 期间若用户开始输数字，浮层归数字直达使用，不要抢着隐藏。
                if (numberBuffer.length() == 0) hideNumberPanel();
            }
        };
        ui.postDelayed(bannerHideTask, 1500L);
    }

    /** 连按合并：先动中央横幅，280ms 后再真正起播。 */
    private void zap(int delta) {
        if (catalog == null || catalog.size() == 0) return;
        final int n = catalog.size();
        final int dir = delta >= 0 ? 1 : -1;
        int base = zapTarget >= 0 ? zapTarget : channelIndex;
        int desired = ((base + delta) % n + n) % n;
        // 台账里整台无一条可达线路的频道（1046 台里有 434 台）点进去注定是
        // 8 秒黑屏再报错，换台时直接跳过，用户按键才是「立刻有反应」。
        // 频道栏 / 数字直达仍可手动进入，进台后照常逐条试线。
        int target = resolvePlayable(desired, dir);
        zapSkippedDead = deadSkipCount;
        zapTarget = target;
        // 顶部信息条已删除，连按期间的即时反馈改用中央「台号 + 台名」横幅。
        showChannelBanner();
        ui.removeCallbacks(zapCommitTask);
        ui.postDelayed(zapCommitTask, zapCommitMs);
    }

    /**
     * 从 index 出发沿 dir 方向找到第一条「台账里有可达线路」的台。
     *
     * <p>只用于连续换台（↑↓ / 频道键）：一圈全是无可用线路的台时保持原样，
     * 不做「无目的跳转」。跳过的条数记在 {@link #deadSkipCount}，由换台提交
     * 时一次性提示，连按过程中不刷屏。
     */
    private int resolvePlayable(int index, int dir) {
        deadSkipCount = 0;
        if (catalog == null || catalog.size() == 0) return index;
        final int n = catalog.size();
        int idx = ((index % n) + n) % n;
        for (int i = 0; i < n; i++) {
            if (catalog.get(idx).hasReachableStream()) {
                deadSkipCount = i;
                return idx;
            }
            idx = ((idx + dir) % n + n) % n;
        }
        return ((index % n) + n) % n;
    }

    private void switchStream(int delta) {
        if (catalog == null || playback == null) return;
        int total = currentChannel().streams.size();
        if (total <= 1) {
            showToast("这个台只有 1 条线路");
            return;
        }
        int next = ((playback.currentStreamIndex() + delta) % total + total) % total;
        paused = false;
        // 换线路同样会重建内核，旧帧会留在 surface 上，一并盖黑幕。
        showBlackout();
        playback.switchTo(next);
        showToast("线路 " + (next + 1) + "/" + total);
    }

    @Override
    public void surfaceCreated(SurfaceHolder holder) {
        surfaceReady = true;
        if (!nativeLibrariesOk || catalog == null) return;
        playback = new PlaybackController(this, holder, this);
        applyPlaybackSettings();
        int startStream = prefs == null ? 0 : prefs.lastStream();
        playback.open(currentChannel(), startStream);
    }

    @Override
    public void surfaceChanged(SurfaceHolder holder, int format, int width, int height) {
        // 尺寸变化不影响 FFmpeg 输出：SurfaceView 会自行缩放。
    }

    @Override
    public void surfaceDestroyed(SurfaceHolder holder) {
        surfaceReady = false;
        if (playback != null) {
            playback.release();
            playback = null;
        }
    }

    @Override
    protected void onResume() {
        super.onResume();
        // 从后台回来时 surface 可能仍有效但 controller 已在 onPause 释放。
        if (surfaceReady && playback == null && nativeLibrariesOk && catalog != null) {
            SurfaceHolder h = surfaceView.getHolder();
            if (h.getSurface() != null && h.getSurface().isValid()) {
                playback = new PlaybackController(this, h, this);
                applyPlaybackSettings();
                playback.open(currentChannel());
            }
        }
    }

    @Override
    protected void onPause() {
        saveLastPosition();
        if (playback != null) {
            playback.release();
            playback = null;
        }
        super.onPause();
    }

    @Override
    protected void onDestroy() {
        ui.removeCallbacksAndMessages(null);
        if (playback != null) {
            playback.release();
            playback = null;
        }
        super.onDestroy();
    }

    private void saveLastPosition() {
        if (catalog == null || prefs == null) return;
        try {
            prefs.saveLast(currentChannel().num, currentStreamIndex);
        } catch (Throwable ignored) {
        }
    }

    // ------------------------------------------------- PlaybackController.Listener

    @Override
    public void onState(String text) {
        showStatus(text);
        if (text != null && text.length() > 0) {
            playbackStateText = text;
            updatePanelState();
        }
    }

    @Override
    public void onStreamChanged(int index, int total, ChannelCatalog.Stream stream) {
        currentStreamIndex = index;
        currentStreamTotal = total;
        firstFrameMs = -1L;
        allStreamsFailed = false;
        playbackStateText = "正在连接";
        updatePanelState();
    }

    @Override
    public void onFirstFrame(long elapsedMs, ChannelCatalog.Stream stream) {
        firstFrameMs = elapsedMs;
        allStreamsFailed = false;
        // 首帧已上屏：撤黑幕（含兜底任务的取消）。
        hideBlackout();
        // 只在真正出画后记「上一个好台」：切台全失败时回退到这里，
        // 不会把「正在连接 / 缓冲中」的中间态误记成可回退目标。
        lastGoodChannel = currentChannel();
        lastGoodStreamIndex = currentStreamIndex;
        playbackStateText = "播放中";
        showStatus("");
        hideOsdForPlayback();
        updatePanelState();
        if (catalog != null && prefs != null) {
            prefs.saveLast(currentChannel().num, currentStreamIndex);
        }
    }

    @Override
    public void onStreamFailed(int index, int what, String reason) {
        // 下一条线路会立刻接上，这里只做短暂提示，不常驻遮挡画面。
        playbackStateText = "线路 " + (index + 1) + " 失败，切换中";
        updatePanelState();
        showStatus("线路 " + (index + 1) + "/" + currentStreamTotal + " 失败："
                + reason + "\n正在切换下一条…");
    }

    @Override
    public void onAllStreamsFailed(ChannelCatalog.Channel channel, String reason) {
        allStreamsFailed = true;
        // 全失败时黑幕撤掉：错误提示本身有半透明底，盖在黑幕上更易读，
        // 也避免用户以为「黑屏 = 死机」。
        hideBlackout();
        playbackStateText = "全部线路不可用";
        updatePanelState();
        // 异常必须说清「哪一台 / 试了几条 / 为什么 / 怎么恢复」，但**不能常驻**：
        // 定时收起，并按设置自动回到上一个正常出画的频道（主流播放软件流程）。
        final int tried = channel == null ? 0 : channel.streams.size();
        final String name = channel == null ? "当前频道" : channel.name;
        final boolean willFallback = prefs != null && prefs.failFallback()
                && lastGoodChannel != null && channel != null
                && lastGoodChannel.num != channel.num;
        showStatus(name + "：全部 " + tried + " 条线路不可用\n" + reason
                + "\n按 OK 重试 · ←→ 换线 · 频道键换台"
                + (willFallback ? "\n数秒后自动回到 " + lastGoodChannel.name : ""));
        showToast("目标台全部线路不可用");
        scheduleFailureDismiss(channel);
    }

    /**
     * 当前这条线路硬解不可用 → 该线路改用软解（**只影响这条线路**）。
     *
     * <p><b>不写设置</b>：真机反馈「有的台可以硬解、有的台只能软解」，上一版把
     * 设置改成软解，等于让所有能硬解的台一起被降级，而且重启后还是软解。
     * 这里只提示，把「这条线路以后直接用软解」交给线路记忆（7 天后过期自愈）。
     */
    @Override
    public void onDecodeFallback(String reason) {
        showToast("本线路不支持硬解（" + reason + "），已改为软解播放 · 其他频道仍用硬解");
    }

    /**
     * 控制条按钮被执行。
     *
     * <p>复用快捷键的同一批入口（togglePause / switchStream / retryAllStreams 等），
     * 不另写一套——按钮能用、快捷键不能用这种事，用户根本没法描述。
     */
    @Override
    public void onControlAction(String action) {
        scheduleControlHide();
        if (ControlBar.A_PANEL.equals(action)) {
            setMode(MODE_PANEL);
        } else if (ControlBar.A_PREV.equals(action)) {
            startChannelSkippingDead(channelIndex - 1, -1);
        } else if (ControlBar.A_NEXT.equals(action)) {
            startChannelSkippingDead(channelIndex + 1, 1);
        } else if (ControlBar.A_PAUSE.equals(action)) {
            togglePause();
            if (controlBar != null) controlBar.setPaused(paused);
        } else if (ControlBar.A_LINE.equals(action)) {
            switchStream(1);
        } else if (ControlBar.A_FAV.equals(action)) {
            toggleFavoriteCurrent();
            if (controlBar != null) controlBar.setFavorite(isCurrentFavorite());
        } else if (ControlBar.A_REGION.equals(action)) {
            setMode(MODE_REGION);
        } else if (ControlBar.A_RETRY.equals(action)) {
            setMode(MODE_PLAY);
            retryAllStreams();
        } else if (ControlBar.A_SEARCH.equals(action)) {
            setMode(MODE_SEARCH);
        } else if (ControlBar.A_SETTINGS.equals(action)) {
            setMode(MODE_SETTINGS);
        } else if (ControlBar.A_INFO.equals(action)) {
            setMode(MODE_HELP);
        }
    }

    /**
     * 控制条焦点变化：只重置浮层空闲计时。
     *
     * <p>这里**不改提示条文案**——控制条的按键提示是固定的一句
     * 「←→ 选择 OK 执行 ↑/返回 收起」，按焦点改文案反而让人读到一半就变。
     * 用户移动焦点本身说明他还在操作，所以只把自动收起往后推。
     */
    @Override
    public void onControlFocus(String action) {
        scheduleControlHide();
    }

    @Override
    public void onFavoriteToggled(int index, boolean nowFavorite) {
        final String name = catalog.get(index).name;
        showToast((nowFavorite ? "已收藏 " : "已取消收藏 ") + name);
        if (controlBar != null) controlBar.setFavorite(isCurrentFavorite());
    }

    @Override
    public void onChannelPicked(int index) {
        setMode(MODE_PLAY);
        startChannel(index);
    }

    @Override
    public void onSearchPick(int channelIndex) {
        setMode(MODE_PLAY);
        startChannel(channelIndex);
    }

    /**
     * 切地区：只换「可见的台集合」，**不打断正在播的节目**。
     *
     * <p>这是早就踩过的坑：切地区时若重新起播，用户正在看的台会黑一下。
     * 所以只在「原来那一台在新地区里已经不存在」时才调 channelIndex，
     * playingChannel 本身不动。
     */
    @Override
    public void onRegionPicked(String mode, String province, String city) {
        if (catalog == null) return;
        final ChannelCatalog.Channel current = currentChannel();
        final int currentNum = current == null ? -1 : current.num;
        catalog.setRegion(mode, province, city);
        if (prefs != null) prefs.saveRegion(mode, province, city);
        final int at = catalog.indexOfNumber(currentNum);
        final int size = catalog.size();
        if (size > 0) {
            if (at >= 0) {
                channelIndex = at;
            } else {
                channelIndex = Math.max(0, Math.min(channelIndex, size - 1));
            }
        }
        if (at >= 0) {
            if (channelPanel != null) channelPanel.setPlayingChannel(at);
        } else {
            if (channelPanel != null) channelPanel.setPlayingChannel(-1);
        }
        showToast("已切换到 " + catalog.regionLabel() + " · " + catalog.localCount()
                + " 个地方台（播放不中断）");
        updatePanelState();
        setMode(MODE_PANEL);
    }

    @Override
    public void onRegionRequested() {
        if (regionPanel != null) setMode(MODE_REGION);
    }

    @Override
    public void onSettingChanged(String key, int value) {
        // 每一项都是即时生效：重排线路、改手感参数、改超时 / 解码 / 画面比例。
        applySettings();
        if (Prefs.K_PANEL_IDLE_MS.equals(key)) {
            showToast(value == 0 ? "浮层自动隐藏：已关闭"
                    : "浮层自动隐藏：" + (value / 1000) + " 秒");
        } else if (Prefs.K_BOOT_AUTOSTART.equals(key)) {
            showToast(value != 0
                    ? "开机自启已开 · 部分电视还需在系统自启管理里放行"
                    : "开机自启已关闭");
        } else if (Prefs.K_HARD_DECODE.equals(key)) {
            // 解码方式即时生效（会重建当前线路），说清楚「其他台不受影响」，
            // 否则用户会以为一切都被改成硬解了。
            showToast(value != 0
                    ? "已切硬解 · 不支持的线路会自动用软解，其他台不受影响"
                    : "已切回软解");
        }
    }

    @Override
    public void onClearFavorites() {
        if (prefs != null) prefs.clearFavorites();
        showToast("收藏已清空");
        if (channelPanel != null) channelPanel.setPlayingChannel(
                playingChannel == null ? -1 : catalog.indexOfNumber(playingChannel.num));
        updatePanelState();
    }

    @Override
    public void onResetSettings() {
        if (prefs != null) prefs.resetSettings();
        applySettings();
        showToast("设置已恢复默认（收藏与地区保留）");
    }

    @Override
    public void onAboutRequested() {
        setMode(MODE_HELP);
    }

    @Override
    public void onRegionFromSettings() {
        // 设置菜单里的「地区切换」：直接打开省 / 市选择面板，
        // setMode 会收起设置页并显示地区面板，不回退到播放态。
        if (regionPanel != null) setMode(MODE_REGION);
    }

    /**
     * 手动「音画立即对齐」：按当前位置 seek 一次，重锚内核的 frame_timer。
     *
     * <p>真机上「声音比画面快」有两种可能：起播相位差（seek 一次就好）和持续漂移
     * （seek 只能缓解）。先让用户按一次，按了有效的说明是前者——这比用一个
     * 两份读数互相矛盾的指标去自动 seek 要诚实。
     */
    @Override
    public void onReanchorRequested() {
        if (playback == null) {
            showToast("播放器未就绪");
            return;
        }
        final String problem = playback.reanchorNow();
        showToast(problem == null ? "已重新对齐音画" : problem);
    }

    // ---------------------------------------------------------------- 遥控器

    @Override
    public boolean onKeyDown(int keyCode, KeyEvent event) {
        // 启动兜底态：控件树没建起来，只留下「看记录 / 退出」两个动作，
        // 其余按键一律吞掉，防止连锁 NPE 把原始异常冲掉。
        if (fatal) {
            if (keyCode == KeyEvent.KEYCODE_MENU || keyCode == KeyEvent.KEYCODE_INFO) {
                showFatalLast();
            } else if (keyCode == KeyEvent.KEYCODE_BACK
                    || keyCode == KeyEvent.KEYCODE_ESCAPE) {
                finish();
            }
            return true;
        }

        // 任何一次按键都视为「用户还在操作」：重置浮层空闲计时；同时撤销
        // 尚未执行的失败自动回退（用户主动换台 / 重试优先于自动回退）。
        resetOverlayHide();
        cancelFailureTasks();

        if (mode == MODE_SETTINGS && settingsPanel != null) {
            settingsPanel.handleKey(keyCode);
            // 「关于」动作会在 handleKey 里把模式改成 MODE_HELP，此时不能
            // 再把它抢回播放态（与地区面板那一处交互坑同理）。
            if (mode == MODE_SETTINGS && !settingsPanel.isVisible()) {
                setMode(MODE_PLAY);
            }
            return true;
        }

        // 信息页：←→ 翻页（内容超过一屏），其余键关闭
        if (mode == MODE_HELP) {
            if (keyCode == KeyEvent.KEYCODE_DPAD_LEFT
                    || keyCode == KeyEvent.KEYCODE_DPAD_RIGHT) {
                if (helpPages > 1) {
                    final int dir = keyCode == KeyEvent.KEYCODE_DPAD_RIGHT ? 1 : -1;
                    helpPage = ((helpPage + dir) % helpPages + helpPages) % helpPages;
                    buildHelp();
                }
                return true;
            }
            if (keyCode == KeyEvent.KEYCODE_MENU || keyCode == KeyEvent.KEYCODE_INFO
                    || keyCode == KeyEvent.KEYCODE_BACK
                    || keyCode == KeyEvent.KEYCODE_DPAD_CENTER
                    || keyCode == KeyEvent.KEYCODE_ENTER
                    || keyCode == KeyEvent.KEYCODE_ESCAPE) {
                setMode(MODE_PLAY);
            }
            return true;
        }

        if (mode == MODE_SEARCH && searchPanel != null) {
            if (keyCode == KeyEvent.KEYCODE_BACK && searchPanel.getQuery().length() == 0) {
                setMode(MODE_PLAY);
                return true;
            }
            if (searchPanel.handleKey(keyCode)) return true;
            return true;
        }

        if (mode == MODE_REGION && regionPanel != null) {
            regionPanel.handleKey(keyCode);
            // 返回键会把面板自己 hide()，模式必须跟着回落，否则后续按键
            // 继续投给一个已隐藏的面板，表现又是「遥控器失灵」。
            if (!regionPanel.isVisible()) setMode(MODE_PANEL);
            return true;
        }

        if (mode == MODE_PANEL && channelPanel != null) {
            boolean handled = channelPanel.handleKey(keyCode);
            // 面板自己按返回会 hide()，此时模式必须跟着回落，否则
            // 后续按键会继续投给一个已隐藏的面板，表现就是「遥控器失灵」。
            // 但「点地区 chip / 绿键 / 状态卡」也会 hide() 并主动切到
            // MODE_REGION：只有模式仍停在 MODE_PANEL 时才能回落，
            // 否则会把刚打开的地区面板又关掉（本轮实测出的交互坑）。
            if (!channelPanel.isVisible() && mode == MODE_PANEL) {
                setMode(MODE_PLAY);
                return true;
            }
            if (handled) return true;
            // 面板不处理的键（例如数字键）交回播放态：数字直达仍然可用
        }

        if (mode == MODE_CONTROL && controlBar != null) {
            if (handleControlKey(keyCode)) return true;
        }

        return handlePlayKey(keyCode, event);
    }

    private boolean handleControlKey(int keyCode) {
        switch (keyCode) {
            case KeyEvent.KEYCODE_DPAD_LEFT:
                controlBar.move(-1);
                return true;
            case KeyEvent.KEYCODE_DPAD_RIGHT:
                controlBar.move(1);
                return true;
            case KeyEvent.KEYCODE_DPAD_CENTER:
            case KeyEvent.KEYCODE_ENTER:
                controlBar.activate();
                return true;
            case KeyEvent.KEYCODE_DPAD_UP:
            case KeyEvent.KEYCODE_BACK:
            case KeyEvent.KEYCODE_ESCAPE:
                setMode(MODE_PLAY);
                return true;
            case KeyEvent.KEYCODE_DPAD_DOWN:
                // 控制条已展开时按下键不换台：很多人会习惯性多按一下方向键，
                // 这里吞掉比「顺手把台切走」更不容易误操作。
                return true;
            case KeyEvent.KEYCODE_MENU:
            case KeyEvent.KEYCODE_INFO:
                setMode(MODE_HELP);
                return true;
            case KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE:
                togglePause();
                controlBar.setPaused(paused);
                return true;
            default:
                return false;
        }
    }

    private boolean handlePlayKey(int keyCode, KeyEvent event) {
        if (keyCode >= KeyEvent.KEYCODE_0 && keyCode <= KeyEvent.KEYCODE_9) {
            appendNumber(keyCode - KeyEvent.KEYCODE_0);
            return true;
        }
        switch (keyCode) {
            case KeyEvent.KEYCODE_DPAD_UP:
            case KeyEvent.KEYCODE_CHANNEL_UP:
                zap(-1);
                return true;
            case KeyEvent.KEYCODE_DPAD_DOWN:
            case KeyEvent.KEYCODE_CHANNEL_DOWN:
                zap(1);
                return true;
            case KeyEvent.KEYCODE_DPAD_LEFT:
            case KeyEvent.KEYCODE_MEDIA_PREVIOUS:
                switchStream(-1);
                return true;
            case KeyEvent.KEYCODE_DPAD_RIGHT:
            case KeyEvent.KEYCODE_MEDIA_NEXT:
                switchStream(1);
                return true;
            case KeyEvent.KEYCODE_DPAD_CENTER:
            case KeyEvent.KEYCODE_ENTER:
                if (numberBuffer.length() > 0) {
                    commitNumber();
                } else if (allStreamsFailed) {
                    // 已经报「全部线路不可用」时，OK 就是「重试」，
                    // 不再让用户先打开控制条再找按钮。
                    retryAllStreams();
                } else {
                    setMode(MODE_CONTROL);
                }
                return true;
            case KeyEvent.KEYCODE_PROG_GREEN:
            case KeyEvent.KEYCODE_GUIDE:
                // 绿键 / 导视键：任何界面下都直达地区选择。
                if (regionPanel != null) setMode(MODE_REGION);
                return true;
            case KeyEvent.KEYCODE_PROG_BLUE:
            case KeyEvent.KEYCODE_SETTINGS:
                // 蓝键 / 设置键：直达设置页；控制条里也有「设置」按钮。
                if (settingsPanel != null) setMode(MODE_SETTINGS);
                return true;
            case KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE:
                togglePause();
                return true;
            case KeyEvent.KEYCODE_MENU:
            case KeyEvent.KEYCODE_INFO:
                setMode(MODE_HELP);
                return true;
            case KeyEvent.KEYCODE_STAR:
            case KeyEvent.KEYCODE_PROG_RED:
                toggleFavoriteCurrent();
                return true;
            case KeyEvent.KEYCODE_SEARCH:
            case KeyEvent.KEYCODE_EXPLORER:
            case KeyEvent.KEYCODE_ASSIST:
                if (searchPanel != null) setMode(MODE_SEARCH);
                return true;
            case KeyEvent.KEYCODE_BACK:
                return onBackPressedCompat();
            case KeyEvent.KEYCODE_MEDIA_STOP:
            case KeyEvent.KEYCODE_ESCAPE:
                finish();
                return true;
            default:
                return super.onKeyDown(keyCode, event);
        }
    }

    private void toggleFavoriteCurrent() {
        if (catalog == null || prefs == null) return;
        ChannelCatalog.Channel c = currentChannel();
        boolean now = prefs.toggleFavorite(c.id);
        showToast(now ? "已收藏 " + c.name : "已取消收藏 " + c.name);
    }

    private void togglePause() {
        if (playback == null) return;
        paused = playback.togglePause();
        showStatus(paused ? "已暂停 · 再按播放键继续" : "");
        // 暂停 / 继续的反馈由中央状态承担（顶部信息条已删除）；
        // 恢复播放且已出画时把底部提示重新收起，回到纯净全屏。
        if (!paused && firstFrameMs >= 0) hideOsdForPlayback();
    }

    private boolean onBackPressedCompat() {
        if (numberBuffer.length() > 0) {
            numberBuffer = "";
            cancelNumberCommit();
            hideNumberPanel();
            return true;
        }
        long now = SystemClock.uptimeMillis();
        if (now - lastBackMs < BACK_DOUBLE_MS) {
            finish();
            return true;
        }
        lastBackMs = now;
        showToast("再按一次返回退出");
        return true;
    }

    // ---------------------------------------------------------------- 台号直达

    private void appendNumber(int digit) {
        // 最多 4 位（清单已到 1046 台），超长从新的一位重新开始，避免溢出。
        if (numberBuffer.length() >= 4) numberBuffer = "";
        numberBuffer += String.valueOf(digit);
        showNumberPanel();
        cancelNumberCommit();
        numberCommitTask = new Runnable() {
            @Override
            public void run() {
                commitNumber();
            }
        };
        ui.postDelayed(numberCommitTask, numberCommitMs);
    }

    private void showNumberPanel() {
        if (numberPanel == null) return;
        if (bannerHideTask != null) ui.removeCallbacks(bannerHideTask);
        numberDigits.setText(numberBuffer);
        int num = -1;
        try {
            num = Integer.parseInt(numberBuffer);
        } catch (NumberFormatException ignored) {
        }
        int idx = (catalog == null || num < 0) ? -1 : catalog.indexOfNumber(num);
        numberTarget.setText(idx < 0
                ? (catalog == null ? "" : "没有台号（范围 1–" + catalog.maxNumber() + "）")
                : catalog.get(idx).name);
        numberPanel.setVisibility(View.VISIBLE);
    }

    private void hideNumberPanel() {
        if (numberPanel != null) numberPanel.setVisibility(View.GONE);
    }

    private void cancelNumberCommit() {
        if (numberCommitTask != null) {
            ui.removeCallbacks(numberCommitTask);
            numberCommitTask = null;
        }
    }

    private void commitNumber() {
        cancelNumberCommit();
        if (numberBuffer.length() == 0) return;
        int num;
        try {
            num = Integer.parseInt(numberBuffer);
        } catch (NumberFormatException e) {
            numberBuffer = "";
            hideNumberPanel();
            return;
        }
        numberBuffer = "";
        hideNumberPanel();
        if (catalog == null) {
            return;
        }
        int idx = catalog.indexOfNumber(num);
        if (idx < 0) {
            showToast("没有台号 " + num + "（范围 1–" + catalog.maxNumber() + "）");
        } else {
            // 数字直达是从任何模式发起的：收起面板/检索页，回到播放态。
            if (mode != MODE_PLAY) setMode(MODE_PLAY);
            startChannel(idx);
        }
    }

    // ---------------------------------------------------------------- 诊断页

    private void buildHelp() {
        buildHelp(false);
    }

    /**
     * @param periodic true = 诊断页打开期间的 2 秒自动刷新。
     *                 刷新时跳过崩溃记录读取（读文件，没必要每秒做一次）。
     */
    private void buildHelp(boolean periodic) {
        StringBuilder b = new StringBuilder();
        b.append("顺播兼容版 1.0.4 · 原生分支\n\n");
        b.append(decision.diagnosticText()).append("\n\n");
        b.append("清单：").append(catalog == null ? "不可用" : catalog.summary()).append('\n');
        // 4K 门槛：把「为什么没有 4K 台 / 为什么 CCTV-4K 不见了」写清楚，
        // 否则用户只会当成丢台。判据是四条硬条件 + 一条运行时开关（硬解/软解）。
        DeviceCapability.Info cap = DeviceCapability.inspect(this);
        b.append("4K：").append(cap.verdict(prefs != null && prefs.hardDecode())).append('\n');
        b.append("    ").append(cap.detail()).append('\n');
        if (catalog != null && catalog.qualityCeiling > 0) {
            b.append("    已剥离 ").append(catalog.dropped4KStreams).append(" 条 2160 线路")
                    .append("、隐藏 ").append(catalog.hidden4KChannels).append(" 个 4K 台");
            if (catalog.kept4KFallbacks > 0) {
                b.append("，另保留 ").append(catalog.kept4KFallbacks)
                        .append(" 条标错清晰度的兜底线路");
            }
            b.append('\n');
        }
        if (catalog != null) {
            b.append("地区：").append(catalog.regionLabel())
                    .append("（频道栏「地区」分组按 OK 切省 / 切市）\n");
        }
        if (catalog != null && catalog.probeAt != null && catalog.probeAt.length() > 0) {
            b.append("台账：").append(catalog.probeAt)
                    .append("（PC 侧 m3u8 + 首分片可达性，不等价于解码）\n");
        }
        if (prefs != null) {
            b.append("收藏：").append(prefs.favoriteCount()).append(" 台")
                    .append(" · 上次观看：")
                    .append(prefs.lastNum() > 0 ? ("第 " + prefs.lastNum() + " 台") : "无")
                    .append(" · 偏好版本 v").append(Prefs.SCHEMA).append('\n');
        }
        if (prefs != null) {
            b.append("设置：自启 ").append(prefs.bootAutostart() ? "开" : "关")
                    .append(" · 启动直达 ").append(prefs.bootDirectPlay() ? "开" : "关")
                    .append(" · 浮层隐藏 ")
                    .append(prefs.panelIdleMs() == 0
                            ? "不隐藏" : (prefs.panelIdleMs() / 1000) + " 秒")
                    .append(" · 失败回退 ").append(prefs.failFallback() ? "开" : "关")
                    .append(" · 自动换线 ").append(prefs.autoFailover() ? "开" : "关")
                    .append(" · 解码 ").append(prefs.hardDecode() ? "硬解" : "软解")
                    .append('\n');
        }
        // 解码一行分开说清「设置要什么 / 这条线路实际用什么 / 有多少条线路硬解不适配」。
        // 真机上「有的台能硬解、有的台只能软解」，只报一个词是看不出差别的。
        if (prefs != null) {
            final boolean usingHard = playback == null ? prefs.hardDecode()
                    : playback.usingHardDecode();
            b.append("解码：实际 ").append(usingHard ? "硬解 MediaCodec" : "软解 FFmpeg");
            if (playback != null && playback.hardDecodePreferred() && !usingHard) {
                b.append(" · 本线路硬解不适配，已自动用软解（其他台不受影响）");
            } else if (prefs.hardDecode()) {
                b.append(" · 设置：硬解（API 18 上不稳定，花屏 / 无声请改回软解）");
            } else {
                b.append(" · 设置：软解");
            }
            final int unfit = playback == null ? 0 : playback.hardUnfitCount();
            if (unfit > 0) {
                b.append(" · 已记 ").append(unfit).append(" 条线路硬解不适配（7 天后自动重试）");
            }
            b.append('\n');
        }
        if (catalog != null) {
            b.append("高清线路 ").append(catalog.highDefinitionStreamCount())
                    .append(" 条 · 扩展线路 ").append(catalog.extraStreamCount())
                    .append(" 条 · 标清线路 ")
                    .append(catalog.qualityStreamCount()).append(" 条\n");
        }
        // 语义分页：往上都是「这台是什么」，往下都是「现在播得怎么样」。
        b.append('\f');
        // 音画同步探针：把「画面延迟」的锅分到正确的一侧，避免一出问题就盲调参数。
        // 口径是 Δ播放位置/Δ墙钟，位置读的是内核的音频主时钟。
        double clockRate = playback == null ? 0.0 : playback.clockRate();
        int clockSamples = playback == null ? 0 : playback.clockSampleCount();
        b.append("时钟：");
        if (clockSamples <= 0 || clockRate <= 0.0) {
            b.append("采样中（每 10 秒一个窗口）\n");
        } else {
            b.append(String.format(Locale.US, "%.3f", clockRate));
            if (clockRate > 1.01) {
                b.append(" · 音频偏快，疑采样率 / 时钟错配（与解码无关）");
            } else if (clockRate < Tuning.STALL_RATE) {
                // 0.169 这类读数就是「画面基本不动」，连续两个窗口会自动处置。
                // 但 0.004 配 13 秒缓存是分片边界重置的假象，必须与缓存一起判。
                final long cachedMs = playback == null ? -1L : playback.quality().videoCachedMs();
                if (cachedMs >= Tuning.STALL_MAX_CACHE_MS) {
                    b.append(" · 读数偏低但缓存充足（").append(cachedMs)
                            .append(" ms），疑似分片边界重置，不处置");
                } else if (cachedMs < 0) {
                    b.append(" · 读数偏低且缓存读数不可用，按停滞观察（不处置）");
                } else {
                    b.append(" · 画面停滞（低于 ")
                            .append(String.format(Locale.US, "%.2f", Tuning.STALL_RATE))
                            .append(" 且缓存见底，连续 ").append(Tuning.STALL_WINDOWS)
                            .append(" 个窗口自动换线 / 重连）");
                }
            } else if (clockRate < 0.99) {
                b.append(" · 位置推进偏慢，疑缓冲拖住");
            } else {
                b.append(" · 正常，偏差应在视频侧（渲染 / 解码）");
            }
            b.append(" · 窗口 ").append(clockSamples).append(" 个\n");
        }
        int bufferHits = playback == null ? 0 : playback.bufferHitsInWindow();
        b.append("画面：最近 60 秒缓冲 ").append(bufferHits).append(" 次")
                .append(bufferHits >= 3 ? "（已达自动换线阈值）" : "").append('\n');
        // 运行时读数（M0）：码率 / 缓存水位 / 丢帧 / 实际分辨率。
        // 只读，不参与决策；它的用途是让「清晰度是真是假」「卡顿是不是马上来」
        // 这两件事第一次有数字可看，而不是等用户说「糊」「卡」。
        if (playback != null) {
            b.append(playback.quality().summary());
        } else {
            b.append("读数：本次会话尚未起播\n");
        }
        // 手动对齐 A/B：上一轮让用户「按一次再看帧率」，但页面只记次数、不记按前的
        // 帧率，用户按了 3 次也看不出有没有效果 —— 这是取证设计的缺口，不是操作问题。
        // 这里把「按下时探针最近一次采样」与「现在」并排写，按一次就能一拍定案：
        // 回升 = frame_timer 落后可修；持平 = 持续 PTS 错位 / 资源问题，别再按了。
        if (playback != null) {
            final long since = playback.reanchorSinceSeconds();
            final int before = playback.reanchorBeforeFpsCenti();
            final int nowFps = playback.quality().outputFpsCenti();
            b.append("对齐：");
            if (since < 0L) {
                b.append("本线路未按过（异常态按一次，等 5 秒再看）");
            } else {
                b.append("按前 ")
                        .append(before >= 0 ? String.format(Locale.US, "%.2f", before / 100.0) : "读不到")
                        .append(" → 现在 ")
                        .append(nowFps >= 0 ? String.format(Locale.US, "%.2f", nowFps / 100.0) : "读不到");
                if (before >= 0 && nowFps >= 0) {
                    final int d = nowFps - before;
                    if (d > 200) {
                        b.append("（回升 ").append(String.format(Locale.US, "%.2f", d / 100.0)).append("）");
                    } else if (d < -200) {
                        b.append("（下滑 ").append(String.format(Locale.US, "%.2f", -d / 100.0)).append("）");
                    } else {
                        b.append("（持平）");
                    }
                }
                b.append(" · 本线路第 ").append(playback.reanchorThisStreamCount())
                        .append(" 次 · 距上次 ").append(since).append(" 秒");
                if (since < 3L) b.append("（对齐后未稳，等 3 秒）");
            }
            b.append('\n');
        }
        // 换台体检：出画耗时 + 换了几次线路 + 本台台账是否整台不可达。
        // 「换台慢」到底是网络慢、还是在本台内部反复换线，这两行能分开。
        long lastOut = playback == null ? -1L : playback.lastFirstFrameMs();
        b.append("换台：上次出画 ")
                .append(lastOut >= 0 ? (lastOut + " ms") : "尚未出画")
                .append(" · 本次线路切换 ")
                .append(playback == null ? 0 : playback.failoverCount()).append(" 次");
        if (playback != null && playback.isChannelLikelyDead()) {
            b.append(" · 本台台账无可用线路（仍在逐条试）");
        }
        b.append('\n');
        // 14:42 真机线索「起播正常、从别的频道切回来才音画不同步」必须能用数字自证。
        // 单点读数回答不了「是切回来就低、还是播放中掉下来」，所以这一行同时给：
        //   ① 会话起播次数（跨台不清零）→ 是否随换台次数加重；
        //   ② 本线路已播秒数 → 是否随播放时长累积；
        //   ③ 同一探针窗口内输出帧率的 20 秒前 / 现在 → 恶化过程的斜率。
        // 三个都是纯读数，不驱动任何动作；样本不足时第 ③ 项自动省略。
        if (playback != null) {
            final QualityProbe q = playback.quality();
            final int nowOut = q.outputFpsCenti();
            final int agoOut = q.outputFpsCentiAgo(20);
            b.append("会话：起播 ").append(playback.sessionStartCount()).append(" 次")
                    .append(" · 本线路已播 ").append(playback.streamElapsedSeconds()).append(" 秒");
            // 起播 8 秒内时钟窗口没填满、码率样本不足、分辨率还在「判定中」、
            // 缓存只有一个样本。15:50 真机那张「本线路已播 1 秒」的页就是这种态，
            // 拿它的 17.04 / 9.61 去判病因会得出错误结论，页面上必须写明。
            final long elapsed = playback.streamElapsedSeconds();
            if (elapsed >= 0L && elapsed < 8L) {
                b.append(" · 起播未稳，勿据此页判读");
            }
            if (nowOut >= 0 && agoOut >= 0) {
                b.append(" · 输出帧率 20 秒前 ")
                        .append(String.format(Locale.US, "%.2f", agoOut / 100.0))
                        .append(" → ").append(String.format(Locale.US, "%.2f", nowOut / 100.0));
                if (agoOut - nowOut > 200) b.append("（下滑）");
                else if (nowOut - agoOut > 200) b.append("（回升）");
                else b.append("（持平）");
            }
            b.append('\n');
        }
        // 换台释放时序（§41 嫌疑 A / §44 干预）：16:48 真机「重叠 83/86 次 ·
        // 最深队列 3 个 · 上次释放 62 ms · 现存 0 个」说明释放既不慢也不长期
        // 堆积，只是几乎每次换台都落在新旧 player 的交接窗口里。本轮起播前
        // 改成有上限地等排空，这两行必须能自证「等待生效 / 本次起播无重叠」，
        // 否则这次干预就无法证伪。拆两行是为了不把长文本挤到下一页。
        if (playback != null) {
            b.append("释放：等待 ").append(playback.drainCount())
                    .append(" 次 / 起播 ").append(playback.sessionStartCount()).append(" 次");
            final long dc = playback.lastDrainCostMs();
            final int timeout = playback.drainTimeoutCount();
            if (dc >= 0L || timeout > 0) {
                b.append('（');
                if (dc >= 0L) b.append("最近 ").append(dc).append(" ms");
                if (timeout > 0) {
                    if (dc >= 0L) b.append(" · ");
                    b.append("超时 ").append(timeout).append(" 次");
                }
                b.append('）');
            }
            final int nowDepth = playback.lastOverlapDepth();
            if (nowDepth > 0) b.append(" · 本次重叠 ").append(nowDepth).append(" 个");
            else b.append(" · 本次无重叠");
            b.append('\n');
            b.append("交接：历史重叠 ").append(playback.releaseOverlapCount())
                    .append(" 次（最深 ").append(playback.maxOverlapDepth()).append(" 个）")
                    .append(" · 现存 ").append(playback.releasePendingCount()).append(" 个");
            final long cost = playback.lastReleaseCostMs();
            if (cost >= 0L) b.append(" · 上次释放 ").append(cost).append(" ms");
            b.append('\n');
        }
        // 起播策略这一行必须跟着真实状态走：兼容模式开着的时候帧队列 / 帧率上限
        // 是**不设**的，写死「帧队列 3 · 帧率上限 30」会和下一行「兼容模式 开」自相
        // 矛盾，拿到截图排障的人会以为参数没生效。
        final boolean compat = playback != null && playback.compatSyncEnabled();
        b.append("起播策略：探测 1.5 秒 · 6 秒无首帧且仍有候选才换线 · ")
                .append(compat ? "帧队列 / 帧率不限（兼容模式）" : "帧队列 3 · 帧率上限 30")
                .append('\n');
        // 同一行里两个「次数」口径不同：alignSeekCount 每条线路清零，reanchorCount
        // 跨起播累计、只有重装/进程重启才归零。15:50 那张「手动对齐 3 次」其实是
        // 装新包后累计按了 3 次，不是本线路按了 3 次；不标清楚会误判。
        b.append("同步：起播静音至首帧 · 长缓冲再对齐 ")
                .append(playback == null ? 0 : playback.alignSeekCount()).append(" 次（本线路）")
                .append(" · 手动对齐 ")
                .append(playback == null ? 0 : playback.reanchorCount()).append(" 次（累计）")
                .append(" · 兼容模式 ")
                .append(playback != null && playback.compatSyncEnabled() ? "开（未设帧率/队列上限）" : "关")
                .append('\n');
        // 闭环状态：把「哪些自动动作开着、各自动过几次」写在一行里。
        // 关掉自动换线时也必须显示，否则用户会以为功能没生效而不是被自己关了。
        final boolean auto = playback != null && playback.autoFailover();
        b.append("闭环：自动换线 ").append(auto ? "开" : "关（等同 1.0.2，只保留超时换线）")
                .append(" · 假高清降权 ").append(playback == null ? 0 : playback.fakeHdCount()).append(" 条")
                .append(" · 塌陷换线 ").append(playback == null ? 0 : playback.bandwidthSwitchCount()).append(" 次")
                .append(" · 时钟换线 ").append(playback == null ? 0 : playback.syncSwitchCount()).append(" 次")
                .append(" · 停滞处置 ").append(playback == null ? 0 : playback.stallActionCount()).append(" 次\n");
        b.append("判据：实测宽度 / 相对自身基线的吞吐 / 播放位置增速；")
                .append("缓存差与丢帧率经真机实测否定，不作换线依据\n");
        // 记忆一行：换台快不快，一半取决于「先试哪一条」，这行把这件事说清楚。
        b.append(playback == null ? "记忆：本次会话尚未起播" : playback.memorySummary())
                .append(playback != null && !playback.adaptiveOrder()
                        ? " · 记忆排序已关闭（优先清晰度非「自动」）" : "")
                .append('\n');
        // 这行原来写死「默认 FFmpeg 软解」，切成硬解后还在说软解，做 A/B 时
        // 根本没法确认设置有没有落到当前线路上。M4 是「按线路」回退，
        // 设置意图与实际使用可能不同（某条线路硬解跑不起来会单独退回软解），
        // 所以两个值都显示，并且明确标出「本线路已回退」。
        final boolean preferHard = playback != null && playback.hardDecodePreferred();
        final boolean actualHard = playback != null && playback.usingHardDecode();
        b.append("内核：ijkplayer 0.8.8（本线路 ")
                .append(actualHard ? "硬解" : "软解")
                .append(" · 设置 ").append(preferHard ? "硬解" : "软解")
                .append(preferHard && !actualHard ? " · 本线路已回退" : "")
                .append("，仅 armeabi-v7a）\n");
        b.append("签名：独立包仅 v1(JAR/SHA-1)；单包 v1+v2，minSdk 16 / targetSdk 36\n");
        b.append("本界面在 API < 24 启动，与主程序共用同一份频道清单\n");
        if (decision.branch == LegacyVersionCompat.Branch.DEFAULT_FLOW) {
            b.append("\n此设备 API ≥ 24，建议改用 Flutter 主程序获得完整功能。\n");
        }
        if (!nativeLibrariesOk && nativeLibraryError != null) {
            b.append("\n内核加载失败：").append(nativeLibraryError).append('\n');
        }
        if (!periodic) {
            String last = CrashReport.readLast(this);
            if (last != null && last.length() > 0) {
                b.append("\n—— 上次崩溃记录（完整内容已存 last_crash.txt）——\n")
                        .append(last, 0, Math.min(last.length(), 600));
            }
        }
        b.append("\n\n←→ 翻页 · OK / 返回 关闭 · 菜单 再按一次也关闭");
        renderHelpPage(b.toString());
    }

    /**
     * 按屏高分页渲染诊断页。
     *
     * <p><b>为什么必须分页</b>：真机 1080p（dp 高 720）上，16sp 正文 + 4dp 行距
     * 一行约 26dp，一屏只放得下 23 行左右；而这版诊断内容有 34 行，
     * 底部「闭环 / 判据 / 记忆 / 内核 / 签名」全被裁在屏幕外——而这些恰好是
     * 排查时最需要看的几行。旧版内容少一点，一直是「刚好差一点」的状态，
     * 所以这个问题一直没被发现。
     *
     * <p>不做滚动条：电视遥控器拖滚动条比翻页难受，且 ScrollView 一旦可聚焦
     * 就会吞掉 OK 键（与旧版状态卡是同一类坑）。翻页只用一个整数状态。
     */
    private void renderHelpPage(String full) {
        // \f 是语义分页符：系统/清单一段、播放读数一段。按行机械切分虽然够用，
        // 但会把「码率」和「缓存」拆到两页，读的人要在两屏之间来回对；
        // 语义分页让第 1 页是「这台是什么」，第 2 页是「现在播得怎么样」。
        final String[] sections = full.split("\f", -1);
        final int per = helpLinesPerPage();
        int total = 0;
        for (int i = 0; i < sections.length; i++) {
            final int n = sections[i].split("\n", -1).length;
            total += Math.max(1, (n + per - 1) / per);
        }
        helpPages = Math.max(1, total);
        if (helpPage >= helpPages) helpPage = helpPages - 1;
        if (helpPage < 0) helpPage = 0;

        int page = helpPage;
        final StringBuilder b = new StringBuilder();
        for (int s = 0; s < sections.length; s++) {
            final String[] lines = sections[s].split("\n", -1);
            final int pages = Math.max(1, (lines.length + per - 1) / per);
            if (page >= pages) {
                page -= pages;
                continue;
            }
            final int from = page * per;
            final int to = Math.min(lines.length, from + per);
            for (int i = from; i < to; i++) b.append(lines[i]).append('\n');
            break;
        }
        if (helpPages > 1) {
            b.append("—— 第 ").append(helpPage + 1).append('/').append(helpPages)
                    .append(" 页 · ←→ 翻页 · 其余键关闭 ——");
        }
        helpView.setText(b.toString());
    }

    /** 一页放几行：按实际屏高算，留出内边距与底部提示的位置。 */
    private int helpLinesPerPage() {
        final DisplayMetrics dm = getResources().getDisplayMetrics();
        final float dpHeight = dm.heightPixels / dm.density;
        // 16sp 正文 + 4dp 行距 ≈ 26dp/行；上下内边距 + 页脚再留 110dp。
        final int n = (int) ((dpHeight - 110f) / 26f);
        return Math.max(12, Math.min(40, n));
    }

    /** 诊断页每 2 秒重建一次；离开该模式立即停，不留后台任务。 */
    private void scheduleHelpRefresh() {
        cancelHelpRefresh();
        helpRefreshTask = new Runnable() {
            @Override
            public void run() {
                if (mode != MODE_HELP || helpView == null
                        || helpView.getVisibility() != View.VISIBLE) {
                    helpRefreshTask = null;
                    return;
                }
                buildHelp(true);
                ui.postDelayed(this, 2000L);
            }
        };
        ui.postDelayed(helpRefreshTask, 2000L);
    }

    private void cancelHelpRefresh() {
        if (helpRefreshTask != null) {
            ui.removeCallbacks(helpRefreshTask);
            helpRefreshTask = null;
        }
    }

    // ---------------------------------------------------------------- 兜底页

    /** 启动失败时的纯 TextView 兜底页：不依赖 SurfaceView / 内核 / 清单。 */
    private void showFatal(Throwable t) {
        fatal = true;
        try {
            TextView v = new TextView(this);
            v.setBackgroundColor(Color.BLACK);
            v.setTextColor(0xFFFF8A80);
            v.setTextSize(17);
            v.setPadding(dp(28), dp(24), dp(28), dp(24));
            v.setText("顺播兼容版 · 启动失败（已自动留痕）\n\n"
                    + CrashReport.shortTrace(t)
                    + "\n\n请拍下本页回传；菜单键重看，返回键退出。\n"
                    + "顺播 1.0.4 / 原生兼容分支");
            setContentView(v);
        } catch (Throwable ignored) {
            // 连 TextView 都建不起来时，堆栈已写进 last_crash.txt。
        }
    }

    /** 菜单键：显示本进程上次崩溃（或本次启动失败）的完整留痕。 */
    private void showFatalLast() {
        if (lastFatal != null) {
            showFatal(lastFatal);
            return;
        }
        String last = CrashReport.readLast(this);
        if (last == null || last.length() == 0) return;
        fatal = true;
        try {
            TextView v = new TextView(this);
            v.setBackgroundColor(Color.BLACK);
            v.setTextColor(0xFFFF8A80);
            v.setTextSize(16);
            v.setPadding(dp(28), dp(24), dp(28), dp(24));
            v.setText("顺播兼容版 · 上次崩溃记录\n\n"
                    + last.substring(0, Math.min(last.length(), 1200))
                    + "\n\n请拍下本页回传；返回键退出。");
            setContentView(v);
        } catch (Throwable ignored) {
        }
    }

    /** 入口路由：只比较 SDK_INT；探测异常按保守策略进兼容分支。 */
    private static LegacyVersionCompat.Decision probeVersion() {
        Object raw = null;
        boolean probeOk = false;
        String release = "";
        try {
            raw = Integer.valueOf(Build.VERSION.SDK_INT);
            release = String.valueOf(Build.VERSION.RELEASE);
            probeOk = true;
        } catch (Throwable t) {
            probeOk = false;
        }
        return LegacyVersionCompat.decide(raw, probeOk, true, release);
    }
}
