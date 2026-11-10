import 'dart:convert';

import 'site_rule.dart';
import 'source_adapter.dart';
import 'source_parser.dart';

/// 规则驱动的桌面/TV 解析器（E2 解析子集扩充）。
///
/// 与硬编码的 `DartSourceParser` 实现同一 [SourceParser] 契约，可直接注入
/// `ParsedSourceAdapter`，**编排层 / UI / 调度层零改动**。
///
/// 健壮性约定（真实站点响应远不如测试样本干净）：
/// - 单条脏数据（缺字段 / 非法数字 / 坏正则 / 坏 JSON）逐条跳过，绝不抛出；
/// - 输入文本超长时截断，防止外部正则在超大页面上放大回溯开销；
/// - 剧集按集数去重升序、地址按 url 去重按清晰度降序，消除乱序与重复；
/// - 所有地址经 [normalizeSiteUrl] 过滤危险 scheme 并补全为绝对地址。
class RuleSourceParser implements SourceParser {
  final SiteRule rule;

  /// 单次解析允许处理的最大字符数（防 ReDoS / 内存放大）。
  final int maxInputChars;

  int _truncatedCount = 0;
  int _skippedRows = 0;

  RuleSourceParser(this.rule, {this.maxInputChars = 2 * 1024 * 1024});

  /// 因超长被截断的次数（供诊断上报）。
  int get truncatedCount => _truncatedCount;

  /// 被隔离丢弃的脏条目数（供诊断上报）。
  int get skippedRows => _skippedRows;

  @override
  Future<List<MediaSearchResult>> parseSearch(String text) async {
    final rows = extractRows(rule.search, text);
    final out = <MediaSearchResult>[];
    final seen = <String>{};
    for (final row in rows) {
      final id = (row['mediaId'] ?? '').trim();
      final title = decodeHtmlEntities(row['title'] ?? '').trim();
      if (id.isEmpty || title.isEmpty || !seen.add(id)) {
        _skippedRows++;
        continue;
      }
      final cover = row['coverUrl'];
      final coverUrl = (cover == null || cover.isEmpty)
          ? null
          : normalizeSiteUrl(cover, rule.baseUrl);
      out.add(MediaSearchResult(
        mediaId: id,
        title: title,
        coverUrl: (coverUrl == null || coverUrl.isEmpty) ? null : coverUrl,
      ));
      if (out.length >= rule.search.maxItems) break;
    }
    return out;
  }

  @override
  Future<List<EpisodeRef>> parseEpisodes(String detailText) async {
    final rows = extractRows(rule.episodes, detailText);
    final byEpisode = <int, EpisodeRef>{};
    for (final row in rows) {
      final ep = int.tryParse((row['episode'] ?? '').trim());
      final rawPath = (row['playPagePath'] ?? '').trim();
      if (ep == null || ep < 0 || rawPath.isEmpty) {
        _skippedRows++;
        continue;
      }
      final path = normalizeSiteUrl(rawPath, rule.baseUrl);
      if (path.isEmpty) {
        _skippedRows++;
        continue;
      }
      byEpisode.putIfAbsent(ep, () => EpisodeRef(episode: ep, playPagePath: path));
    }
    final eps = byEpisode.keys.toList()..sort();
    return eps.map((e) => byEpisode[e]!).toList();
  }

  @override
  Future<List<PlayUrl>> parsePlayUrls(String playPageText) async {
    final rows = extractRows(rule.playUrls, playPageText);
    final byUrl = <String, PlayUrl>{};
    for (final row in rows) {
      final raw = (row['url'] ?? '').trim();
      if (raw.isEmpty) {
        _skippedRows++;
        continue;
      }
      final url = normalizeSiteUrl(raw, rule.baseUrl);
      if (url.isEmpty) {
        _skippedRows++;
        continue;
      }
      final rank = int.tryParse((row['qualityRank'] ?? '').trim()) ?? 1;
      final prev = byUrl[url];
      // 同地址重复出现时保留更高清晰度标注，避免低清标注覆盖择优结果。
      if (prev == null || rank > prev.qualityRank) {
        byUrl[url] = PlayUrl(url: url, qualityRank: rank);
      }
    }
    final list = byUrl.values.toList()
      ..sort((a, b) => b.qualityRank.compareTo(a.qualityRank));
    if (list.length > rule.playUrls.maxItems) {
      return list.sublist(0, rule.playUrls.maxItems);
    }
    return list;
  }

