#!/usr/bin/env python3
"""把抓取产物打包成安装包内置的分片索引（`assets/vod_index/*.tsv.gz`）。

## 为什么是「精简检索索引」而不是完整目录

`?ac=detail` 单条记录实测 17,216 B，其中 `vod_play_url` 占 13,595 B。
全量 135 万条 ≈ 21 GB，任何安装包都装不下。所以内置的只有**检索元数据**：
`站点 + vod_id + type_id + 片名`。用户点开某部片时，再用
`?ac=detail&ids=<vod_id>` 回源取 `vod_play_url`（这条链路早已存在，
见 `third_party_vod.dart` 的 `detailUrl`）。索引负责「搜得到」，
详情接口负责「播得了」。

## 编码

片名是绝对大头（占 74%），所以按片名排序后做**前端编码**（front coding）：
只存「与上一条的公共前缀长度 + 剩余后缀」。实测 15.59 B/条 → 13.24 B/条。
再用 gzip 压。二进制列式只再省 3%，但不可读、无法在门禁里直接断言，
不值得，所以选文本。

## 分片

按 `VodSection` 分片（电影 / 电视剧 / 纪录片 / 短视频 / 动漫 / 其他），
每片一个 `.tsv.gz` + 一份 `manifest.json` 描述。用户检索时按栏目取分片，
不必把 135 万条全解到内存 —— 电视盒子 / API18 单包内存很紧。

## 与 Dart 判定保持一致

`sectionFromCms()` 的父链遍历（`type_pid` 成环要防）在这里逐行复刻。
两边的词表必须一字不差，否则会出现「App 里搜到、栏目里没有」。
`tooling/verify_vod_builtin_index.dart` 会交叉校验这一点。

用法：
    python tooling/pack_vod_index.py              # 只打包抓全的站
    python tooling/pack_vod_index.py --allow-partial   # 未抓全的站也纳入
"""

from __future__ import annotations

import argparse
import glob
import gzip
import hashlib
import json
import os
import re
import sys
import time
from datetime import datetime, timezone

sys.stdout.reconfigure(encoding="utf-8")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "assets", "vod_index")
PAGESIZE = 100

# 原始抓取目录，**按优先级排列**：靠前的优先，缺的站才回落到后面。
#
# 为什么要有回退：v2 抓取（`ac=detail`，带地区/年份）要重下 18 GB，
# 万一某个站这一轮抓不全，整站被排除就会让索引少掉几万条 —— 比没有
# 地区维度更糟。所以 v2 目录优先，抓不到的站回落到 v1 目录的旧数据
# （那些行没有地区/年份，检索照用，只是筛不到）。
_DEFAULT_RAW_DIRS = [
    p for p in (
        os.path.join(ROOT, "build", "vod_index_raw2"),
        os.path.join(ROOT, "build", "vod_index_raw"),
    ) if os.path.isdir(p)
] or [os.path.join(ROOT, "build", "vod_index_raw")]
RAW_DIRS = [p.strip() for p in (os.environ.get("VOD_RAW_DIRS") or "").split(os.pathsep)
            if p.strip()] or _DEFAULT_RAW_DIRS
# 兼容旧变量（第一优先级目录）。
RAW = RAW_DIRS[0]

