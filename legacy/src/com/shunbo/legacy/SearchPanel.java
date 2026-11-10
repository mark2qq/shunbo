package com.shunbo.legacy;

import android.content.Context;
import android.view.Gravity;
import android.view.KeyEvent;
import android.view.View;
import android.widget.LinearLayout;
import android.widget.TextView;

import java.util.ArrayList;
import java.util.List;

/**
 * 频道检索页：26 字母网格 + 拼音首字母匹配。
 *
 * <p>遥控器没有键盘，所以检索只能做成「屏幕键盘 + 首字母」。拼音索引
 * （{@code pyi} 首字母串 / {@code py} 全拼串）在生成清单时就写进 channels.json，
 * 运行时零依赖、零计算——老机器上不必为了搜索再塞一份拼音字典。
 *
 * <p>匹配顺序刻意分三档：首字母前缀（{@code zjws} → 浙江卫视）> 全拼前缀
 * （{@code zhejiang}）> 任意位置包含。这样「zj」不会把「北京」排到「浙江」前面。
 */
final class SearchPanel {

    interface Listener {
        void onSearchPick(int channelIndex);
    }

    private static final int RESULT_ROWS = 8;
    private static final int COLS = 7;
    /** 参差行：最后一行只有 V–Z。按行长做焦点边界，比补齐空格更符合直觉。 */
    private static final String[] KEY_ROWS = {
            "ABCDEFG", "HIJKLMN", "OPQRSTU", "VWXYZ",
    };
    private static final String KEY_DEL = "⌫";
    private static final String KEY_CLR = "清空";

    private static final int AREA_RESULT = 0;
    private static final int AREA_GRID = 1;

    private final Context context;
    private final ChannelCatalog catalog;
    private final Prefs prefs;
    private final Listener listener;

    private final LinearLayout root;
    private final TextView queryView;
    private final TextView hintView;
    private final TextView[] resultViews = new TextView[RESULT_ROWS];
    private final TextView[][] keyViews =
            new TextView[KEY_ROWS.length][COLS];

    private final List<Integer> results = new ArrayList<Integer>();
    private String query = "";
    private int area = AREA_GRID;
    private int resultFocus = 0;
    private int gridRow = 0;
    private int gridCol = 0;

    SearchPanel(Context context, ChannelCatalog catalog, Prefs prefs, Listener listener) {
        this.context = context;
        this.catalog = catalog;
        this.prefs = prefs;
        this.listener = listener;

        root = new LinearLayout(context);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setBackgroundColor(0xF00A0E14);
        root.setPadding(Ui.dp(context, 24), Ui.dp(context, 18),
                Ui.dp(context, 24), Ui.dp(context, 16));
        root.setVisibility(View.GONE);

        LinearLayout header = new LinearLayout(context);
        header.setOrientation(LinearLayout.HORIZONTAL);
        header.setGravity(Gravity.CENTER_VERTICAL);
        root.addView(header, new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT));

