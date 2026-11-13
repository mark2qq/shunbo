#!/usr/bin/env python3
"""只抓各采集站的类目表（`class`），落 build/vod_index_raw/_classes.json。

为什么单独一个脚本：分片要靠「type_id → 栏目」的映射，而这个映射来自
各站 `?ac=list` 响应里自带的 `class` 数组。主抓取脚本要到全部页抓完才落盘，
但分片打包不等它。这里 21 个站点一次探测（每个一条请求）几秒就完。

用法：python tooling/probe_vod_classes.py
"""

from __future__ import annotations

import concurrent.futures
import json
import os
import sys
import urllib.request

sys.stdout.reconfigure(encoding="utf-8")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RAW = os.path.join(ROOT, "build", "vod_index_raw")
CONFIG = os.path.join(ROOT, "build", "_probe60", "config.json")
UA = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
)


def site_api(api: str) -> str:
    api = (api or "").strip()
    if "?" not in api:
        api += "?"
    if not api.endswith("?") and not api.endswith("&"):
        api += "&"
    return api


def probe(site: dict):
    key = site.get("key") or "?"
    api = site_api(site.get("api") or "")
    try:
        req = urllib.request.Request(
            api + "ac=list&pagesize=1&pg=1", headers={"User-Agent": UA})
        raw = urllib.request.urlopen(req, timeout=25).read()
        data = json.loads(raw.decode("utf-8", "replace"))
    except Exception as exc:  # noqa: BLE001
        print(f"  DEAD {key:10s} {exc}", flush=True)
        return key, None
    total = int(data.get("total") or 0)
    klass = data.get("class")
    if not isinstance(klass, list):
        klass = []
    rows = [
        {"id": str(c.get("type_id")), "pid": str(c.get("type_pid") or ""), "name": c.get("type_name")}
        for c in klass
        if isinstance(c, dict) and c.get("type_id") is not None
    ]
    print(f"  OK   {key:10s} total={total:7d} class={len(rows)}", flush=True)
    return key, {"total": total, "class": rows}


def main() -> int:
    with open(CONFIG, encoding="utf-8") as fh:
        cfg = json.load(fh)
    sites = [s for s in cfg.get("sites") or [] if s.get("type") == 1]
    out = {}
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as ex:
        for key, payload in ex.map(probe, sites):
            if payload:
                out[key] = payload
    os.makedirs(RAW, exist_ok=True)
    path = os.path.join(RAW, "_classes.json")
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(out, fh, ensure_ascii=False, indent=1)
    names = sorted({c["name"] for p in out.values() for c in p["class"] if c["name"]})
    print(f"\n可用站点 {len(out)} 个，去重类目名 {len(names)} 个 → {path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
