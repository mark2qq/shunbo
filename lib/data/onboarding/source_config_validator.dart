/// 源配置导入的**安全白名单校验**（E9：闭合评估报告点名的「安全/隐私需求缺失」）。
///
/// 威胁模型：本应用允许导入外部「源配置」，而 Android 侧会加载 jar 爬虫 / 执行
/// QuickJS 脚本。若配置里能夹带类名、脚本地址、可执行路径，那么「导入一份配置」
/// 就等价于开放**任意代码执行面**。因此这里采用严格白名单：
/// - 顶层只允许纯数据字段；
/// - 任意层级禁止动态代码加载相关键；
/// - URL / scheme 白名单，拒绝 `javascript:` / `file:` / `data:`；
/// - 深度、条目数、字符串长度全部设上限，防止超深嵌套与内存放大；
/// - 外部配置**默认禁止 jar / QuickJS 后端**，要启用必须显式授权。
///
/// 这是纯函数，不依赖 Flutter，可在裸 `dart run` 下完整验证。
library;

import '../../core/source/site_rule.dart';

/// 校验结果。[ok] 为 true 时 [reasons] 为空。
class ConfigValidationResult {
  final List<String> reasons;

  const ConfigValidationResult(this.reasons);

  static const passed = ConfigValidationResult(<String>[]);

  bool get ok => reasons.isEmpty;

  @override
  String toString() =>
      ok ? '配置校验通过' : '配置校验失败：${reasons.join('；')}';
}

const Set<String> _allowedRootKeys = <String>{
  'id',
  'name',
  'version',
  'baseUrl',
  'parser',
  'searchPath',
  'playPath',
  'episodeOffset',
  'adInterval',
  'adDuration',
  'qualityRank',
  // 运行期允许取页面的额外源站 origin（真实站点的详情页/播放页常挂在 CDN 子域）。
  'allowedOrigins',
  'headers',
  'platforms',
  'enabled',
  // E2 站点规则（纯数据：正则/JSON 路径，不含代码）。导入时另做正则安全校验。
  'rules',
  // 多源配置容器：`{"sources": [单源配置, ...]}`。
  'sources',
};

const Set<String> _allowedContainerKeys = <String>{
  'sources',
  'name',
  'version',
};

/// 归一化后命中即拒绝：覆盖类名/jar/dex/脚本引擎/命令行等代码加载入口。
const Set<String> _forbiddenKeys = <String>{
  'script',
  'scripts',
  'javascript',
  'quickjs',
  'eval',
  'exec',
  'execute',
  'command',
  'cmd',
  'shell',
  'jar',
  'jarpath',
  'dex',
  'class',
  'classname',
  'classloader',
  'classpath',
  'so',
  'native',
  'libpath',
  'onload',
  'entrypoint',
  'plugin',
};

/// 单份配置允许声明的额外源站数量上限（默认拒绝，显式声明才扩权）。
const int kMaxAllowedOrigins = 8;
const int kMaxOriginLength = 256;

/// 校验并归一化 `allowedOrigins`：**按整个 origin 授权**，不接受通配符。
///
/// 威胁模型不是「限制配置作者」（他本来就能填任意 baseUrl），而是限制
/// **运行期站点响应**：详情页返回的绝对取址页 / 302 Location 只能落在
/// 事先声明的 origin 内，防止源站被劫持后把 App 导向任意主机（SSRF / 内网探测）。
/// 额外约束：https 主站不得授权 http 附加源站，避免协议降级。
({Set<String> origins, List<String> reasons}) normalizeAllowedOrigins(
  Object? raw, {
  required String baseUrl,
}) {
  final origins = <String>{};
  final reasons = <String>[];
  if (raw == null) return (origins: origins, reasons: reasons);
  if (raw is! List) {
    return (origins: origins, reasons: <String>['必须是字符串数组']);
  }
  if (raw.length > kMaxAllowedOrigins) {
    reasons.add('数量超过上限 $kMaxAllowedOrigins');
  }
  final baseScheme = Uri.tryParse(baseUrl)?.scheme;
  for (var i = 0; i < raw.length && i < kMaxAllowedOrigins; i++) {
    final e = raw[i];
    if (e is! String || e.isEmpty || e.length > kMaxOriginLength) {
      reasons.add('[$i] 必须是 1..$kMaxOriginLength 字符的字符串');
      continue;
    }
    if (e.contains('*') ||
        e.contains('\r') ||
        e.contains('\n') ||
        e.contains(' ')) {
      reasons.add('[$i] 含通配符/空白（不接受模糊匹配）');
      continue;
    }
    final u = Uri.tryParse(e);
    if (u == null ||
        (u.scheme != 'http' && u.scheme != 'https') ||
        u.host.isEmpty) {
      reasons.add('[$i] 必须是 http/https 绝对 origin：$e');
      continue;
    }
    if (u.path.isNotEmpty && u.path != '/') {
      reasons.add('[$i] 不允许携带路径（按整个 origin 授权）：$e');
      continue;
    }
    if (u.query.isNotEmpty || u.fragment.isNotEmpty || u.userInfo.isNotEmpty) {
      reasons.add('[$i] 不允许查询串/片段/userinfo：$e');
      continue;
    }
    if (baseScheme == 'https' && u.scheme == 'http') {
      reasons.add('[$i] https 主站不允许附加 http 源站（协议降级）：$e');
      continue;
    }
    origins.add(u.origin);
  }
  return (origins: origins, reasons: reasons);
}