# ── 地区规范词表 ─────────────────────────────────────────────────────────
# 与 `lib/features/vod/vod_facets.dart` 的 `kVodAreaVocabulary` **必须一致**
# （门禁 F03 会校验索引里出现的地区词都在这张表内）。
#
# 采集站的 `vod_area` 是方言集合：`中国大陆`/`大陆`/`内地`/`国内` 说的是
# 同一个地方。直接按原串落盘，地区行会出现四个同义词各命中几千条，
# 看着像筛选坏了。所以落盘前统一映射，行内只存规范词的下标。
AREA_VOCAB = [
    "内地", "中国香港", "中国台湾", "中国澳门", "美国", "韩国", "日本",
    "泰国", "英国", "法国", "德国", "印度", "俄罗斯", "加拿大", "澳大利亚",
    "新加坡", "马来西亚", "意大利", "西班牙", "其他",
]
AREA_ALIASES = {
    "中国大陆": ["内地"], "大陆": ["内地"], "内地": ["内地"],
    "国内": ["内地"], "中国": ["内地"], "大陆地区": ["内地"],
    "中国香港": ["中国香港"], "香港": ["中国香港"], "港": ["中国香港"],
    "中国台湾": ["中国台湾"], "台湾": ["中国台湾"], "台湾地区": ["中国台湾"],
    "台": ["中国台湾"],
    "中国澳门": ["中国澳门"], "澳门": ["中国澳门"],
    "港台": ["中国香港", "中国台湾"],
    "港澳台": ["中国香港", "中国澳门", "中国台湾"],
    "美国": ["美国"], "韩国": ["韩国"], "日本": ["日本"], "泰国": ["泰国"],
    "英国": ["英国"], "法国": ["法国"], "德国": ["德国"], "印度": ["印度"],
    "俄罗斯": ["俄罗斯"], "加拿大": ["加拿大"], "澳大利亚": ["澳大利亚"],
    "澳洲": ["澳大利亚"], "新加坡": ["新加坡"], "马来西亚": ["马来西亚"],
    "意大利": ["意大利"], "西班牙": ["西班牙"],
}
# `vod_area` 里根本不是地名的脏值（更新状态 / 画质备注）。
AREA_JUNK = ("集", "完结", "更新", "正片", "预告", "花絮", "抢先",
             "HD", "BD", "TC")
_AREA_SPLIT = re.compile(r"[/、,，|&和\s]+")
_DIGITS = re.compile(r"\d")


def area_tokens(raw: str) -> list[str]:
    """`vod_area` → 规范地区词（去重、保序）。与 Dart `vodAreaTokens` 同一口径。"""
    out: list[str] = []
    for piece in _AREA_SPLIT.split((raw or "").strip()):
        t = piece.strip()
        if not t:
            continue
        mapped = AREA_ALIASES.get(t)
        if mapped:
            for m in mapped:
                if m not in out:
                    out.append(m)
            continue
        if t in AREA_VOCAB:
            if t not in out:
                out.append(t)
            continue
        # 认不出来的地名归「其他」；更新状态 / 画质备注不是地名，直接丢。
        if len(t) <= 8 and not _DIGITS.search(t) and not any(j in t for j in AREA_JUNK):
            if "其他" not in out:
                out.append("其他")
    return out


def clean_year(raw) -> str:
    """年份只留 1900–2100 的四位数字，其余一律空串（不要让 `2026-01-01` 混进来）。"""
    s = str(raw or "").strip()
    if len(s) != 4 or not s.isdigit():
        return ""
    y = int(s)
    return s if 1900 <= y <= 2100 else ""

# ── 与 lib/features/vod/vod_catalog.dart 逐字对齐的词表 ──────────────────
# 任何一处不同都会导致「打包时归到 A 栏目、App 里归到 B 栏目」。
SHORT_VIDEO_MARKERS = [
    "短视频", "短剧", "微剧", "电影解说", "预告片", "片花", "短片",
    "微电影", "影视解说",
]
ANIME_MARKERS = ["动漫", "番剧", "动画", "漫剧", "国漫", "日漫"]
DOCUMENTARY_MARKERS = ["纪录", "记录片", "纪实"]
SERIES_MARKERS = [
    "连续剧", "剧集", "国产剧", "欧美剧", "日韩剧",
    "港台剧", "海外剧", "韩剧", "日剧", "泰剧", "美剧", "内地剧",
]
OTHER_MARKERS = [
    "综艺", "真人秀", "脱口秀", "选秀", "访谈", "晚会", "颁奖",
    "相声", "小品", "赛事", "足球", "篮球", "体育", "网球", "台球",
    "搏击", "赛车", "电竞", "音乐", "演唱会", "mv", "戏曲",
    "少儿", "儿童", "教育", "新闻", "资讯", "直播", "美食", "旅游",
]
MOVIE_MARKERS = ["电影", "正片", "院线", "剧场版", "movie", "film"]

