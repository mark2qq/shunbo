// 内容级正确性判据回归（黑屏 / 静帧 / 纯色 / 循环垫片 / 采样不足）。
//
// 全部用合成帧序列，不发网络请求、不需要 libmpv；「真实帧能否被正确降采样」
// 由 scan_content_frames.dart 的实跑结果单独给证据（content_probe_real.json）。
// 这里钉住的是判定状态机：任何一类假可播都不能被判成 `ok`。
//
// 运行：dart run tooling/verify_content_gate.dart
library;

import 'dart:io';

import 'package:shunbo/features/live/content_gate.dart';

int _pass = 0;
int _fail = 0;

void check(String name, bool ok, [String? detail]) {
  if (!ok) {
    _fail++;
    print('FAIL: $name${detail == null ? '' : ' —— $detail'}');
    return;
  }
  _pass++;
  print('PASS: $name');
}

FrameSample f(
  int at, {
  double mean = 100,
  double min = 8,
  double max = 248,
  double motion = 20,
  String hash = '',
}) =>
    FrameSample(
      atMs: at,
      lumaMean: mean,
      lumaMin: min,
      lumaMax: max,
      motion: motion,
      hash: hash,
    );

/// 正常直播：亮度、动态范围、时域差都在合理区间，哈希逐帧不同。
List<FrameSample> healthy() => <FrameSample>[
      f(0, mean: 103, motion: 0, hash: 'a0'),
      f(606, mean: 102.5, min: 28, motion: 11.21, hash: 'a1'),
      f(1258, mean: 104.3, motion: 17.17, hash: 'a2'),
      f(1864, mean: 99.8, motion: 19.96, hash: 'a3'),
      f(2470, mean: 100.4, motion: 17.53, hash: 'a4'),
      f(3076, mean: 80.8, motion: 48.5, hash: 'a5'),
      f(3728, mean: 101.1, motion: 42.01, hash: 'a6'),
      f(4334, mean: 94.6, min: 0, motion: 22.29, hash: 'a7'),
    ];

void testHealthy() {
  print('\n== A. 正常画面不误杀 ==');
  final gate = ContentGate();
  final v = gate.evaluate(healthy());
  check('真实基线序列判正常', v.ok, v.summary);
  check('采样数正确', v.samples == 8);
  check('平均运动量落在 20~30', v.meanMotion > 20 && v.meanMotion < 30,
      '${v.meanMotion}');
  check('黑帧占比为 0', v.blackRatio == 0);
  check('纯色占比为 0', v.flatRatio == 0);
  check('静帧占比为 0', v.frozenRatio == 0);
  check('未误报循环', v.loopPeriod == 0);
  check('摘要可读', v.summary.contains('内容正常'));
  check('标签映射', ContentVerdict.labelOf(ContentFaultKind.none) == '内容正常');
}

void testInsufficient() {
  print('\n== B. 采样不足绝不判通过 ==');
  final gate = ContentGate();
  check('空序列判不足', gate.evaluate(<FrameSample>[]).kind ==
      ContentFaultKind.insufficient);
  check('空序列 ok=false', !gate.evaluate(<FrameSample>[]).ok);
  final five = healthy().take(5).toList();
  final v = gate.evaluate(five);
  check('5 帧低于 6 帧下限', v.kind == ContentFaultKind.insufficient);
  check('不足理由含数字', v.reason.contains('5 帧') && v.reason.contains('6 帧'));
  check('刚好 6 帧可进入判定', gate.evaluate(healthy().take(6).toList()).ok);
  check('自定义下限生效',
      const ContentGate(minSamples: 3).evaluate(healthy().take(3).toList()).ok);
}

void testBlack() {
  print('\n== C. 黑屏 ==');
  final gate = ContentGate();
  final black = <FrameSample>[
    for (var i = 0; i < 8; i++)
      f(i * 500, mean: 4, min: 0, max: 12, motion: 0.2, hash: 'b$i'),
  ];
  final v = gate.evaluate(black);
  check('全黑判黑屏', v.kind == ContentFaultKind.black);
  check('黑屏不通过', !v.ok);
  check('黑帧占比 100%', v.blackRatio == 1);
  check('理由带百分比', v.reason.contains('100%'));

  final mostly = healthy().map((s) => f(s.atMs, mean: 5, min: 0, max: 9,
      motion: s.motion, hash: s.hash)).toList();
  mostly[0] = f(0, mean: 120, min: 8, max: 248, hash: 'x');
  check('偶发一帧亮画面不洗掉黑屏判定',
      gate.evaluate(mostly).kind == ContentFaultKind.black);

  final belowThreshold = <FrameSample>[
    for (var i = 0; i < 8; i++)
      f(i * 500, mean: i < 2 ? 5 : 110, min: 8, max: 248, motion: 20,
          hash: 'c$i'),
  ];
  check('黑帧占比低于阈值不判黑屏',
      gate.evaluate(belowThreshold).kind != ContentFaultKind.black);
  check('阈值可调',
      const ContentGate(blackRatio: 0.2).evaluate(belowThreshold).kind ==
          ContentFaultKind.black);
}

