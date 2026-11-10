import 'dart:convert';
import 'dart:io';

import '../resume_record.dart';

/// 跨端续播同步条目：一条续播记录 + 冲突裁决元数据。
///
/// **为什么不用「按 updatedAt 取最新」（LWW）**：跨端设备的挂钟不可信 —— TV 可能
/// 长期离线、手机可能改过时间或时区，单纯比较时间戳会让「时钟超前」的设备永久压制
/// 其他设备的真实更新。这里改用 **Lamport 逻辑时钟**：
/// 发送事件时 `stamp = max(本地时钟, 已观察到的远端最大 stamp) + 1`，
/// 冲突时只比较 [stamp]，**完全不依赖挂钟**；stamp 相同才用 [writerDeviceId]
/// 做确定性裁决（三端结果一致，不会出现各端保留不同进度）。
///
/// [record] 为 null 表示**墓碑（删除）**。墓碑必须长期保留，否则另一台设备上
/// 过期的旧记录会在下次同步时把已经删除的进度「复活」——这是同步系统的经典暗坑。
class SyncEntry {
  final String mediaId;
  final ResumeRecord? record;
  final int stamp;
  final String writerDeviceId;

  const SyncEntry({
    required this.mediaId,
    required this.record,
    required this.stamp,
    required this.writerDeviceId,
  });

  factory SyncEntry.tombstone(String mediaId, int stamp, String deviceId) =>
      SyncEntry(
          mediaId: mediaId, record: null, stamp: stamp, writerDeviceId: deviceId);

  bool get isTombstone => record == null;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'mediaId': mediaId,
        'record': record?.toJson(),
        'stamp': stamp,
        'writerDeviceId': writerDeviceId,
      };

  /// 宽松解析：坏条目返回 null，由快照层跳过，绝不因单条脏数据中断整个同步。
  static SyncEntry? tryParse(Object? raw) {
    if (raw is! Map) return null;
    try {
      final m = Map<String, dynamic>.from(raw);
      final id = m['mediaId'];
      final stamp = m['stamp'];
      if (id is! String || id.isEmpty || stamp is! int || stamp < 0) return null;
      ResumeRecord? rec;
      final r = m['record'];
      if (r != null) {
        if (r is! Map) return null;
        rec = ResumeRecord.fromJson(Map<String, dynamic>.from(r));
        if (rec.mediaId.isEmpty) return null;
      }
      return SyncEntry(
        mediaId: id,
        record: rec,
        stamp: stamp,
        writerDeviceId: m['writerDeviceId'] as String? ?? '',
      );
    } catch (_) {
      return null;
    }
  }

  /// 全序合并：stamp 大者胜；相同则按 deviceId 字典序确定性裁决。
  static SyncEntry choose(SyncEntry? a, SyncEntry b) {
    if (a == null) return b;
    if (b.stamp != a.stamp) return b.stamp > a.stamp ? b : a;
    return b.writerDeviceId.compareTo(a.writerDeviceId) > 0 ? b : a;
  }
}

/// 一次同步的远端快照（全量条目集，按 mediaId 索引）。
class SyncSnapshot {
  final Map<String, SyncEntry> entries;

  const SyncSnapshot(this.entries);

  static const empty = SyncSnapshot(<String, SyncEntry>{});

  Map<String, dynamic> toJson() => <String, dynamic>{
        'version': 1,
        'entries': entries.values.map((e) => e.toJson()).toList(),
      };

  String toJsonText() => jsonEncode(toJson());

  /// 坏 JSON / 坏字段一律降级：能救多少条目救多少，解析不出来就当空快照，
  /// 保证「对端数据损坏」不会阻断本机播放。
  factory SyncSnapshot.fromJsonText(String text) {
    try {
      final decoded = jsonDecode(text);
      if (decoded is! Map) return SyncSnapshot.empty;
      final list = decoded['entries'];
      final out = <String, SyncEntry>{};
      if (list is List) {
        for (final item in list) {
          final e = SyncEntry.tryParse(item);
          if (e != null) out[e.mediaId] = e;
        }
      }
      return SyncSnapshot(out);
    } catch (_) {
      return SyncSnapshot.empty;
    }
  }
}

/// 同步传输抽象。真实实现可为「账号云同步」或「局域网共享目录 / WebDAV 挂载」；
/// 本抽象让合并逻辑与网络解耦，可在纯 `dart run` 下完整验证。
abstract class SyncTransport {
  Future<SyncSnapshot> pull();
  Future<void> push(SyncSnapshot snapshot);
}

class SyncTransportException implements Exception {
  final String message;
  const SyncTransportException(this.message);

  @override
  String toString() => 'SyncTransportException: $message';
}

/// 内存传输（逻辑验证用）：可注入离线故障与任意初始远端状态。
class InMemorySyncTransport implements SyncTransport {
  SyncSnapshot _remote;

  /// 模拟断网：pull / push 均抛 [SyncTransportException]。
  bool offline;

  int pullCount = 0;
  int pushCount = 0;

  InMemorySyncTransport({SyncSnapshot? initial, this.offline = false})
      : _remote = initial ?? SyncSnapshot.empty;

  SyncSnapshot get remote => _remote;

  /// 直接注入坏 JSON，验证对端数据损坏时的容错（仅测试辅助）。
  void seedRaw(String text) => _remote = SyncSnapshot.fromJsonText(text);

  @override
  Future<SyncSnapshot> pull() async {
    pullCount++;
    if (offline) throw const SyncTransportException('offline (pull)');
    return _remote;
  }

  @override
  Future<void> push(SyncSnapshot snapshot) async {
    pushCount++;
    if (offline) throw const SyncTransportException('offline (push)');
    _remote = SyncSnapshot(Map<String, SyncEntry>.unmodifiable(
        Map<String, SyncEntry>.from(snapshot.entries)));
  }
}

/// 局域网共享目录传输：把快照写成单个 JSON 文件（零平台插件，三端通用）。
/// 适用于家庭内一台设备作为「共享盘」的场景，也是云同步不可用时的降级路径。
/// 采用 `.tmp` → 目标文件的原子替换，避免读到写一半的快照。
class FileSyncTransport implements SyncTransport {
  final File file;

  /// 曾发生读/写降级（供诊断上报）。
  bool degraded = false;

  FileSyncTransport(this.file);

  factory FileSyncTransport.at(String path) => FileSyncTransport(File(path));

  @override
  Future<SyncSnapshot> pull() async {
    try {
      if (!await file.exists()) return SyncSnapshot.empty;
      return SyncSnapshot.fromJsonText(await file.readAsString());
    } catch (_) {
      degraded = true;
      throw const SyncTransportException('shared snapshot unreadable');
    }
  }

  @override
  Future<void> push(SyncSnapshot snapshot) async {
    final tmp = File('${file.path}.tmp');
    try {
      if (!await file.parent.exists()) await file.parent.create(recursive: true);
      await tmp.writeAsString(snapshot.toJsonText());
      if (await file.exists()) await file.delete();
      await tmp.rename(file.path);
    } catch (_) {
      degraded = true;
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {
        // 清理失败不影响主流程
      }
      throw const SyncTransportException('shared snapshot unwritable');
    }
  }
}