SECTION_KEYS = ["movies", "series", "documentaries", "shortVideo", "anime", "other"]
SECTION_LABELS = {
    "movies": "电影",
    "series": "电视剧",
    "documentaries": "纪录片",
    "shortVideo": "短视频",
    "anime": "动漫",
    "other": "其他",
}

_WS = re.compile(r"\s+")


def _norm(s: str) -> str:
    return _WS.sub("", (s or "").lower())


def is_short_video_text(raw: str) -> bool:
    if not raw:
        return False
    s = _norm(raw)
    return any(m in s for m in SHORT_VIDEO_MARKERS)


def is_anime_text(raw: str) -> bool:
    if not raw:
        return False
    s = _norm(raw)
    return any(m in s for m in ANIME_MARKERS)


def vod_section_from_text(raw: str) -> str | None:
    """复刻 Dart `vodSectionFromText`。None = 证据不足。"""
    s = _norm(raw)
    if not s:
        return None
    if is_short_video_text(s):
        return "shortVideo"
    if any(m in s for m in ANIME_MARKERS):
        return "anime"
    if any(m in s for m in DOCUMENTARY_MARKERS):
        return "documentaries"
    if any(m in s for m in SERIES_MARKERS) or s.endswith("剧"):
        return "series"
    if any(m in s for m in OTHER_MARKERS):
        return "other"
    if s.endswith("片") or any(m in s for m in MOVIE_MARKERS):
        return "movies"
    return None


def section_from_name(raw: str) -> str:
    """复刻 Dart `sectionFromName`（英文枚举 + 文本判定 + other 兜底）。"""
    s = (raw or "").lower().strip()
    aliases = {
        "shortvideo": "shortVideo", "short_video": "shortVideo",
        "short": "shortVideo", "shorts": "shortVideo",
        "anime": "anime", "animation": "anime", "cartoon": "anime",
        "documentaries": "documentaries", "documentary": "documentaries",
        "series": "series", "tv": "series", "tvseries": "series",
        "movies": "movies", "movie": "movies", "film": "movies",
        "other": "other", "others": "other",
    }
    if s in aliases:
        return aliases[s]
    return vod_section_from_text(s) or "other"


def section_from_cms(type_name: str, type_id: str, classes: dict[str, dict]) -> str:
    """复刻 Dart `sectionFromCms`：文本 → 父链短视频 → 父链动漫 → 文本兜底。"""
    if is_short_video_text(type_name):
        return "shortVideo"
    if type_id:
        if _walk_parents(type_id, classes, is_short_video_text):
            return "shortVideo"
        if _walk_parents(type_id, classes, is_anime_text):
            return "anime"
    return section_from_name(type_name)


def _walk_parents(type_id: str, classes: dict[str, dict], hit) -> bool:
    """沿 type_pid 上溯；visited 防脏数据成环（Dart 侧同样有）。"""
    cursor = type_id
    seen: set[str] = set()
    while cursor and cursor != "0" and cursor not in seen:
        seen.add(cursor)
        c = classes.get(cursor)
        if c is None:
            return False
        if hit(c.get("name") or ""):
            return True
        cursor = str(c.get("pid") or "")
    return False


# ── 抓取产物读取 ────────────────────────────────────────────────────────

