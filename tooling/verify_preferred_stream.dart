// 每频道「上次顺畅播放」线路缓存回归：记录 / 读取 / TTL / 落盘 / 限容。
//
// 这段逻辑是「按频道记住流畅线路、下次直接选用」的核心，错了的表现是
// 「明明昨天看得很顺的台，今天又要从头探测、黑屏几秒」——没有任何异常栈。
// 三个直接对应真机体验的断言：
//   ① 记录的偏好必须在 TTL 内可读取，过期后失效（公开源会换 token / 限流）；
//   ② 后写入的同频道记录必须覆盖先写（永远保留「最近一次」顺畅线路）；
//   ③ 落盘 → 读回必须一致（跨会话才能生效），且坏文件 / 空文件不崩溃。
//
// 运行：dart run tooling/verify_preferred_stream.dart
import 'dart:io';

import 'package:shunbo/features/live/preferred_stream.dart';

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

/// 可控时钟：TTL 相关断言不能靠 `sleep` 等 24 小时。
class _FakeClock {
  DateTime now = DateTime(2026, 11, 6, 12);
  DateTime call() => now;
  void advance(Duration d) => now = now.add(d);
}

void testRecordAndRead() {
  print('\n== 记录与读取 ==');
  final board = PreferredStreamBoard();
  check('初始无偏好', board.preferredFor('CCTV-1') == null);

  board.record('CCTV-1', 'http://a.example/1.m3u8');
  check('记录后可读取', board.preferredFor('CCTV-1') == 'http://a.example/1.m3u8');

  board.record('CCTV-2', 'http://b.example/2.m3u8');
  check('不同频道互不影响', board.preferredFor('CCTV-2') == 'http://b.example/2.m3u8');
  check('CCTV-1 仍保留', board.preferredFor('CCTV-1') == 'http://a.example/1.m3u8');

  // 后写覆盖先写：永远保留最近一次顺畅线路。
  board.record('CCTV-1', 'http://a.example/hd.m3u8');
  check('同频道后写覆盖先写',
      board.preferredFor('CCTV-1') == 'http://a.example/hd.m3u8',
      board.preferredFor('CCTV-1'));
}

void testTtl() {
  print('\n== TTL 过期 ==');
  final clock = _FakeClock();
  final board = PreferredStreamBoard(clock: clock.call);
  board.record('CCTV-1', 'http://a.example/1.m3u8');
  check('TTL 内可读', board.preferredFor('CCTV-1') == 'http://a.example/1.m3u8');

  // 「持久保存」要求跨天仍有效：隔一天回来不该重新检索。
  clock.advance(const Duration(hours: 23));
  check('隔天仍可读', board.preferredFor('CCTV-1') == 'http://a.example/1.m3u8');

  clock.advance(const Duration(days: 5));
  check('6 天后仍可读（TTL=7 天）',
      board.preferredFor('CCTV-1') == 'http://a.example/1.m3u8');

  clock.advance(const Duration(days: 2));
  check('超过 TTL 后失效', board.preferredFor('CCTV-1') == null);
}

void testForget() {
  print('\n== 主动作废 ==');
  final board = PreferredStreamBoard();
  board.record('CCTV-1', 'http://a.example/1.m3u8');
  board.record('CCTV-2', 'http://b.example/2.m3u8');

  board.forget('CCTV-1');
  check('作废后读不到', board.preferredFor('CCTV-1') == null);
  check('其它频道不受影响', board.preferredFor('CCTV-2') == 'http://b.example/2.m3u8');
  check('作废后长度减一', board.length == 1, 'len=${board.length}');

  // 空 id 不产生任何记录（自动切台路径可能传入空 id）。
  board.forget('');
  check('空 id 作废不新增记录', board.length == 1, 'len=${board.length}');

  // 作废必须体现在落盘结果里：否则重启后又「复活」成一条死链。
  board.forget('CCTV-2');
  final restored = PreferredStreamBoard()..loadEncoded(board.encode());
  check('作废写入落盘后不复活', restored.preferredFor('CCTV-2') == null);
}

void testEncodeDecode() {
  print('\n== 落盘往返 ==');
  final board = PreferredStreamBoard();
  board.record('CCTV-1', 'http://a.example/1.m3u8');
  board.record('CCTV-2', 'http://b.example/2.m3u8');

  final json = board.encode();
  check('编码产出非空 JSON', json.isNotEmpty);

  final restored = PreferredStreamBoard();
  restored.loadEncoded(json);
  check('读回后 CCTV-1 一致',
      restored.preferredFor('CCTV-1') == 'http://a.example/1.m3u8');
  check('读回后 CCTV-2 一致',
      restored.preferredFor('CCTV-2') == 'http://b.example/2.m3u8');

  // 坏文件 / 空文本不能崩：缓存只是加速项，坏文件应被忽略。
  final safe = PreferredStreamBoard();
  safe.loadEncoded('这不是 json');
  check('坏 JSON 不崩溃且无记录', safe.preferredFor('X') == null);
  final empty = PreferredStreamBoard();
  empty.loadEncoded('');
  check('空文本不崩溃', empty.preferredFor('X') == null);

  // 缺少 preferred 字段的 JSON 也能安全忽略。
  final partial = PreferredStreamBoard();
  partial.loadEncoded('{"version":1}');
  check('缺 preferred 字段不崩溃', partial.preferredFor('X') == null);
}

void testTrim() {
  print('\n== 限容 ==');
  final clock = _FakeClock();
  final board = PreferredStreamBoard(clock: clock.call, );
  for (var i = 0; i < PreferredStreamBoard.maxEntries + 5; i++) {
    board.record('CH$i', 'http://h$i.example/$i.m3u8');
    clock.advance(const Duration(seconds: 1));
  }
  check('超限后记录数不溢出', board.length <= PreferredStreamBoard.maxEntries,
      'len=${board.length}');
  // 最旧的记录（CH0）应被淘汰，最新的（CH${max+4}）应保留。
  check('最旧记录被淘汰', board.preferredFor('CH0') == null);
  check('最新记录仍保留',
      board.preferredFor('CH${PreferredStreamBoard.maxEntries + 4}') != null);
}

Future<void> main() async {
  testRecordAndRead();
  testTtl();
  testForget();
  testEncodeDecode();
  testTrim();

  print('');
  if (_fail == 0) {
    print('回归通过：$_pass/$_pass 断言通过');
    exit(0);
  }
  print('回归失败：$_pass/${_pass + _fail} 断言通过');
  exit(1);
}
