"""alignment.py 的单元测试（stdlib unittest，零依赖）。

运行：python -m unittest tests.test_alignment -v
"""
import unittest
from ..core.alignment import (
    SourceProfile, raw_to_content, content_to_raw,
    switch_source, calibrate,
)


class TestAlignment(unittest.TestCase):

    def test_same_profile_no_ads_no_offset(self):
        p = SourceProfile(name="A")
        # 同源同参数，换源应原样返回
        ep, sec = switch_source(p, p, 5, 100.0)
        self.assertEqual((ep, sec), (5, 100.0))

    def test_episode_offset_plus_one(self):
        # B 的集号比规范大 1：规范第 5 集 == B 第 6 集
        A = SourceProfile(name="A", episode_offset=0)
        B = SourceProfile(name="B", episode_offset=1)
        ep, sec = switch_source(A, B, 5, 100.0)
        self.assertEqual(ep, 6)
        self.assertAlmostEqual(sec, 100.0)
        # 往返一致
        ep2, sec2 = switch_source(B, A, ep, sec)
        self.assertEqual(ep2, 5)
        self.assertAlmostEqual(sec2, 100.0)

    def test_ad_insertion_aligns_content(self):
        # A 无广告；B 每 600s 插 30s 广告
        A = SourceProfile(name="A")
        B = SourceProfile(name="B", ad_interval=600.0, ad_duration=30.0)
        # A 在 (1, 650) 处的真实内容 = (1, 650)
        # 换到 B：B 在 650s 前已插 1 段 30s 广告 -> 应落在 B 的 (1, 680)
        ep, sec = switch_source(A, B, 1, 650.0)
        self.assertEqual(ep, 1)
        self.assertAlmostEqual(sec, 680.0)
        # 反向应回到 (1, 650)
        ep2, sec2 = switch_source(B, A, ep, sec)
        self.assertEqual(ep2, 1)
        self.assertAlmostEqual(sec2, 650.0)

    def test_round_trip_with_offset_and_ads(self):
        A = SourceProfile(name="A", episode_offset=-1, ad_interval=900.0, ad_duration=20.0)
        B = SourceProfile(name="B", episode_offset=2, ad_interval=600.0, ad_duration=30.0)
        original = (7, 1234.5)
        ep, sec = switch_source(A, B, *original)
        back = switch_source(B, A, ep, sec)
        self.assertEqual(back[0], original[0])
        self.assertAlmostEqual(back[1], original[1], places=6)

    def test_calibrate_recovers_offset_and_ad(self):
        # 已知：A(1,650) 与 B(1,680) 是同一内容位置（用户确认）
        A = SourceProfile(name="A")  # 无广告，规范即 A
        B_guess = SourceProfile(name="B", ad_interval=600.0, ad_duration=0.0)
        B_cal = calibrate(A, B_guess, 1, 650.0, 1, 680.0)
        self.assertEqual(B_cal.episode_offset, 0)
        self.assertAlmostEqual(B_cal.ad_duration, 30.0, places=6)
        # 用校准后的 B 换源，应与 A 对齐到用户确认点
        ep, sec = switch_source(A, B_cal, 1, 650.0)
        self.assertEqual(ep, 1)
        self.assertAlmostEqual(sec, 680.0, places=6)

    def test_calibrate_offset_only(self):
        A = SourceProfile(name="A")
        B_guess = SourceProfile(name="B", episode_offset=0)
        # A 第 5 集 == B 第 6 集（同内容点，无广告）
        B_cal = calibrate(A, B_guess, 5, 100.0, 6, 100.0)
        self.assertEqual(B_cal.episode_offset, 1)
        ep, sec = switch_source(A, B_cal, 5, 100.0)
        self.assertEqual((ep, sec), (6, 100.0))


if __name__ == "__main__":
    unittest.main()
