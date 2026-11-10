package com.shunbo.legacy;

import android.content.Context;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.view.Gravity;
import android.widget.TextView;

/**
 * 视觉常量与控件工厂。
 *
 * <p>刻意只做「深色底 + 半透明面板 + 蓝色焦点框」这一套：这是电视端最稳的组合，
 * 在 1280×720 的老屏上对比度足够，也不依赖 Material / Leanback 主题
 * （目标机是 Android 4.3，没有 Material，也不该为了圆角去引 support 库）。
 *
 * <p>焦点态统一由 {@link #styleRow}/{@link #styleButton} 设置**背景 drawable**，
 * 不用 XML selector：一套代码控制，改一处全站生效，也避免漏掉某个控件没焦点反馈。
 * 全部 API 均为 minSdk 16 可用（{@code View.setBackground} 是 API 16）。
 */
final class Ui {

    /** 全屏遮罩（面板/检索页背后压暗画面）。 */
    static final int SCRIM = 0xB3000000;
    /** 面板底色：深蓝灰，不纯黑，避免和画面黑边糊在一起。 */
    static final int PANEL = 0xF2141A22;
    /**
     * 频道栏浮层：65% 不透明度的深色压暗层。主流电视直播软件的频道列表
     * 都是半透明——左侧画面要能透出来，用户才能边挑台边确认当前台还在播。
     * 不用 0xFF 实色，也不低到 50% 以下（老电视对比度有限，字会糊）。
     */
    static final int PANEL_SCRIM = 0xA60B1420;
    /** 次级卡片（分组条、状态卡、输入框）：半透明版 CARD。 */
    static final int CARD_SCRIM = 0x801E2733;
    /** 次级卡片（分组条、输入框）：检索页等需要实底的场景仍用不透明。 */
    static final int CARD = 0xFF1E2733;
    /** 主文字。 */
    static final int TEXT = 0xFFFFFFFF;
    /** 次文字。 */
    static final int TEXT_DIM = 0xB3FFFFFF;
    /** 强调色（当前台、台号、进度）。 */
    static final int ACCENT = 0xFF4DA3FF;
    /** 焦点底：主流电视端的亮蓝高亮。 */
    static final int FOCUS = 0xFF1E88E5;
    /** 当前播放行底色（未聚焦时）。 */
    static final int PLAYING_BG = 0x332B6CB0;
    /** 播放中标记 / 收藏标记。 */
    static final String MARK_PLAYING = "▍";
    static final String MARK_FAV = "★";

    private Ui() {
    }

    static int dp(Context c, float v) {
        return (int) (v * c.getResources().getDisplayMetrics().density + 0.5f);
    }

    /** 圆角矩形；strokeW <= 0 表示不描边。 */
    static GradientDrawable rect(Context c, int fill, float radiusDp,
                                 int strokeW, int strokeColor) {
        GradientDrawable d = new GradientDrawable();
        d.setShape(GradientDrawable.RECTANGLE);
        d.setColor(fill);
        d.setCornerRadius(dp(c, radiusDp));
        if (strokeW > 0) d.setStroke(dp(c, strokeW), strokeColor);
        return d;
    }

    static TextView text(Context c, float sp, int color, boolean bold) {
        TextView v = new TextView(c);
        v.setTextColor(color);
        v.setTextSize(sp);
        if (bold) v.setTypeface(Typeface.DEFAULT_BOLD);
        v.setSingleLine(true);
        v.setIncludeFontPadding(false);
        v.setGravity(Gravity.CENTER_VERTICAL);
        return v;
    }

    /** 列表行：焦点 / 当前播放 / 收藏 三种状态叠加。 */
    static void styleRow(Context c, TextView row, boolean focused,
                         boolean playing, boolean favorite, String label) {
        StringBuilder b = new StringBuilder();
        if (playing) b.append(MARK_PLAYING).append(' ');
        b.append(label);
        if (favorite) b.append("  ").append(MARK_FAV);
        row.setText(b.toString());
        if (focused) {
            row.setBackground(rect(c, FOCUS, 6, 0, 0));
            row.setTextColor(TEXT);
            row.setTypeface(Typeface.DEFAULT_BOLD);
        } else if (playing) {
            row.setBackground(rect(c, PLAYING_BG, 6, 0, 0));
            row.setTextColor(ACCENT);
            row.setTypeface(Typeface.DEFAULT);
        } else {
            row.setBackground(null);
            row.setTextColor(TEXT_DIM);
            row.setTypeface(Typeface.DEFAULT);
        }
    }

    /** 底部控制条按钮：焦点时亮蓝填充 + 白字。 */
    static void styleButton(Context c, TextView btn, boolean focused, String label) {
        btn.setText(label);
        if (focused) {
            btn.setBackground(rect(c, FOCUS, 8, 0, 0));
            btn.setTextColor(TEXT);
        } else {
            btn.setBackground(rect(c, CARD, 8, 0, 0));
            btn.setTextColor(TEXT_DIM);
        }
    }

    /** 分组标签：选中时强调色填充。 */
    static void styleChip(Context c, TextView chip, boolean active, String label) {
        chip.setText(label);
        if (active) {
            chip.setBackground(rect(c, ACCENT, 10, 0, 0));
            chip.setTextColor(Color.BLACK);
            chip.setTypeface(Typeface.DEFAULT_BOLD);
        } else {
            // 频道栏的 chip 也要透出画面，所以这里用半透明卡片色。
            chip.setBackground(rect(c, CARD_SCRIM, 10, 0, 0));
            chip.setTextColor(TEXT_DIM);
            chip.setTypeface(Typeface.DEFAULT);
        }
    }

    /** 字母键格（检索页）：小方块，焦点时反色。 */
    static void styleKey(Context c, TextView key, boolean focused, String label) {
        key.setText(label);
        if (focused) {
            key.setBackground(rect(c, TEXT, 8, 0, 0));
            key.setTextColor(Color.BLACK);
        } else {
            key.setBackground(rect(c, CARD, 8, 0, 0));
            key.setTextColor(TEXT);
        }
    }
}
