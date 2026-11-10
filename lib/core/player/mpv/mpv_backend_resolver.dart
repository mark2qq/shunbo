/// 播放内核后端类型（E3 真实集成的两条路线）。
enum MpvBackend {
  /// Dart FFI 直连 libmpv 动态库（桌面/TV 首选，零桥接开销）。
  ffi,

  /// 平台通道调用各端原生封装（Android 端 ExoPlayer 回退时必要）。
  platformChannel,
}

/// libmpv 动态库可用性探针（抽象，便于纯 Dart 验证与注入）。
abstract class MpvLibraryProbe {
  /// 动态库是否可加载。
  bool get isAvailable;

  /// 库名/路径（诊断用）。
  String get libraryName;
}

class FakeMpvLibraryProbe implements MpvLibraryProbe {
  @override
  final bool isAvailable;
  @override
  final String libraryName;

  const FakeMpvLibraryProbe(this.isAvailable,
      [this.libraryName = 'fake-libmpv']);
}

/// 后端决议结果。
class MpvBackendResolution {
  final MpvBackend backend;
  final String reason;

  const MpvBackendResolution(this.backend, this.reason);
}

/// 后端决议：优先 FFI（零桥接开销）；libmpv 缺失时降级到平台通道（ExoPlayer 回退）。
///
/// 对应设计稿两处风险：「跨内核画质桥接」与「低版本/无原生库设备兼容」。
/// 注意：降级后画质/能力可能不等价，调用方须在 UI 明示（不可静默降级）。
MpvBackendResolution resolveMpvBackend(MpvLibraryProbe probe) {
  if (probe.isAvailable) {
    return const MpvBackendResolution(
      MpvBackend.ffi,
      'libmpv 动态库可用，走 FFI 零桥接路径',
    );
  }
  return MpvBackendResolution(
    MpvBackend.platformChannel,
    'libmpv 动态库缺失(${probe.libraryName})，降级到平台通道/ExoPlayer 回退',
  );
}
