import 'dart:convert';

/// libmpv 事件类型（E3 真机集成的事件数据通路）。
///
/// 对应 libmpv JSON IPC / `mpv_wait_event` 的常见事件；原生侧（FFI 轮询或
/// Android EventChannel）统一以 **一行一个 JSON** 推送给 Dart 层。
enum MpvEventKind {
  fileLoaded,
  playbackRestart,
  endFile,
  propertyChange,
  logMessage,
  shutdown,
  unknown,
}

/// 一条内核事件。
class MpvEvent {
  final MpvEventKind kind;

  /// 原始事件名（unknown 时保留，便于诊断新版本内核的新事件）。
  final String? eventName;

  /// property-change 的属性名。
  final String? name;

  /// 事件载荷：property-change 为属性值，end-file 为 reason，log-message 为文本。
  final Object? data;
  final String? error;

  /// 原始 JSON 行（诊断落盘用）。
  final String raw;

  const MpvEvent({
    required this.kind,
    this.eventName,
    this.name,
    this.data,
    this.error,
    this.raw = '',
  });

  /// 数值型载荷（libmpv 的 time-pos / frame-count 等可能以 num 或字符串到达）。
  double? get numericData {
    final d = data;
    if (d is num) return d.toDouble();
    if (d is String) return double.tryParse(d);
    return null;
  }

  /// 宽松解析：坏行/非对象/缺 event 一律返回 null，绝不因单条脏数据打断事件循环。
  static MpvEvent? tryParse(String line) {
    if (line.trim().isEmpty) return null;
    try {
      final v = jsonDecode(line);
      if (v is! Map) return null;
      return MpvEvent.fromJson(Map<String, dynamic>.from(v), raw: line);
    } catch (_) {
      return null;
    }
  }

  factory MpvEvent.fromJson(Map<String, dynamic> j, {String raw = ''}) {
    final name0 = j['event'] as String?;
    final kind = _kindOf(name0);
    Object? data;
    switch (kind) {
      case MpvEventKind.endFile:
        data = j['reason'] ?? j['data'];
        break;
      case MpvEventKind.logMessage:
        data = j['text'] ?? j['data'];
        break;
      default:
        data = j['data'];
        break;
    }
    return MpvEvent(
      kind: kind,
      eventName: name0,
      name: j['name'] as String?,
      data: data,
      error: j['error'] as String?,
      raw: raw,
    );
  }

  static MpvEventKind _kindOf(String? e) {
    switch (e) {
      case 'file-loaded':
        return MpvEventKind.fileLoaded;
      case 'playback-restart':
        return MpvEventKind.playbackRestart;
      case 'end-file':
        return MpvEventKind.endFile;
      case 'property-change':
        return MpvEventKind.propertyChange;
      case 'log-message':
        return MpvEventKind.logMessage;
      case 'shutdown':
        return MpvEventKind.shutdown;
      default:
        return MpvEventKind.unknown;
    }
  }

  @override
  String toString() => 'MpvEvent(${eventName ?? kind.name}, name=$name, data=$data)';
}
