#!/usr/bin/env python3
"""抓取 config.json 中全部 CMS 采集站的检索元数据。

设计要点：
- 分页上限实测 100（pagesize=500/1000/2000 被服务端钳制回 100）。
- 断点续抓靠「每页一个结果文件」：build/vod_index_raw/<key>/<pg>.json 已存在即跳过，
  因此中断后重跑同一条命令即可续上，不需要额外的状态文件。
- 每页只保留检索必需字段，完整记录（含 vod_play_url 13 KB）不入盘。
- 站点并发 × 页并发受本机网络约束，默认 6 线程/站，实测单站约 600 条/秒。
"""

from __future__ import annotations

import concurrent.futures
import json
import os
import sys
import threading
import time
import urllib.error
import urllib.request

sys.stdout.reconfigure(encoding="utf-8")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# 落盘目录可用环境变量改（v2 抓取写 `build/vod_index_raw2`，不覆盖旧产物：
# 旧抓取只留了四个字段，没有 `vod_area`/`vod_year`，重抓失败时还要靠它兜底）。
RAW = os.environ.get("VOD_RAW_DIR") or os.path.join(ROOT, "build", "vod_index_raw")
CONFIG = os.path.join(ROOT, "build", "_probe60", "config.json")
CONFIG_URL = "http://47.96.82.41:5188/config.json"

# 抓哪一档接口：
#  * `list`  —— 每页约 50 KB，只有 vod_id/片名/type_id/vod_time，**没有地区年份**；
#  * `detail` —— 每页约 600 KB，字段齐全（含 vod_area / vod_year），
#    代价是体积涨 10 倍，13 站 3 万页 ≈ 18 GB。
# 1.0.5 第十八次修之后「地区 / 时间」两个筛选维度直接来自索引，必须用 detail。
AC = os.environ.get("VOD_AC") or "list"
UA = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
)
PAGESIZE = 100
# 单站并发 6（实测单站约 600 条/秒，再加会开始出现超时）。
WORKERS = int(os.environ.get("VOD_WORKERS") or 6)
# 同时抓几个站（每站独立 6 线程，所以总并发 = WORKERS × SITES_IN_FLIGHT）。
#
# 原来是「逐站串行」，13 站排队跑完要三小时；其中 4 个站的每页容量被钳到
# 20、页数是按 100 算出来的 5 倍，串行更顶不住。3 站并行 ⇒ 总并发 18，
# 不同域名之间互不影响，对单个站的压力仍是原来的 6。
#
# v2（ac=detail，18 GB）把站数放开到「全部并跑」：瓶颈已经从请求数变成带宽，
# 再按 3 站串行排下去只会把总时长乘以 4。
SITES_IN_FLIGHT = int(os.environ.get("VOD_SITES") or 3)
# 进程内共享的进度锁（多个站池同时往 _done/_fail 累加）。
progress_lock = threading.Lock()

RETRY = 3

# 只保留检索与定位必需的字段。vod_remarks（已完结/更新至xx集）对检索无用，
# 且每条约 10 B，全量 1.3 MB，直接丢弃。
#
# `vod_area` / `vod_year` 是「地区 / 时间」两个筛选维度的唯一来源：
#  * 实测覆盖率（每站抽查两页）：area 93%~100%（lzi 47%）、year 90%~100%；
#  * 列表接口只给 `vod_time`，拿不到这两列，所以 v2 必须走 `ac=detail`。
KEEP = tuple(
    f.strip()
    for f in (os.environ.get("VOD_KEEP")
              or "vod_id,vod_name,type_id,vod_year,vod_area").split(",")
    if f.strip()
)

_lock = threading.Lock()
_done = [0]
_fail = [0]


def http_get(url: str, timeout: int = 25) -> bytes | None:
    last = None
    for attempt in range(RETRY):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA})
            return urllib.request.urlopen(req, timeout=timeout).read()
        except Exception as exc:  # noqa: BLE001
            last = exc
            time.sleep(0.6 * (attempt + 1))
    with _lock:
        _fail[0] += 1
    print(f"    ! {url} -> {last}", flush=True)
    return None


def fetch_json(url: str):
    raw = http_get(url)
    if not raw:
        return None
    try:
        return json.loads(raw.decode("utf-8", "replace"))
    except Exception:  # noqa: BLE001
        return None


def site_api(api: str) -> str:
    """把站点 api 统一成可拼参数的形式（ckzy 那条没有 ?ac=list）。"""
    api = api.strip()
    if "?" not in api:
        api += "?"
    if not api.endswith("?") and not api.endswith("&"):
        api += "&"
    return api


def probe_site(site: dict):
    """返回 (key, name, api, total, class_rows, capacity)。

    `capacity` 是**该站真实的每页条数**，不是我们请求的 [PAGESIZE]。
    实测各站对 `pagesize` 的钳制不一样：dyttzy / bfzy 给 100，
    tyyszy / zuid 只给 20。按请求值算页数会让后者的 80% 数据**永远不会被抓**，
    而产物看着「抓全了」（页数对得上、条数也对得上 manifest 里自己算的 total）——
    这种缺口不会报错，只会表现成「搜得到的人少了一大半」。
    """
    key = site.get("key") or "?"
    api = site_api(site.get("api") or "")
    data = fetch_json(api + f"ac={AC}&pagesize={PAGESIZE}&pg=1")
    if not data or not isinstance(data.get("list"), list):
        return key, site.get("name"), api, None, None, 0
    total = int(data.get("total") or 0)
    klass = data.get("class")
    if not isinstance(klass, list):
        klass = []
    # 用第一页实际返回的条数当容量；超过 total 时以 total 为准（末页可能不满）。
    capacity = len(data["list"])
    if total and capacity > total:
        capacity = total
    return key, site.get("name"), api, total, klass, capacity