def load_classes() -> dict[str, dict[str, dict]]:
    """类目表：多个原始目录合并，**靠前的优先**。

    v2 目录里没有类目表（`ac=detail` 不返回 `class`），只能靠 v1 目录的
    `_classes.json`。类目 id 是站点自己的编号，两轮抓取之间不会变，
    所以借旧表回填名字是安全的。
    """
    out: dict[str, dict[str, dict]] = {}
    for root in RAW_DIRS:
        path = os.path.join(root, "_classes.json")
        if not os.path.exists(path):
            continue
        try:
            with open(path, encoding="utf-8") as fh:
                raw = json.load(fh)
        except Exception:  # noqa: BLE001
            continue
        for key, payload in raw.items():
            # 两种形状都要认：
            #  * 老抓取脚本存的是接口原始响应 `{"total":N,"class":[...]}`；
            #  * 现在的抓取脚本只存扁平列表 `[{id,pid,name}, ...]`（省一半体积）。
            rows = payload.get("class") if isinstance(payload, dict) else payload
            table = out.setdefault(key, {})
            if table:
                continue  # 前面的目录已经给过这张表，优先级更高
            for c in rows or []:
                # 字段名有两套方言：`id/pid/name`（多数苹果 CMS 站）与
                # `type_id/type_pid/type_name`（dyttzy 这类）。只认前者会让
                # 整站类目表解析成空，进而整站掉进「其他」栏目。
                cid = str(c.get("id") or c.get("type_id") or "")
                if not cid:
                    continue
                table[cid] = {
                    "name": c.get("name") or c.get("type_name") or "",
                    "pid": str(c.get("pid") or c.get("type_pid") or ""),
                }
    return out


# 每个站最终选用的抓取目录（main 里按「先抓全、再页数最多」挑一次）。
_SITE_DIR: dict[str, str] = {}


def site_dir(key: str) -> str | None:
    """该站的抓取目录：优先用 main 选定的那份，否则取第一个有页文件的。"""
    chosen = _SITE_DIR.get(key)
    if chosen:
        return chosen
    for root in RAW_DIRS:
        if glob.glob(os.path.join(root, key, "*.json")):
            return os.path.join(root, key)
    return None


def page_count(key: str) -> int:
    d = site_dir(key)
    return len(glob.glob(os.path.join(d, "*.json"))) if d else 0


def read_page_rows(key: str, pg: int) -> list:
    """读单页的行（完整性核对用；坏文件当作 0 条，不抛）。"""
    d = site_dir(key)
    if d is None:
        return []
    path = os.path.join(d, f"{pg}.json")
    if not os.path.exists(path):
        return []
    try:
        with open(path, encoding="utf-8") as fh:
            doc = json.load(fh)
    except Exception:  # noqa: BLE001
        return []
    return doc.get("rows") or []


def load_site_rows(key: str):
    d = site_dir(key)
    if d is None:
        return []
    files = glob.glob(os.path.join(d, "*.json"))
    files.sort(key=lambda p: int(os.path.basename(p)[:-5]))
    rows = []
    for p in files:
        try:
            with open(p, encoding="utf-8") as fh:
                doc = json.load(fh)
        except Exception:  # noqa: BLE001
            continue
        rows.extend(doc.get("rows") or [])
    return rows


