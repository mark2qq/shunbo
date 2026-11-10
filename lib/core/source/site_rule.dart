/// 站点解析规则（E2 桌面解析子集扩充）。
///
/// 设计动机：原 [DartSourceParser] 把站点结构硬编码成三条正则，只能解析一种
/// 「约定结构」，无法覆盖真实多源场景。本文件把站点结构抽成**纯数据规则**，
/// 由 `RuleSourceParser` 解释执行 —— 规则可 JSON 导入/导出，但**不含任何可执行代码**，
/// 因此能与 E9 源配置安全白名单配合：导入前先跑 [validateSiteRuleMap] 做正则安全校验。
///
/// 安全边界（对应评估报告「安全/隐私需求缺失」）：
/// - 规则只允许正则字符串 / JSON 路径字符串 / 字面量模板，绝不加载类、脚本或命令；
/// - Dart 的 RegExp 无超时，外部正则有 ReDoS 风险，故对长度与嵌套量词做静态拒绝，
///   解析时再对输入文本长度设上限（见 `RuleSourceParser.maxInputChars`）。
library;

/// 规则校验结果（独立于 E9 的结果类型，避免 core → data 的层次倒置）。
class RuleValidation {
  final List<String> reasons;

  const RuleValidation(this.reasons);

  bool get ok => reasons.isEmpty;

  @override
  String toString() =>
      ok ? '站点规则校验通过' : '站点规则校验失败：${reasons.join('；')}';
}

/// 单段抽取规则：把一段站点响应文本转成若干「字段 → 值」行。
///
/// - [mode] = `regex`：对 [patterns] 中每条正则取 `allMatches`，字段值来自命名捕获组；
/// - [mode] = `json`：`jsonDecode` 后按 [listPath] 定位列表，字段值来自点分路径。
/// - [fields] 的值支持：命名组名 / JSON 值路径 / `?name`（可选组，缺失填空串）/
///   `r'${x}'` 形式的模板（缺组则跳过该条）/ 字面量。
///   `?name` 让「同一段有多条 pattern、但只有部分 pattern 有该组」成为可能。
class ExtractionRule {
  final String mode;
  final List<String> patterns;
  final String listPath;
  final Map<String, String> fields;
  final int maxItems;

  const ExtractionRule({
    this.mode = 'regex',
    this.patterns = const <String>[],
    this.listPath = '',
    required this.fields,
    this.maxItems = 100,
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
        'mode': mode,
        'patterns': patterns,
        'listPath': listPath,
        'fields': fields,
        'maxItems': maxItems,
      };

  factory ExtractionRule.fromJson(Object? raw) {
    if (raw is! Map) {
      return const ExtractionRule(fields: <String, String>{});
    }
    final m = Map<String, dynamic>.from(raw);
    return ExtractionRule(
      mode: m['mode'] is String ? m['mode'] as String : 'regex',
      patterns: m['patterns'] is List
          ? (m['patterns'] as List).whereType<String>().toList()
          : const <String>[],
      listPath: m['listPath'] is String ? m['listPath'] as String : '',
      fields: m['fields'] is Map
          ? (m['fields'] as Map).map(
              (k, v) => MapEntry(k.toString(), v.toString()),
            )
          : const <String, String>{},
      maxItems: m['maxItems'] is int ? m['maxItems'] as int : 100,
    );
  }
}

/// 一个站点的完整解析规则（搜索 / 剧集 / 播放地址三段）。
class SiteRule {
  final String id;
  final String baseUrl;
  final ExtractionRule search;
  final ExtractionRule episodes;
  final ExtractionRule playUrls;

  const SiteRule({
    required this.id,
    required this.baseUrl,
    required this.search,
    required this.episodes,
    required this.playUrls,
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'baseUrl': baseUrl,
        'search': search.toJson(),
        'episodes': episodes.toJson(),
        'playUrls': playUrls.toJson(),
      };

  factory SiteRule.fromJson(Object? raw) {
    if (raw is! Map) {
      return SiteRule(
        id: '',
        baseUrl: '',
        search: const ExtractionRule(fields: <String, String>{}),
        episodes: const ExtractionRule(fields: <String, String>{}),
        playUrls: const ExtractionRule(fields: <String, String>{}),
      );
    }
    final m = Map<String, dynamic>.from(raw);
    return SiteRule(
      id: m['id'] is String ? m['id'] as String : '',
      baseUrl: m['baseUrl'] is String ? m['baseUrl'] as String : '',
      search: ExtractionRule.fromJson(m['search']),
      episodes: ExtractionRule.fromJson(m['episodes']),
      playUrls: ExtractionRule.fromJson(m['playUrls']),
    );
  }
}

/// 内置规则预设：覆盖三类常见站点结构，供桌面/TV 开箱即用。
class SiteRulePresets {
  const SiteRulePresets._();

