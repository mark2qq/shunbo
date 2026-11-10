/// 外部源配置 → 可运行的多源适配器（E9 安全白名单的**真正消费方**）。
///
/// 此前 E9 白名单已经校验 `headers` / `searchPath` / `playPath` / `platforms` /
/// `episodeOffset` 等字段，但没有任何代码去消费它们：配置导入后仍然只能手工
/// 构造 `MockFetcher`。本加载器把「一份配置 = N 个真实源」打通：
///
///   配置 JSON → 逐条 E9 校验（坏条隔离，不拖垮其余源） → `SiteRule` 静态校验
///   → `SourceProfile` / 平台裁剪 / 请求头 / 路径模板 → `ParsedSourceAdapter`
///   → 注册进 `SourceRegistry` + `SourceCatalog`，供编排层与自动换源直接使用。
///
/// 层次：本文件位于 data/onboarding，向下依赖 core/source 与 core/scheduler，
/// 不产生 core → data 的反向依赖。
import 'dart:convert';

import '../../core/scheduler/source_catalog.dart';
import '../../core/source/dart_backend.dart';
import '../../core/source/parsed_source_adapter.dart';
import '../../core/source/rule_source_parser.dart';
import '../../core/source/site_rule.dart';
import '../../core/source/source_adapter.dart';
import '../../core/source/source_profile.dart';
import '../../core/source/source_registry.dart';
import 'source_config_validator.dart';

/// 单次导入允许的最大源数量（防配置放大内存与启动耗时）。
const int kMaxSources = 50;

const Set<String> _dartParsers = <String>{'dart', 'regex', 'json'};

/// 禁止由外部配置覆盖的请求头：改动这些会改变连接语义 / 造成请求走私或凭据外泄。
const Set<String> _forbiddenHeaders = <String>{
  'host',
  'content-length',
  'transfer-encoding',
  'connection',
  'proxy-authorization',
  'proxy-connection',
  'upgrade',
};

final RegExp _headerName = RegExp(r'^[A-Za-z0-9-]{1,64}$');
final RegExp _safeId = RegExp(r'^[A-Za-z0-9_-]{1,64}$');

/// 一个通过校验的源定义（仍是不可执行的纯数据）。
class SourceDefinition {
  final String id;
  final String name;
  final SourceProfile profile;
  final String baseUrl;
  final SiteRule rule;
  final Map<String, String> headers;
  final Set<SourcePlatform> platforms;
  final Set<String> allowedOrigins;
  final int qualityRank;
  final String searchPath;
  final String detailPath;

  const SourceDefinition({
    required this.id,
    required this.name,
    required this.profile,
    required this.baseUrl,
    required this.rule,
    required this.headers,
    required this.platforms,
    required this.allowedOrigins,
    required this.qualityRank,
    required this.searchPath,
    required this.detailPath,
  });
}

/// 被拒绝的单条配置（含索引与可读原因，供 UI 展示 / 诊断上报）。
class ConfigRejection {
  final int index;
  final String id;
  final List<String> reasons;

  const ConfigRejection(this.index, this.id, this.reasons);

  @override
  String toString() => '源[$index]${id.isEmpty ? '' : ' $id'}：${reasons.join('；')}';
}

/// 加载结果：已接受的源 + 被拒绝的记录 + 可直接注册的适配器。
class LoadedSourceConfig {
  final List<SourceDefinition> sources;
  final List<ConfigRejection> rejections;

  /// **净化后的配置**：仅含通过校验且未被禁用的源，用于持久化与流程推进。
  ///
  /// 关键：导入时坏条被隔离，若不净化就把原文落盘，重启后会反复导入同一批
  /// 危险字段；若把原文交给 `OnboardingFlow.importSourceConfig`（全量校验），
  /// 多源容器里只要有一条坏就会整体失败，出现「源已注册但引导卡在导入步」的
  /// 状态撕裂。持久化/推进统一只用这份净化配置，二者必然一致。
  /// 无可用源时为 null。
  final Object? validatedConfig;

  /// 构造时即生成（只创建对象、不发请求），复用同一批实例避免连接池泄漏。
  final List<ParsedSourceAdapter> adapters;
  final List<DartHttpFetcher> _fetchers;

  LoadedSourceConfig._(
    this.sources,
    this.rejections,
    this.validatedConfig,
    this.adapters,
    this._fetchers,
  );

  int get accepted => sources.length;
  int get rejected => rejections.length;
  bool get hasSources => adapters.isNotEmpty;

  /// 注册到业务能力层：换源决策权威仍只认 [SourceCatalog] 里的画像。
  void registerInto(SourceRegistry registry, SourceCatalog catalog) {
    for (final a in adapters) {
      registry.register(a);
      catalog.register(a.profile);
    }
  }

  /// 源退役 / 应用退出时释放连接池（失败连接残留会挂住 Dart 进程）。
  void close() {
    for (final f in _fetchers) {
      f.close();
    }
  }
}

LoadedSourceConfig _empty(List<ConfigRejection> rejections) =>
    LoadedSourceConfig._(
      const <SourceDefinition>[],
      rejections,
      null,
      const <ParsedSourceAdapter>[],
      const <DartHttpFetcher>[],
    );

