import '../../core/diagnostics/diagnostic_sink.dart';
import '../resume_record.dart';
import '../resume_store.dart';
import 'sync_transport.dart';

/// 本地写入的暂存接口。由 [ResumeSyncEngine] 实现，[SyncAwareResumeStore] 调用。
abstract class SyncStage {
  void stageWrite(ResumeRecord record);
  void stageDelete(String mediaId);
}

/// 续播存储装饰器：拦截本地写入 → 暂存待同步；同步应用远端变更走
/// [applyRemote] / [applyRemoteDelete]，**不产生新的待同步项**（否则会无限回声）。
///
/// 编排层、UI 无需任何改动：只要注入本装饰器，`save`/`remove` 就会自动进入同步。
class SyncAwareResumeStore implements ResumeStore {
  final ResumeStore inner;
  SyncStage? stage;

  SyncAwareResumeStore(this.inner);

  @override
  Future<void> save(ResumeRecord r) async {
    await inner.save(r);
    stage?.stageWrite(r);
  }

  @override
  Future<ResumeRecord?> load(String mediaId) => inner.load(mediaId);

  @override
  Future<List<ResumeRecord>> all() => inner.all();

  @override
  Future<void> remove(String mediaId) async {
    await inner.remove(mediaId);
    stage?.stageDelete(mediaId);
  }

  /// 应用远端合并结果：绕过 stage，避免把「同步下来的进度」当成新的本地写入。
  Future<void> applyRemote(ResumeRecord r) => inner.save(r);

  /// 应用远端墓碑：从本地删除，同样不产生待同步项。
  Future<void> applyRemoteDelete(String mediaId) => inner.remove(mediaId);
}

/// 一次同步的结果（供 UI 展示 / 诊断）。
class SyncResult {
  /// 传输不可用（断网 / 共享目录不可达）；本地进度不受影响，待同步项保留待重试。
  final bool offline;

  /// 从远端合并进来的条目数。
  final int pulled;

  /// 推送到远端的条目总数。
  final int pushed;

  /// 实际写回本地的条目数。
  final int applied;

  /// 远端与本地同时有更新、由逻辑时钟裁决覆盖的次数。
  final int conflicts;

  /// 仍待同步的本地写入数（离线时 > 0）。
  final int pending;

  const SyncResult({
    required this.offline,
    required this.pulled,
    required this.pushed,
    required this.applied,
    required this.conflicts,
    required this.pending,
  });

  String get userMessage => offline
      ? '同步暂不可用，已保留 $pending 条进度，联网后会自动重试。'
      : '已同步：下行 $pulled 条 / 上行 $pushed 条'
          '${conflicts > 0 ? "，解决 $conflicts 处进度冲突" : ""}。';
}

/// 跨端续播同步引擎（E6 收尾，「跨端续播」卖点的最后一环）。
///
/// 合并次序（每一步都是可验证的不变量）：
/// 1. `pull` 远端快照；失败 → 离线返回，**本地数据不动、待同步项保留**。
/// 2. 观察远端最大 stamp 并推进本地 Lamport 时钟（保证因果：后写者 stamp 必更大）。
/// 3. 把本地全部记录以 stamp 0 兜底并入合并集，避免远端空快照抹掉本机进度。
/// 4. 暂存写入在「观察远端之后」才打 stamp，因此一定胜出；墓碑同理。
/// 5. 合并集写回本地（绕过 stage，无回声）。
/// 6. `push` 合并集；失败同样保留待同步项，下次原样重试（幂等）。
class ResumeSyncEngine implements SyncStage {
  final SyncAwareResumeStore local;
  final SyncTransport transport;
  final String deviceId;
  final DiagnosticSink diagnostics;

  int _clock = 0;
  final Map<String, bool> _staged = <String, bool>{}; // mediaId → 是否删除
  final Map<String, ResumeRecord> _stagedRecords = <String, ResumeRecord>{};
  SyncResult? lastResult;

  ResumeSyncEngine({
    required this.local,
    required this.transport,
    required this.deviceId,
    this.diagnostics = const NoopDiagnosticSink(),
  }) {
    local.stage = this;
  }

  /// 当前 Lamport 逻辑时钟（验证因果单调性用）。
  int get clock => _clock;