        TextView caption = Ui.text(context, 15, Ui.TEXT_DIM, false);
        caption.setText("检索频道");
        header.addView(caption, new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT,
                LinearLayout.LayoutParams.WRAP_CONTENT));

        queryView = Ui.text(context, 26, Ui.ACCENT, true);
        queryView.setPadding(Ui.dp(context, 16), 0, 0, 0);
        header.addView(queryView, new LinearLayout.LayoutParams(
                0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f));

        hintView = Ui.text(context, 13, Ui.TEXT_DIM, false);
        header.addView(hintView, new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT,
                LinearLayout.LayoutParams.WRAP_CONTENT));

        LinearLayout resultBox = new LinearLayout(context);
        resultBox.setOrientation(LinearLayout.VERTICAL);
        // 结果贴着键盘上沿排：主流电视检索页都是「结果紧邻输入区」，
        // 中间留一大片空白会让人以为没搜到。
        resultBox.setGravity(Gravity.BOTTOM);
        LinearLayout.LayoutParams boxLp = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f);
        boxLp.topMargin = Ui.dp(context, 12);
        boxLp.bottomMargin = Ui.dp(context, 8);
        root.addView(resultBox, boxLp);

        for (int i = 0; i < RESULT_ROWS; i++) {
            final int slot = i;
            TextView row = Ui.text(context, 16, Ui.TEXT_DIM, false);
            row.setPadding(Ui.dp(context, 10), 0, Ui.dp(context, 10), 0);
            row.setOnClickListener(new View.OnClickListener() {
                @Override
                public void onClick(View v) {
                    area = AREA_RESULT;
                    resultFocus = slot;
                    activate();
                }
            });
            resultBox.addView(row, new LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.MATCH_PARENT, Ui.dp(context, 34)));
            resultViews[i] = row;
        }

        LinearLayout grid = new LinearLayout(context);
        grid.setOrientation(LinearLayout.VERTICAL);
        root.addView(grid, new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT));

        for (int r = 0; r < KEY_ROWS.length; r++) {
            LinearLayout line = new LinearLayout(context);
            line.setOrientation(LinearLayout.HORIZONTAL);
            LinearLayout.LayoutParams lineLp = new LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.MATCH_PARENT,
                    LinearLayout.LayoutParams.WRAP_CONTENT);
            lineLp.bottomMargin = Ui.dp(context, 6);
            grid.addView(line, lineLp);
            for (int c = 0; c < COLS; c++) {
                LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                        0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f);
                lp.setMargins(Ui.dp(context, 3), 0, Ui.dp(context, 3), 0);
                if (c >= KEY_ROWS[r].length()) {
                    // 占位：保持每格等宽，让最后一行左对齐而不是被拉伸居中
                    View spacer = new View(context);
                    line.addView(spacer, lp);
                    continue;
                }
                final int row = r;
                final int col = c;
                TextView key = Ui.text(context, 16, Ui.TEXT, false);
                key.setGravity(Gravity.CENTER);
                key.setPadding(0, Ui.dp(context, 8), 0, Ui.dp(context, 8));
                key.setOnClickListener(new View.OnClickListener() {
                    @Override
                    public void onClick(View v) {
                        area = AREA_GRID;
                        gridRow = row;
                        gridCol = col;
                        pressKey(String.valueOf(KEY_ROWS[row].charAt(col)));
                    }
                });
                line.addView(key, lp);
                keyViews[r][c] = key;
            }
        }

        LinearLayout footerLine = new LinearLayout(context);
        footerLine.setOrientation(LinearLayout.HORIZONTAL);
        root.addView(footerLine, new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT));

        TextView del = Ui.text(context, 15, Ui.TEXT, false);
        del.setGravity(Gravity.CENTER);
        del.setPadding(Ui.dp(context, 18), Ui.dp(context, 9),
                Ui.dp(context, 18), Ui.dp(context, 9));
        del.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                area = AREA_GRID;
                pressKey(KEY_DEL);
            }
        });
        footerLine.addView(del, new LinearLayout.LayoutParams(
                0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f));
        del.setTag("del");

        TextView clr = Ui.text(context, 15, Ui.TEXT, false);
        clr.setGravity(Gravity.CENTER);
        clr.setPadding(Ui.dp(context, 18), Ui.dp(context, 9),
                Ui.dp(context, 18), Ui.dp(context, 9));
        clr.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                area = AREA_GRID;
                pressKey(KEY_CLR);
            }
        });
        footerLine.addView(clr, new LinearLayout.LayoutParams(
                0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f));
        clr.setTag("clr");

        extraDel = del;
        extraClr = clr;
    }

    private TextView extraDel;
    private TextView extraClr;

    View getView() {
        return root;
    }

    boolean isVisible() {
        return root.getVisibility() == View.VISIBLE;
    }

    void show() {
        root.setVisibility(View.VISIBLE);
        query = "";
        area = AREA_GRID;
        gridRow = 0;
        gridCol = 0;
        resultFocus = 0;
        refresh();
    }

    void hide() {
        root.setVisibility(View.GONE);
    }

    String getQuery() {
        return query;
    }

    int resultCount() {
        return results.size();
    }

    boolean handleKey(int keyCode) {
        if (keyCode >= KeyEvent.KEYCODE_0 && keyCode <= KeyEvent.KEYCODE_9) {
            append(String.valueOf((char) ('0' + (keyCode - KeyEvent.KEYCODE_0))));
            return true;
        }
        if (keyCode >= KeyEvent.KEYCODE_A && keyCode <= KeyEvent.KEYCODE_Z) {
            append(String.valueOf((char) ('a' + (keyCode - KeyEvent.KEYCODE_A))));
            return true;
        }
        switch (keyCode) {
            case KeyEvent.KEYCODE_DPAD_UP:
                moveVertical(-1);
                return true;
            case KeyEvent.KEYCODE_DPAD_DOWN:
                moveVertical(1);
                return true;
            case KeyEvent.KEYCODE_DPAD_LEFT:
                moveHorizontal(-1);
                return true;
            case KeyEvent.KEYCODE_DPAD_RIGHT:
                moveHorizontal(1);
                return true;
            case KeyEvent.KEYCODE_DPAD_CENTER:
            case KeyEvent.KEYCODE_ENTER:
                activate();
                return true;
            case KeyEvent.KEYCODE_DEL:
                pressKey(KEY_DEL);
                return true;
            case KeyEvent.KEYCODE_MENU:
                pressKey(KEY_CLR);
                return true;
            case KeyEvent.KEYCODE_BACK:
                if (query.length() > 0) {
                    query = query.substring(0, query.length() - 1);
                    refresh();
                } else {
                    hide();
                }
                return true;
            default:
                return false;
        }
    }

    // ---------------------------------------------------------------- 内部

    private void moveVertical(int delta) {
        if (area == AREA_RESULT) {
            if (results.isEmpty()) {
                area = AREA_GRID;
                render();
                return;
            }
            int next = resultFocus + delta;
            if (next < 0 || next >= results.size()) {
                // 结果区在网格上方：下到底 / 上到顶都回到网格顶部
                area = AREA_GRID;
                render();
                return;
            }
            resultFocus = next;
            render();
            return;
        }
        // 网格内
        int newRow = gridRow + delta;
        if (newRow < 0) {
            // 网格上边：跳到结果区最后一条（结果区在网格上方）
            if (results.isEmpty()) return;
            area = AREA_RESULT;
            resultFocus = results.size() - 1;
            render();
            return;
        }
        if (newRow >= KEY_ROWS.length) return;
        gridRow = newRow;
        if (gridCol >= KEY_ROWS[gridRow].length()) {
            gridCol = KEY_ROWS[gridRow].length() - 1;
        }
        render();
    }

    private void moveHorizontal(int delta) {
        if (area == AREA_RESULT) return;
        int len = KEY_ROWS[gridRow].length();
        gridCol = ((gridCol + delta) % len + len) % len;
        render();
    }

    private void activate() {
        if (area == AREA_RESULT) {
            if (results.isEmpty()) return;
            if (resultFocus < 0 || resultFocus >= results.size()) return;
            listener.onSearchPick(results.get(resultFocus).intValue());
            return;
        }
        pressKey(String.valueOf(KEY_ROWS[gridRow].charAt(gridCol)));
    }

    private void pressKey(String key) {
        if (KEY_DEL.equals(key)) {
            if (query.length() > 0) query = query.substring(0, query.length() - 1);
            refresh();
            return;
        }
        if (KEY_CLR.equals(key)) {
            query = "";
            refresh();
            return;
        }
        append(key);
    }

    private void append(String ch) {
        if (query.length() >= 18) return;
        query = query + ch.toLowerCase();
        // 输入后结果会变，焦点留在键盘上——这是屏幕键盘的通用手感：
        // 只有主动按「上」才把焦点移到结果列表。
        area = AREA_GRID;
        resultFocus = 0;
        refresh();
    }

    private void refresh() {
        results.clear();
        String q = query.toLowerCase();
        List<int[]> scored = new ArrayList<int[]>();
        for (int i = 0; i < catalog.size(); i++) {
            ChannelCatalog.Channel c = catalog.get(i);
            int score = score(c, q);
            if (score > 0) scored.add(new int[]{score, i});
        }
        // 稳定排序：先按 score 降序，再按台号升序（Dart/Java 的 sort 都不稳定，
        // 所以把台号作为显式第二键，避免同一分数下顺序抖动）。
        for (int i = 1; i < scored.size(); i++) {
            int[] cur = scored.get(i);
            int j = i - 1;
            while (j >= 0 && better(cur, scored.get(j))) {
                scored.set(j + 1, scored.get(j));
                j--;
            }
            scored.set(j + 1, cur);
        }
        final int limit = 120;
        for (int i = 0; i < scored.size() && i < limit; i++) {
            results.add(Integer.valueOf(scored.get(i)[1]));
        }
        if (resultFocus >= results.size()) resultFocus = results.isEmpty() ? 0 : results.size() - 1;
        render();
    }

    private boolean better(int[] a, int[] b) {
        if (a[0] != b[0]) return a[0] > b[0];
        return catalog.get(a[1]).num < catalog.get(b[1]).num;
    }

    /** 0 = 不匹配；分值越大越靠前。 */
    private int score(ChannelCatalog.Channel c, String q) {
        if (q.length() == 0) return prefs.isFavorite(c.id) ? 2 : 1;
        String pyi = c.pyi == null ? "" : c.pyi;
        String py = c.py == null ? "" : c.py;
        String name = c.name == null ? "" : c.name.toLowerCase();
        if (pyi.startsWith(q)) return 100;
        if (py.startsWith(q)) return 80;
        if (name.startsWith(q)) return 70;
        if (pyi.contains(q)) return 50;
        if (py.contains(q)) return 30;
        if (name.contains(q)) return 20;
        return 0;
    }

    private void render() {
        queryView.setText(query.length() == 0 ? "输入首字母，如 zjws / cctv1" : query + "_");
        hintView.setText("结果 " + results.size() + " 台");
        int s = 0;
        if (area == AREA_RESULT && results.size() > RESULT_ROWS) {
            s = resultFocus - RESULT_ROWS / 2;
            if (s < 0) s = 0;
            if (s > results.size() - RESULT_ROWS) s = results.size() - RESULT_ROWS;
        }
        for (int i = 0; i < RESULT_ROWS; i++) {
            int at = s + i;
            TextView row = resultViews[i];
            if (at >= results.size()) {
                if (i == 0 && results.isEmpty()) {
                    row.setText("没有匹配的频道，按「清空」重来");
                    row.setTextColor(Ui.TEXT_DIM);
                    row.setBackground(null);
                    row.setVisibility(View.VISIBLE);
                } else {
                    // 多余行直接 GONE：留着空行会把结果顶到屏幕上方，
                    // 看起来像「中间空了一大块」。
                    row.setVisibility(View.GONE);
                }
                continue;
            }
            row.setVisibility(View.VISIBLE);
            ChannelCatalog.Channel c = catalog.get(results.get(at).intValue());
            boolean focused = area == AREA_RESULT && at == resultFocus;
            Ui.styleRow(context, row, focused, false, prefs.isFavorite(c.id),
                    pad(c.num) + "  " + c.name + "  · " + c.group);
        }
        for (int r = 0; r < KEY_ROWS.length; r++) {
            for (int c = 0; c < KEY_ROWS[r].length(); c++) {
                Ui.styleKey(context, keyViews[r][c],
                        area == AREA_GRID && r == gridRow && c == gridCol,
                        String.valueOf(KEY_ROWS[r].charAt(c)));
            }
        }
        if (extraDel != null) {
            Ui.styleButton(context, extraDel, false, KEY_DEL + " 删除");
        }
        if (extraClr != null) {
            Ui.styleButton(context, extraClr, false, KEY_CLR);
        }
    }

    private static String pad(int num) {
        if (num >= 100) return String.valueOf(num);
        if (num >= 10) return " " + num;
        return "  " + num;
    }
}