  /// 按 [ExtractionRule] 把响应文本转成「字段 → 值」行（公开便于诊断与单测）。
  List<Map<String, String>> extractRows(ExtractionRule er, String text) {
    var body = text;
    if (body.length > maxInputChars) {
      _truncatedCount++;
      body = body.substring(0, maxInputChars);
    }
    return er.mode == 'json' ? _rowsFromJson(er, body) : _rowsFromRegex(er, body);
  }

  List<Map<String, String>> _rowsFromRegex(ExtractionRule er, String text) {
    final rows = <Map<String, String>>[];
    for (final pattern in er.patterns) {
      if (rows.length >= er.maxItems) break;
      final RegExp re;
      try {
        re = RegExp(pattern, dotAll: true);
      } catch (_) {
        continue; // 坏正则不应让整段解析失败
      }
      for (final m in re.allMatches(text)) {
        if (rows.length >= er.maxItems) break;
        final row = _buildRegexRow(er, m);
        if (row == null) {
          _skippedRows++;
          continue;
        }
        rows.add(row);
      }
    }
    return rows;
  }

  Map<String, String>? _buildRegexRow(ExtractionRule er, RegExpMatch m) {
    final row = <String, String>{};
    for (final e in er.fields.entries) {
      final v = _evalRegexExpr(e.value, m);
      if (v == null) return null;
      row[e.key] = v;
    }
    return row;
  }

  String? _evalRegexExpr(String expr, RegExpMatch m) {
    // 可选组：缺失填空串（用于多条 pattern 只有部分含该组的场景）。
    if (expr.startsWith('?')) {
      final name = expr.substring(1);
      return m.groupNames.contains(name) ? (m.namedGroup(name) ?? '') : '';
    }
    // 模板：任一组缺失即丢弃整条，避免产出半截 URL。
    if (expr.contains(r'${')) {
      var missing = false;
      final out = expr.replaceAllMapped(RegExp(r'\$\{([^}]+)\}'), (tm) {
        final name = tm.group(1)!;
        if (!m.groupNames.contains(name)) {
          missing = true;
          return '';
        }
        return m.namedGroup(name) ?? '';
      });
      return missing ? null : out;
    }
    if (m.groupNames.contains(expr)) return m.namedGroup(expr) ?? '';
    return expr; // 字面量（如默认 qualityRank）
  }

  List<Map<String, String>> _rowsFromJson(ExtractionRule er, String text) {
    Object? root;
    try {
      root = jsonDecode(text);
    } catch (_) {
      return const <Map<String, String>>[]; // 坏 JSON 降级为空集
    }
    final list = jsonPath(root, er.listPath);
    if (list is! List) return const <Map<String, String>>[];
    final rows = <Map<String, String>>[];
    for (final item in list) {
      if (rows.length >= er.maxItems) break;
      final row = _buildJsonRow(er, item);
      if (row == null) {
        _skippedRows++;
        continue;
      }
      rows.add(row);
    }
    return rows;
  }

  Map<String, String>? _buildJsonRow(ExtractionRule er, Object? item) {
    final row = <String, String>{};
    for (final e in er.fields.entries) {
      final expr = e.value;
      String? v;
      if (expr.startsWith('?')) {
        v = _scalar(jsonPath(item, expr.substring(1)));
      } else if (expr.contains(r'${')) {
        var missing = false;
        final out = expr.replaceAllMapped(RegExp(r'\$\{([^}]+)\}'), (tm) {
          final node = jsonPath(item, tm.group(1)!);
          if (node == null) {
            missing = true;
            return '';
          }
          return _scalar(node);
        });
        v = missing ? null : out;
      } else {
        final node = jsonPath(item, expr);
        // 找不到路径时按字面量处理（如默认清晰度 '1'）。
        v = node == null ? expr : _scalar(node);
      }
      if (v == null) return null;
      row[e.key] = v;
    }
    return row;
  }

  String _scalar(Object? node) => switch (node) {
        null => '',
        String s => s,
        num n => n.toString(),
        bool b => b.toString(),
        _ => '',
      };
}