def dedup_key(name: str) -> str:
    """跨站去重键：去掉标点空白后的小写片名。

    与 Dart `vodContentKey` 不完全相同（那边还带年份），因为列表接口
    实测 `vod_year` 常常是空串（dyttzy 全量只有 1 种取值），带年份等于
    不去重。片名归一后的键在这里更有效。
    """
    return re.sub(r"[\s\u3000·・:：,，.。!！?？\"'（）()\[\]【】《》\-—_/\\|~]+", "", name.lower())


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--allow-partial", action="store_true",
                    help="未抓全的站也纳入（默认排除，保证产物自洽）")
    ap.add_argument("--keep-per-title", type=int, default=2,
                    help="同一片名最多保留几条（优先来自不同站，用于回源失败换源；1 = 只留一条）")
    ap.add_argument("--allow-missing-classes", action="store_true",
                    help="类目表缺失的站也打包（默认报错：缺表会让整站归错栏目）")
    ap.add_argument("--out", default=OUT)
    args = ap.parse_args()

    manifest_path = None
    for root in RAW_DIRS:
        p = os.path.join(root, "_manifest.json")
        if os.path.exists(p):
            manifest_path = p
            break
    if manifest_path is None:
        print("缺 _manifest.json，先跑 fetch_vod_index.py")
        return 2
    with open(manifest_path, encoding="utf-8") as fh:
        manifest = json.load(fh)
    print(f"原始目录：{' → '.join(RAW_DIRS)}")

    classes = load_classes()
    # 站点可用性以**本地已抓到的页**为准，而不是本次探测的 `dead` 标记。
    #
    # 踩过的坑：`dyttzy`（电影天堂，8.5 万条）在第一轮抓全后，下一轮重启
    # 探活被 WAF 回了 403 ⇒ manifest 里 `dead=true` ⇒ 整站 8.5 万条被静默
    # 排除，产物看着完全自洽（总数、sha256、行数全对）。站点可用性会波动，
    # 但已落盘的数据不会变坏，只有一页都没有才算真死站。
    # 每个目录各有一份 manifest：v2 目录声明的是这一轮的 total/pages，
    # v1 目录声明的是上一轮的。挑数据源时要用**对应目录自己的**声明。
    dir_manifests = {}
    for root in RAW_DIRS:
        p = os.path.join(root, "_manifest.json")
        if os.path.exists(p):
            try:
                with open(p, encoding="utf-8") as fh:
                    dir_manifests[root] = json.load(fh)
            except Exception:  # noqa: BLE001
                pass

    def pick_source(key: str):
        """给一个站挑数据源：先找「页数已抓全」的目录，再退回页数最多的。"""
        best = None
        for root in RAW_DIRS:
            d = os.path.join(root, key)
            if not os.path.isdir(d):
                continue
            n = len(glob.glob(os.path.join(d, "*.json")))
            if n == 0:
                continue
            meta = {}
            for s2 in dir_manifests.get(root, {}).get("sites") or []:
                if (s2.get("key") or "") == key:
                    meta = s2
                    break
            need = meta.get("pages") or 0
            cand = {
                "dir": d, "have": n, "meta": meta, "root": root,
                "complete": need <= 0 or n >= need,
            }
            if cand["complete"]:
                return cand
            if best is None or n > best["have"]:
                best = cand
        return best

    order: list[str] = []
    for root in RAW_DIRS:
        for s2 in dir_manifests.get(root, {}).get("sites") or []:
            k = s2.get("key") or ""
            if k and k not in order:
                order.append(k)

    sites_meta = []
    for key in order:
        src = pick_source(key)
        if src is None:
            print(f"  SKIP {key}（无本地数据）")
            continue
        entry = dict(src["meta"])
        entry["key"] = key
        entry["api"] = entry.get("api") or ""
        entry["total"] = entry.get("total") or 0
        entry["pages"] = entry.get("pages") or src["have"]
        entry["dead"] = False
        _SITE_DIR[key] = src["dir"]
        sites_meta.append(entry)
        if src["root"] != RAW_DIRS[0] or not src["complete"]:
            print(f"  源  {key:10s} ← {os.path.basename(src['root'])}"
                  f"（{src['have']}/{entry['pages']} 页，"
                  f"{'已抓全' if src['complete'] else '**未抓全**'}）")
    if not sites_meta:
        print("manifest 里没有可用站点")
        return 2

    # ── 类目表完整性（静默归错栏目的防线）──
    #
    # 没类目表 ⇒ 每个 type_id 都查不到名字 ⇒ `section_from_cms` 全部回落到
    # `other`。产物照样自洽（行数、sha256、总数全对），症状只是「电影栏目
    # 空了一半、其他栏目多出 8 万条」。刚踩过：`dyttzy` 探活 403 那轮类目表
    # 没抓到，8.5 万条全进了 other。
    missing = [s["key"] for s in sites_meta
               if page_count(s["key"])
               and not classes.get(s["key"])]
    if missing:
        print(f"缺少类目表的站：{', '.join(missing)}")
        print("→ 这些站的 type_id 无法还原类目名，会整站掉进「其他」栏目；"
              "先补抓类目表，或加 --allow-missing-classes 强行继续")
        if not args.allow_missing_classes:
            return 2

    # ── 站点完整性 ──
    #
    # 两道检查，缺一不可：
    #  ① 页数：抓到的页数 ≥ manifest 声明的页数；
    #  ② **真实条数**：抓到的条目数 ≥ 接口 total 的 90%。
    #
    # 为什么必须有 ②：`pages = ceil(total / 请求的 pagesize)` 这个算法在
    # 「服务端把 pagesize 钳制到 20」的站点上是错的 —— 页数全部「抓全」，
    # 产物自洽、条数也对得上 manifest 自己算的值，唯独真实数据只有 20%。
    # 这个缺口不会报错，只表现为「某些站搜出来的片少了一大半」。
    # 实测 tyyszy / zuid 就是钳到 20，dyttzy / bfzy 给 100。
    complete, partial = [], []
    rows_cache: dict[str, list] = {}
    for s in sites_meta:
        key = s["key"]
        pages = s.get("pages") or 0
        total = s.get("total") or 0
        have = page_count(key)
        # 用「所有存在的页文件里的行」而不是「前 have 页」：中间缺页时
        # 文件数会小于最大页码，按页码累加会漏算后半段。
        site_rows = load_site_rows(key)
        rows_cache[key] = site_rows
        rows = len(site_rows)
        # 允许 10% 缺口：接口 total 与列表接口实际可翻到的最大页码常有出入
        # （下架片仍计入 total、末页不满等），但 80% 的缺口一定是抓取算法错了。
        enough_rows = total == 0 or rows >= total * 0.9
        ok = have >= pages and pages > 0 and enough_rows
        (complete if ok else partial).append((s, have, pages, rows, total))
    print(f"抓全 {len(complete)} 站 / 未抓全 {len(partial)} 站")
    for s, have, pages, rows, total in partial:
        why = []
        if have < pages:
            why.append(f"页数 {have}/{pages}")
        if total and rows < total * 0.9:
            why.append(f"条数 {rows:,}/{total:,}（{100 * rows / max(1, total):.0f}%）")
        print(f"  PARTIAL {s['key']:10s} " + "；".join(why))
    if partial and not args.allow_partial:
        print("→ 默认排除未抓全的站（要纳入请加 --allow-partial）")

    use = [s for s, *_ in complete] if not args.allow_partial else sites_meta
    if not use:
        print("没有可打包的站点")
        return 2
    site_index = {s["key"]: i for i, s in enumerate(use)}

    # ── 读行 + 跨站去重 + 分栏目 ──
    #
    # 去重口径（`--keep-per-title`，默认 2）：
    #
    # 13 个采集站转发的是同一批资源池，同一个片名平均在 3.6 个站里出现，
    # 全量保留 147 万条毫无意义（同一部片 4 张卡片）。但**只留一条**又会
    # 丢掉「换源」能力：那条记录指向的站一旦详情接口抽风，这部片就点不开，
    # 而索引里明明还有另外几个站有它。
    #
    # 所以每个片名保留最多 N 条，且**优先来自不同站点**（同一站同名的第二条
    # 没有换源价值，纯占体积）。实测 N=2 时 37.6 万片名 → 约 70 万条 / 8.5 MB，
    # 仍在安装包体积门禁（60 MB）之内。
    seen: dict[str, set[int]] = {}
    buckets: dict[str, list[tuple[str, str, str, str, str, list[str]]]] = {
        k: [] for k in SECTION_KEYS
    }
    # 类目表的下标键是 **(站点 key, type_id)**，不是裸 type_id。
    #
    # 踩过的坑：先按裸 `type_id` 建全局表，实测 **31.4 万行**同名冲突 ——
    # 各站的 `type_id` 是各自编号，`1` 在 A 站是「电影」、在 B 站是「电视剧」。
    # 用全局表回填显示名，会把「电视剧」标到一部电影上（不报错，只是标错）。
    # 分片每行本来就带站点下标，所以按「站点 + 类目」建表既准确又几乎不增体积
    # （78 项 → 四百余项，manifest 仍不到 8 KB）。
    type_dict: dict[tuple[str, str], int] = {}
    type_names: dict[tuple[str, str], str] = {}
    type_name_conflicts = 0
    raw_total = 0
    dropped_dup = 0
    dropped_bad = 0
    keep_n = max(1, args.keep_per_title)
    for s in use:
        key = s["key"]
        table = classes.get(key, {})
        sidx = site_index[key]
        for r in rows_cache.get(key) or load_site_rows(key):
            raw_total += 1
            name = (r[1] or "").strip()
            vid = str(r[0] or "").strip()
            if not name or not vid:
                dropped_bad += 1
                continue
            dk = dedup_key(name)
            sites_of = seen.get(dk)
            if sites_of is None:
                sites_of = set()
                seen[dk] = sites_of
            if sidx in sites_of or len(sites_of) >= keep_n:
                dropped_dup += 1
                continue
            sites_of.add(sidx)
            tid = str(r[2] or "")
            tname = (table.get(tid) or {}).get("name") or ""
            section = section_from_cms(tname, tid, table)
            tkey = (key, tid)
            if tkey not in type_dict:
                type_dict[tkey] = len(type_dict)
            if tname:
                prev_name = type_names.get(tkey)
                if prev_name is None:
                    type_names[tkey] = tname
                elif prev_name != tname:
                    # 同一个站的同一个 type_id 叫两个名字（脏数据）：不报错，
                    # 只计数，取首次出现的那个。跨站的同名不再算冲突 ——
                    # 它们本来就是两回事（见 tkey 的注释）。
                    type_name_conflicts += 1
            # 年份与地区：v2 抓取（ac=detail）才有；回退到 v1 旧目录的站
            # 这两列为空 —— 检索照用，只是「时间 / 地区」筛不到它们。
            year = clean_year(r[3] if len(r) > 3 else "")
            areas = area_tokens(r[4] if len(r) > 4 else "")
            buckets[section].append((key, vid, tid, name, year, areas))

    total = sum(len(v) for v in buckets.values())
    print(f"原始 {raw_total:,} 条 → 保留 {total:,} 条 / 唯一片名 {len(seen):,} 个"
          f"（每名≤{keep_n} 条；丢弃重复 {dropped_dup:,} / 无效 {dropped_bad:,}）")

    # ── 地区词表下标 ──
    #
    # 行内只存下标：`中国香港,中国台湾` 这种两三个词的值也比原串短，
    # 且同一批值反复出现，gzip 压得下去。词表按**全局命中数降序**，
    # 这样即便界面不做二次排序，「地区」行也是从最常见的开始。
    area_counts: dict[str, int] = {}
    for rows_ in buckets.values():
        for row_ in rows_:
            for w_ in row_[5]:
                area_counts[w_] = area_counts.get(w_, 0) + 1
    area_list = [w for w, _ in sorted(area_counts.items(),
                                      key=lambda e: (-e[1], e[0]))]
    area_index = {w: i for i, w in enumerate(area_list)}
    print(f"地区词表 {len(area_list)} 项：" +
          "、".join(f"{w}({area_counts[w]:,})" for w in area_list))

    # ── 落盘 ──
    os.makedirs(args.out, exist_ok=True)
    sections_out = []
    for skey in SECTION_KEYS:
        rows = buckets[skey]
        if not rows:
            continue
        rows.sort(key=lambda r: r[3])          # 前端编码必须先排序
        lines = []
        prev = ""
        with_year = 0
        with_area = 0
        for site_key, vid, tid, name, year, areas in rows:
            p = 0
            lim = min(len(prev), len(name))
            while p < lim and prev[p] == name[p]:
                p += 1
            if year:
                with_year += 1
            if areas:
                with_area += 1
            area_csv = ",".join(str(area_index[w]) for w in areas)
            lines.append(
                f"{site_index[site_key]}\t{vid}\t{type_dict[(site_key, tid)]}"
                f"\t{p}\t{year}\t{area_csv}\t{name[p:]}"
            )
            prev = name
        body = "\n".join(lines).encode("utf-8")
        gz = gzip.compress(body, 9)
        fname = f"{skey}.tsv.gz"
        path = os.path.join(args.out, fname)
        with open(path, "wb") as fh:
            fh.write(gz)
        sections_out.append({
            "key": skey,
            "label": SECTION_LABELS[skey],
            "file": fname,
            "records": len(rows),
            "withYear": with_year,
            "withArea": with_area,
            "rawBytes": len(body),
            "gzBytes": len(gz),
            "bytesPerRecord": round(len(gz) / len(rows), 2),
            "sha256": hashlib.sha256(gz).hexdigest(),
        })
        print(f"  {skey:14s} {len(rows):>9,} 条  gz={len(gz):>10,} B  "
              f"({len(gz) / len(rows):5.2f} B/条)  → {fname}")

    # 类目字典：下标 → type_id（App 侧要能还原出 type_id），
    # 外加一条平行的**名字表**（下标 → type_name，仅用于界面显示）。
    #
    # 下标是 (站点, type_id) 组合的下标，所以同一个 type_id 在不同站会
    # 落在不同项上，名字各自独立、不会串台。
    types_list = [None] * len(type_dict)
    names_list = [None] * len(type_dict)
    # 每一项属于哪个站（站点下标）：App 侧要靠它把 (站点, type_id) 还原成
    # 唯一项。少了这一列，`type_id=1` 在 13 个站里会命中十几个不同名字。
    sites_list = [None] * len(type_dict)
    site_pos = {s["key"]: i for i, s in enumerate(use)}
    for tkey, idx in type_dict.items():
        types_list[idx] = tkey[1]
        names_list[idx] = type_names.get(tkey) or ""
        sites_list[idx] = site_pos.get(tkey[0], -1)
    unnamed = sum(1 for n in names_list if not n)
    print(f"类目字典 {len(types_list)} 项（站点 × 类目）/ 无名字 {unnamed} 项"
          f" / 站内同名冲突 {type_name_conflicts:,} 行")
    if unnamed:
        print("→ 有类目 id 查不到名字（该站类目表不全），这些条目界面上不显示类型，"
              "不会退化成显示数字 id")

    payload = {
        "format": "shunbo-vod-index",
        "version": 2,
        "generatedAt": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "sourceUrl": manifest.get("sourceUrl"),
        "pagesize": PAGESIZE,
        "sites": [{"key": s["key"], "name": s.get("name") or s["key"],
                   "api": s.get("api") or "", "total": s.get("total") or 0} for s in use],
        "types": types_list,
        "typeNames": names_list,
        "typeSites": sites_list,
        "areas": area_list,
        "sections": sections_out,
        "total": total,
        "titleCount": len(seen),
        "keepPerTitle": keep_n,
        "rawTotal": raw_total,
        "dedupDropped": dropped_dup,
        "partialSites": [s["key"] for s, *_rest in partial] if args.allow_partial else [],
        "excludedSites": [s["key"] for s, *_rest in partial] if not args.allow_partial else [],
        "note": "精简检索索引：只含检索元数据，播放地址由 ?ac=detail&ids= 回源获取",
    }
    mpath = os.path.join(args.out, "manifest.json")
    with open(mpath, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, ensure_ascii=False, indent=1)

    total_gz = sum(s["gzBytes"] for s in sections_out)
    print(f"\n合计 {total:,} 条 / {len(sections_out)} 片 / gzip {total_gz:,} B "
          f"= {total_gz / 1048576:.2f} MB")
    print(f"manifest → {mpath}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
