/// 「设置-点播源」的片源索引自动更新（1.0.5 第二十一次修）。
///
/// ## 先说排查结论：改之前系统**没有**定时自动更新
///
/// 1.0.5 已有的 `VodAutoSource` 名字里带「Auto」，但它是**首次进入栏目时
/// 的一次性装载器**：`ensureLoaded()` 要求「开关已开 + 选中的正好是默认源
/// + 片库尚无外部条目 + 本进程没试过」，成功后 `_pending` 就固化，失败也
/// 不重试。它回答的是「第一次进来把片库填上」，不是「过一天把最新片源
/// 补进来」。`VodBootController` 同理只在启动校验时跑一次。
///
/// 所以本文件补的是**真正的定时更新**，并且周期由用户自己定：
///
/// * **七档可选**（第二十四次修，用户红标「可以手动设定更新时间」）：
///   一天 / 三天 / 一周 / 一月 / 一季度 / 半年 / 一年，见
///   [VodUpdateCadence]。默认「一天」—— TVBox / 影视仓一类聚合播放器对
///   片源配置的通行刷新周期就是每天一次；片源站本身按天更新，小时级轮询
///   只会给接口添堵、给电视端添耗电。
/// * 档位存在设置里（`vodUpdateIntervalDays`），改完**立刻生效**：定时器
///   本身按 [kVodIndexUpdateTick]（1 小时）走，只在 tick 时问一句「按当前
///   档位到点了吗」，所以不必为了改周期去重启定时器。
/// * 启动后先补一次（距上次成功已满一个档位才真跑）。上次成功时间落盘，
///   重启不会把周期重置成「立刻又跑」。
///
/// ## 三条纪律
///
/// * **只追加、不重取**：取数只拿「每个采集站的最新一页」，不遍历分页、
///   不重新生成整份目录；写盘走 [VodIndexDirectoryStore.appendFor] 的
///   按 id 合并去重，旧条目一条不删。
/// * **默认索引也更新，但只往里加**（第二十三次修）：默认片源索引地址
///   对应随包只读资产，整份目录一个字节都不改；最新片源追加进它自己的
///   **本地增补**文件（`appendFor` → `loadSupplementFor`），点播页浏览时
///   并进列表最前面。上一版这里直接跳过，设置页按钮点了只回一句
///   「默认片源索引随包只读，无需更新」—— 用户红标：那不是「不能获取」。
/// * **让位播放链路**：跑之前等 `vodBoot.settled` → `vodIndexGate.settled`，
///   没设定接口 / 外部地址关闭时提前 return；只写盘、不 `gate.check()`，
///   不会在用户看片时把播放列表清掉。新条目在**下次进入点播**时生效。
library;

import 'dart:async';

import '../../features/vod/third_party_vod.dart'
    show kVodSitesPerBatch, kMaxThirdPartySites;
import '../../features/vod/vod_catalog.dart';
import 'third_party_vod_service.dart';
import 'vod_index_directory_store.dart';
import 'vod_update_cadence.dart';

export 'vod_update_cadence.dart' show VodUpdateCadence;

/// 默认间隔：**一天**。七档表见 `vod_update_cadence.dart` 的
/// [VodUpdateCadence]，UI 文案与文档都读那张表，不再写死 24 小时。
const Duration kVodIndexUpdateInterval = Duration(days: 1);

/// 定时器的 tick：**每小时**问一次「按当前档位到点了吗」。
///
/// 刻意不把档位直接当 `Timer.periodic` 的周期：用户随时能在设置里改档位，
/// 短 tick + 每次读设定 ⇒ 改完立刻生效，不必重启定时器；代价只是每小时
/// 读一次设置文件（几毫秒），且真正到点前 `runOnce` 在周期判断处就返回了，
/// 不发任何网络请求。
const Duration kVodIndexUpdateTick = Duration(hours: 1);

/// 一次增量取数最多覆盖多少个站的第一页。
/// `kVodSitesPerBatch = 5`，20 批正好覆盖站点上限 100 —— 每站只取一页，
/// 与「全量重取」（要翻到每个站的第几千页）是两回事。
const int kMaxVodUpdateRounds = 20;

/// 单轮更新的预算：弱网下不许把后台任务挂死一整天。
const Duration kVodIndexUpdateBudget = Duration(seconds: 90);

/// 「上次成功更新」的落盘键。只存 UTC ISO8601 字符串。
const String kVodIndexUpdateStateKey = 'vod-index-last-update';

