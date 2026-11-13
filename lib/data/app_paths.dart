import 'dart:io';

/// 应用数据目录的唯一解析点（进度 / 配置 / 引导状态 / 诊断日志都落在这里）。
///
/// 为什么不能继续用 `Directory.systemTemp`：
/// 临时目录在桌面端会被系统清理（Windows 存储感知、macOS 定期清 `/var/folders`），
/// 用户装完用一周再打开，「继续观看」就没了 —— 而这正是本项目最核心的卖点。
/// 所以桌面端一律落到每个用户自己的持久目录。
///
/// **Android 端尤其不能用缓存目录**（R8「同一渠道内升级必须保留用户数据」）：
/// `Directory.systemTemp` 在 Android 上解析到 `context.getCacheDir()`，
/// 系统在存储紧张时会主动清空它，用户的播放进度、收藏、频道号绑定会一起消失。
/// 正确的目录是应用私有 **files** 目录，由原生侧通过 `shunbo/system` 的
/// `dataDir` 方法给出（[configure] 注入）。取不到时才退回旧行为并置 [degraded]，
/// 让诊断页能看出「数据可能被系统清理」。
///
/// 两个渠道包（`com.shunbo.tv` / `com.shunbo.tv.lite`）各自拥有独立的
/// files 目录，因此天然互不影响，满足 R8 的「可同机并存、数据互不干扰」。
class AppPaths {
  /// 数据文件名（与目录分开定义，避免各处手写字符串拼错）。
  static const String resumeFile = 'resume.json';
  static const String syncSnapshotFile = 'sync-snapshot.json';
  static const String diagnosticsFile = 'diagnostics.jsonl';
  static const String configFile = 'config.json';
  static const String liveHealthFile = 'live-health.json';
  static const String liveRegionFile = 'live-region.txt';
  static const String channelNumbersFile = 'channel-numbers.json';
  static const String livePreferredFile = 'live-preferred.json';

  /// 第三方点播片库的本地缓存（1.0.5 第三次修：冷启动秒开）。
  static const String vodLibraryFile = 'vod-library.json';

  /// 用户提交新接口后生成的片源索引目录文件（1.0.5 第十六次修）。
  ///
  /// 与随包的 `assets/vod_index/` 同构但落在**数据目录**，因为用户换的
  /// 接口是运行期才知道的，不可能打包进去。后续进入点播优先读这一份。
  static const String vodIndexFile = 'vod-index.json';

  /// 形态偏好（R1：自动 / 强制手机 / 强制电视）。
  static const String formFactorFile = 'form-factor.txt';

  /// 投屏模式记忆（R12b：该源该走直推还是串流）。
  static const String castModeFile = 'cast-mode.json';

  /// 由平台层注入的目录（Android 的应用私有 files 目录）。
  static Directory? _override;

  /// 是否退回了「可能被系统清理」的目录（供诊断展示）。
  static bool degraded = false;

  /// 注入平台解析出的数据目录。传 null / 空串表示没有拿到，保持原有推断。
  static void configure(String? path) {
    if (path == null || path.isEmpty) return;
    _override = Directory(path);
    degraded = false;
  }

  /// 解析数据目录（不创建）。
  static Directory dataDir() {
    final injected = _override;
    if (injected != null) return injected;

    final sep = Platform.pathSeparator;
    String? env(String key) {
      final v = Platform.environment[key];
      return (v == null || v.isEmpty) ? null : v;
    }

    if (Platform.isWindows) {
      // LOCALAPPDATA 在极少数精简系统里可能缺失，退回 APPDATA，再退回用户目录下的默认位置。
      final base = env('LOCALAPPDATA') ??
          env('APPDATA') ??
          '${env('USERPROFILE') ?? '.'}$sep'
              'AppData${sep}Local';
      return Directory('${_trimSep(base)}$sep'
          'Shunbo');
    }
    if (Platform.isMacOS) {
      final home = env('HOME') ?? '.';
      return Directory('$home/Library/Application Support/Shunbo');
    }
    if (Platform.isLinux) {
      final base = env('XDG_DATA_HOME') ?? '${env('HOME') ?? '.'}/.local/share';
      return Directory('${_trimSep(base)}/shunbo');
    }
    // 兜底：Android 未注入目录时退回应用私有缓存目录。
    // 这不是期望路径（系统可能清空），仅保证功能可用，并由 [degraded] 暴露。
    degraded = true;
    return Directory('${Directory.systemTemp.path}${sep}shunbo');
  }

  /// 解析并确保目录存在（写盘前必须调用）。
  static Future<Directory> ensureDataDir() async {
    final dir = dataDir();
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// 某个数据文件的完整路径（调用前应先 [ensureDataDir]）。
  static String file(String name) =>
      '${dataDir().path}${Platform.pathSeparator}$name';
}

String _trimSep(String s) {
  while (s.length > 1 && (s.endsWith('/') || s.endsWith('\\'))) {
    s = s.substring(0, s.length - 1);
  }
  return s;
}