  /// A. 兼容旧 [DartSourceParser] 的约定结构（保证向后等价）。
  static const legacy = SiteRule(
    id: 'legacy',
    baseUrl: 'https://example.com',
    search: ExtractionRule(
      patterns: <String>[
        r'<div class="item" data-id="(?<mediaId>[^"]+)">\s*<a[^>]*>(?<title>[^<]+)</a>',
      ],
      fields: <String, String>{'mediaId': 'mediaId', 'title': 'title'},
    ),
    episodes: ExtractionRule(
      patterns: <String>[
        r'<a class="ep" data-ep="(?<episode>\d+)" href="(?<playPagePath>[^"]+)">',
      ],
      fields: <String, String>{
        'episode': 'episode',
        'playPagePath': 'playPagePath',
      },
    ),
    playUrls: ExtractionRule(
      patterns: <String>[
        r'<video[^>]*src="(?<url>[^"]+)"',
        r'<a class="q" data-rank="(?<qualityRank>\d+)" href="(?<url>[^"]+)"',
      ],
      fields: <String, String>{
        'url': 'url',
        // 只有 `a.q` 那条正则含该组；`video` 那条缺失时填空串，由解析器给默认 rank。
        'qualityRank': '?qualityRank',
      },
    ),
  );

  /// B. 常见影视站结构：`li[data-id]` 列表 + `option` 选集 + 页面内 m3u8 直链。
  static const vodHtml = SiteRule(
    id: 'vod-html',
    baseUrl: 'https://vod.example.com',
    search: ExtractionRule(
      patterns: <String>[
        r'<li[^>]*data-id="(?<mediaId>\d+)"[^>]*>\s*<h3>(?<title>[^<]+)</h3>',
      ],
      fields: <String, String>{'mediaId': 'mediaId', 'title': 'title'},
    ),
    episodes: ExtractionRule(
      patterns: <String>[
        r'<option value="(?<playPagePath>[^"]+)"[^>]*>第(?<episode>\d+)集</option>',
      ],
      fields: <String, String>{
        'episode': 'episode',
        'playPagePath': 'playPagePath',
      },
    ),
    playUrls: ExtractionRule(
      patterns: <String>[
        r'"url"\s*:\s*"(?<url>https?:[^"\s]+?\.m3u8[^"\s]*)"',
        r'(?<url>https?://[^"\s]+?\.m3u8[^"\s]*)',
      ],
      fields: <String, String>{'url': 'url', 'qualityRank': '1'},
    ),
  );

  /// C. JSON API 结构（大量移动端接口返回 JSON，正则无法可靠解析）。
  static const jsonApi = SiteRule(
    id: 'json-api',
    baseUrl: 'https://api.example.com',
    search: ExtractionRule(
      mode: 'json',
      listPath: 'data.list',
      fields: <String, String>{
        'mediaId': 'vod_id',
        'title': 'vod_name',
      },
    ),
    episodes: ExtractionRule(
      mode: 'json',
      listPath: 'data.episodes',
      fields: <String, String>{
        'episode': 'ep',
        'playPagePath': 'url',
      },
    ),
    playUrls: ExtractionRule(
      mode: 'json',
      listPath: 'data.urls',
      fields: <String, String>{
        'url': 'play_url',
        'qualityRank': 'rank',
      },
    ),
  );

