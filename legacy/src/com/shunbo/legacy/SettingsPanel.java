package com.shunbo.legacy;

import android.content.Context;
import android.view.Gravity;
import android.view.KeyEvent;
import android.view.View;
import android.widget.LinearLayout;
import android.widget.TextView;

/**
 * 设置面板：遥控器可操作的单列选项表，参考主流电视直播软件的设置布局。
 *
 * <p>交互固定为「↑↓ 选行、OK / ←→ 改值、返回 关闭」，不引入二级弹窗，
 * 老遥控器也能两步内改完一项。所有条目都画在一屏内并用 weight 均分行高，
 * 不需要滚动——1280×720 的老电视上滚动列表既难看清也容易按过头。
 *
 * <p><b>每一项都真实接线</b>，没有装饰性开关：
 * <ul>
 *   <li>开机自启 → {@link BootReceiver} 读 {@link Prefs#bootAutostart()}；</li>
 *   <li>启动直达播放 / 启动频道 → Activity 的启动分支与 preferredChannelIndex；</li>
 *   <li>频道栏自动隐藏 → 统一的 OSD 空闲计时器；</li>
 *   <li>切台失败自动回退 / 提示停留 → 失败提示生命周期与 lastGood 回退；</li>
 *   <li>优先清晰度 → {@link ChannelCatalog#applyQualityPriority(int)}；</li>
 *   <li>台号确认 / 连按合并 / 首帧超时 / 解码方式 → Activity 与
 *       {@link PlaybackController} 的实例参数；</li>
 *   <li>画面比例 → SurfaceView 布局。</li>
 * </ul>
 *
 * <p>「顶部信息条」开关已随顶部信息条一并下线：截图红标「不管什么时候都不要
 * 显示」后，台号 / 台名改由换台横幅承担，播放诊断移入「关于与诊断」。
 *
 * <p>底部说明随焦点变化，直接写清该项的副作用与真机限制（例如部分 ROM
 * 需要到系统「自启管理」放行），不把系统限制伪装成软件功能。
 */
final class SettingsPanel {

    interface Listener {
        /** 任一项改动后立即回调，Activity 负责把值应用到运行时。 */
        void onSettingChanged(String key, int value);

        void onClearFavorites();

        void onResetSettings();

        void onAboutRequested();

        /** 设置菜单里的「地区切换」：打开省 / 市选择面板。 */
        void onRegionFromSettings();

        /** 立刻做一次音画再对齐（seek 到当前播放位置，重锚 frame_timer）。 */
        void onReanchorRequested();
    }

    private static final int ACTION_NONE = 0;
    private static final int ACTION_CLEAR_FAV = 1;
    private static final int ACTION_RESET = 2;
    private static final int ACTION_ABOUT = 3;
    private static final int ACTION_REGION = 4;
    private static final int ACTION_REANCHOR = 5;

    private static final class Item {
        final String key;          // null = 动作项
        final String title;
        final String desc;
        final String[] labels;
        final int[] values;
        final int action;

        Item(String key, String title, String desc, String[] labels,
             int[] values, int action) {
            this.key = key;
            this.title = title;
            this.desc = desc;
            this.labels = labels;
            this.values = values;
            this.action = action;
        }
    }