double _asDouble(Object? v, double fallback) =>
    v is num ? v.toDouble() : fallback;

int _asInt(Object? v, int fallback) => v is num ? v.toInt() : fallback;

/// 从配置对象加载。支持两种根形态：
/// - 多源容器 `{"sources": [单源配置, ...]}`
/// - 单源配置（向后兼容 E9 既有格式）
///
/// 逐条校验、逐条隔离：某个源坏掉或带危险字段，不影响其余源正常加载。
///
/// [reservedIds] 是「已被占用且不允许覆盖」的源 id（通常是内置源）。
/// 注册表 `register` 是覆盖语义，外部配置若故意用同名 id，会悄悄顶掉内置
/// 适配器与 `SourceCatalog` 画像 —— 等于让外部配置篡改换源决策基准。
/// 因此命中即拒绝该条。重复导入时调用方需先从该集合中剔除自己上次注册的 id。
LoadedSourceConfig loadSourceConfig(
  Object? raw, {
  bool allowUnsafeBackends = false,
  Set<String> reservedIds = const <String>{},
}) {
  if (raw is! Map) {
    return _empty(<ConfigRejection>[
      const ConfigRejection(0, '', <String>['根节点必须是对象'])
    ]);
  }
  final root = Map<String, dynamic>.from(raw);
  final entries = root['sources'] is List
      ? List<Object?>.from(root['sources'] as List)
      : <Object?>[root];

  final rejections = <ConfigRejection>[];
  if (entries.length > kMaxSources) {
    rejections.add(ConfigRejection(-1, '', <String>[
      '源数量 ${entries.length} 超过上限 $kMaxSources，仅加载前 $kMaxSources 个'
    ]));
  }
  final limit = entries.length > kMaxSources ? kMaxSources : entries.length;
  final defs = <SourceDefinition>[];
  final acceptedEntries = <Object?>[];
  final seen = <String>{};

  for (var i = 0; i < limit; i++) {
    final entry = entries[i];
    final m = entry is Map
        ? Map<String, dynamic>.from(entry)
        : <String, dynamic>{};
    final id = (m['id'] ?? '').toString();
    final reasons = <String>[
      ...validateSourceConfig(
        entry,
        allowUnsafeBackends: allowUnsafeBackends,
      ).reasons,
    ];
    if (entry is! Map) reasons.add('源配置必须是对象');

    if (!_safeId.hasMatch(id)) {
      reasons.add('id 非法（只允许字母数字下划线/短横线，1..64 位）');
    }
    if (id.isNotEmpty && !seen.add(id)) reasons.add('id 重复：$id');
    if (reservedIds.contains(id)) {
      reasons.add('id 与已注册源冲突：$id（禁止外部配置覆盖内置源画像）');
    }

    final baseUrl = (m['baseUrl'] ?? '').toString();
    final parser = (m['parser'] ?? 'regex').toString();
    if (!_dartParsers.contains(parser)) {
      reasons.add('parser=$parser 不是 Dart 后端（jar/QuickJS 需原生实现，本加载器不构造）');
    }

    SiteRule? rule;
    final rulesRaw = m['rules'];
    if (rulesRaw is! Map) {
      reasons.add('缺少 rules：Dart 后端必须携带纯数据站点规则');
    } else {
      // 强制用配置 baseUrl 覆盖规则自带地址，杜绝「规则内指向另一个站点」。
      final merged = <String, dynamic>{
        ...Map<String, dynamic>.from(rulesRaw),
        'baseUrl': baseUrl,
        'id': id,
      };
      rule = SiteRule.fromJson(merged);
      for (final r in validateSiteRule(rule).reasons) {
        reasons.add('rules: $r');
      }
      final ruleHost = Uri.tryParse((rulesRaw['baseUrl'] ?? '').toString())?.host;
      final cfgHost = Uri.tryParse(baseUrl)?.host;
      if (ruleHost != null &&
          ruleHost.isNotEmpty &&
          cfgHost != null &&
          ruleHost != cfgHost) {
        reasons.add('rules.baseUrl 与 baseUrl 主机不一致（防配置注入外部站点）');
      }
    }

    final headers = <String, String>{};
    final h = m['headers'];
    if (h != null && h is! Map) {
      reasons.add('headers 必须是对象');
    } else if (h is Map) {
      h.forEach((k, v) {
        if (k is! String || v is! String) {
          reasons.add('headers 必须是「字符串 → 字符串」映射');
          return;
        }
        if (!_headerName.hasMatch(k)) {
          reasons.add('请求头名非法：$k');
        } else if (_forbiddenHeaders.contains(k.toLowerCase())) {
          reasons.add('禁止由配置覆盖请求头：$k');
        } else if (v.contains('\r') || v.contains('\n')) {
          reasons.add('请求头值含换行（注入风险）：$k');
        } else {
          headers[k] = v;
        }
      });
    }

    final platforms = <SourcePlatform>{};
    final p = m['platforms'];
    if (p != null && p is! List) {
      reasons.add('platforms 必须是数组');
    } else if (p is List) {
      for (final x in p) {
        final matched = SourcePlatform.values.where((e) => e.name == x.toString());
        if (matched.isEmpty) {
          reasons.add('未知平台：$x');
        } else {
          platforms.add(matched.first);
        }
      }
    }
    if (platforms.isEmpty) {
      platforms.addAll(const <SourcePlatform>{
        SourcePlatform.desktop,
        SourcePlatform.tv,
      });
    }

    // qualityRank / allowedOrigins 已由 validateSourceConfig 逐条校验，
    // 这里只做取值（被拒绝的条目不会走到 defs.add）。
    final qualityRank = _asInt(m['qualityRank'], 0);
    final allowedOrigins =
        normalizeAllowedOrigins(m['allowedOrigins'], baseUrl: baseUrl).origins;

    // E9 的 playPath 在这里作为「详情页路径模板」消费（取播放页地址来自站点响应本身）。
    final searchPath = (m['searchPath'] ?? 'search?q={keyword}').toString();
    final detailPath = (m['playPath'] ?? 'detail/{mediaId}').toString();
    for (final t in <(String, String, String)>[
      ('searchPath', searchPath, '{keyword}'),
      ('playPath', detailPath, '{mediaId}'),
    ]) {
      if (!t.$2.contains(t.$3)) reasons.add('${t.$1} 缺少占位符 ${t.$3}');
      if (t.$2.contains('://')) {
        reasons.add('${t.$1} 不允许绝对地址（由 baseUrl + origin 白名单决定）');
      }
      if (t.$2.contains('\r') || t.$2.contains('\n')) {
        reasons.add('${t.$1} 含换行');
      }
    }

    if (reasons.isNotEmpty) {
      rejections.add(ConfigRejection(i, id, List<String>.unmodifiable(reasons)));
      continue;
    }
    if (m['enabled'] == false) continue; // 显式禁用：不算拒绝

    defs.add(SourceDefinition(
      id: id,
      name: (m['name'] ?? id).toString(),
      profile: SourceProfile(
        name: id,
        episodeOffset: _asInt(m['episodeOffset'], 0),
        adInterval: _asDouble(m['adInterval'], 0),
        adDuration: _asDouble(m['adDuration'], 0),
      ),
      baseUrl: baseUrl,
      rule: rule!,
      headers: Map<String, String>.unmodifiable(headers),
      platforms: Set<SourcePlatform>.unmodifiable(platforms),
      allowedOrigins: Set<String>.unmodifiable(allowedOrigins),
      qualityRank: qualityRank,
      searchPath: searchPath,
      detailPath: detailPath,
    ));
    acceptedEntries.add(entry);
  }

  final adapters = <ParsedSourceAdapter>[];
  final fetchers = <DartHttpFetcher>[];
  for (final d in defs) {
    // 本机/局域网源固定直连：系统代理常把 loopback 请求改写成 502，
    // 且与「源站返回什么」的判定无关（真实联网回归里实测过）。
    final host = Uri.tryParse(d.baseUrl)?.host.toLowerCase();
    final loopback = host == '127.0.0.1' || host == 'localhost' || host == '::1';
    final fetcher = DartHttpFetcher(
      d.baseUrl,
      headers: d.headers,
      searchPath: d.searchPath,
      detailPath: d.detailPath,
      // 默认只放行 baseUrl 自身；只有配置显式声明 allowedOrigins 才扩权。
      allowedOrigins: <String>{
        Uri.parse(d.baseUrl).origin,
        ...d.allowedOrigins,
      },
      useSystemProxy: !loopback,
    );
    fetchers.add(fetcher);
    adapters.add(ParsedSourceAdapter(
      id: d.id,
      profile: d.profile,
      parser: RuleSourceParser(d.rule),
      fetcher: fetcher,
      supportedPlatforms: d.platforms,
      qualityRank: d.qualityRank,
      // 取数与播放用同一份请求头：源站校验 Referer 时，少一份就播不了。
      playbackHeaders: d.headers,
    ));
  }
  // 统一重建为多源容器：只包含真正被接受的条目，且必然能通过 E9 全量校验。
  Object? validated;
  if (acceptedEntries.isNotEmpty) {
    validated = <String, dynamic>{
      if (root['name'] is String) 'name': root['name'],
      'version': 1,
      'sources': acceptedEntries,
    };
  }
  return LoadedSourceConfig._(
      defs, rejections, validated, adapters, fetchers);
}

/// 从 JSON 文本加载；坏 JSON 降级为「零可用源 + 一条拒绝记录」，不抛异常。
LoadedSourceConfig loadSourceConfigFromJson(
  String text, {
  bool allowUnsafeBackends = false,
  Set<String> reservedIds = const <String>{},
}) {
  try {
    return loadSourceConfig(jsonDecode(text),
        allowUnsafeBackends: allowUnsafeBackends, reservedIds: reservedIds);
  } catch (e) {
    return _empty(<ConfigRejection>[
      ConfigRejection(0, '', <String>['JSON 解析失败：$e'])
    ]);
  }
}
