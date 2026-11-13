#!/usr/bin/env python3
"""片名前端编码（front coding）探针：把内置索引压进 APK 余量的关键一步。

原理：中文片名按码点排序后，相邻片名的公共前缀很长
（`斗罗大陆第1季` / `斗罗大陆第2季` / `斗罗大陆第3季` …）。
只存「公共前缀长度 + 剩余后缀」，gzip 之前先把重复前缀消掉。

这个脚本对比：
  E  front-coding + 列式（site/type 单字节，id varint）
  E2 front-coding 但片名分片存储（模拟按栏目分片）
  D  裸 TSV（上一轮的基线）
用法：python tooling/probe_vod_index_frontcode.py
"""

from __future__ import annotations

import glob
import gzip
import json
import os
import re
import sys

sys.stdout.reconfigure(encoding="utf-8")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RAW = os.path.join(ROOT, "build", "vod_index_raw")
_PUNCT = re.compile(r"[\s\u3000·・:：,，.。!！?？\"'（）()\[\]【】《》\-—_/\\|~]+")


def load(key: str):
    rows = []
    files = sorted(glob.glob(os.path.join(RAW, key, "*.json")),
                   key=lambda p: int(os.path.basename(p)[:-5]))
    for p in files:
        try:
            with open(p, encoding="utf-8") as fh:
                d = json.load(fh)
        except Exception:  # noqa: BLE001
            continue
        rows.extend(d.get("rows") or [])
    return rows


def varint(n: int) -> bytes:
    out = bytearray()
    while True:
        b = n & 0x7F
        n >>= 7
        out.append(b | (0x80 if n else 0))
        if not n:
            return bytes(out)


def collect():
    keys = [k for k in sorted(os.listdir(RAW)) if os.path.isdir(os.path.join(RAW, k))]
    seen = set()
    recs = []
    raw_count = 0
    for k in keys:
        for r in load(k):
            raw_count += 1
            name = (r[1] or "").strip()
            vid = str(r[0] or "").strip()
            if not name or not vid:
                continue
            nk = _PUNCT.sub("", name.lower())
            if nk in seen:
                continue
            seen.add(nk)
            recs.append((k, vid, str(r[2] or ""), name))
    return keys, recs, raw_count


def front_code(names: list[str]) -> bytes:
    """按字节公共前缀编码：varint(共享前缀字节数) + varint(后缀字节数) + 后缀。"""
    out = bytearray()
    prev = b""
    for name in names:
        cur = name.encode("utf-8")
        # 不能切断 UTF-8 多字节字符：按字符边界回退
        lim = min(len(prev), len(cur))
        p = 0
        while p < lim and prev[p] == cur[p]:
            p += 1
        while p > 0 and (cur[p - 1] & 0xC0) == 0x80:
            p -= 1
        out += varint(p)
        out += varint(len(cur) - p)
        out += cur[p:]
        prev = cur
    return bytes(out)


def main() -> int:
    keys, recs, raw_count = collect()
    n = max(1, len(recs))
    print(f"站点 {len(keys)}，去重后 {len(recs):,} 条（原始 {raw_count:,}，保留 {100 * len(recs) / max(1, raw_count):.1f}%）")

    # ---- D 基线：裸 TSV ----
    d = "\n".join(f"{keys.index(s)}\t{v}\t{t}\t{nm}" for s, v, t, nm in recs).encode()
    print(f"  D  raw-tsv        gz={len(gzip.compress(d, 9)):>10,}  B/条={len(gzip.compress(d, 9)) / n:6.2f}")

    # ---- E 前端编码（不排序，保持原顺序，前缀共享少）----
    e_names = front_code([r[3] for r in recs])
    print(f"  E  前端编码(原序) 片名部分 gz={len(gzip.compress(e_names, 9)):>10,}  B/条={len(gzip.compress(e_names, 9)) / n:6.2f}")

    # ---- E2 前端编码（按片名排序）----
    srt = sorted(recs, key=lambda r: r[3].encode("utf-8"))
    names2 = front_code([r[3] for r in srt])
    gz_names2 = len(gzip.compress(names2, 9))
    print(f"  E2 前端编码(排序) 片名部分 gz={gz_names2:>10,}  B/条={gz_names2 / n:6.2f}")

    # E2 的 id/site/type 列（排序后 id 顺序打乱，绝对值 varint）
    meta = bytearray()
    for s, v, t, _ in srt:
        meta.append(keys.index(s))
        try:
            meta += varint(int(v))
        except ValueError:
            meta += varint(0) + varint(len(v.encode())) + v.encode()
        tb = t.encode()
        meta += varint(len(tb)) + tb
    gz_meta = len(gzip.compress(bytes(meta), 9))
    print(f"     E2 元数据列(site/id/type) gz={gz_meta:>10,}  B/条={gz_meta / n:6.2f}")
    total_e2 = gz_names2 + gz_meta
    print(f"     E2 合计 gz={total_e2:>10,}  B/条={total_e2 / n:6.2f}")

    # ---- E3：type_id 换成「类目名字典下标」（1 字节）----
    tmap = {}
    for _, _, t, _ in srt:
        if t not in tmap:
            tmap[t] = len(tmap)
    meta3 = bytearray()
    for s, v, t, _ in srt:
        meta3.append(keys.index(s))
        try:
            meta3 += varint(int(v))
        except ValueError:
            meta3 += varint(0) + varint(len(v.encode())) + v.encode()
        meta3.append(tmap[t] & 0xFF)
    gz_meta3 = len(gzip.compress(bytes(meta3), 9))
    total_e3 = gz_names2 + gz_meta3
    print(f"  E3 type→字典下标   元数据 gz={gz_meta3:>10,}  合计 gz={total_e3:>10,}  B/条={total_e3 / n:6.2f}（类目 {len(tmap)} 个）")

    per = total_e3 / n
    print(f"\n外推（E3，{per:.2f} B/条）：")
    for keep in (1.0, 0.80, 0.70, 0.65, 0.60, 0.55):
        cnt = int(1357577 * keep)
        print(f"  保留 {keep:.0%}（{cnt:>9,} 条）≈ {cnt * per / 1048576:5.1f} MB")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