def fetch_page(api: str, key: str, pg: int, capacity: int):
    outdir = os.path.join(RAW, key)
    path = os.path.join(outdir, f"{pg}.json")
    if os.path.exists(path) and os.path.getsize(path) > 2:
        with _lock:
            _done[0] += 1
        return
    data = fetch_json(api + f"ac={AC}&pagesize={capacity}&pg={pg}")
    rows = []
    if data and isinstance(data.get("list"), list):
        for item in data["list"]:
            if not isinstance(item, dict):
                continue
            row = [item.get(k) for k in KEEP]
            if not row[1]:
                continue
            rows.append(row)
    payload = {"pg": pg, "rows": rows}
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, ensure_ascii=False, separators=(",", ":"))
    os.replace(tmp, path)
    with _lock:
        _done[0] += 1
        n = _done[0]
        if n % 200 == 0:
            print(f"  ... 已抓 {n} 页", flush=True)


def main() -> int:
    if not os.path.exists(CONFIG):
        print(f"本地无配置缓存，从 {CONFIG_URL} 拉取", flush=True)
        os.makedirs(os.path.dirname(CONFIG), exist_ok=True)
        raw = http_get(CONFIG_URL)
        if not raw:
            return 2
        with open(CONFIG, "wb") as fh:
            fh.write(raw)
    with open(CONFIG, encoding="utf-8") as fh:
        cfg = json.load(fh)
    sites = [s for s in cfg.get("sites") or [] if s.get("type") == 1]
    print(f"配置站点 {len(cfg.get('sites') or [])} 个，其中 CMS 采集站 {len(sites)} 个", flush=True)

    os.makedirs(RAW, exist_ok=True)
    manifest = {"sourceUrl": CONFIG_URL, "pagesize": PAGESIZE, "sites": []}
    live = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as ex:
        for key, name, api, total, klass, capacity in ex.map(probe_site, sites):
            if not total:
                print(f"  DEAD  {key} ({name})", flush=True)
                manifest["sites"].append({"key": key, "name": name, "api": api, "total": 0, "dead": True})
                continue
            cap = capacity or PAGESIZE
            pages = (total + cap - 1) // cap
            print(f"  OK    {key:10s} total={total:7d} 每页={cap:3d} pages={pages:5d} class={len(klass)}",
                  flush=True)
            manifest["sites"].append(
                {"key": key, "name": name, "api": api, "total": total,
                 "pageSize": cap, "pages": pages, "dead": False}
            )
            live.append((key, api, pages, klass, cap))

    total_pages = sum(p for _, _, p, _, _ in live)
    print(f"待抓 {len(live)} 站 / {total_pages} 页 / {sum(t for t in [m['total'] for m in manifest['sites']]):,} 条", flush=True)

    t0 = time.time()
    # 多站并行：**每个站自己的 6 线程池**，同时跑 [SITES_IN_FLIGHT] 个站。
    #
    # 为什么不是「一个大池 + 每站信号量」：那会互相抢占 —— 18 个 worker 里
    # 若有 6 个被同一站的信号量卡住，其余 12 个也跟着阻塞在 acquire 上，
    # 实际并发掉到 6。实测那一版比串行还慢（60 s 只推进 140 页）。
    # 每站独立池的写法：单站并发恒为 6（对每个域名压力不变），
    # 总并发 = 6 × 同时在跑的站数。
    site_queue = list(live)

    def run_site(item) -> None:
        key, api, pages, _klass, cap = item
        os.makedirs(os.path.join(RAW, key), exist_ok=True)
        with concurrent.futures.ThreadPoolExecutor(max_workers=WORKERS) as ex:
            list(ex.map(lambda pg: fetch_page(api, key, pg, cap),
                        range(1, pages + 1)))
        with progress_lock:
            el = time.time() - t0
            print(f"  站 {key:10s} 完成，累计 {_done[0]}/{total_pages} 页，"
                  f"{el:.0f}s，失败 {_fail[0]}", flush=True)

    # 目录必须先建：fetch_page 直接往 <RAW>/<key>/ 写。
    for key, *_ in live:
        os.makedirs(os.path.join(RAW, key), exist_ok=True)
    with concurrent.futures.ThreadPoolExecutor(max_workers=SITES_IN_FLIGHT) as site_pool:
        list(site_pool.map(run_site, site_queue))

    el = time.time() - t0
    print(f"全部站点完成，{_done[0]}/{total_pages} 页，{el:.0f}s，失败 {_fail[0]}", flush=True)

    # 类目字典单独落盘（type_id -> type_name 全局合并）
    klass_out = {}
    for key, _api, _pages, klass, _cap in live:
        klass_out[key] = [
            {"id": c.get("type_id"), "pid": c.get("type_pid"), "name": c.get("type_name")}
            for c in klass
            if isinstance(c, dict)
        ]
    with open(os.path.join(RAW, "_classes.json"), "w", encoding="utf-8") as fh:
        json.dump(klass_out, fh, ensure_ascii=False, indent=1)
    with open(os.path.join(RAW, "_manifest.json"), "w", encoding="utf-8") as fh:
        json.dump(manifest, fh, ensure_ascii=False, indent=1)

    print(f"完成：{_done[0]} 页，失败 {_fail[0]}，耗时 {time.time() - t0:.0f}s", flush=True)
    return 0 if _fail[0] == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