const Set<String> _safeParsers = <String>{'dart', 'json', 'regex', 'jar', 'quickjs'};
const Set<String> _unsafeParsers = <String>{'jar', 'quickjs'};

String _normalizeKey(String k) =>
    k.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

bool _isSafeHttpUrl(String s) {
  final u = Uri.tryParse(s);
  return u != null &&
      (u.scheme == 'http' || u.scheme == 'https') &&
      u.host.isNotEmpty;
}

bool _isSafePathOrUrl(String s) {
  final u = Uri.tryParse(s);
  if (u == null) return false;
  if (u.hasScheme) return u.scheme == 'http' || u.scheme == 'https';
  final lower = s.toLowerCase();
  for (final bad in const <String>[
    'javascript:',
    'data:',
    'file:',
    'vbscript:',
    'jar:',
  ]) {
    if (lower.startsWith(bad)) return false;
  }
  return lower != '<script' && !lower.contains('<script');
}

/// 多源容器校验。顶层只允许 `sources` / `name` / `version`，
/// 每个元素按单源配置完整校验，问题带上索引前缀便于 UI 定位。
ConfigValidationResult _validateContainer(
  Map<String, dynamic> root, {
  required bool allowUnsafeBackends,
  required int maxDepth,
  required int maxEntries,
  required int maxStringLength,
}) {
  final reasons = <String>[];
  for (final k in root.keys) {
    if (!_allowedContainerKeys.contains(k)) {
      reasons.add('多源配置含未知顶层字段 $k');
    }
  }
  final list = root['sources'];
  if (list is! List || list.isEmpty) {
    reasons.add('sources 必须是非空数组');
    return ConfigValidationResult(List<String>.unmodifiable(reasons));
  }
  if (list.length > 50) reasons.add('源数量超过上限 50');
  for (var i = 0; i < list.length; i++) {
    final sub = validateSourceConfig(
      list[i],
      allowUnsafeBackends: allowUnsafeBackends,
      maxDepth: maxDepth,
      maxEntries: maxEntries,
      maxStringLength: maxStringLength,
    );
    for (final r in sub.reasons) {
      if (reasons.length >= 12) break;
      reasons.add('sources[$i]: $r');
    }
  }
  return ConfigValidationResult(List<String>.unmodifiable(reasons));
}

