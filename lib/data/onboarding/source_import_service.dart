// 源配置导入的**编排层**（E9 引导 UI 与 E2 多源加载器之间的唯一桥梁）。
//
// 此前 `loadSourceConfig` 只被回归脚本调用，App 的引导卡片写死「使用内置源」，
// 用户手里的 App 根本无法导入源配置。本服务把导入做成可验证的纯逻辑：
//
//   文本 → 安全门禁（免责声明 / 步骤 / 长度） → JSON 解析
//       → 逐条隔离加载（含与内置源的 id 冲突检测）
//       → 零可用源即失败（不注册、不落盘、不推进引导，杜绝假成功）
//       → 注销上一批源并释放连接池 → 注册新源
//       → 持久化"净化后"的配置（坏条不会在重启时复活）
//       → 推进引导状态
//
// 不依赖 package:flutter；文件读取经 [SourceConfigFileLoader] 注入（默认实现用
// dart:io），因此整条编排仍可在裸 `dart run` 下完整验证。
import 'dart:convert';

import '../../core/scheduler/source_catalog.dart';
import '../../core/source/source_registry.dart';
import 'onboarding_flow.dart';
import 'source_config_file.dart';
import 'source_config_loader.dart';
import 'source_config_url.dart';
import 'source_config_validator.dart';
import 'source_trust.dart';

/// 单次导入允许的最大文本长度（防粘贴超长文本放大内存）。
const int kMaxImportTextLength = 256 * 1024;

/// 持久化结构版本；不兼容时按损坏处理，不猜测字段语义。
const int kSourceConfigStateVersion = 1;

/// 读回已保存的净化配置文本；无记录返回 null。
typedef SourceConfigReader = Future<String?> Function();

/// 写入净化配置文本。实现应自行保证原子写与失败降级。
typedef SourceConfigWriter = Future<void> Function(String text);

/// 读取本地配置文件。注入以便回归统计 IO 次数、模拟读取异常；
/// 缺省使用 [readSourceConfigFile]（唯一带 dart:io 的实现）。
typedef SourceConfigFileLoader = Future<SourceConfigFileResult> Function(
    String path);

/// 写出当前生效配置（备份 / 迁移）。注入以便回归模拟写入异常；
/// 缺省使用 [writeSourceConfigFile]。
typedef SourceConfigFileWriter = Future<SourceConfigFileWriteResult> Function(
  String path,
  String text, {
  bool overwrite,
});

/// 从 URL 下载配置文本。注入以便回归统计「是否真的发起了请求」/ 模拟各类网络故障；
/// 缺省使用 [fetchSourceConfigUrl]。
typedef SourceConfigUrlLoader = Future<SourceConfigUrlResult> Function(
    String url);

enum ImportOutcomeKind {
  /// 用户导入成功并已注册。
  applied,

  /// 启动时从磁盘恢复成功。
  restored,

  /// 导入/恢复未产生任何可用源。
  rejected,

  /// 来源未通过信任判定，或用户取消了首次使用 / 内容变更确认。
  /// 与 [rejected] 分开是为了 UI 能给出「去确认来源」而不是「配置写错了」。
  untrustedSource,

  /// 磁盘有配置，但用户未接受免责声明，按安全约束拒绝加载。
  blockedByDisclaimer,

  /// 无已保存配置（不是错误）。
  nothingToRestore,
}

/// 导入结果：UI 直接展示，不需要再解释内部状态。
class ImportOutcome {
  final ImportOutcomeKind kind;
  final int accepted;
  final List<ConfigRejection> rejections;
  final List<String> sourceIds;

  /// 配置是否真的写入了持久层；false 时源仍可用，但重启会丢失。
  final bool persisted;
  final String message;

  /// 配置来源（仅文件名，不回显完整本机路径）；粘贴导入时为 null。
  final String? originLabel;

  const ImportOutcome({
    required this.kind,
    required this.message,
    this.accepted = 0,
    this.rejections = const <ConfigRejection>[],
    this.sourceIds = const <String>[],
    this.persisted = false,
    this.originLabel,
  });

  /// 是否产生了可用源（applied / restored）。
  bool get ok =>
      kind == ImportOutcomeKind.applied || kind == ImportOutcomeKind.restored;

