#!/usr/bin/env python3
"""二进制列式编码探针：把「站点 / vod_id / type_id / 片名」压到极限。

纯文本 TSV 每条要付 tab、十进制 id、十进制 type_id 的字符成本；
二进制版用 1 字节站点下标 + varint id + 1 字节类目下标 + varint 长度 + UTF-8 片名，
整体再 gzip。这个脚本只用于选型，不产出正式资产。

用法：python tooling/probe_vod_index_binary.py
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


def main() -> int:
    keys = [k for k in sorted(os.listdir(RAW)) if os.path.isdir(os.path.join(RAW, k))]
    seen = set()
    recs = []
    raw_count = 0
    type_sets = {k: {} for k in keys}
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
            tid = str(r[2] or "")
            ts = type_sets[k]
            if tid not in ts:
                ts[tid] = len(ts)
            recs.append((k, vid, ts[tid], name))

    n = max(1, len(recs))
    print(f"去重后 {len(recs):,} 条（原始 {raw_count:,}）")

    # ---- 二进制流 ----
    blob = bytearray()
    for k, vid, tidx, name in recs:
        site = keys.index(k)
        name_b = name.encode("utf-8")
        blob += bytes([site])
        try:
            blob += varint(int(vid))
        except ValueError:
            blob += varint(0) + varint(len(vid.encode())) + vid.encode()
        blob.append(tidx & 0xFF)
        blob += varint(len(name_b))
        blob += name_b

    bz = len(gzip.compress(bytes(blob), 9))
    print(f"二进制+gzip  raw={len(blob):,}  gz={bz:,}  B/条(gz)={bz / n:.2f}")

    # ---- 片名单独 gzip 的下界（判断片名占多少）----
    names = "\n".join(r[3] for r in recs).encode()
    print(f"  其中片名裸 {len(names):,}  gz={len(gzip.compress(names, 9)):,}")

    per = bz / n
    print(f"\n外推 135.7 万条未去重 ≈ {1357577 * per / 1048576:.1f} MB")
    for keep in (0.55, 0.60, 0.65, 0.70, 0.80):
        print(f"外推 去重保留 {keep:.0%}（{int(1357577 * keep):,} 条）≈ {1357577 * keep * per / 1048576:.1f} MB")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
