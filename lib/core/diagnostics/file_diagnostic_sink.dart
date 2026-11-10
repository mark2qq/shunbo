import 'dart:convert';
import 'dart:io';

import 'diagnostic_sink.dart';

/// 真实落盘的诊断 Sink（E7 可观测性收尾）：JSONL 追加写 + 体积轮转 + 串行化。
///
/// 设计约束：[DiagnosticSink.record] 是**同步**接口（不允许阻塞播放链路），
/// 因此这里只做「入缓冲 + 挂到串行 Future 链」，真正的文件 IO 异步执行；
/// 写入失败保留缓冲等待重试，缓冲有上限避免无限增长。
/// 只用 `dart:io`，三端通用且可在裸 `dart run` 下验证。
class FileDiagnosticSink implements DiagnosticSink {
  final File file;

  /// 超过该字节数时把当前文件轮转为 `<file>.1`（保留上一轮）。
  final int maxBytes;

  /// 缓冲上限，防止长期离线时内存膨胀。
  final int maxBuffer;

  final List<DiagnosticEvent> _buffer = <DiagnosticEvent>[];
  Future<void> _chain = Future<void>.value();

  /// 因缓冲溢出被丢弃的事件数（供诊断自监控）。
  int dropped = 0;

  /// 写入降级标志（目录只读 / 磁盘满）。
  bool degraded = false;

  FileDiagnosticSink(
    this.file, {
    this.maxBytes = 256 * 1024,
    this.maxBuffer = 1000,
  });

  int get buffered => _buffer.length;

  @override
  void record(DiagnosticEvent event) {
    _buffer.add(event);
    while (_buffer.length > maxBuffer) {
      _buffer.removeAt(0);
      dropped++;
    }
    // 串行链：避免并发 append 交错写坏 JSONL。
    _chain = _chain.then((_) => flush());
  }

  /// 等待所有已排队的写入完成（验证 / 应用退出时调用）。
  Future<void> drain() => _chain;

  /// 把当前缓冲刷到文件；失败则保留缓冲待下次重试。
  Future<void> flush() async {
    if (_buffer.isEmpty) return;
    final batch = _buffer.toList();
    try {
      if (!await file.parent.exists()) {
        await file.parent.create(recursive: true);
      }
      if (await file.exists() && await file.length() > maxBytes) {
        final rotated = File('${file.path}.1');
        if (await rotated.exists()) await rotated.delete();
        await file.rename(rotated.path);
      }
      final text =
          '${batch.map((e) => jsonEncode(e.toJson())).join('\n')}\n';
      await file.writeAsString(text, mode: FileMode.append);
      _buffer.removeRange(0, batch.length);
      degraded = false;
    } catch (_) {
      degraded = true;
    }
  }
}
