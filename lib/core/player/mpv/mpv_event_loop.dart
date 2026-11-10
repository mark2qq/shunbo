import 'dart:collection';
import 'dart:async';

import 'mpv_event.dart';

/// 原生侧事件源：只负责提供「一行一个 JSON」的原始流。
///
/// FFI 侧可把 `mpv_wait_event` 轮询结果推入；Android 侧可由
/// `shunbo/mpv/events` EventChannel 提供（见 mpv_event_channel.dart）。
/// 抽象成纯 Dart，使事件循环无需原生构建即可完整验证。
abstract class MpvEventSource {
  Stream<String> get rawLines;
}

/// 包装任意字符串流为事件源。
class MpvEventStreamSource implements MpvEventSource {
  final Stream<String> _lines;
  const MpvEventStreamSource(this._lines);

  @override
  Stream<String> get rawLines => _lines;
}

/// 同步广播的事件源（测试 / 本地注入用；`sync: true` 保证 pump 确定性）。
class MpvEventFeed implements MpvEventSource {
  final StreamController<String> _controller =
      StreamController<String>.broadcast(sync: true);

  @override
  Stream<String> get rawLines => _controller.stream;

  void emit(String line) => _controller.add(line);

  Future<void> close() => _controller.close();
}

class _Subscriber {
  final MpvEventKind? kind; // null = 订阅全部
  final void Function(MpvEvent) handler;

  const _Subscriber(this.kind, this.handler);
}

/// 取消订阅句柄。
class MpvEventSubscription {
  final MpvEventLoop _loop;
  final _Subscriber _subscriber;
  bool _cancelled = false;

  MpvEventSubscription._(this._loop, this._subscriber);

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _loop._remove(_subscriber);
  }
}

/// 内核事件循环：解析 → 入队 → 按类型分发。
///
/// 真机集成的关键性质：
/// - **脏数据隔离**：坏 JSON 只计数、不抛出、不打断后续事件。
/// - **背压**：队列超限时丢弃最旧事件并计数（保留最新状态，避免 OOM）。
/// - **订阅者隔离**：单个 handler 抛异常不影响其他订阅者，事件循环继续运行。
/// - **可暂停**：渲染表面未就绪时暂停分发，恢复后按序补发。
/// - **确定性 pump**：同步分发，测试无需依赖微任务时序。
///
/// ⚠️ **集成约束**：真机必须走 [attach]（每来一行立即分发）。若用
/// [acceptRaw] 批量入队后再 [pump]，多个事件会落在同一时钟刻，
/// 导致 `file-loaded → playback-restart` 的首帧耗时被算成 0ms，门禁失真。
/// 批量模式仅用于重放/回放，且应让事件自带时间戳而非依赖墙钟。
class MpvEventLoop {
  final int maxQueueSize;
  final Queue<MpvEvent> _queue = Queue<MpvEvent>();
  final List<_Subscriber> _subscribers = [];
  bool _paused = false;

  int received = 0;
  int dispatched = 0;
  int malformed = 0;
  int dropped = 0;
  int handlerErrors = 0;

  MpvEventLoop({this.maxQueueSize = 256});

  bool get paused => _paused;
  int get queued => _queue.length;

  void setPaused(bool v) {
    _paused = v;
    if (!v) pump();
  }

  /// 订阅指定类型；[kind] 为 null 时订阅全部事件。
  MpvEventSubscription on(MpvEventKind? kind, void Function(MpvEvent) handler) {
    final sub = _Subscriber(kind, handler);
    _subscribers.add(sub);
    return MpvEventSubscription._(this, sub);
  }

  void _remove(_Subscriber s) => _subscribers.remove(s);

  /// 接收一行原生 JSON（坏行计入 [malformed]）。
  void acceptRaw(String line) {
    final ev = MpvEvent.tryParse(line);
    if (ev == null) {
      malformed++;
      return;
    }
    accept(ev);
  }

  void accept(MpvEvent ev) {
    received++;
    if (_queue.length >= maxQueueSize) {
      // 丢弃最旧，保留最新（播放状态类事件越新越有价值）。
      _queue.removeFirst();
      dropped++;
    }
    _queue.addLast(ev);
  }

  /// 分发队列中的全部事件（暂停时不分发）。
  void pump() {
    if (_paused) return;
    while (_queue.isNotEmpty) {
      final ev = _queue.removeFirst();
      dispatched++;
      for (final s in List<_Subscriber>.from(_subscribers)) {
        if (s.kind != null && s.kind != ev.kind) continue;
        try {
          s.handler(ev);
        } catch (_) {
          handlerErrors++;
        }
      }
    }
  }

  /// 接入原生事件流：每来一行立即解析并分发。
  StreamSubscription<String> attach(
    MpvEventSource source, {
    void Function(Object error)? onError,
  }) {
    return source.rawLines.listen(
      (line) {
        acceptRaw(line);
        pump();
      },
      onError: (Object e) => onError?.call(e),
    );
  }
}
