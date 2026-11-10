import 'dart:convert';

import 'package:flutter/services.dart';

import 'source_adapter.dart';
import 'source_fetcher.dart';
import 'source_parser.dart';

/// Android jar 解析后端（E2 真实适配器，仅 Android 可用）。
///
/// 解析逻辑运行在 Java jar 内（经 MethodChannel 调用），Dart 侧负责传参 + 反序列化。
///
/// 重要落差（原评估已登记）：jar 不可跨端——本后端仅用于 Android 平台；
/// 桌面/TV 不会注册该源，由 [SourceRegistry] 按平台裁剪，避免「桌面列出 Android 专属源」。
class JarSourceParser implements SourceParser {
  static const MethodChannel _channel = MethodChannel('shunbo/source_jar');
  final String jarEntry;

  JarSourceParser(this.jarEntry);

  Future<Map<String, dynamic>> _call(
    String method,
    Map<String, dynamic> args,
  ) async {
    final resp = await _channel.invokeMethod<String>(
      method,
      {'jarEntry': jarEntry, ...args},
    );
    final decoded = jsonDecode(resp ?? '{}');
    return Map<String, dynamic>.from(decoded as Map);
  }

  @override
  Future<List<MediaSearchResult>> parseSearch(String html) async {
    final data = await _call('parseSearch', {'html': html});
    final list = (data['items'] as List?) ?? const <dynamic>[];
    return [
      for (final it in list)
        MediaSearchResult(
          mediaId: it['id'] as String? ?? '',
          title: it['title'] as String? ?? '',
        )
    ];
  }

  @override
  Future<List<EpisodeRef>> parseEpisodes(String detailHtml) async {
    final data = await _call('parseEpisodes', {'html': detailHtml});
    final list = (data['eps'] as List?) ?? const <dynamic>[];
    return [
      for (final it in list)
        EpisodeRef(
          episode: it['ep'] as int? ?? 0,
          playPagePath: it['path'] as String? ?? '',
        )
    ];
  }

  @override
  Future<List<PlayUrl>> parsePlayUrls(String playPageHtml) async {
    final data = await _call('parsePlayUrls', {'html': playPageHtml});
    final list = (data['urls'] as List?) ?? const <dynamic>[];
    return [
      for (final it in list)
        PlayUrl(
          url: it['url'] as String? ?? '',
          qualityRank: it['rank'] as int? ?? 0,
        )
    ];
  }
}

/// Android jar 取数后端（仅 Android 可用），与 [JarSourceParser] 共用 MethodChannel。
class JarFetcher implements SourceFetcher {
  static const MethodChannel _channel = MethodChannel('shunbo/source_jar');
  final String jarEntry;

  JarFetcher(this.jarEntry);

  @override
  Future<String> fetchSearch(String keyword) =>
      _fetch('search', {'q': keyword});

  @override
  Future<String> fetchDetail(String mediaId) =>
      _fetch('detail', {'id': mediaId});

  @override
  Future<String> fetchPlayPage(String mediaId, String playPagePath) =>
      _fetch('play', {'id': mediaId, 'path': playPagePath});

  Future<String> _fetch(String kind, Map<String, dynamic> args) async {
    final resp = await _channel.invokeMethod<String>(
      'fetch',
      {'jarEntry': jarEntry, 'kind': kind, ...args},
    );
    return resp ?? '';
  }
}