/// 当前生效的接口设定（从 `VodSourceAddressSettings` 投影出来）。
class VodIndexUpdateSettings {
  const VodIndexUpdateSettings({
    required this.url,
    this.enabled = true,
    this.allowInsecureHttp = false,
    this.allowExternalCode = true,
    this.updateIntervalDays = 1,
  });

  final String url;
  final bool enabled;
  final bool allowInsecureHttp;
  final bool allowExternalCode;

  /// 用户在设置页选的自动更新间隔（天）。默认一天。
  final int updateIntervalDays;

  bool get hasAddress => enabled && url.trim().isNotEmpty;

  /// 当前档位（含坏值回落）。
  VodUpdateCadence get cadence => VodUpdateCadence.fromDays(updateIntervalDays);

  /// 当前档位对应的时长，`runOnce` 的周期判断读它。
  Duration get interval => cadence.duration;
}

/// 一次更新的结果（UI 直接显示 [message]）。
class VodIndexUpdateOutcome {
  const VodIndexUpdateOutcome({
    required this.status,
    required this.message,
    this.added = 0,
    this.duplicates = 0,
    this.total = 0,
  });

  final VodIndexUpdateStatus status;
  final String message;
  final int added;
  final int duplicates;
  final int total;

  bool get ok =>
      status == VodIndexUpdateStatus.updated ||
      status == VodIndexUpdateStatus.unchanged;
}

enum VodIndexUpdateStatus { updated, unchanged, skipped, busy, failed }

/// 注入点：设置读取 / 默认地址判定 / 增量取数 / 追加写盘 / 时间戳读写 / 让位。
typedef VodIndexSettingsReader = Future<VodIndexUpdateSettings> Function();
typedef VodLatestFetcher = Future<List<VodItem>> Function(
    VodIndexUpdateSettings settings);
typedef VodIndexAppender = Future<VodIndexAppendResult> Function(
    String url, List<VodItem> items);
typedef VodTimeReader = Future<DateTime?> Function();
typedef VodTimeWriter = Future<void> Function(DateTime time);
typedef VodIdleWaiter = Future<void> Function();

/// 调度器本身**不发网络、不读文件**，全部由装配层注入，
/// 因此 `dart run` 门禁能把整张判定表（周期 / 让位 / 单飞 / 默认地址）
/// 跑完，不需要起 HttpServer。
class VodIndexAutoUpdater {
  VodIndexAutoUpdater({
    required this.readSettings,
    required this.fetchLatest,
    required this.append,
    required this.readLastUpdateAt,
    required this.writeLastUpdateAt,
    required this.waitForIdle,
    this.interval = kVodIndexUpdateInterval,
    this.now = DateTime.now,
  });

  final VodIndexSettingsReader readSettings;
  final VodLatestFetcher fetchLatest;
  final VodIndexAppender append;
  final VodTimeReader readLastUpdateAt;
  final VodTimeWriter writeLastUpdateAt;
  final VodIdleWaiter waitForIdle;

  final Duration interval;
  final DateTime Function() now;

  Timer? _timer;
  bool _running = false;

  bool get isRunning => _running;
  bool get isScheduled => _timer != null;

  /// 纯函数：距上次成功更新是否已经满一个周期。
  /// `last` 为 null（从没成功过）时**允许**立即跑一次 —— 但依然受
  /// 「已设定接口 + 让位完成」两重前置条件约束。
  ///
  /// [every] 不传则用构造时的 [interval]（门禁里的固定档位用），
  /// 传的话按调用方给的周期判断 —— `runOnce` 传的是**设置里当前选的档位**。
  bool shouldUpdate(DateTime? last, DateTime current, [Duration? every]) =>
      last == null || current.difference(last) >= (every ?? interval);