  int get pendingCount => _staged.length;

  @override
  void stageWrite(ResumeRecord record) {
    _staged[record.mediaId] = false;
    _stagedRecords[record.mediaId] = record;
  }

  @override
  void stageDelete(String mediaId) {
    _staged[mediaId] = true;
    _stagedRecords.remove(mediaId);
  }

  Future<SyncResult> sync() async {
    // 1. 下行：失败即离线退出，绝不损伤本地进度。
    final SyncSnapshot remote;
    try {
      remote = await transport.pull();
    } catch (_) {
      return _offline();
    }

    // 2. 观察远端 → 推进逻辑时钟（Lamport receive 规则）。
    var remoteMax = 0;
    for (final e in remote.entries.values) {
      if (e.stamp > remoteMax) remoteMax = e.stamp;
    }
    if (remoteMax > _clock) _clock = remoteMax;

    // 3. 合并集基线：远端优先，本地未暂存记录以 stamp 0 兜底。
    final merged = <String, SyncEntry>{...remote.entries};
    for (final r in await local.all()) {
      merged.putIfAbsent(
        r.mediaId,
        () => SyncEntry(
            mediaId: r.mediaId,
            record: r,
            stamp: 0,
            writerDeviceId: deviceId),
      );
    }

    // 4. 应用暂存写入：观察远端之后才打 stamp，故必然胜出（因果正确）。
    var conflicts = 0;
    for (final id in _staged.keys.toList()) {
      _clock += 1;
      final isDelete = _staged[id]!;
      final entry = isDelete
          ? SyncEntry.tombstone(id, _clock, deviceId)
          : SyncEntry(
              mediaId: id,
              record: _stagedRecords[id],
              stamp: _clock,
              writerDeviceId: deviceId);
      final remoteHadUpdate = remote.entries[id] != null;
      if (remoteHadUpdate && !isDelete) {
        conflicts++;
        diagnostics.record(DiagnosticEvent(
          kind: DiagnosticKind.syncConflict,
          at: DateTime.now(),
          sourceId: '',
          mediaId: id,
          detail: '远端与本地同时更新，按逻辑时钟裁决',
          attributes: <String, Object?>{
            'deviceId': deviceId,
            'remoteStamp': remote.entries[id]!.stamp,
            'localStamp': entry.stamp,
          },
        ));
      }
      merged[id] = SyncEntry.choose(merged[id], entry);
    }

    // 5. 写回本地（不经过 stage）。
    var applied = 0;
    for (final e in merged.values) {
      if (e.isTombstone) {
        await local.applyRemoteDelete(e.mediaId);
      } else if (e.record != null) {
        await local.applyRemote(e.record!);
      }
      applied++;
    }

    // 6. 上行：失败保留待同步项，下次原样重试。
    try {
      await transport.push(
          SyncSnapshot(Map<String, SyncEntry>.unmodifiable(merged)));
    } catch (_) {
      return _offline(pulled: remote.entries.length, applied: applied);
    }

    _staged.clear();
    _stagedRecords.clear();
    final result = SyncResult(
      offline: false,
      pulled: remote.entries.length,
      pushed: merged.length,
      applied: applied,
      conflicts: conflicts,
      pending: 0,
    );
    lastResult = result;
    diagnostics.record(DiagnosticEvent(
      kind: DiagnosticKind.syncApplied,
      at: DateTime.now(),
      detail: '跨端续播同步完成',
      attributes: <String, Object?>{
        'deviceId': deviceId,
        'pulled': result.pulled,
        'pushed': result.pushed,
        'conflicts': result.conflicts,
        'clock': _clock,
      },
    ));
    return result;
  }

  SyncResult _offline({int pulled = 0, int applied = 0}) {
    final result = SyncResult(
      offline: true,
      pulled: pulled,
      pushed: 0,
      applied: applied,
      conflicts: 0,
      pending: _staged.length,
    );
    lastResult = result;
    diagnostics.record(DiagnosticEvent(
      kind: DiagnosticKind.syncOffline,
      at: DateTime.now(),
      detail: '同步传输不可用，待同步项保留',
      attributes: <String, Object?>{
        'deviceId': deviceId,
        'pending': result.pending,
      },
    ));
    return result;
  }
}