    private static Item[] buildItems() {
        return new Item[]{
                new Item(Prefs.K_BOOT_AUTOSTART, "开机自启",
                        "开机后自动启动顺播。部分电视 ROM 还需到系统「自启管理 / 开机启动」里把顺播设为允许，系统拦截时应用无法自行绕过。",
                        new String[]{"关", "开"}, new int[]{0, 1}, ACTION_NONE),
                new Item(Prefs.K_BOOT_DIRECT_PLAY, "启动直接进入播放",
                        "打开：启动即全屏播放，不再先弹频道栏；关闭：启动先显示频道列表，按 OK 选台。",
                        new String[]{"否", "是"}, new int[]{0, 1}, ACTION_NONE),
                new Item(Prefs.K_START_CHANNEL, "启动频道",
                        "上次观看＝记住上次那台；第 1 台＝固定从 CCTV-1 开始；收藏首台＝从收藏里的第一台开始。",
                        new String[]{"上次观看", "第 1 台", "收藏首台"},
                        new int[]{0, 1, 2}, ACTION_NONE),
                new Item(Prefs.K_PANEL_IDLE_MS, "浮层自动隐藏",
                        "频道栏 / 地区面板 / 控制条 / 检索页无操作多久后自动收起，回到纯净播放画面。默认 30 秒，给遥控器选台留足时间；想更快收起可调小，也可设「不隐藏」。",
                        new String[]{"不隐藏", "5 秒", "10 秒", "15 秒", "20 秒", "30 秒", "60 秒"},
                        new int[]{0, 5000, 10000, 15000, 20000, 30000, 60000}, ACTION_NONE),
                new Item(Prefs.K_FAIL_FALLBACK, "切台失败自动回退",
                        "切到一个所有线路都播不出的台时，短暂提示后自动回到上一个正常出画的频道，不让错误提示一直挂在屏幕上。",
                        new String[]{"关", "开"}, new int[]{0, 1}, ACTION_NONE),
                new Item(Prefs.K_FAIL_HINT_MS, "失败提示停留",
                        "错误提示显示多久后消失（随后按设置自动回退或等待手动重试）。",
                        new String[]{"2 秒", "3 秒", "5 秒"},
                        new int[]{2000, 3000, 5000}, ACTION_NONE),
                new Item(Prefs.K_QUALITY_PRIORITY, "优先清晰度",
                        "决定同一台里线路的尝试顺序。自动＝先挑实测起播快的线路（央视多为官方 576P 源，换台快、少卡顿），同档再比画质；想要高画质就选「1080P 优先」，代价是起播慢一些、跨境源更容易缓冲。",
                        new String[]{"自动", "1080P 优先", "720P 优先", "标清优先"},
                        new int[]{0, 1, 2, 3}, ACTION_NONE),
                new Item(Prefs.K_NUMBER_COMMIT_MS, "台号输入确认",
                        "按完数字键后等多久自动切台；输错可按返回清除。",
                        new String[]{"1 秒", "2 秒", "3 秒"},
                        new int[]{1000, 2000, 3000}, ACTION_NONE),
                new Item(Prefs.K_ZAP_COMMIT_MS, "换台连按合并",
                        "连续按 ↑↓ 时只起播最后停下的那台，避免一路上反复 prepare 把内核拖死。",
                        new String[]{"不合并", "280 毫秒", "500 毫秒"},
                        new int[]{0, 280, 500}, ACTION_NONE),
                new Item(Prefs.K_FIRST_FRAME_TIMEOUT_MS, "首帧超时",
                        "一条线路多久还没出第一帧就换下一条；网络慢的电视可适当调大。",
                        new String[]{"8 秒", "12 秒", "18 秒"},
                        new int[]{8000, 12000, 18000}, ACTION_NONE),
                new Item(Prefs.K_AUTO_FAILOVER, "自动换线",
                        "播放中实测带宽塌到自身基线的 40% 以下（且近 60 秒已经卡过一次），或音画时钟真的走快 2% 以上时，自动换到下一条线路；同时把实测分辨率够不上标称的线路在下次选线时排到后面。关掉＝只保留「已超时才换」的老逻辑，不做预测性换线。",
                        new String[]{"关", "开"}, new int[]{0, 1}, ACTION_NONE),
                new Item(Prefs.K_ASPECT, "画面比例",
                        "铺满＝画面占满屏幕；16:9 / 4:3＝按比例居中显示，两侧或上下留黑边，不拉伸变形。",
                        new String[]{"铺满", "16:9", "4:3"},
                        new int[]{0, 1, 2}, ACTION_NONE),
                new Item(Prefs.K_HARD_DECODE, "解码方式",
                        "默认软解（FFmpeg）。切成硬解后立刻用当前频道重建解码器（画面会闪一下，不用换台）；若某条线路硬解跑不起来（解码报错 / 6 秒不出画面），只让这条线路改用软解，本项设置保持不变、别的台该硬解还继续硬解，7 天后自动重试。API 18 老电视的 MediaCodec 行为不稳，花屏 / 无声请改回软解。4K 台按新解码方式在重启后显示。",
                        new String[]{"软解", "硬解"}, new int[]{0, 1}, ACTION_NONE),
                new Item(Prefs.K_SYNC_COMPAT, "同步兼容模式",
                        "个别高清台出现「声音比画面快一点」时再开它试试：它会关掉本程序为老机型加的两个同步保护参数（帧率上限 30、视频帧队列 3），把同步交回播放内核自己调度。代价是极端抖动源更容易卡；默认关闭。",
                        new String[]{"关", "开"}, new int[]{0, 1}, ACTION_NONE),
                new Item(null, "音画立即对齐",
                        "立刻按当前位置重新对齐一次音画（会闪一下、可能短暂缓冲）。声音比画面快、且怎么换线都一样时可以按一次试试；诊断页「同步」一行会记下用了几次。",
                        new String[0], new int[0], ACTION_REANCHOR),
                // 「顶部信息条」设置已下线：顶部信息条本身按截图红标
                // 「不管什么时候都不要显示」整体删除，留着开关只会是个无效选项。
                // 播放诊断仍在「关于与诊断」里可查。
                new Item(null, "地区切换",
                        "打开省 / 市选择界面，切换省份（加载全省地方台）或城市（加载本市地方台）。面板上标着当前地区与正在播的台，选中即应用，不打断正在播的节目；也可用绿键 / 控制条「地区」直达。",
                        new String[0], new int[0], ACTION_REGION),
                new Item(null, "清空收藏",
                        "删除本机全部收藏频道；上次观看、地区与设置不受影响。",
                        new String[0], new int[0], ACTION_CLEAR_FAV),
                new Item(null, "恢复默认设置",
                        "只把上面这些设置恢复成默认值；收藏 / 上次观看 / 地区一概保留。",
                        new String[0], new int[0], ACTION_RESET),
                new Item(null, "关于与诊断",
                        "查看版本、清单、台账、内核与上次崩溃记录。",
                        new String[0], new int[0], ACTION_ABOUT),
        };
    }