  ImportOutcome copyWith({
    ImportOutcomeKind? kind,
    String? message,
    int? accepted,
    List<ConfigRejection>? rejections,
    List<String>? sourceIds,
    bool? persisted,
    String? originLabel,
  }) =>
      ImportOutcome(
        kind: kind ?? this.kind,
        message: message ?? this.message,
        accepted: accepted ?? this.accepted,
        rejections: rejections ?? this.rejections,
        sourceIds: sourceIds ?? this.sourceIds,
        persisted: persisted ?? this.persisted,
        originLabel: originLabel ?? this.originLabel,
      );
}

/// 把引导流程、注册表、持久层粘合起来的导入服务。
///
/// 一个服务实例对应一份「当前生效的外部源配置」；重复导入会先注销上一批，
/// 不会留下孤儿源或未关闭的 HttpClient 连接池。
class SourceImportService {
  final SourceRegistry registry;
  final SourceCatalog catalog;
  final OnboardingFlow flow;
  final SourceConfigReader readSaved;
  final SourceConfigWriter writeSaved;

  /// 可注入的文件读取器；null 时使用默认实现。测试用它统计 IO / 模拟异常。
  final SourceConfigFileLoader? readFile;

  /// 可注入的文件写入器；null 时使用默认实现。
  final SourceConfigFileWriter? writeFile;

  /// 可注入的 URL 下载器；null 时使用默认实现（唯一网络 IO 边界）。
  final SourceConfigUrlLoader? readUrl;

  /// 来源信任策略。null 时行为与接入前逐字节一致（老回归不改一行也能过）。
  /// App 装配时注入，回归可直接注入假 persist 验证整条链路。
  final SourceTrustPolicy? trust;

  /// 需要用户确认「首次使用 / 内容已变化」时调用。null 等同用户拒绝，
  /// 绝不静默放行——这是「下载成功 ≠ 内容可信」的落点。
  final Future<bool> Function(String reason)? confirmTrust;

  LoadedSourceConfig? _active;
  List<String> _activeIds = <String>[];
  String? _currentConfigText;
  ImportOutcome? _lastOutcome;

  SourceImportService({
    required this.registry,
    required this.catalog,
    required this.flow,
    required this.readSaved,
    required this.writeSaved,
    this.readFile,
    this.writeFile,
    this.readUrl,
    this.trust,
    this.confirmTrust,
  });

  /// 当前生效的外部源 id（重启恢复后同样有值）。
  List<String> get activeSourceIds => List<String>.unmodifiable(_activeIds);

  /// 当前生效的净化配置文本，供 UI 重新打开导入框时回填编辑。
  String? get currentConfigText => _currentConfigText;

  ImportOutcome? get lastOutcome => _lastOutcome;

  bool get hasImportedSources => _activeIds.isNotEmpty;

  ImportOutcome _finish(ImportOutcome o) {
    _lastOutcome = o;
    return o;
  }

  /// 注销上一批源并释放连接池。注册表是覆盖语义，不注销会让重复导入
  /// 留下「旧 id 指向旧站点」的孤儿，且失败连接会挂住 Dart 进程。
  void _release() {
    for (final id in _activeIds) {
      registry.unregister(id);
      catalog.unregister(id);
    }
    _active?.close();
    _active = null;
    _activeIds = <String>[];
  }

  void _apply(LoadedSourceConfig loaded) {
    _release();
    loaded.registerInto(registry, catalog);
    _active = loaded;
    _activeIds = loaded.adapters.map((a) => a.id).toList();
  }

  /// 计算不允许被外部配置覆盖的 id：所有已注册源，减去本服务上次注册的
  /// （那些正是这次要被替换的）。
  Set<String> _reservedIds() =>
      registry.ids.toSet()..removeAll(_activeIds);