  static const all = <String, SiteRule>{
    'legacy': legacy,
    'vod-html': vodHtml,
    'json-api': jsonApi,
  };
}

/// 约束上限（同时供 E9 白名单与解析器运行时使用）。
const int kMaxPatternLength = 1024;
const int kMaxRuleItems = 500;
const int kMaxFieldExpressionLength = 256;

bool _isSafeBaseUrl(String s) {
  final u = Uri.tryParse(s);
  return u != null &&
      (u.scheme == 'http' || u.scheme == 'https') &&
      u.host.isNotEmpty;
}

/// 启发式 ReDoS 检测：拒绝「组内含量词 + 组外再含量词」这类指数回溯形态。
bool _hasNestedQuantifier(String p) {
  if (RegExp(r'\([^)]*[+*][^)]*\)\s*[+*{]').hasMatch(p)) return true;
  if (RegExp(r'[+*][+*]').hasMatch(p)) return true;
  return false;
}

RuleValidation _validateSection(String name, ExtractionRule r,
    List<String> requiredFields) {
  final reasons = <String>[];
  if (r.mode != 'regex' && r.mode != 'json') {
    reasons.add('$name.mode 只能是 regex / json');
  }
  if (r.mode == 'regex') {
    if (r.patterns.isEmpty) reasons.add('$name.patterns 不能为空');
    for (final p in r.patterns) {
      if (p.isEmpty || p.length > kMaxPatternLength) {
        reasons.add('$name 正则为空或超长（>$kMaxPatternLength）');
      }
      if (_hasNestedQuantifier(p)) {
        reasons.add('$name 正则含嵌套量词（ReDoS 风险）');
      }
      if (!p.contains('(?<')) {
        reasons.add('$name 正则缺少命名捕获组 (?<name>...)');
      }
    }
  } else if (r.listPath.trim().isEmpty) {
    reasons.add('$name.listPath 不能为空');
  }
  for (final f in requiredFields) {
    if (!r.fields.containsKey(f)) reasons.add('$name 缺少必需字段 $f');
  }
  r.fields.forEach((k, v) {
    if (k.isEmpty || v.isEmpty || v.length > kMaxFieldExpressionLength) {
      reasons.add('$name.fields 表达式为空或超长');
    }
  });
  if (r.maxItems < 1 || r.maxItems > kMaxRuleItems) {
    reasons.add('$name.maxItems 超出 1..$kMaxRuleItems');
  }
  return RuleValidation(List<String>.unmodifiable(reasons));
}

/// 校验一条站点规则（导入前必跑）。
RuleValidation validateSiteRule(SiteRule rule) {
  final reasons = <String>[];
  if (rule.id.trim().isEmpty) reasons.add('id 不能为空');
  if (!_isSafeBaseUrl(rule.baseUrl)) {
    reasons.add('baseUrl 必须是含主机名的 http/https 绝对地址');
  }
  reasons.addAll(_validateSection(
          'search', rule.search, const <String>['mediaId', 'title'])
      .reasons);
  reasons.addAll(_validateSection('episodes', rule.episodes,
          const <String>['episode', 'playPagePath'])
      .reasons);
  reasons.addAll(_validateSection(
          'playUrls', rule.playUrls, const <String>['url'])
      .reasons);
  return RuleValidation(List<String>.unmodifiable(reasons));
}

/// 从外部配置的 `rules` 节点做静态校验（供 E9 `validateSourceConfig` 调用）。
RuleValidation validateSiteRuleMap(Object? raw) {
  if (raw is! Map) return const RuleValidation(<String>['rules 必须是对象']);
  try {
    return validateSiteRule(SiteRule.fromJson(raw));
  } catch (e) {
    return RuleValidation(<String>['规则格式非法：$e']);
  }
}

/// HTML 实体解码（只解一层，避免双重解码把 `&amp;#39;` 变成引号）。
String decodeHtmlEntities(String s) {
  if (!s.contains('&')) return s;
  var out = s.replaceAllMapped(
    RegExp(r'&#x([0-9a-fA-F]+);'),
    (m) => String.fromCharCode(int.parse(m.group(1)!, radix: 16)),
  );
  out = out.replaceAllMapped(
    RegExp(r'&#(\d+);'),
    (m) => String.fromCharCode(int.parse(m.group(1)!)),
  );
  return out
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll('&#39;', "'")
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&');
}

/// URL 规范化：拒绝危险 scheme，把相对/协议相对地址按 [baseUrl] 补全。
///
/// 返回空串表示「非法地址」，调用方应跳过该条而非抛异常（脏数据隔离）。
String normalizeSiteUrl(String raw, String baseUrl) {
  // 站点 JSON 常把斜杠转义成 `\/`，先还原再做 URL 解析。
  var s = decodeHtmlEntities(raw.replaceAll(r'\/', '/')).trim();
  if (s.isEmpty) return '';
  final lower = s.toLowerCase();
  for (final bad in const <String>[
    'javascript:',
    'data:',
    'file:',
    'vbscript:',
    'jar:',
  ]) {
    if (lower.startsWith(bad)) return '';
  }
  final base = Uri.tryParse(baseUrl);
  if (base == null || (base.scheme != 'http' && base.scheme != 'https')) {
    return '';
  }
  final u = base.resolve(s);
  if (u.scheme != 'http' && u.scheme != 'https') return '';
  return u.toString();
}

/// JSON 点分路径取值（`data.list.0.title`；数字段当列表索引）。
Object? jsonPath(Object? node, String path) {
  var cur = node;
  for (final part in path.split('.')) {
    if (part.isEmpty) continue;
    if (cur is Map) {
      cur = cur[part];
    } else if (cur is List) {
      final i = int.tryParse(part);
      if (i == null || i < 0 || i >= cur.length) return null;
      cur = cur[i];
    } else {
      return null;
    }
  }
  return cur;
}