/// 校验一份外部源配置。
///
/// [allowUnsafeBackends] 默认 false：外部导入的配置若声明 `jar` / `quickjs` 后端
/// 一律拒绝；只有用户在明确知情并授权后才可置 true（对应 UI 的二次确认）。
ConfigValidationResult validateSourceConfig(
  Object? raw, {
  bool allowUnsafeBackends = false,
  int maxDepth = 6,
  int maxEntries = 200,
  int maxStringLength = 4096,
}) {
  if (raw is! Map) {
    return const ConfigValidationResult(<String>['根节点必须是对象']);
  }
  // jsonDecode 可能产出非字符串键；先拦下，避免后面 Map<String,dynamic>.from 抛类型错误。
  for (final k in raw.keys) {
    if (k is! String) {
      return const ConfigValidationResult(<String>['配置含非字符串键']);
    }
  }

  // 多源容器：逐条递归校验，单条坏配置不影响其余源（加载器也按此语义隔离）。
  if (raw['sources'] is List) {
    return _validateContainer(
      Map<String, dynamic>.from(raw),
      allowUnsafeBackends: allowUnsafeBackends,
      maxDepth: maxDepth,
      maxEntries: maxEntries,
      maxStringLength: maxStringLength,
    );
  }

  final reasons = <String>[];
  var entries = 0;

  void add(String r) {
    if (reasons.length < 8) reasons.add(r);
  }

  void walk(Object? node, int depth, String path) {
    if (node is String) {
      if (node.length > maxStringLength) {
        add('$path 字符串超长（>${maxStringLength}）');
      }
      final lower = node.toLowerCase();
      if (lower.contains('javascript:') ||
          lower.contains('<script') ||
          lower.contains('data:text/html')) {
        add('$path 含可疑脚本内容');
      }
      return;
    }
    if (node is num) {
      if (node.isNaN || node.isInfinite) add('$path 数值非法（NaN/Infinity）');
      return;
    }
    if (node == null || node is bool) return;
    if (depth > maxDepth) {
      add('$path 嵌套过深（>${maxDepth} 层）');
      return;
    }
    if (node is List) {
      entries += node.length;
      for (var i = 0; i < node.length; i++) {
        walk(node[i], depth + 1, '$path[$i]');
      }
      return;
    }
    if (node is Map) {
      entries += node.length;
      node.forEach((k, v) {
        if (k is! String) {
          add('$path 存在非字符串键');
          return;
        }
        if (_forbiddenKeys.contains(_normalizeKey(k))) {
          add('$path.$k 为禁止字段（动态代码加载面）');
        }
        if (depth == 0 && !_allowedRootKeys.contains(k)) {
          add('未知顶层字段 $k');
        }
        walk(v, depth + 1, '$path.$k');
      });
      return;
    }
    add('$path 类型不支持：${node.runtimeType}');
  }

  walk(raw, 0, 'root');
  if (entries > maxEntries) add('配置条目过多（$entries > $maxEntries）');

  final root = Map<String, dynamic>.from(raw);
  final baseUrl = root['baseUrl'];
  if (baseUrl is! String || !_isSafeHttpUrl(baseUrl)) {
    add('baseUrl 必须是 http/https 绝对地址且含主机名');
  }
  for (final k in const <String>['searchPath', 'playPath']) {
    final v = root[k];
    if (v != null && (v is! String || !_isSafePathOrUrl(v))) {
      add('$k 含非法 scheme 或格式');
    }
  }

  final parser = root['parser'];
  if (parser != null) {
    if (parser is! String || !_safeParsers.contains(parser)) {
      add('parser 取值非法（允许：${_safeParsers.join('/')}）');
    } else if (!allowUnsafeBackends && _unsafeParsers.contains(parser)) {
      add('外部配置默认禁止 jar/QuickJS 后端（代码执行面），需显式授权');
    }
  }

  // E2 闭环：外部配置可携带站点规则，但必须是纯数据且正则通过 ReDoS 静态检查。
  // 规则会交给 `RuleSourceParser` 解释执行，因此这里不能只做字段白名单。
  final rules = root['rules'];
  if (rules != null) {
    final ruleCheck = validateSiteRuleMap(rules);
    for (final r in ruleCheck.reasons) {
      add('rules: $r');
    }
    if (rules is Map) {
      final ruleBase = rules['baseUrl'];
      if (ruleBase is String &&
          baseUrl is String &&
          Uri.tryParse(ruleBase)?.host != Uri.tryParse(baseUrl)?.host) {
        add('rules.baseUrl 与配置 baseUrl 主机不一致（防配置注入外部站点）');
      }
    }
  }

  // 源级优先级：只接受 0..100 的整数，避免外部配置塞入 NaN / 超大值扰乱排序。
  final qualityRank = root['qualityRank'];
  if (qualityRank != null &&
      (qualityRank is! int || qualityRank < 0 || qualityRank > 100)) {
    add('qualityRank 必须是 0..100 的整数');
  }

  final originCheck = normalizeAllowedOrigins(
    root['allowedOrigins'],
    baseUrl: baseUrl is String ? baseUrl : '',
  );
  for (final r in originCheck.reasons) {
    add('allowedOrigins: $r');
  }

  final headers = root['headers'];
  if (headers != null) {
    if (headers is! Map) {
      add('headers 必须是对象');
    } else {
      headers.forEach((k, v) {
        if (k is! String || v is! String) {
          add('headers 必须是「字符串 → 字符串」映射');
        }
      });
    }
  }

  return ConfigValidationResult(List<String>.unmodifiable(reasons));
}
