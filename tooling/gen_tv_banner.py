#!/usr/bin/env python3
"""生成电视桌面横幅 PNG（R2）。

为什么不用现成的矢量图：`android:banner` 在部分电视桌面与商店校验里会被当成
普通位图读取（aapt2 badging 对 XML 矢量只能输出 `banner=''`），
真机上偶尔会出现「白底空图」。位图最稳，且 320x180 的体积只有几 KB，
不影响 R9 的 60 MB 预算。

本机没有 Pillow，所以这里用标准库直接写 PNG（zlib + struct），
不引入任何构建依赖，可在 CI 上逐字节复现。

用法：python tooling/gen_tv_banner.py
"""
import os
import struct
import zlib

W, H = 320, 180

BG = (0x12, 0x16, 0x1C)
ACCENT = (0x4C, 0x8D, 0xFF)
TITLE = (0xF2, 0xF5, 0xF9)
SUBTITLE = (0x9A, 0xA7, 0xB8)


def blend(dst, src, alpha):
    return tuple(
        int(dst[i] * (1 - alpha) + src[i] * alpha) for i in range(3)
    )


def rounded_rect(px, x0, y0, x1, y1, color, radius=0):
    for y in range(max(0, y0), min(H, y1)):
        for x in range(max(0, x0), min(W, x1)):
            # 4 点超采样做抗锯齿（边缘不要锯齿，电视桌面是等比放大的）
            hits = 0
            for sy in (0.25, 0.75):
                for sx in (0.25, 0.75):
                    fx, fy = x + sx, y + sy
                    if radius > 0:
                        cx = min(max(fx, x0 + radius), x1 - radius)
                        cy = min(max(fy, y0 + radius), y1 - radius)
                        if (fx - cx) ** 2 + (fy - cy) ** 2 > radius * radius:
                            continue
                    hits += 1
            if hits:
                px[y][x] = blend(px[y][x], color, hits / 4.0)


def triangle(px, ax, ay, bx, by, cx, cy, color):
    def sign(x1, y1, x2, y2, x3, y3):
        return (x1 - x3) * (y2 - y3) - (x2 - x3) * (y1 - y3)

    minx, maxx = int(min(ax, bx, cx)), int(max(ax, bx, cx)) + 1
    miny, maxy = int(min(ay, by, cy)), int(max(ay, by, cy)) + 1
    for y in range(max(0, miny), min(H, maxy)):
        for x in range(max(0, minx), min(W, maxx)):
            inside = 0
            for sy in (0.25, 0.75):
                for sx in (0.25, 0.75):
                    fx, fy = x + sx, y + sy
                    d1 = sign(fx, fy, ax, ay, bx, by)
                    d2 = sign(fx, fy, bx, by, cx, cy)
                    d3 = sign(fx, fy, cx, cy, ax, ay)
                    has_neg = d1 < 0 or d2 < 0 or d3 < 0
                    has_pos = d1 > 0 or d2 > 0 or d3 > 0
                    if not (has_neg and has_pos):
                        inside += 1
            if inside:
                px[y][x] = blend(px[y][x], color, inside / 4.0)


def build():
    px = [[BG for _ in range(W)] for _ in range(H)]

    # 左侧强调竖条（与应用内导航栏选中条同色）
    rounded_rect(px, 24, 44, 30, 136, ACCENT, radius=3)
    # 品牌播放三角
    triangle(px, 52, 68, 100, 90, 52, 112, ACCENT)
    # 标题条 + 副标题条（矢量图无法写中文，位图同理：字体资源另交付；
    # 这里用两条色块占位，位置已按「顺播 / shunbo」的排版预留）
    rounded_rect(px, 118, 76, 206, 90, TITLE, radius=3)
    rounded_rect(px, 118, 100, 172, 109, SUBTITLE, radius=2)
    return px


def write_png(path, px):
    raw = bytearray()
    for row in px:
        raw.append(0)  # filter type 0
        for r, g, b in row:
            raw += bytes((r, g, b))

    def chunk(tag, data):
        return (
            struct.pack(">I", len(data))
            + tag
            + data
            + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
        )

    ihdr = struct.pack(">IIBBBBB", W, H, 8, 2, 0, 0, 0)
    png = (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", ihdr)
        + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
        + chunk(b"IEND", b"")
    )
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(png)
    return len(png)


if __name__ == "__main__":
    root = os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
        "android", "app", "src", "main", "res", "drawable-nodpi",
    )
    target = os.path.join(root, "tv_banner.png")
    size = write_png(target, build())
    print(f"written {target} ({size} bytes, {W}x{H})")