void testFrozen() {
  print('\n== D. 静帧 ==');
  final gate = ContentGate();
  final frozen = <FrameSample>[
    for (var i = 0; i < 8; i++)
      f(i * 500, mean: 96, motion: i == 0 ? 0 : 0.1, hash: 'same$i'),
  ];
  final v = gate.evaluate(frozen);
  check('全静帧判静帧', v.kind == ContentFaultKind.frozen, v.summary);
  check('静帧不通过', !v.ok);
  check('静帧占比 100%', v.frozenRatio == 1);
  check('平均运动量接近 0', v.meanMotion < 1);
  check('理由带平均运动量', v.reason.contains('平均'));

  final moving = healthy();
  check('正常运动不误判静帧',
      gate.evaluate(moving).kind != ContentFaultKind.frozen);
  final slow = <FrameSample>[
    for (var i = 0; i < 8; i++) f(i * 500, motion: i == 0 ? 0 : 1.3, hash: 's$i'),
  ];
  check('阈值边界可配',
      const ContentGate(frozenMotion: 2).evaluate(slow).kind ==
          ContentFaultKind.frozen);
}

void testFlat() {
  print('\n== E. 纯色 / 测试卡 ==');
  final gate = ContentGate();
  final flat = <FrameSample>[
    for (var i = 0; i < 8; i++)
      f(i * 500, mean: 128, min: 126, max: 130, motion: 0.1, hash: 'f$i'),
  ];
  final v = gate.evaluate(flat);
  check('纯色判 flat', v.kind == ContentFaultKind.flat);
  check('纯色不通过', !v.ok);
  check('纯色占比 100%', v.flatRatio == 1);
  check('纯色优先于静帧', v.reason.contains('动态范围'));
  check('灰阶范围大的画面不误判',
      gate.evaluate(healthy()).kind != ContentFaultKind.flat);
}

void testLoop() {
  print('\n== F. 循环垫片 ==');
  final gate = ContentGate();
  final hashes = <String>['p0', 'p1', 'p2', 'p3', 'p0', 'p1', 'p2', 'p3'];
  final loop = <FrameSample>[
    for (var i = 0; i < hashes.length; i++)
      f(i * 500, mean: 90 + i.toDouble(), motion: 15, hash: hashes[i]),
  ];
  final v = gate.evaluate(loop);
  check('4 帧周期判循环', v.kind == ContentFaultKind.loop, v.summary);
  check('周期值正确', v.loopPeriod == 4);
  check('循环不通过', !v.ok);
  check('理由点明周期', v.reason.contains('4 帧'));

  final noHash = <FrameSample>[
    for (var i = 0; i < 8; i++) f(i * 500, motion: i.toDouble()),
  ];
  check('缺哈希时跳过循环检测',
      gate.evaluate(noHash).loopPeriod == 0);
  check('短序列不误报周期', gate.evaluate(healthy().take(6).toList()).loopPeriod == 0);
  final tooNoisy = <String>['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h'];
  check('无重复哈希不报循环',
      gate.evaluate(<FrameSample>[
        for (var i = 0; i < 8; i++)
          f(i * 500, motion: 15, hash: tooNoisy[i]),
      ]).loopPeriod == 0);
  check('最小周期可配',
      const ContentGate(loopMinPeriod: 5).evaluate(loop).loopPeriod == 0);
}

void testPriority() {
  print('\n== G. 判定优先级与边界 ==');
  final gate = ContentGate();
  final allBad = <FrameSample>[
    for (var i = 0; i < 8; i++)
      f(i * 500, mean: 2, min: 0, max: 3, motion: 0, hash: 'z${i % 2}'),
  ];
  check('黑屏/纯色/静帧/循环同时命中时优先报黑屏',
      gate.evaluate(allBad).kind == ContentFaultKind.black);

  final flatLoop = <FrameSample>[
    for (var i = 0; i < 8; i++)
      f(i * 500, mean: 100, min: 99, max: 101, motion: 0,
          hash: 'q${i % 3}'),
  ];
  check('纯色优先于静帧/循环',
      gate.evaluate(flatLoop).kind == ContentFaultKind.flat);

  final loopFrozen = <FrameSample>[
    for (var i = 0; i < 8; i++)
      f(i * 500, mean: 100, motion: 0, hash: 'r${i % 2}'),
  ];
  check('循环优先于静帧',
      gate.evaluate(loopFrozen).kind == ContentFaultKind.loop);

  check('标签全部有中文映射',
      ContentFaultKind.values.every((k) =>
          ContentVerdict.labelOf(k).isNotEmpty &&
          ContentVerdict.labelOf(k) != k.name));
}

Future<void> main() async {
  testHealthy();
  testInsufficient();
  testBlack();
  testFrozen();
  testFlat();
  testLoop();
  testPriority();
  print('\n回归通过：$_pass/${_pass + _fail} 断言通过');
  if (_fail > 0) exitCode = 1;
}
