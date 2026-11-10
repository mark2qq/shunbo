import 'resume_record.dart';
import 'resume_store.dart';

/// 内存版续播存储（MVP / 单元测试用，不落盘）。
///
/// 复刻 [ResumeStore] 全部语义；真实持久化（shared_preferences / sqlite）
/// 将在 E6 落地阶段替换，编排层与 UI 不改动。
class MemoryResumeStore implements ResumeStore {
  final Map<String, ResumeRecord> _records = {};

  @override
  Future<void> save(ResumeRecord r) async => _records[r.mediaId] = r;

  @override
  Future<ResumeRecord?> load(String mediaId) async => _records[mediaId];

  @override
  Future<List<ResumeRecord>> all() async => List.unmodifiable(_records.values);

  @override
  Future<void> remove(String mediaId) async => _records.remove(mediaId);
}
