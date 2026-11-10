package com.shunbo.legacy;

import android.content.Context;
import android.view.Gravity;
import android.view.View;
import android.widget.LinearLayout;
import android.widget.TextView;

/**
 * 底部控制条：遥控器可聚焦的功能行。
 *
 * <p>之前这一层只有一行静态提示文字，所有操作都靠背快捷键；实际用遥控器时
 * 没人记得住，等于没有入口。这里改成主流电视播放器的做法：按 OK / ↓ 唤出，
 * ←→ 移动焦点，OK 执行，无操作自动收起（时长由「浮层自动隐藏」设置决定）。
 *
 * <p>只承载「命令」，不持有播放状态：焦点变化与点击统一回调给 Activity，
 * 由它决定是切台、换线还是开面板，避免同一份状态在两个类里各存一遍。
 */
final class ControlBar {

    interface Listener {
        void onControlAction(String action);

        void onControlFocus(String action);
    }

    static final String A_PANEL = "panel";
    static final String A_REGION = "region";
    static final String A_RETRY = "retry";
    static final String A_FAV = "fav";
    static final String A_LINE = "line";
    static final String A_PREV = "prev";
    static final String A_PAUSE = "pause";
    static final String A_NEXT = "next";
    static final String A_SEARCH = "search";
    static final String A_SETTINGS = "settings";
    static final String A_INFO = "info";

    private static final String[] IDS = {
            A_PANEL, A_REGION, A_PREV, A_PAUSE, A_NEXT,
            A_LINE, A_RETRY, A_FAV, A_SEARCH, A_SETTINGS, A_INFO,
    };

    private final Context context;
    private final Listener listener;
    private final LinearLayout root;
    private final TextView[] buttons = new TextView[IDS.length];
    private int focus = 0;
    private boolean paused = false;
    private boolean favorite = false;

    ControlBar(Context context, Listener listener) {
        this.context = context;
        this.listener = listener;

        root = new LinearLayout(context);
        root.setOrientation(LinearLayout.HORIZONTAL);
        root.setGravity(Gravity.CENTER);
        root.setBackgroundColor(Ui.SCRIM);
        root.setPadding(Ui.dp(context, 16), Ui.dp(context, 10),
                Ui.dp(context, 16), Ui.dp(context, 10));
        root.setVisibility(View.GONE);

        for (int i = 0; i < IDS.length; i++) {
            TextView btn = Ui.text(context, 15, Ui.TEXT_DIM, false);
            btn.setGravity(Gravity.CENTER);
            btn.setPadding(Ui.dp(context, 10), Ui.dp(context, 9),
                    Ui.dp(context, 10), Ui.dp(context, 9));
            final int index = i;
            btn.setOnClickListener(new View.OnClickListener() {
                @Override
                public void onClick(View v) {
                    focusTo(index);
                    activate();
                }
            });
            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                    0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f);
            lp.setMargins(Ui.dp(context, 3), 0, Ui.dp(context, 3), 0);
            root.addView(btn, lp);
            buttons[i] = btn;
        }
        refresh();
    }

    View getView() {
        return root;
    }

    boolean isVisible() {
        return root.getVisibility() == View.VISIBLE;
    }

    void setVisible(boolean visible) {
        root.setVisibility(visible ? View.VISIBLE : View.GONE);
        if (visible) {
            // 每次唤出都把焦点放回「频道」：绝大多数操作的第一步都是它，
            // 也避免上次停在「信息」上再按 OK 时让人意外。
            focusTo(0);
        }
    }

    void setPaused(boolean value) {
        paused = value;
        refresh();
    }

    void setFavorite(boolean value) {
        favorite = value;
        refresh();
    }

    String getFocusId() {
        return IDS[focus];
    }

    void move(int delta) {
        int n = IDS.length;
        focus = ((focus + delta) % n + n) % n;
        refresh();
        listener.onControlFocus(getFocusId());
    }

    void activate() {
        listener.onControlAction(getFocusId());
    }

    private void focusTo(int index) {
        focus = ((index % IDS.length) + IDS.length) % IDS.length;
        refresh();
        listener.onControlFocus(getFocusId());
    }

    private String labelOf(int i) {
        switch (IDS[i]) {
            case A_PANEL:
                return "频道";
            case A_REGION:
                return "地区";
            case A_RETRY:
                return "重试";
            case A_FAV:
                return favorite ? "已收藏 ★" : "收藏 ☆";
            case A_LINE:
                return "换线路";
            case A_PREV:
                return "上一台";
            case A_PAUSE:
                return paused ? "继续" : "暂停";
            case A_NEXT:
                return "下一台";
            case A_SEARCH:
                return "检索";
            case A_SETTINGS:
                return "设置";
            case A_INFO:
                return "信息";
            default:
                return IDS[i];
        }
    }

    private void refresh() {
        for (int i = 0; i < buttons.length; i++) {
            Ui.styleButton(context, buttons[i], i == focus, labelOf(i));
        }
    }
}
