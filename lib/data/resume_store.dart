import 'resume_record.dart';

/// 续播持久化抽象（E6）。
///
/// 真实实现：移动/桌面/TV 端用 shared_preferences 或 sqlite；
/// 本抽象使上层（编排层/UI）不依赖具体存储，便于用内存实现做逻辑验证。
///
/// 续播只保存规范内容坐标，读取后由调度层按目标源画像重新对齐到物理位置。
abstract class ResumeStore {
  /// 保存/覆盖某媒体的续播进度。
  Future<void> save(ResumeRecord r);

  /// 读取某媒体的续播进度（无则返回 null）。
  Future<ResumeRecord?> load(String mediaId);

  /// 读取全部续播记录（用于"继续观看"列表）。
  Future<List<ResumeRecord>> all();

  /// 删除某媒体的续播记录。
  Future<void> remove(String mediaId);
}
