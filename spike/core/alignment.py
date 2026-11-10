"""
顺播 (shunbo) — 换源对齐核心算法（M0 技术验证原型）

问题背景（设计稿 #1 暗坑）：
  同一部影片/剧集在不同「源」上播放时，存在两类错位：
    1) 集数错位：源 A 的第 5 集 == 源 B 的第 6 集（episode_offset）。
    2) 时间错位：不同源插入广告的时机/时长不同，导致「同一内容位置」
       在源上的「原始时间戳」不同；用户中途换源必须续在「正确内容位置」，
       而不是原始时间戳。

设计（纯逻辑，零依赖，便于 1:1 移植到 Dart）：
  - 规范坐标 Canonical(episode, content_seconds)：去掉广告后的「真实内容位置」，作为全局基准。
  - 源原始坐标 Raw(episode, seconds)：源实际播放位置（含广告）。
  - SourceProfile：描述某源如何从 Raw 映射到 Canonical：
        raw_episode      = canonical_episode + episode_offset
        ad_seconds(raw)  = ad_duration * floor(raw_seconds / ad_interval)   (ad_interval>0)
        content_seconds  = raw_seconds - ad_seconds(raw)
  - 换源：Raw_A --raw_to_content--> Canonical --content_to_raw--> Raw_B
  - 校准：给定「用户确认 A 的某位置 == B 的某位置（同一内容）」，反解 B 的
        episode_offset 与（在固定 ad_interval 假设下）ad_duration。

移植到 Dart 的映射（函数级 1:1）：
  dataclass -> class with final fields
  raw_to_content / content_to_raw / switch_source / calibrate -> 同名静态方法
  unittest -> flutter_test / dart test
"""

from __future__ import annotations

from dataclasses import dataclass
from math import floor


@dataclass(frozen=True)
class SourceProfile:
    """描述单个「源」的集数偏移与广告插入模型。"""
    name: str
    episode_offset: int = 0          # raw_episode = canonical_episode + episode_offset
    ad_interval: float = 0.0         # 两次广告间隔秒数；0 表示无广告
    ad_duration: float = 0.0         # 每次广告时长（秒）

    def _ad_seconds(self, raw_seconds: float) -> float:
        if self.ad_interval <= 0 or self.ad_duration <= 0:
            return 0.0
        return self.ad_duration * floor(raw_seconds / self.ad_interval)


def raw_to_content(p: SourceProfile, raw_episode: int, raw_seconds: float):
    """源原始坐标 -> 规范内容坐标。"""
    canonical_episode = raw_episode - p.episode_offset
    content_seconds = raw_seconds - p._ad_seconds(raw_seconds)
    return canonical_episode, content_seconds


def content_to_raw(p: SourceProfile, canonical_episode: int, content_seconds: float):
    """规范内容坐标 -> 源原始坐标（广告锯齿映射的精确逆运算）。"""
    raw_episode = canonical_episode + p.episode_offset
    if p.ad_interval <= 0 or p.ad_duration <= 0:
        return raw_episode, content_seconds
    # 逆运算：求 k 使 raw = content + k*ad_duration 且 floor(raw/ad_interval) == k
    for k in range(0, 100000):
        raw_seconds = content_seconds + k * p.ad_duration
        if floor(raw_seconds / p.ad_interval) == k:
            return raw_episode, raw_seconds
    raise ValueError("content_to_raw: 无法在合理范围内求解广告逆映射")


def switch_source(from_p: SourceProfile, to_p: SourceProfile,
                  from_raw_episode: int, from_raw_seconds: float):
    """在 from 源某原始位置，换到 to 源时应落在的原始位置（内容对齐）。"""
    c_ep, c_sec = raw_to_content(from_p, from_raw_episode, from_raw_seconds)
    return content_to_raw(to_p, c_ep, c_sec)


def calibrate(from_p: SourceProfile, to_p: SourceProfile,
              from_raw_episode: int, from_raw_seconds: float,
              to_raw_episode: int, to_raw_seconds: float) -> SourceProfile:
    """用一次「用户确认两源同一内容位置」的样本，反解 to_p 的偏移与广告时长。

    假设：to_p 的 ad_interval 已知（沿用入参值），仅求 episode_offset 与 ad_duration。
    若样本落在首个广告前（floor(to_raw_seconds/ad_interval)==0），广告时长无法唯一确定，
    保持入参值（视为无广告或沿用默认）。
    """
    c_ep, c_sec = raw_to_content(from_p, from_raw_episode, from_raw_seconds)
    new_offset = to_raw_episode - c_ep
    new_duration = to_p.ad_duration
    if to_p.ad_interval > 0:
        k = floor(to_raw_seconds / to_p.ad_interval)
        if k > 0:
            new_duration = (to_raw_seconds - c_sec) / k
    return SourceProfile(name=to_p.name, episode_offset=new_offset,
                         ad_interval=to_p.ad_interval, ad_duration=new_duration)
