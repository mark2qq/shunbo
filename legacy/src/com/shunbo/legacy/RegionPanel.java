package com.shunbo.legacy;

import android.content.Context;
import android.graphics.Typeface;
import android.text.Spannable;
import android.text.SpannableString;
import android.text.TextUtils;
import android.text.style.ForegroundColorSpan;
import android.text.style.RelativeSizeSpan;
import android.util.DisplayMetrics;
import android.view.Gravity;
import android.view.KeyEvent;
import android.view.View;
import android.widget.LinearLayout;
import android.widget.TextView;

import java.util.ArrayList;
import java.util.List;

/**
 * 省 / 市地区选择面板：三列（最近 / 省 / 市），遥控器可操作，选中即应用。
 *
 * <p>需求原文：「默认只显示本地地方台，其它地方台不要显示，但可以通过切换城市
 * （切换省则把本省的所有地方台都加载，切换市则把本市的所有台加载）来加载」。
 *
 * <p><b>本轮重设计的三个点</b>：
 * <ol>
 *   <li><b>入口清晰</b>：绿键 / 导视键、频道栏「地区·苏州 ▾切换」chip、
 *       底部状态卡、控制条「地区」按钮四处都能打开；面板标题直接写明
 *       「当前地区 + 正在播的台 + 播放状态」。</li>
 *   <li><b>步骤少</b>：新增「最近使用」列并默认聚焦，回到常看城市只要
 *       「绿键 → OK」两步；省 / 市两列也保持「←→ 切列、↑↓ 选行、OK 应用」，
 *       选中后立刻应用并关闭，没有额外的「确定」页。</li>
 *   <li><b>稳定</b>：切换只重算可见列表，不重启播放器、不打断正在播的画面；
 *       央视 / 卫视 / 其它频道任何地区下都始终可见。</li>
 * </ol>
 *
 * <p>目录与台数都由 {@code channels.json} 的 {@code regions} 段给出，
 * 老机器运行时不重算归属。末尾「其它城市」收容推断不出省市的台。
 */
final class RegionPanel {

    interface Listener {
        void onRegionPicked(String mode, String province, String city);
    }

    /** 列内行数按屏幕高度算出（见 {@link #computeRows}），不再写死 9 行。 */
    private static final float ROW_SP = 22f;
    private static final float HEAD_SP = 18f;
    private static final int COL_QUICK = 0;
    private static final int COL_PROVINCE = 1;
    private static final int COL_CITY = 2;
    private static final String OTHER = ChannelCatalog.OTHER_LABEL;

    private final Context context;
    private final ChannelCatalog catalog;
    private final Prefs prefs;
    private final Listener listener;

    private final LinearLayout root;
    private final TextView title;
    private final int rowCount;
    private final TextView[] quick;
    private final TextView[] left;
    private final TextView[] right;

    /** 左列 {名称, 台数}；右列 {名称, 台数}；快捷列 {标题, mode, 省, 市}。 */
    private final List<String[]> provinces = new ArrayList<String[]>();
    private List<String[]> cities = new ArrayList<String[]>();
    private final List<String[]> recents = new ArrayList<String[]>();

    private int col = COL_QUICK;
    private int qFocus = 0;
    private int pFocus = 0;
    private int cFocus = 0;
    private String stateText = "";

    RegionPanel(Context context, ChannelCatalog catalog, Prefs prefs,
                Listener listener) {
        this.context = context;
        this.catalog = catalog;
        this.prefs = prefs;
        this.listener = listener;

        root = new LinearLayout(context);
        root.setOrientation(LinearLayout.VERTICAL);
        // 全屏 EPG 式半透明遮罩：画面仍在，文字靠高对比度前景保证可读。
        root.setBackgroundColor(Ui.SCRIM);
        root.setPadding(Ui.dp(context, 26), Ui.dp(context, 16),
                Ui.dp(context, 26), Ui.dp(context, 12));
        root.setVisibility(View.GONE);

        rowCount = computeRows(context);
        quick = new TextView[rowCount];
        left = new TextView[rowCount];
        right = new TextView[rowCount];

        title = Ui.text(context, 21, Ui.TEXT, true);
        // 标题可能很长（含「正在播什么」），放大后必须省略而不是溢出屏幕。
        title.setEllipsize(TextUtils.TruncateAt.END);
        root.addView(title, new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT));