    private final Context context;
    private final Prefs prefs;
    private final Listener listener;
    private final LinearLayout root;
    private final TextView heading;
    private final TextView hint;
    private final Item[] items;
    private final LinearLayout[] rows;
    private final TextView[] names;
    private final TextView[] values;
    private int focus = 0;

    SettingsPanel(Context context, Prefs prefs, Listener listener) {
        this.context = context;
        this.prefs = prefs;
        this.listener = listener;
        this.items = buildItems();
        this.rows = new LinearLayout[items.length];
        this.names = new TextView[items.length];
        this.values = new TextView[items.length];

        root = new LinearLayout(context);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setBackgroundColor(Ui.SCRIM);
        root.setPadding(Ui.dp(context, 34), Ui.dp(context, 14),
                Ui.dp(context, 34), Ui.dp(context, 12));
        root.setVisibility(View.GONE);

        heading = Ui.text(context, 19, Ui.TEXT, true);
        root.addView(heading, new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT));

        TextView nav = Ui.text(context, 13, Ui.ACCENT, false);
        nav.setText("↑↓ 选择   OK / ←→ 修改   返回 关闭   ·   设置项即时生效并保存");
        nav.setPadding(0, Ui.dp(context, 5), 0, Ui.dp(context, 8));
        root.addView(nav, new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT));

        LinearLayout list = new LinearLayout(context);
        list.setOrientation(LinearLayout.VERTICAL);
        root.addView(list, new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f));

        for (int i = 0; i < items.length; i++) {
            final int slot = i;
            LinearLayout row = new LinearLayout(context);
            row.setOrientation(LinearLayout.HORIZONTAL);
            row.setGravity(Gravity.CENTER_VERTICAL);
            row.setPadding(Ui.dp(context, 12), 0, Ui.dp(context, 12), 0);
            row.setClickable(true);
            row.setOnClickListener(new View.OnClickListener() {
                @Override
                public void onClick(View v) {
                    focus = slot;
                    activate();
                    render();
                }
            });
            TextView name = Ui.text(context, 15, Ui.TEXT_DIM, false);
            row.addView(name, new LinearLayout.LayoutParams(
                    0, LinearLayout.LayoutParams.MATCH_PARENT, 1f));
            TextView value = Ui.text(context, 14, Ui.ACCENT, true);
            value.setGravity(Gravity.RIGHT | Gravity.CENTER_VERTICAL);
            row.addView(value, new LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.WRAP_CONTENT,
                    LinearLayout.LayoutParams.MATCH_PARENT));
            list.addView(row, new LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f));
            rows[i] = row;
            names[i] = name;
            values[i] = value;
        }

        hint = new TextView(context);
        hint.setTextColor(Ui.TEXT_DIM);
        hint.setTextSize(13);
        hint.setSingleLine(false);
        hint.setMaxLines(3);
        hint.setPadding(Ui.dp(context, 12), Ui.dp(context, 8),
                Ui.dp(context, 12), 0);
        root.addView(hint, new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT));
        render();
    }

    View getView() { return root; }

    boolean isVisible() { return root.getVisibility() == View.VISIBLE; }

    void hide() { root.setVisibility(View.GONE); }

    void show() {
        root.setVisibility(View.VISIBLE);
        focus = 0;
        render();
    }

    boolean handleKey(int keyCode) {
        switch (keyCode) {
            case KeyEvent.KEYCODE_DPAD_UP:
            case KeyEvent.KEYCODE_CHANNEL_UP:
                focus = (focus - 1 + items.length) % items.length;
                render();
                return true;
            case KeyEvent.KEYCODE_DPAD_DOWN:
            case KeyEvent.KEYCODE_CHANNEL_DOWN:
                focus = (focus + 1) % items.length;
                render();
                return true;
            case KeyEvent.KEYCODE_DPAD_LEFT:
            case KeyEvent.KEYCODE_MEDIA_PREVIOUS:
                cycle(-1);
                return true;
            case KeyEvent.KEYCODE_DPAD_RIGHT:
            case KeyEvent.KEYCODE_MEDIA_NEXT:
            case KeyEvent.KEYCODE_DPAD_CENTER:
            case KeyEvent.KEYCODE_ENTER:
                activate();
                return true;
            case KeyEvent.KEYCODE_BACK:
            case KeyEvent.KEYCODE_ESCAPE:
            case KeyEvent.KEYCODE_MENU:
            case KeyEvent.KEYCODE_INFO:
                hide();
                return true;
            default:
                return false;
        }
    }

    private void activate() {
        if (items[focus].key != null) {
            cycle(1);
            return;
        }
        switch (items[focus].action) {
            case ACTION_CLEAR_FAV:
                listener.onClearFavorites();
                break;
            case ACTION_RESET:
                listener.onResetSettings();
                break;
            case ACTION_ABOUT:
                listener.onAboutRequested();
                break;
            case ACTION_REGION:
                listener.onRegionFromSettings();
                break;
            case ACTION_REANCHOR:
                listener.onReanchorRequested();
                break;
            default:
                break;
        }
    }

    private void cycle(int delta) {
        final Item it = items[focus];
        if (it.key == null || it.values.length == 0) return;
        final int current = prefs.setting(it.key);
        int at = 0;
        for (int i = 0; i < it.values.length; i++) {
            if (it.values[i] == current) { at = i; break; }
        }
        at = ((at + delta) % it.values.length + it.values.length)
                % it.values.length;
        final int next = it.values[at];
        prefs.setSetting(it.key, next);
        listener.onSettingChanged(it.key, next);
        render();
    }

    private String labelOf(Item it) {
        final int current = prefs.setting(it.key);
        for (int i = 0; i < it.values.length; i++) {
            if (it.values[i] == current) return it.labels[i];
        }
        return it.labels.length > 0 ? it.labels[0] : "";
    }

    private void render() {
        heading.setText("设置  ·  顺播兼容版  ·  " + items.length + " 项");
        for (int i = 0; i < items.length; i++) {
            final Item it = items[i];
            final boolean on = i == focus;
            rows[i].setBackground(Ui.rect(context,
                    on ? Ui.FOCUS : (i % 2 == 0 ? 0x00000000 : Ui.CARD_SCRIM),
                    6, 0, 0));
            names[i].setText((on ? "▸ " : "   ") + it.title);
            names[i].setTextColor(on ? Ui.TEXT : Ui.TEXT_DIM);
            values[i].setText(it.key == null ? "按 OK 执行" : labelOf(it));
            values[i].setTextColor(on ? Ui.TEXT : Ui.ACCENT);
        }
        hint.setText("【" + items[focus].title + "】" + items[focus].desc);
    }
}
