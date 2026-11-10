import 'dart:io';

import 'media_kit_player_controller.dart';
import 'mock_player_controller.dart';
import 'mpv/libmpv_player_controller.dart';
import 'mpv/mpv_platform_channel_native.dart';
import 'player_controller.dart';

/// 按平台选择播放内核（E3 真机接线的唯一入口）。
///
/// - **Android**：走 `shunbo/mpv` 平台通道（原生侧 media3/ExoPlayer 后端）。
///   这是本机唯一能真实编译验证的原生路径，也是渲染面（TextureView）已经接好的那条。
/// - **桌面（Windows/Linux/macOS）**：走 media_kit（随包分发的 libmpv）。
///   自研 FFI 渲染面缺 GPU 纹理桥，硬接只会得到「编译通过、运行黑屏」。
/// - **其它（含 `dart run` 纯逻辑环境）**：仍用 [MockPlayerController]，
///   避免在没有 Flutter 引擎的场景里初始化原生插件。
///
/// 判定用 `Platform.isAndroid` / `Platform.isWindows` 系而不是 `defaultTargetPlatform`：
/// 后者在 Flutter 单元测试里会被 override，容易让测试环境误走原生通道。
PlayerController createPlatformPlayer() {
  if (Platform.isAndroid) {
    return LibMpvPlayerController(
      native: MpvPlatformChannelNative(backendTag: 'ExoPlayer'),
    );
  }
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    return MediaKitPlayerController();
  }
  return MockPlayerController()..durationSeconds = 45 * 60.0;
}

/// 当前内核是否需要真实渲染表面（决定 UI 是否挂视频面）。
bool needsRenderSurface(PlayerController player) =>
    player is LibMpvPlayerController || player is MediaKitPlayerController;

/// 内核名（UI 明示，避免「跨内核画质桥接」被静默降级）。
String playerBackendLabel(PlayerController player) {
  if (player is LibMpvPlayerController) {
    final n = player.native;
    if (n is MpvPlatformChannelNative) return n.backendTag;
    return 'libmpv';
  }
  if (player is MediaKitPlayerController) {
    return 'libmpv（media_kit，硬解）';
  }
  return 'Mock（演示内核，不出画面）';
}
