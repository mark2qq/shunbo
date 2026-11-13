/// 「默认加载源」的一次性装载器（纯 Dart，不依赖 Flutter，可在裸 `dart run` 下回归）。
///
/// 需求来源：五个候选地址实测后选定 `47.96.82.41/config.json` 作为默认源，
/// 用户打开开关后**不该再需要手动点一次导入**才算生效。因此进入点播栏目时
/// 若「开关已开 + 选中的就是默认源 + 片库里还没有外部条目」，自动拉一次。
///
/// 三条纪律：
/// * **单飞**：三个栏目页（电影 / 电视剧 / 纪录片）共用同一个实例，
///   只发一次请求，其余页面等同一个 Future；
/// * **不重试**：进程内只尝试一次。失败不自动重来 —— 默认源一次要 40 秒以上，
///   静默重试会让人以为播放器坏了；
/// * **只在默认源上生效**：用户自己填的地址不自动请求，避免拿别人的地址做后台访问。
library;

import '../../data/onboarding/third_party_vod_service.dart';
import '../../data/onboarding/vod_source_address.dart';

/// 取一次接口并产出报告。实现方负责把成功的条目装进片库。
///
/// [onProgress] 用于「边加载边入库」：默认源最多探测 100 个站点，
/// 等全跑完再一次性刷卡片，用户会觉得栏目切换像卡死。
typedef VodImportRunner = Future<VodImportReport> Function(
  String url, {
  required bool allowInsecureHttp,
  required bool allowExternalCode,
  void Function(VodImportPartial partial)? onProgress,
});

class VodAutoSource {
  VodAutoSource({
    required VodImportRunner runner,
    this.defaultUrl = kVodDefaultSourceUrl,
    this.onPartial,
  }) : _runner = runner;

  final VodImportRunner _runner;

  /// 分批回调（由构造方注入，通常是「把当前累计条目装进片库后通知刷新」）。
  /// 为空表示不关心中间结果。
  final void Function(VodImportPartial partial)? onPartial;

  /// 允许被自动加载的那一条地址。
  final String defaultUrl;

  Future<VodImportReport?>? _pending;

  /// 本次进程是否已经尝试过（成功或失败都算）。
  bool get attempted => _pending != null;

  /// 是否需要 / 是否已经发起默认源加载。
  ///
  /// 返回 `null` 表示「这次不该加载」（开关关着、选中的不是默认源、
  /// 片库里已经有外部条目），调用方据此不要显示加载中状态。
  Future<VodImportReport?>? ensureLoaded({
    required bool enabled,
    required String selectedUrl,
    required bool allowInsecureHttp,
    required bool alreadyHasItems,
    bool allowExternalCode = true,
  }) {
    if (_pending != null) return _pending;
    if (!enabled) return null;
    if (alreadyHasItems) return null;
    if (selectedUrl.trim() != defaultUrl) return null;
    _pending = _run(allowInsecureHttp, allowExternalCode);
    return _pending;
  }

  Future<VodImportReport?> _run(
      bool allowInsecureHttp, bool allowExternalCode) async {
    try {
      return await _runner(
        defaultUrl,
        allowInsecureHttp: allowInsecureHttp,
        allowExternalCode: allowExternalCode,
        onProgress: _onPartial,
      );
    } catch (_) {
      // 自动加载失败不该把栏目页打崩：返回 null，界面显示「未自动加载」。
      return null;
    }
  }

  /// 分批回调（由构造方注入）。为空表示不关心中间结果。
  void _onPartial(VodImportPartial partial) => onPartial?.call(partial);

  /// 门禁用：重置单飞状态。
  void resetForTest() => _pending = null;
}