  /// 手动 / 定时共用的一次更新。
  ///
  /// [force] = true 时忽略周期（设置页「立即获取最新片源」用），
  /// **但仍保留**让位、单飞两道闸 —— 手动点击不该成为绕过安全约束的后门。
  /// 默认接口也照走：它写的是本地增补文件，不动随包的只读索引。
  Future<VodIndexUpdateOutcome> runOnce({bool force = false}) async {
    if (_running) {
      return const VodIndexUpdateOutcome(
        status: VodIndexUpdateStatus.busy,
        message: '已有一次片源更新在进行中',
      );
    }
    _running = true;
    try {
      // 让位：启动校验 / 进入点播的闸门还在读目录时，不许并发写盘。
      await waitForIdle();
      final settings = await readSettings();
      if (!settings.hasAddress) {
        return const VodIndexUpdateOutcome(
          status: VodIndexUpdateStatus.skipped,
          message: '尚未设定第三方片源接口，不自动更新',
        );
      }
      final last = await readLastUpdateAt();
      // 周期读**设置里的当前档位**，不读构造参数：用户在设置页改完
      // 档位后，下一次 tick 就按新档位判断，不必重启定时器。
      if (!force && !shouldUpdate(last, now(), settings.interval)) {
        return VodIndexUpdateOutcome(
          status: VodIndexUpdateStatus.skipped,
          message: '距上次更新不足${settings.cadence.label}',
        );
      }
      final items = await fetchLatest(settings);
      if (items.isEmpty) {
        // 取数失败（空列表）不写时间戳：下次定时器还会再试，不会把
        // 「接口临时抽风」记成「今天已经更新过了」。
        return const VodIndexUpdateOutcome(
          status: VodIndexUpdateStatus.failed,
          message: '接口这次没有返回片源，保留原目录，稍后会自动重试',
        );
      }
      final result = await append(settings.url, items);
      if (!result.ok) {
        return VodIndexUpdateOutcome(
          status: VodIndexUpdateStatus.failed,
          message: result.message.isEmpty ? '写入片源索引目录失败' : result.message,
        );
      }
      await writeLastUpdateAt(now().toUtc());
      return VodIndexUpdateOutcome(
        status: result.added > 0
            ? VodIndexUpdateStatus.updated
            : VodIndexUpdateStatus.unchanged,
        message: result.added > 0
            ? '已追加 ${result.added} 条新片源（重复 ${result.duplicates} 条已跳过），'
                '本地目录共 ${result.total} 条；下次进入点播生效'
            : '片源已是最新（重复 ${result.duplicates} 条已跳过），'
                '本地目录共 ${result.total} 条',
        added: result.added,
        duplicates: result.duplicates,
        total: result.total,
      );
    } catch (e) {
      return VodIndexUpdateOutcome(
        status: VodIndexUpdateStatus.failed,
        message: '片源更新失败：$e',
      );
    } finally {
      _running = false;
    }
  }

  /// 启动定时更新：首帧后先补一次，之后每 [kVodIndexUpdateTick] 问一次
  /// 「按当前档位到点了吗」。
  ///
  /// 用固定短 tick 而不是把档位当周期：档位在设置页可改，改完要立刻生效。
  /// 返回 Timer 只为方便测试 / 退出时取消；应用生命周期内不取消。
  Timer start({bool runImmediately = true}) {
    _timer?.cancel();
    if (runImmediately) unawaited(runOnce());
    return _timer =
        Timer.periodic(kVodIndexUpdateTick, (_) => unawaited(runOnce()));
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }
}

/// 增量取数的真实实现：只拿**每个站的最新一页**。
///
/// 苹果 CMS 的 `?ac=detail&pg=1` 按更新时间倒序，第一页就是最新片源；
/// 这里用 [VodSourcePager.next] 轮转若干批把「所有站的第 1 页」覆盖到，
/// 但绝不翻第 2 页 —— 全量目录是几万页，重取一遍既慢又会把磁盘写爆。
/// 对契约 JSON（没有分页）则直接用它一次给全的条目。
///
/// 全程不碰 `VodLibrary` / `VodSession`，因此不会改播放列表、不会换源、
/// 不会触发闸门的 `clearExternal` 一类副作用。
Future<List<VodItem>> fetchLatestVodIndexItems(
  ThirdPartyVodService service,
  VodIndexUpdateSettings settings, {
  Duration budget = kVodIndexUpdateBudget,
}) async {
  final start = await service.open(
    url: settings.url,
    allowInsecureHttp: settings.allowInsecureHttp,
    allowExternalCode: settings.allowExternalCode,
    maxSites: kMaxThirdPartySites,
    sitesPerBatch: kVodSitesPerBatch,
  );
  if (!start.ok) {
    throw StateError(start.message.isEmpty ? '接口无法识别' : start.message);
  }
  final pager = start.pager;
  if (pager == null) {
    return List<VodItem>.of(start.contractItems);
  }
  final out = <VodItem>[];
  final seen = <String>{};
  final watch = Stopwatch()..start();
  final rawRounds = (pager.siteCount / kVodSitesPerBatch).ceil();
  final rounds = rawRounds < 1
      ? 1
      : (rawRounds > kMaxVodUpdateRounds ? kMaxVodUpdateRounds : rawRounds);
  for (var i = 0; i < rounds && !pager.done; i++) {
    if (watch.elapsed >= budget) break;
    final batch = await pager.next();
    for (final item in batch.items) {
      if (item.id.isEmpty || !seen.add(item.id)) continue;
      out.add(item);
    }
  }
  return out;
}
