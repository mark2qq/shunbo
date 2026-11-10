import 'package:flutter_test/flutter_test.dart';
import 'package:shunbo/core/scheduler/alignment.dart';
import 'package:shunbo/core/source/source_profile.dart';

void main() {
  test('同源无广告无偏移：换源应原样返回', () {
    final p = SourceProfile(name: 'A');
    final r = switchSource(p, p, 5, 100.0);
    expect(r.$1, 5);
    expect(r.$2, 100.0);
  });

  test('集数偏移 +1：规范第5集 == B第6集', () {
    final a = SourceProfile(name: 'A', episodeOffset: 0);
    final b = SourceProfile(name: 'B', episodeOffset: 1);
    final r = switchSource(a, b, 5, 100.0);
    expect(r.$1, 6);
    expect(r.$2, 100.0);
    // 往返一致
    final back = switchSource(b, a, r.$1, r.$2);
    expect(back.$1, 5);
    expect(back.$2, 100.0);
  });

  test('广告插入导致时间错位并对齐内容', () {
    final a = SourceProfile(name: 'A'); // 无广告
    final b = SourceProfile(name: 'B', adInterval: 600.0, adDuration: 30.0);
    // A 在 (1,650) 的真实内容 = (1,650)；B 在该位置前已插 1 段 30s 广告
    final r = switchSource(a, b, 1, 650.0);
    expect(r.$1, 1);
    expect(r.$2, 680.0);
    // 反向回到 (1,650)
    final back = switchSource(b, a, r.$1, r.$2);
    expect(back.$1, 1);
    expect(back.$2, 650.0);
  });

  test('同时含偏移与广告：跨源往返一致', () {
    final a = SourceProfile(
      name: 'A',
      episodeOffset: -1,
      adInterval: 900.0,
      adDuration: 20.0,
    );
    final b = SourceProfile(
      name: 'B',
      episodeOffset: 2,
      adInterval: 600.0,
      adDuration: 30.0,
    );
    const original = (7, 1234.5);
    final r = switchSource(a, b, original.$1, original.$2);
    final back = switchSource(b, a, r.$1, r.$2);
    expect(back.$1, original.$1);
    expect(back.$2, closeTo(original.$2, 1e-6));
  });

  test('校准反解偏移与广告时长', () {
    // 已知 A(1,650) 与 B(1,680) 是同一内容位置（用户确认）
    final a = SourceProfile(name: 'A');
    final bGuess = SourceProfile(name: 'B', adInterval: 600.0, adDuration: 0.0);
    final bCal = calibrate(a, bGuess, 1, 650.0, 1, 680.0);
    expect(bCal.episodeOffset, 0);
    expect(bCal.adDuration, closeTo(30.0, 1e-6));
    final r = switchSource(a, bCal, 1, 650.0);
    expect(r.$1, 1);
    expect(r.$2, closeTo(680.0, 1e-6));
  });

  test('仅校准偏移（无广告）', () {
    final a = SourceProfile(name: 'A');
    final bGuess = SourceProfile(name: 'B', episodeOffset: 0);
    final bCal = calibrate(a, bGuess, 5, 100.0, 6, 100.0);
    expect(bCal.episodeOffset, 1);
    final r = switchSource(a, bCal, 5, 100.0);
    expect(r.$1, 6);
    expect(r.$2, 100.0);
  });
}
