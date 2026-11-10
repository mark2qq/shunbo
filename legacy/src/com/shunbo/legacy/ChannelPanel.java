package com.shunbo.legacy;

import android.content.Context;
import android.util.DisplayMetrics;
import android.view.Gravity;
import android.view.KeyEvent;
import android.view.View;
import android.view.ViewGroup;
import android.widget.HorizontalScrollView;
import android.widget.LinearLayout;
import android.widget.TextView;

import java.util.ArrayList;
import java.util.List;

/**
 * 右侧频道抽屉：分组 + 可聚焦列表 + 当前播放状态卡 + 地区切换入口。
 *
 * <p>主流电视直播软件的频道栏都是「半透明浮层」而不是一整块不透明色板：
 * 左侧正在播的画面要能透出来，用户才能一边挑台一边看当前台是否还在播。
 * 本轮按截图反馈做了三件事：
 * <ol>
 *   <li><b>透明背景</b>：{@link Ui#PANEL_SCRIM} 只压暗不遮死，非焦点行无底色；</li>
 *   <li><b>填满列表</b>：行数按屏幕高度算出来，行高用 weight 均分剩余空间，
 *       列表下方不再留一大片空白；</li>
 *   <li><b>状态卡 + 地区入口</b>：底部固定显示「当前台 / 线路 / 播放状态」
 *       与「当前地区 / 地方台数 / 切换」，可用方向键聚焦、绿键直达、鼠标点击。</li>
 * </ol>
 *
 * <p>刻意不引入 RecyclerView / Leanback：目标是 API 16-18 的老机器，
 * 固定容量 TextView 数组 + 权重布局比 support 库更稳。
 */
final class ChannelPanel {

    interface Listener {
        void onChannelPicked(int channelIndex);

        void onFavoriteToggled(int channelIndex, boolean nowFavorite);

        /** 打开省 / 市选择面板（绿键、地区 chip、状态卡、控制条共用）。 */
        void onRegionRequested();
    }

    private static final int MIN_ROWS = 9;
    private static final int MAX_ROWS = 16;
    /** 标题 + 分组条 + 状态卡 + 页脚 + 上下留白占用的大致 dp。 */
    private static final int CHROME_DP = 190;
    private static final String GROUP_ALL = "";
    private static final String GROUP_FAV = "#fav";

    private final Context context;
    private final ChannelCatalog catalog;
    private final Prefs prefs;
    private final Listener listener;

    private final LinearLayout root;
    private final TextView title;
    private final HorizontalScrollView chipScroll;
    private final LinearLayout chips;
    private final LinearLayout rows;
    private final TextView nowPlaying;
    private final LinearLayout infoCard;
    private final TextView regionLine;
    private final TextView footer;
    private final int rowCount;
    private final TextView[] rowViews;

    /** 分组：{键, 显示名}，键为 "" 表示全部、"#fav" 表示收藏 */
    private final List<String[]> groups = new ArrayList<String[]>();
    private int groupIndex = 0;
    private int focus = 0;
    private final List<Integer> filtered = new ArrayList<Integer>();

    /** 当前播放信息（Activity 推送），底部状态卡常驻显示。 */
    private String stateChannel = "";
    private String stateLine = "线路 1/1";
    private String stateText = "准备中";
    private boolean stateFailed = false;
    private String stateRegion = "";
    private int stateLocalCount = 0;

    ChannelPanel(Context context, ChannelCatalog catalog, Prefs prefs, Listener listener) {
        this.context = context;
        this.catalog = catalog;
        this.prefs = prefs;
        this.listener = listener;
        this.rowCount = computeRows(context);
        this.rowViews = new TextView[rowCount];

        root = new LinearLayout(context);
        root.setOrientation(LinearLayout.VERTICAL);
        // 半透明深色浮层：画面能透出来，文字仍有足够对比度。
        root.setBackgroundColor(Ui.PANEL_SCRIM);
        root.setPadding(Ui.dp(context, 14), Ui.dp(context, 12),
                Ui.dp(context, 14), Ui.dp(context, 10));
        root.setVisibility(View.GONE);

        title = Ui.text(context, 16, Ui.TEXT, true);
        root.addView(title, new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT));

