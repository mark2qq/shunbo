#!/usr/bin/env python3
"""实测内置索引的几种落盘编码，选出能进 APK 的那一种。

背景（第十二次修 · 第 1 项）：
完整记录（`?ac=detail`，含 `vod_play_url`）单条 17,216 B，全量约 21 GB，
物理上不可能进安装包。所以内置的是**精简检索索引**：只存
「站点 + vod_id + 片名 + type_id」，点开影片时再用 `?ac=detail&ids=`
回源取播放地址。这个脚本只回答一个问题：同样的数据，哪种编码最省。

用法：python tooling/probe_vod_index_codec.py
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


def load(key: str):
    rows = []
    files = glob.glob(os.path.join(RAW, key, "*.json"))
    files.sort(key=lambda p: int(os.path.basename(p)[:-5]))
    for p in files:
        try:
            with open(p, encoding="utf-8") as fh:
                d = json.load(fh)
        except Exception:  # noqa: BLE001
            continue
        rows.extend(d.get("rows") or [])
    return rows


_PUNCT = re.compile(r"[\s\u3000·・:：,，.。!！?？\"'（）()\[\]【】《》\-—_/\\|~]+")


def norm(s: str) -> str:
    return _PUNCT.sub("", (s or "").lower())


def gz(b: bytes) -> int:
    return len(gzip.compress(b, 9))


def main() -> int:
    keys = [k for k in sorted(os.listdir(RAW)) if os.path.isdir(os.path.join(RAW, k))]
    if not keys:
        print("无抓取产物")
        return 2
    sites = {k: i for i, k in enumerate(keys)}
    print(f"站点 {len(keys)}：{keys}")

    seen = set()
    rows = []          # [siteIdx, id, name, typeId]
    raw_count = 0
    for k in keys:
        for r in load(k):
            raw_count += 1
            name = (r[1] or "").strip()
            vid = str(r[0] or "").strip()
            if not name or not vid:
                continue
            key = norm(name)
            if key in seen:      # 跨站同名镜像：只留先出现的站
                continue
            seen.add(key)
            rows.append([sites[k], vid, name, str(r[2] or "")])

    print(f"原始 {raw_count:,} 条 → 去重后 {len(rows):,} 条（{100 * len(rows) / max(1, raw_count):.1f}%）")

    # ---- 方案 A：JSON 数组套数组 ----
    a = json.dumps(rows, ensure_ascii=False, separators=(",", ":")).encode()

    # ---- 方案 B：JSON 数组套 TSV 字符串 ----
    b_rows = [f"{s}\t{v}\t{n}\t{t}" for s, v, n, t in rows]
    b = json.dumps(b_rows, ensure_ascii=False, separators=(",", ":")).encode()

    # ---- 方案 C：单个大 TSV 字符串（一个 JSON string）----
    c = json.dumps("\n".join(b_rows), ensure_ascii=False).encode()

    # ---- 方案 D：C 去掉 JSON 包装，裸 TSV ----
    d = "\n".join(b_rows).encode()

    n = max(1, len(rows))
    for tag, blob in (("A json-array", a), ("B json-tsv[]", b), ("C json-string", c), ("D raw-tsv", d)):
        print(f"  {tag:14s} raw={len(blob):>10,}  gz={gz(blob):>10,}  B/条(raw)={len(blob)/n:6.2f}  B/条(gz)={gz(blob)/n:6.2f}")

    # ---- 外推 ----
    per = gz(c) / n
    print(f"\n按方案 C 外推：135.7 万条 ≈ {1357577 * per / 1024 / 1024:.1f} MB（gzip）")
    print(f"按方案 C 外推：去重后若剩 60% ≈ {1357577 * 0.6 * per / 1024 / 1024:.1f} MB（gzip）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