  /// 用户导入（引导中或引导完成后均可）。
  ///
  /// 安全不变量：**未接受免责声明一律拒绝**，包括「跳过引导」的用户；
  /// `jar` / `quickjs` 后端不提供授权开关，Dart 侧永不构造代码执行面。
  Future<ImportOutcome> importFromText(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      return _finish(const ImportOutcome(
        kind: ImportOutcomeKind.rejected,
        message: '导入失败：配置内容为空',
      ));
    }
    if (text.length > kMaxImportTextLength) {
      return _finish(ImportOutcome(
        kind: ImportOutcomeKind.rejected,
        message: '导入失败：配置超过 ${kMaxImportTextLength ~/ 1024} KB 上限',
      ));
    }
    if (!flow.state.disclaimerAccepted) {
      return _finish(const ImportOutcome(
        kind: ImportOutcomeKind.blockedByDisclaimer,
        message: '请先阅读并接受风险声明，才能导入外部源配置',
      ));
    }
    // welcome 步骤绝对禁止；其余步骤（sourceImport / platformConfirm / done）
    // 均已完成免责声明，允许导入或重新导入。
    if (flow.state.step == OnboardingStep.welcome) {
      return _finish(const ImportOutcome(
        kind: ImportOutcomeKind.rejected,
        message: '导入失败：请先完成引导的免责声明步骤',
      ));
    }

    Object? decoded;
    try {
      decoded = jsonDecode(trimmed);
    } catch (e) {
      return _finish(ImportOutcome(
        kind: ImportOutcomeKind.rejected,
        message: '导入失败：JSON 解析错误（$e）',
      ));
    }

    final loaded = loadSourceConfig(decoded, reservedIds: _reservedIds());
    final prepared = _prepare(loaded, '导入');
    if (prepared != null) return _finish(prepared);

    // 前置全量校验：净化配置必然能通过 OnboardingFlow 的严格校验，
    // 若这里失败就在注册/落盘/推进之前停下，避免出现状态撕裂。
    final verified = loaded.validatedConfig!;
    final precheck = validateSourceConfig(verified);
    if (!precheck.ok) {
      loaded.close();
      return _finish(ImportOutcome(
        kind: ImportOutcomeKind.rejected,
        message: '导入失败：净化配置未通过安全复检（${precheck.reasons.join('；')}）',
        rejections: loaded.rejections,
      ));
    }

    _apply(loaded);
    final purified = jsonEncode(verified);
    var persisted = false;
    try {
      await writeSaved(purified);
      persisted = true;
    } catch (_) {
      // 写失败不回滚已生效的源，但必须如实告知「重启会丢失」。
    }
    _currentConfigText = purified;

    if (flow.state.step == OnboardingStep.sourceImport) {
      await flow.importSourceConfig(verified);
    } else {
      await flow.recordReimport();
    }