        chips = new LinearLayout(context);
        chips.setOrientation(LinearLayout.HORIZONTAL);
        // 分组从 6 个涨到 11 个（全部/收藏/央视/卫视/地方/新闻/体育/影视/少儿/
        // 纪实/生活/其它）之后，一行已经放不下：截图红标「比如目前是其它频道，
        // 但是下面菜单栏没有出现其它频道」正是被截断的那几个栏目。
        // 换成横向滚动容器：chip 的样式、顺序、点击与 ←→ 交互完全不变，
        // 只是超出部分可以滚动露出，右侧还会自动把选中项滚进可视区。
        chipScroll = new HorizontalScrollView(context);
        chipScroll.setHorizontalScrollBarEnabled(false);
        chipScroll.setFillViewport(true);
        // 关键：滚动容器与 chip 都不可聚焦。频道栏的全部按键都由
        // Activity.onKeyDown 手写处理，任何可聚焦子控件都会把 OK 抢走
        // （历史故障：状态卡可聚焦导致「第二次换台弹省市面板」）。
        chipScroll.setFocusable(false);
        chipScroll.setFocusableInTouchMode(false);
        chipScroll.setDescendantFocusability(ViewGroup.FOCUS_BLOCK_DESCENDANTS);
        chipScroll.addView(chips, new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT,
                LinearLayout.LayoutParams.WRAP_CONTENT));
        LinearLayout.LayoutParams chipLp = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT);
        chipLp.topMargin = Ui.dp(context, 8);
        chipLp.bottomMargin = Ui.dp(context, 6);
        root.addView(chipScroll, chipLp);

        rows = new LinearLayout(context);
        rows.setOrientation(LinearLayout.VERTICAL);
        root.addView(rows, new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f));

        for (int i = 0; i < rowCount; i++) {
            final int slot = i;
            TextView row = Ui.text(context, 16, Ui.TEXT_DIM, false);
            row.setPadding(Ui.dp(context, 10), 0, Ui.dp(context, 10), 0);
            row.setOnClickListener(new View.OnClickListener() {
                @Override
                public void onClick(View v) {
                    focus = start() + slot;
                    if (focus >= 0 && focus < filtered.size()) activate();
                    render();
                }
            });
            // 权重布局把剩余高度均分给每一行，彻底消掉截图里的下半屏留白。
            rows.addView(row, new LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f));
            rowViews[i] = row;
        }

        // ---- 底部状态卡：当前台 + 播放状态 + 地区切换入口 ----
        infoCard = new LinearLayout(context);
        infoCard.setOrientation(LinearLayout.VERTICAL);
        infoCard.setPadding(Ui.dp(context, 12), Ui.dp(context, 8),
                Ui.dp(context, 12), Ui.dp(context, 8));
        infoCard.setBackgroundColor(Ui.CARD_SCRIM);
        // 只作信息展示：既不可聚焦也不可点击。曾经这里 setFocusable(true)
        // + setOnClickListener → onRegionRequested()：频道栏显示时它是整个窗口
        // 唯一的可聚焦控件，遥控器 OK 会被它当成「点击」直接打开省 / 市面板，
        // 于是「第二次在列表里换台」就变成「弹地区选择」。现在它是纯展示卡，
        // OK 永远回到 Activity.onKeyDown → 频道栏切台，不会再误弹省市面板。
        infoCard.setClickable(false);
        infoCard.setFocusable(false);

        nowPlaying = Ui.text(context, 14, Ui.TEXT, true);
        infoCard.addView(nowPlaying, new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT));

        regionLine = Ui.text(context, 13, Ui.ACCENT, false);
        regionLine.setPadding(0, Ui.dp(context, 4), 0, 0);
        infoCard.addView(regionLine, new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT));
        LinearLayout.LayoutParams cardLp = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT);
        cardLp.topMargin = Ui.dp(context, 6);
        root.addView(infoCard, cardLp);

        footer = Ui.text(context, 12, Ui.TEXT_DIM, false);
        footer.setPadding(0, Ui.dp(context, 6), 0, 0);
        footer.setText("↑↓ 选择   OK 切台   ←→ 分组   绿键 地区   菜单 收藏   返回 关闭");
        root.addView(footer, new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT));

        buildGroups();
        renderInfo();
    }

    /** 行数按屏幕高度算，最少 9 行、最多 16 行；行高再由 weight 均分。 */
    private static int computeRows(Context c) {
        final DisplayMetrics dm = c.getResources().getDisplayMetrics();
        final int heightDp = (int) (dm.heightPixels / dm.density);
        final int n = (heightDp - CHROME_DP) / 38;
        return Math.max(MIN_ROWS, Math.min(MAX_ROWS, n));
    }

    int rowCount() { return rowCount; }

    View getView() {
        return root;
    }

    boolean isVisible() {
        return root.getVisibility() == View.VISIBLE;
    }

    /** 打开面板：定位到当前频道，并把它放在可视窗口中间。 */
    void show(int currentChannelIndex) {
        root.setVisibility(View.VISIBLE);
        buildGroups();
        rebuild();
        int at = filtered.indexOf(Integer.valueOf(currentChannelIndex));
        focus = at >= 0 ? at : 0;
        render();
    }

    void hide() {
        root.setVisibility(View.GONE);
    }

    /** 当前分组下可选的频道数量（自检页展示用）。 */
    int visibleCount() {
        return filtered.size();
    }

    boolean handleKey(int keyCode) {
        switch (keyCode) {
            case KeyEvent.KEYCODE_DPAD_UP:
            case KeyEvent.KEYCODE_CHANNEL_UP:
                if (filtered.isEmpty()) return true;
                focus = (focus - 1 + filtered.size()) % filtered.size();
                render();
                return true;
            case KeyEvent.KEYCODE_DPAD_DOWN:
            case KeyEvent.KEYCODE_CHANNEL_DOWN:
                if (filtered.isEmpty()) return true;
                // 列表内 OK 永远只切台：走到末行再按 ↓ 不再误聚焦底部「切换地区」
                // 卡片——那正是「选频道却弹省市台面板」的根源。切换地区改走
                // 绿键 / 控制条「地区」/ 设置菜单里的「地区切换」（触摸点底部卡片亦可）。
                if (focus < filtered.size() - 1) focus++;
                render();
                return true;
            case KeyEvent.KEYCODE_DPAD_LEFT:
                switchGroup(-1);
                return true;
            case KeyEvent.KEYCODE_DPAD_RIGHT:
                switchGroup(1);
                return true;
            case KeyEvent.KEYCODE_DPAD_CENTER:
            case KeyEvent.KEYCODE_ENTER:
                activate();
                return true;
            case KeyEvent.KEYCODE_PROG_GREEN:
            case KeyEvent.KEYCODE_GUIDE:
                listener.onRegionRequested();
                return true;
            case KeyEvent.KEYCODE_MENU:
            case KeyEvent.KEYCODE_PROG_RED:
            case KeyEvent.KEYCODE_STAR:
                toggleFavorite();
                return true;
            case KeyEvent.KEYCODE_BACK:
                hide();
                return true;
            default:
                // 数字键不吞：交给 Activity 走「台号直达」。
                return false;
        }
    }

    // ---------------------------------------------------------------- 内部

    private void buildGroups() {
        String keep = groupIndex < groups.size() ? groups.get(groupIndex)[0] : GROUP_ALL;
        groups.clear();
        groups.add(new String[]{GROUP_ALL, "全部"});
        groups.add(new String[]{GROUP_FAV, "收藏"});
        List<String> seen = new ArrayList<String>();
        for (int i = 0; i < catalog.size(); i++) {
            String g = catalog.get(i).group;
            if (g == null || g.length() == 0 || seen.contains(g)) continue;
            seen.add(g);
            groups.add(new String[]{g, shortGroup(g)});
        }
        // 内容分类（新闻/体育/影视/少儿/纪实/生活）是主分类之外的叠加导航栏：
        // 紧跟「地方频道」之后，与手机端 LiveRegion.groups 顺序一致；列表用
        // inCategory 叠加匹配，所以「苏州新闻综合」同时出现在「地方频道」与「新闻」。
        final String[] THEMATIC = new String[]{
                "新闻", "体育", "影视", "少儿", "纪实", "生活"
        };
        int at = -1;
        for (int i = 0; i < groups.size(); i++) {
            if (ChannelCatalog.LOCAL_GROUP.equals(groups.get(i)[0])) {
                at = i;
                break;
            }
        }
        int insertAt = at >= 0 ? at + 1 : groups.size();
        for (int t = 0; t < THEMATIC.length; t++) {
            groups.add(insertAt++, new String[]{THEMATIC[t], THEMATIC[t]});
        }
        // 频道栏只负责「挑台」：地区切换已从栏内移除（截图红标「地区切换去除」）。
        // 曾在这里追加「地区·<市> ▾切换」镜像分组，它既是可点的 chip、又与底部
        // 状态卡一起把 OK 引到 onRegionRequested()，是「第二次换台误弹省市面板」
        // 的根因之一；现在地区切换只走绿键 / 控制条「地区」/ 设置「地区切换」。
        groupIndex = 0;
        for (int i = 0; i < groups.size(); i++) {
            if (groups.get(i)[0].equals(keep)) {
                groupIndex = i;
                break;
            }
        }
        rebuildChips();
    }

    private static String shortGroup(String g) {
        if (g.endsWith("频道") && g.length() > 2) return g.substring(0, g.length() - 2);
        return g;
    }

    private void rebuildChips() {
        chips.removeAllViews();
        for (int i = 0; i < groups.size(); i++) {
            TextView chip = Ui.text(context, 13, Ui.TEXT_DIM, false);
            chip.setGravity(Gravity.CENTER);
            chip.setPadding(Ui.dp(context, 10), Ui.dp(context, 5),
                    Ui.dp(context, 10), Ui.dp(context, 5));
            // 靠点击处理，但不参与焦点：焦点永远留在「列表行」这套手写状态机上。
            chip.setFocusable(false);
            final int index = i;
            chip.setOnClickListener(new View.OnClickListener() {
                @Override
                public void onClick(View v) {
                    groupIndex = index;
                    focus = 0;
                    rebuild();
                    render();
                }
            });
            Ui.styleChip(context, chip, i == groupIndex, groups.get(i)[1]);
            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.WRAP_CONTENT,
                    LinearLayout.LayoutParams.WRAP_CONTENT);
            lp.setMargins(0, 0, Ui.dp(context, 6), 0);
            chips.addView(chip, lp);
        }
        scrollChipIntoView(groupIndex);
    }

    /**
     * 把当前分组 chip 滚进可视区。分组一行放不下时（全部…其它 共 12 个），
     * ←→ 切到后面的分组必须能看见它，否则用户不知道自己在哪个栏目下。
     */
    private void scrollChipIntoView(int index) {
        if (chips.getChildCount() == 0) return;
        final int at = Math.max(0, Math.min(index, chips.getChildCount() - 1));
        final View chip = chips.getChildAt(at);
        chipScroll.post(new Runnable() {
            @Override
            public void run() {
                final int pad = Ui.dp(context, 10);
                final int left = chip.getLeft() - pad;
                final int right = chip.getRight() + pad;
                final int viewW = chipScroll.getWidth();
                final int cur = chipScroll.getScrollX();
                if (left < cur) {
                    chipScroll.smoothScrollTo(Math.max(0, left), 0);
                } else if (right > cur + viewW) {
                    chipScroll.smoothScrollTo(Math.max(0, right - viewW), 0);
                }
            }
        });
    }

    private void switchGroup(int delta) {
        if (groups.isEmpty()) return;
        groupIndex = ((groupIndex + delta) % groups.size() + groups.size()) % groups.size();
        focus = 0;
        rebuild();
        render();
    }

    /** 重算当前分组的频道索引集合，并把 4K 台稳定地归集到最前面。 */
    private void rebuild() {
        filtered.clear();
        String key = groups.isEmpty() ? GROUP_ALL : groups.get(groupIndex)[0];
        for (int i = 0; i < catalog.size(); i++) {
            ChannelCatalog.Channel c = catalog.get(i);
            if (GROUP_FAV.equals(key)) {
                if (prefs.isFavorite(c.id)) filtered.add(Integer.valueOf(i));
            } else if (GROUP_ALL.equals(key)) {
                filtered.add(Integer.valueOf(i));
            } else if (c.inCategory(key)) {
                filtered.add(Integer.valueOf(i));
            }
        }
        // 4K 归集是**显示层**规则：只做一次稳定分区，4K 之间、非 4K 之间
        // 都保持清单原顺序，因此台号 / 线路排序 / 数字直达全都不受影响。
        List<Integer> fourK = new ArrayList<Integer>();
        List<Integer> rest = new ArrayList<Integer>();
        for (int i = 0; i < filtered.size(); i++) {
            Integer index = filtered.get(i);
            if (catalog.get(index.intValue()).is4K) {
                fourK.add(index);
            } else {
                rest.add(index);
            }
        }
        filtered.clear();
        filtered.addAll(fourK);
        filtered.addAll(rest);
        if (focus >= filtered.size()) focus = filtered.isEmpty() ? 0 : filtered.size() - 1;
        rebuildChips();
    }

    private int start() {
        int n = filtered.size();
        if (n <= rowCount) return 0;
        int s = focus - rowCount / 2;
        if (s < 0) s = 0;
        if (s > n - rowCount) s = n - rowCount;
        return s;
    }

    private void render() {
        String key = groups.isEmpty() ? GROUP_ALL : groups.get(groupIndex)[0];
        String groupName = groups.isEmpty() ? "全部" : groups.get(groupIndex)[1];
        title.setText(groupName + " · " + filtered.size() + " 台 · 收藏 "
                + prefs.favoriteCount());
        int s = start();
        if (filtered.isEmpty()) {
            rowViews[0].setText(GROUP_FAV.equals(key)
                    ? "还没有收藏：在列表里按「菜单」键即可收藏"
                    : "该分组暂无频道");
            rowViews[0].setTextColor(Ui.TEXT_DIM);
            rowViews[0].setBackground(null);
            for (int i = 1; i < rowCount; i++) {
                rowViews[i].setText("");
                rowViews[i].setBackground(null);
            }
            footer.setText("←→ 分组   绿键/设置 切换地区   返回 关闭");
            renderInfo();
            return;
        }
        for (int i = 0; i < rowCount; i++) {
            int at = s + i;
            TextView row = rowViews[i];
            if (at >= filtered.size()) {
                row.setText("");
                row.setBackground(null);
                continue;
            }
            int channelIndex = filtered.get(at).intValue();
            ChannelCatalog.Channel c = catalog.get(channelIndex);
            boolean playing = channelIndex == playingChannel;
            // 台号 + 台名，仅此而已。曾经在这里拼过「·可达线路数」，
            // 用户误以为是频道号后缀，按反馈去掉；可达信息在信息页。
            String label = pad(c.num) + "  " + c.name;
            Ui.styleRow(context, row,
                    at == focus, playing,
                    prefs.isFavorite(c.id), label);
        }
        footer.setText("↑↓ 选择   OK 切台   ←→ 分组   "
                + "绿键/设置 切换地区   菜单 收藏   返回 关闭");
        renderInfo();
    }

    /** 底部状态卡：当前台、线路、播放状态、地区与切换入口一次说清。 */
    private void renderInfo() {
        final StringBuilder b = new StringBuilder();
        b.append(stateFailed ? "⚠ " : "▶ ");
        if (stateChannel.length() > 0) b.append(stateChannel).append(" · ");
        b.append(stateLine).append(" · ").append(stateText);
        nowPlaying.setText(b.toString());
        nowPlaying.setTextColor(stateFailed ? 0xFFFF8A80 : Ui.TEXT);
        regionLine.setText("地区  " + stateRegion + " · " + stateLocalCount
                + " 个地方台（绿键 / 设置 切换省·市）");
        infoCard.setBackground(Ui.rect(context, Ui.CARD_SCRIM, 8, 0, 0));
    }

    /** Activity 推送当前播放状态；面板可见时立即刷新。 */
    void setPlaybackState(String channel, String line, String state,
                          boolean failed, String region, int localCount) {
        stateChannel = channel;
        stateLine = line;
        stateText = state;
        stateFailed = failed;
        stateRegion = region;
        stateLocalCount = localCount;
        if (isVisible()) renderInfo();
    }

    /** 高亮「当前正在播的台」——由 Activity 在打开面板时告知。 */
    private int playingChannel = -1;

    void setPlayingChannel(int index) {
        playingChannel = index;
    }

    private void activate() {
        if (filtered.isEmpty()) return;
        if (focus < 0 || focus >= filtered.size()) return;
        int channelIndex = filtered.get(focus).intValue();
        listener.onChannelPicked(channelIndex);
    }

    private void toggleFavorite() {
        if (filtered.isEmpty() || focus < 0 || focus >= filtered.size()) return;
        int channelIndex = filtered.get(focus).intValue();
        ChannelCatalog.Channel c = catalog.get(channelIndex);
        boolean now = prefs.toggleFavorite(c.id);
        listener.onFavoriteToggled(channelIndex, now);
        // 收藏分组里取消收藏后该项会消失，焦点要跟着收敛，避免落到空位。
        rebuild();
        render();
    }

    private static String pad(int num) {
        if (num >= 100) return String.valueOf(num);
        if (num >= 10) return " " + num;
        return "  " + num;
    }
}
