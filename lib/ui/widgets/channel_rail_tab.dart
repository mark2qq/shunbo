import 'package:flutter/material.dart';

import '../../app/theme.dart';

/// 全屏横屏右侧的常驻「频道」入口（手机触摸形态专用）。
///
/// 为什么需要它：全屏模式下 AppShell 会隐藏左侧导航栏、直播页也不渲染
/// 右侧浮层，原来的换台入口只剩控制条里一个图标和贴边的 30px 手柄 ——
/// 在 2.16:1 的手机横屏上，右边那块正是用户反馈的「纯黑空白」，既不
/// 好看也点不到。主流手机播放器在这里放的是一枚常驻的侧边标签：
/// 平时缩成一条、点一下（或从左往右贴边内滑）展开节目单。
///
/// 只放在**右侧**：左侧是返回/台标区，底部是控制条，右侧中段是单手
/// 横握时拇指最容易够到、又不会挡住台标与字幕的位置。
class ChannelRailTab extends StatelessWidget {
  const ChannelRailTab({
    super.key,
    required this.onTap,
    this.number,
    this.name,
  });

  /// 展开右侧频道抽屉。
  final VoidCallback onTap;

  /// 当前频道号 / 台名，让入口自带「现在在看哪台」的信息，
  /// 而不是一枚不知道通向哪里的箭头。
  final int? number;
  final String? name;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: name == null ? '打开频道列表' : '打开频道列表，当前 $name',
      child: GestureDetector(
        onTap: onTap,
        // 从右缘向屏幕内侧滑动也能展开（手机上抽屉的惯用手势）。
        onHorizontalDragEnd: (d) {
          if (d.velocity.pixelsPerSecond.dx < -260) onTap();
        },
        child: Container(
          width: 46,
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.58),
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(12),
              bottomLeft: Radius.circular(12),
            ),
            border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.playlist_play_rounded,
                  size: 22, color: Colors.white),
              const SizedBox(height: 5),
              const Text(
                '频道',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  height: 1.1,
                ),
              ),
              if (number != null) ...[
                const SizedBox(height: 7),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: AppTheme.accent,
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: Text(
                    '$number',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