    final ids = List<String>.of(_activeIds);
    return _finish(ImportOutcome(
      kind: ImportOutcomeKind.applied,
      accepted: loaded.accepted,
      rejections: loaded.rejections,
      sourceIds: ids,
      persisted: persisted,
      message: _appliedMessage(
        loaded.accepted,
        loaded.rejected,
        persisted,
      ),
    ));
  }

  /// 从本机文件导入。与粘贴导入共用**完全相同**的净化 / 注册 / 落盘链路，
  /// 区别只在最前面多一层文件 IO。
  ///
  /// 两个刻意的安全顺序：
  /// 1. **免责声明门禁在读文件之前**——未接受声明时连一次 IO 都不做，
  ///    避免「只是选择了个文件」就触发任意路径读取；
  /// 2. 文件读取失败只返回结果，绝不触碰 `_release()`，因此上一次已生效
  ///    的源不会被一次失败的文件选择清空。
  Future<ImportOutcome> importFromFile(String rawPath) async {
    if (rawPath.trim().isEmpty) {
      return _finish(const ImportOutcome(
        kind: ImportOutcomeKind.rejected,
        message: '文件导入失败：请先填写配置文件路径',
      ));
    }
    if (!flow.state.disclaimerAccepted) {
      return _finish(const ImportOutcome(
        kind: ImportOutcomeKind.blockedByDisclaimer,
        message: '请先阅读并接受风险声明，才能从文件导入源配置',
      ));
    }
    if (flow.state.step == OnboardingStep.welcome) {
      return _finish(const ImportOutcome(
        kind: ImportOutcomeKind.rejected,
        message: '导入失败：请先完成引导的免责声明步骤',
      ));
    }

    final loader = readFile ?? readSourceConfigFile;
    SourceConfigFileResult file;
    try {
      file = await loader(normalizeSourceConfigPath(rawPath));
    } catch (e) {
      return _finish(ImportOutcome(
        kind: ImportOutcomeKind.rejected,
        message: '文件导入失败：读取时发生异常（$e）',
      ));
    }
    if (!file.ok) {
      return _finish(ImportOutcome(
        kind: ImportOutcomeKind.rejected,
        message: '文件导入失败：${file.message}',
        rejections: const <ConfigRejection>[],
        originLabel: file.fileName,
      ));
    }

    final outcome = await importFromText(file.text!);
    return _finish(outcome.copyWith(originLabel: file.fileName));
  }

  /// 从 URL 导入（「把朋友发来的配置链接直接粘进来」）。
  ///
  /// 与文件导入完全相同的三条安全顺序，只是第一层从「文件 IO」换成「网络 IO」：
  /// 1. **免责声明门禁在最前面**——未接受声明时连一次请求都不发，
  ///    避免「贴了个链接」就替用户向任意地址发起访问（也避免把内网探测当作导入副作用）；
  /// 2. 下载失败只返回结果，绝不触碰 `_release()`，上一次已生效的源不受影响；
  /// 3. 下载到的文本走**同一条**净化链路（白名单 / 冲突检测 / 零可用源回退）。
  ///
  /// 需要强调的一点：URL 导入**不构成任何信任背书**。能下载只说明网络通，
  /// 不说明内容是安全的——真正的门槛仍在 E9 白名单。
  Future<ImportOutcome> importFromUrl(String rawUrl) async {
    if (rawUrl.trim().isEmpty) {
      return _finish(const ImportOutcome(
        kind: ImportOutcomeKind.rejected,
        message: '链接导入失败：请先填写配置链接',
      ));
    }
    if (!flow.state.disclaimerAccepted) {
      return _finish(const ImportOutcome(
        kind: ImportOutcomeKind.blockedByDisclaimer,
        message: '请先阅读并接受风险声明，才能从链接导入源配置',
      ));
    }
    if (flow.state.step == OnboardingStep.welcome) {
      return _finish(const ImportOutcome(
        kind: ImportOutcomeKind.rejected,
        message: '导入失败：请先完成引导的免责声明步骤',
      ));
    }

    final loader = readUrl ?? fetchSourceConfigUrl;
    SourceConfigUrlResult fetched;
    try {
      fetched = await loader(rawUrl.trim());
    } catch (e) {
      return _finish(ImportOutcome(
        kind: ImportOutcomeKind.rejected,
        message: '链接导入失败：下载时发生异常（$e）',
      ));
    }
    if (!fetched.ok) {
      return _finish(ImportOutcome(
        kind: ImportOutcomeKind.rejected,
        message: '链接导入失败：${fetched.message}',
        originLabel: fetched.originLabel,
      ));
    }

    // 传输层净化已经保证「这段文本来自用户填的主机」，这里补的是内容层：
    // 首次使用必须确认、摘要变化必须重新确认、带签名的来源不许无签名降级。
    var trustNote = '';
    final policy = trust;
    if (policy != null) {
      final decision = await policy.check(
        url: rawUrl.trim(),
        text: fetched.text!,
        headers: fetched.headers,
      );
      if (decision.rejected) {
        return _finish(ImportOutcome(
          kind: ImportOutcomeKind.untrustedSource,
          message: '链接导入失败：${decision.reason}',
          originLabel: fetched.originLabel,
        ));
      }
      if (decision.needsApproval) {
        final confirm = confirmTrust;
        final agreed = confirm == null ? false : await confirm(decision.reason);
        if (!agreed) {
          return _finish(const ImportOutcome(
            kind: ImportOutcomeKind.untrustedSource,
            message: '已取消导入：来源未获确认（首次使用或内容变化需人工确认）',
            originLabel: null,
          ));
        }
        final applied = await policy.approve(
          url: rawUrl.trim(),
          text: fetched.text!,
          headers: fetched.headers,
        );
        if (applied.rejected) {
          return _finish(ImportOutcome(
            kind: ImportOutcomeKind.untrustedSource,
            message: '链接导入失败：${applied.reason}',
            originLabel: fetched.originLabel,
          ));
        }
        if (!applied.persisted) {
          trustNote = '（注意：信任记录未能落盘，重启后需重新确认来源）';
        }
      }
    }

    final outcome = await importFromText(fetched.text!);
    final merged = outcome.copyWith(originLabel: fetched.originLabel);
    return _finish(trustNote.isEmpty
        ? merged
        : merged.copyWith(message: '${merged.message} $trustNote'));
  }

  /// 把**当前生效的净化配置**导出到本机文件（备份 / 换机迁移）。
  /// 只导出 `_currentConfigText`（导入或恢复时落定的净化配置），不导出 UI 编辑框
  /// 里的草稿 —— 否则用户可能把一段尚未通过校验的文本写进「备份」，恢复时才发现
  /// 它是坏的。没有生效配置时直接返回 `noContent`，不产生空文件。
  Future<SourceConfigFileWriteResult> exportToFile(
    String path, {
    bool overwrite = false,
  }) async {
    final text = _currentConfigText;
    if (text == null || text.trim().isEmpty) {
      return SourceConfigFileWriteResult.fail(
        SourceConfigFileWriteFailure.noContent,
        '当前没有可导出的源配置（请先导入或恢复一个源）',
      );
    }
    final writer = writeFile ?? writeSourceConfigFile;
    try {
      return await writer(normalizeSourceConfigPath(path), text,
          overwrite: overwrite);
    } catch (e) {
      return SourceConfigFileWriteResult.fail(
        SourceConfigFileWriteFailure.writeError,
        '导出失败：写入时发生异常（$e）',
      );
    }
  }

  /// 启动时恢复上次导入。不推进引导、不回写磁盘。
  ///
  /// 磁盘可能被手工篡改，因此与用户导入走**完全相同**的校验与冲突检测；
  /// 未接受免责声明时不加载（保留文本，不静默删除用户数据）。
  Future<ImportOutcome> restore() async {
    String? saved;
    try {
      saved = await readSaved();
    } catch (_) {
      saved = null;
    }
    if (saved == null || saved.trim().isEmpty) {
      return _finish(const ImportOutcome(
        kind: ImportOutcomeKind.nothingToRestore,
        message: '无已保存的源配置',
      ));
    }
    if (!flow.state.disclaimerAccepted) {
      return _finish(const ImportOutcome(
        kind: ImportOutcomeKind.blockedByDisclaimer,
        message: '检测到已保存的源配置，但未接受风险声明，本次启动不予加载',
      ));
    }
    if (saved.length > kMaxImportTextLength) {
      return _finish(const ImportOutcome(
        kind: ImportOutcomeKind.rejected,
        message: '恢复失败：已保存配置超过长度上限，需重新导入',
      ));
    }

    Object? decoded;
    try {
      decoded = jsonDecode(saved);
    } catch (_) {
      return _finish(const ImportOutcome(
        kind: ImportOutcomeKind.rejected,
        message: '恢复失败：已保存配置损坏，需重新导入',
      ));
    }
    final loaded = loadSourceConfig(decoded, reservedIds: _reservedIds());
    final prepared = _prepare(loaded, '恢复');
    if (prepared != null) return _finish(prepared);

    _apply(loaded);
    _currentConfigText = saved;
    return _finish(ImportOutcome(
      kind: ImportOutcomeKind.restored,
      accepted: loaded.accepted,
      rejections: loaded.rejections,
      sourceIds: List<String>.of(_activeIds),
      persisted: true,
      message: loaded.rejected == 0
          ? '已恢复上次导入的 ${loaded.accepted} 个源'
          : '已恢复 ${loaded.accepted} 个源，另有 ${loaded.rejected} 条配置被拒绝',
    ));
  }

  /// 共用失败分支：零可用源时，不注册、不落盘、不推进引导。
  ImportOutcome? _prepare(LoadedSourceConfig loaded, String verb) {
    if (loaded.hasSources && loaded.validatedConfig != null) return null;
    loaded.close();
    final first = loaded.rejections.take(3).map((r) => r.toString()).join('；');
    return ImportOutcome(
      kind: ImportOutcomeKind.rejected,
      rejections: loaded.rejections,
      message: '$verb失败：没有任何可用源${first.isEmpty ? '' : '（$first）'}',
    );
  }

  String _appliedMessage(int accepted, int rejected, bool persisted) {
    final buf = StringBuffer('导入成功：$accepted 个源已生效');
    if (rejected > 0) buf.write('，$rejected 条配置被安全策略拒绝');
    buf.write(persisted ? '，已保存（重启后仍可用）' : '；但保存失败，重启后需重新导入');
    return buf.toString();
  }

  /// 应用退出 / 源全量退役时释放连接池。
  void close() => _release();
}