        // 提示只保留按键说明：省 / 市的含义已写在列头，原先把两者塞进同一行
        // 会被屏幕截断（截图里只剩「并关闭 | 左列选省=…」的半句）。
        TextView hint = Ui.text(context, 14, Ui.TEXT_DIM, false);
        hint.setText("←→ 切列    ↑↓ 选行    OK 应用并关闭    返回 取消");
        hint.setEllipsize(TextUtils.TruncateAt.END);
        hint.setPadding(0, Ui.dp(context, 6), 0, Ui.dp(context, 8));
        root.addView(hint, new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT));

        LinearLayout columns = new LinearLayout(context);
        columns.setOrientation(LinearLayout.HORIZONTAL);
        root.addView(columns, new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f));

        buildColumn(columns, "最近使用 / 快捷", quick, COL_QUICK);
        buildColumn(columns, "省 / 全省", left, COL_PROVINCE);
        buildColumn(columns, "市 / 本市", right, COL_CITY);

        TextView footer = Ui.text(context, 13, Ui.TEXT_DIM, false);
        // 放大字号后长句会被截断，这里只留最关键的一句。
        footer.setText("切换只改列表，不打断正在播的画面 · 返回 取消");
        footer.setEllipsize(TextUtils.TruncateAt.END);
        footer.setPadding(0, Ui.dp(context, 8), 0, 0);
        root.addView(footer, new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT));
    }

    private void buildColumn(LinearLayout parent, String caption,
                             final TextView[] rows, final int column) {
        LinearLayout box = new LinearLayout(context);
        box.setOrientation(LinearLayout.VERTICAL);
        box.setPadding(0, 0, Ui.dp(context, 12), 0);
        parent.addView(box, new LinearLayout.LayoutParams(
                0, LinearLayout.LayoutParams.MATCH_PARENT, 1f));

        TextView head = Ui.text(context, HEAD_SP, Ui.ACCENT, true);
        head.setText(caption);
        head.setEllipsize(TextUtils.TruncateAt.END);
        head.setPadding(Ui.dp(context, 10), 0, Ui.dp(context, 10), Ui.dp(context, 6));
        box.addView(head, new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT));

        // 主流电视播放软件的省 / 市列表：字大、行距均匀、整列铺满不留空白。
        // 演进过程：15sp + weight 拉满（行距巨大）→ 19sp + 固定 38dp 顶部对齐
        // （底部一大片空白，截图红标「要铺满，不留空白」）→ 现在 22sp + 行数按
        // 屏幕高度算（computeRows）+ weight 均分，既铺满列高、又把字放大。
        for (int i = 0; i < rowCount; i++) {
            final int slot = i;
            TextView row = Ui.text(context, ROW_SP, Ui.TEXT, false);
            row.setPadding(Ui.dp(context, 10), 0, Ui.dp(context, 10), 0);
            row.setEllipsize(TextUtils.TruncateAt.END);
            row.setGravity(Gravity.CENTER_VERTICAL);
            row.setOnClickListener(new View.OnClickListener() {
                @Override
                public void onClick(View v) {
                    int at = start(focusOf(column), sizeOf(column)) + slot;
                    if (at >= sizeOf(column)) return;
                    setFocusOf(column, at);
                    col = column;
                    if (column == COL_PROVINCE) reloadCities();
                    apply();
                }
            });
            // weight=1 均分列内剩余高度：整列铺满到页脚，底部不留空白。
            box.addView(row, new LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f));
            rows[i] = row;
        }
    }

    /**
     * 行数按屏幕高度算：22sp 字下每行约 40dp（字高约 1.4 倍，紧凑但不挤）；
     * 标题 / 提示 / 页脚与内边距合计按 150dp 预留。7~14 行之间收敛：
     * 540dp 高的老电视约 9 行、720dp 约 14 行，都能把列高铺满。
     */
    private static int computeRows(Context c) {
        final DisplayMetrics dm = c.getResources().getDisplayMetrics();
        final int heightDp = (int) (dm.heightPixels / dm.density);
        final int n = (heightDp - 150) / 40;
        return Math.max(7, Math.min(14, n));
    }

    private int sizeOf(int column) {
        if (column == COL_QUICK) return recents.size();
        if (column == COL_PROVINCE) return provinces.size();
        return cities.size();
    }

    private int focusOf(int column) {
        if (column == COL_QUICK) return qFocus;
        if (column == COL_PROVINCE) return pFocus;
        return cFocus;
    }

    private void setFocusOf(int column, int value) {
        if (column == COL_QUICK) qFocus = value;
        else if (column == COL_PROVINCE) pFocus = value;
        else cFocus = value;
    }

    View getView() { return root; }

    boolean isVisible() { return root.getVisibility() == View.VISIBLE; }

    void hide() { root.setVisibility(View.GONE); }

    /** Activity 在打开面板前推送「正在播什么、播得怎么样」。 */
    void setStateText(String text) {
        stateText = text == null ? "" : text;
        if (isVisible()) render();
    }

    void show() {
        root.setVisibility(View.VISIBLE);
        provinces.clear();
        for (ChannelCatalog.RegionOption o : catalog.provinceOptions()) {
            provinces.add(new String[]{o.name, String.valueOf(o.count)});
        }
        provinces.add(new String[]{OTHER,
                String.valueOf(catalog.otherRegionCount())});

        // 最近使用：把「当前地区」排除掉，剩下的按最近顺序排列；
        // 再补一条「本省全部」快捷项，方便一键从市切到全省。
        recents.clear();
        final String currentMode = catalog.regionMode();
        final String currentProvince = catalog.regionProvince();
        final String currentCity = catalog.regionCity();
        if (prefs != null) {
            for (String[] r : prefs.recentRegions()) {
                final String mode = r[0], province = r[1], city = r[2];
                if (mode.equals(currentMode) && province.equals(currentProvince)
                        && city.equals(currentCity)) continue;
                recents.add(new String[]{labelOf(mode, province, city),
                        mode, province, city});
                if (recents.size() >= rowCount - 1) break;
            }
        }
        if (currentProvince.length() > 0
                && !ChannelCatalog.MODE_PROVINCE.equals(currentMode)) {
            recents.add(new String[]{"▸ " + currentProvince + "全省（全部地方台）",
                    ChannelCatalog.MODE_PROVINCE, currentProvince, currentCity});
        }
        qFocus = 0;
        col = recents.isEmpty() ? COL_PROVINCE : COL_QUICK;

        String wanted = ChannelCatalog.MODE_OTHER.equals(currentMode)
                ? OTHER : currentProvince;
        pFocus = Math.max(0, indexOf(provinces, wanted));
        reloadCities();
        cFocus = Math.max(0, indexOf(cities, currentCity));
        render();
    }

    private static String labelOf(String mode, String province, String city) {
        if (ChannelCatalog.MODE_PROVINCE.equals(mode)) return province + "全省";
        if (ChannelCatalog.MODE_OTHER.equals(mode)) return OTHER;
        return (province.length() > 0 ? province + " · " : "") + city;
    }

    private void reloadCities() {
        cities = new ArrayList<String[]>();
        if (provinces.isEmpty() || OTHER.equals(provinces.get(pFocus)[0])) return;
        String province = provinces.get(pFocus)[0];
        for (ChannelCatalog.RegionOption o : catalog.cityOptions(province)) {
            cities.add(new String[]{o.name, String.valueOf(o.count)});
        }
        if (cFocus >= cities.size()) cFocus = 0;
    }

    boolean handleKey(int keyCode) {
        switch (keyCode) {
            case KeyEvent.KEYCODE_DPAD_UP:
                moveFocus(-1);
                render();
                return true;
            case KeyEvent.KEYCODE_DPAD_DOWN:
                moveFocus(1);
                render();
                return true;
            case KeyEvent.KEYCODE_DPAD_LEFT:
                col = Math.max(COL_QUICK, col - 1);
                if (col == COL_QUICK && recents.isEmpty()) col = COL_PROVINCE;
                render();
                return true;
            case KeyEvent.KEYCODE_DPAD_RIGHT:
                col = Math.min(COL_CITY, col + 1);
                render();
                return true;
            case KeyEvent.KEYCODE_DPAD_CENTER:
            case KeyEvent.KEYCODE_ENTER:
                apply();
                return true;
            case KeyEvent.KEYCODE_BACK:
            case KeyEvent.KEYCODE_ESCAPE:
                hide();
                return true;
            case KeyEvent.KEYCODE_PROG_GREEN:
            case KeyEvent.KEYCODE_GUIDE:
                // 面板已打开时再按绿键 = 取消，符合「按一下开、再按一下关」。
                hide();
                return true;
            default:
                return false;
        }
    }

    private void moveFocus(int delta) {
        final int n = sizeOf(col);
        if (n == 0) return;
        setFocusOf(col, ((focusOf(col) + delta) % n + n) % n);
        if (col == COL_PROVINCE) {
            reloadCities();
            cFocus = 0;
        }
    }

    private void apply() {
        if (col == COL_QUICK) {
            if (recents.isEmpty() || qFocus >= recents.size()) return;
            String[] e = recents.get(qFocus);
            listener.onRegionPicked(e[1], e[2], e[3]);
            return;
        }
        if (provinces.isEmpty()) return;
        String province = provinces.get(pFocus)[0];
        if (col == COL_PROVINCE) {
            if (OTHER.equals(province)) {
                listener.onRegionPicked(ChannelCatalog.MODE_OTHER, "", "");
            } else {
                // 省模式：city 只作为面板下次打开的定位线索，过滤时只看 province。
                listener.onRegionPicked(ChannelCatalog.MODE_PROVINCE,
                        province, catalog.regionCity());
            }
            return;
        }
        if (cities.isEmpty()) return;
        if (OTHER.equals(province)) {
            listener.onRegionPicked(ChannelCatalog.MODE_OTHER, "", "");
        } else {
            listener.onRegionPicked(ChannelCatalog.MODE_CITY,
                    province, cities.get(cFocus)[0]);
        }
    }

    private void render() {
        title.setText("地区选择 · 当前 " + catalog.regionLabel()
                + " · " + catalog.localCount() + " 个地方台"
                + (stateText.length() > 0 ? "   |   " + stateText : ""));
        fillQuick();
        fillColumn(left, provinces, start(pFocus, provinces.size()), pFocus,
                col == COL_PROVINCE, catalog.regionProvince(), OTHER);
        fillColumn(right, cities, start(cFocus, cities.size()), cFocus,
                col == COL_CITY, catalog.regionCity(), null);
    }

    private void fillQuick() {
        for (int i = 0; i < rowCount; i++) {
            int at = start(qFocus, recents.size()) + i;
            TextView row = quick[i];
            if (at >= recents.size()) {
                row.setText(i == 0 && recents.isEmpty()
                        ? "（暂无最近地区，用 → 选省 / 市）" : "");
                row.setBackground(null);
                row.setTextColor(Ui.TEXT_DIM);
                row.setTypeface(Typeface.DEFAULT);
                continue;
            }
            applyRowStyle(row, col == COL_QUICK && at == qFocus, false,
                    (at == qFocus ? "▸ " : "") + recents.get(at)[0], null);
        }
    }

    private void fillColumn(TextView[] rows, List<String[]> data, int start,
                            int focus, boolean columnActive,
                            String currentName, String special) {
        for (int i = 0; i < rowCount; i++) {
            int at = start + i;
            TextView row = rows[i];
            if (at >= data.size()) {
                row.setText(i == 0 && data.isEmpty()
                        ? (special == null ? "（此省没有可切换的市）" : "（无地区数据）")
                        : "");
                row.setBackground(null);
                row.setTextColor(Ui.TEXT_DIM);
                row.setTypeface(Typeface.DEFAULT);
                continue;
            }
            String name = data.get(at)[0];
            applyRowStyle(row, columnActive && at == focus, name.equals(currentName),
                    name, data.get(at)[1] + " 台");
        }
    }

    /**
     * 行样式：名称用主字色（放大后要醒目），台数用小一号的次字色（层级分明），
     * 当前地区用「●」标出；焦点行亮蓝底白字加粗。所有行单行 + 末尾省略号，
     * 字号放大后也不会溢出或换行错位。
     */
    private void applyRowStyle(TextView row, boolean focused, boolean current,
                               String name, String suffix) {
        String head = (current ? "● " : "") + name;
        String tail = suffix == null ? "" : "   " + suffix;
        SpannableString text = new SpannableString(head + tail);
        if (tail.length() > 0) {
            final int from = head.length();
            text.setSpan(new RelativeSizeSpan(0.82f), from, text.length(),
                    Spannable.SPAN_EXCLUSIVE_EXCLUSIVE);
            text.setSpan(new ForegroundColorSpan(focused ? Ui.TEXT : Ui.TEXT_DIM),
                    from, text.length(), Spannable.SPAN_EXCLUSIVE_EXCLUSIVE);
        }
        row.setText(text);
        if (focused) {
            row.setBackground(Ui.rect(context, Ui.FOCUS, 6, 0, 0));
            row.setTextColor(Ui.TEXT);
            row.setTypeface(Typeface.DEFAULT_BOLD);
        } else if (current) {
            row.setBackground(null);
            row.setTextColor(Ui.ACCENT);
            row.setTypeface(Typeface.DEFAULT);
        } else {
            row.setBackground(null);
            row.setTextColor(Ui.TEXT);
            row.setTypeface(Typeface.DEFAULT);
        }
    }

    private int start(int focus, int n) {
        if (n <= rowCount) return 0;
        int s = focus - rowCount / 2;
        if (s < 0) s = 0;
        if (s > n - rowCount) s = n - rowCount;
        return s;
    }

    private static int indexOf(List<String[]> data, String name) {
        for (int i = 0; i < data.size(); i++) {
            if (data.get(i)[0].equals(name)) return i;
        }
        return 0;
    }
}
