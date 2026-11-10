// 从 URL 导入源配置的回归：这是唯一「把外部内容拉进本机」的网络入口，
// 每一条收紧都必须被钉住，否则它会在某次重构里悄悄放宽。
//
// 三层验证：
//   A. 本地校验（根本不发请求）：空地址 / 未接受免责 / file:// / 明文 http / URL 内联凭据
//   B. 真实下载边界：重定向（同主机 / 跨主机）、字节上限、二进制、非法 UTF-8、超时、状态码
//   C. 与服务层编排：成功后注册+落盘、失败不破坏已生效源、坏配置回退、重复导入替换
//
// 取数走真实 socket（本地 HttpServer），不用 Mock——这类边界的 bug 基本都长在
// 「真实响应长什么样」上。运行：dart run tooling/verify_url_import.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shunbo/core/scheduler/source_catalog.dart';
import 'package:shunbo/core/source/memory_source_adapter.dart';
import 'package:shunbo/core/source/source_adapter.dart';
import 'package:shunbo/core/source/source_profile.dart';
import 'package:shunbo/core/source/source_registry.dart';
import 'package:shunbo/data/onboarding/onboarding_flow.dart';
import 'package:shunbo/data/onboarding/sample_source_config.dart';
import 'package:shunbo/data/onboarding/source_config_url.dart';
import 'package:shunbo/data/onboarding/source_import_service.dart';

int _checkCount = 0;
int _failCount = 0;

void check(String name, bool ok, [String? detail]) {
  if (!ok) {
    _failCount++;
    print('FAIL: $name${detail == null ? '' : ' —— $detail'}');
    return;
  }
  _checkCount++;
  print('PASS: $name');
}

/// 本地样本站点：一张路由表，返回各类「真实但不友好」的响应。
class ConfigServer {
  late HttpServer _server;
  final Map<String, FutureOr<void> Function(HttpRequest)> routes = {};

  String get base => 'http://127.0.0.1:${_server.port}';

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((req) async {
      final handler = routes[req.uri.path];
      if (handler == null) {
        req.response.statusCode = 404;
        await req.response.close();
        return;
      }
      try {
        await handler(req);
      } catch (e) {
        // 不静默吞掉：客户端提前断开（超时/中止下载）是预期，但夹具自身写响应失败
        // 会让被测代码一直等到超时——那种「失败原因看起来像网络超时」的假象最难查。
        stderr.writeln('fixture handler error on ${req.uri.path}: $e');
      }
    });
  }

  Future<void> stop() => _server.close(force: true);
}

void _text(HttpRequest req, String body,
    {int status = 200, String type = 'application/json'}) {
  req.response.statusCode = status;
  req.response.headers.contentType = ContentType.parse(type);
  // 必须显式 UTF-8 编码：HttpResponse.write 在 contentType 未声明 charset 时按
  // latin1 编码，样本配置含中文会直接抛 "Contains invalid characters"。
  req.response.add(utf8.encode(body));
  req.response.close();
}

void _bytes(HttpRequest req, List<int> body) {
  req.response.statusCode = 200;
  req.response.headers.contentType = ContentType.parse('application/octet-stream');
  req.response.add(body);
  req.response.close();
}

/// 一次「启动」：全新注册表 + 引导流程 + 导入服务。
class Harness {
  final SourceRegistry registry = SourceRegistry();
  final SourceCatalog catalog = SourceCatalog();
  late final OnboardingFlow flow;
  late final SourceImportService svc;
  String? savedText;
  int urlLoads = 0;

  Harness({SourceConfigUrlLoader? readUrl, bool acceptDisclaimer = true}) {
    final builtin = MemorySourceAdapter(
      id: 'builtin',
      profile: const SourceProfile(name: 'builtin'),
      episodes: <String, List<EpisodeInfo>>{},
      urls: <String, List<PlayUrl>>{},
    );
    registry.register(builtin);
    catalog.register(builtin.profile);

    flow = OnboardingFlow(
      initial: null,
      persist: (s) async {},
    );
    svc = SourceImportService(
      registry: registry,
      catalog: catalog,
      flow: flow,
      readSaved: () async => savedText,
      writeSaved: (t) async => savedText = t,
      readUrl: readUrl ??
          (url) {
            urlLoads++;
            return fetchSourceConfigUrl(url);
          },
    );
  }

  void close() => svc.close();
}

Future<void> main() async {
  final server = ConfigServer();
  await server.start();
  try {
    await _localGuards(server);
    await _networkBoundary(server);
    await _serviceIntegration(server);
  } finally {
    await server.stop();
  }

  final total = _checkCount + _failCount;
  print('URL 导入回归：$_checkCount/$total 断言通过');
  if (_failCount > 0) {
    print('存在 $_failCount 条失败');
    exitCode = 1;
  }
}

// ---------------------------------------------------------------------------
// A. 本地校验：这些情况连一次请求都不该发出去
// ---------------------------------------------------------------------------
Future<void> _localGuards(ConfigServer server) async {
  // 未接受免责声明：门禁必须在网络之前，否则「贴了个链接」就等于替用户去访问地址。
  {
    final h = Harness(acceptDisclaimer: false);
    final r = await h.svc.importFromUrl('${server.base}/ok.json');
    check('未接受免责声明时拒绝链接导入',
        r.kind == ImportOutcomeKind.blockedByDisclaimer, '${r.kind}');
    check('未接受免责声明时一次请求都不发', h.urlLoads == 0, '${h.urlLoads}');
    h.close();
  }

  // 空地址同样不该发请求。
  {
    final h = Harness();
    await h.flow.acceptDisclaimer();
    final r = await h.svc.importFromUrl('   ');
    check('空链接被拒绝', r.kind == ImportOutcomeKind.rejected);
    check('空链接不发请求', h.urlLoads == 0, '${h.urlLoads}');
    h.close();
  }

  // 协议 / 明文 / 内联凭据 / 缺 scheme：全部在本地拦下。
  {
    final cases = <String, SourceConfigUrlFailure>{
      'file:///c:/sources.json': SourceConfigUrlFailure.unsupportedScheme,
      'ftp://example.com/s.json': SourceConfigUrlFailure.unsupportedScheme,
      'http://example.com/s.json': SourceConfigUrlFailure.insecureTransport,
      'https://user:pw@example.com/s.json': SourceConfigUrlFailure.userInfo,
      'example.com/s.json': SourceConfigUrlFailure.malformed,
      'http://user:pw@127.0.0.1/s.json': SourceConfigUrlFailure.userInfo,
    };
    for (final e in cases.entries) {
      final r = await fetchSourceConfigUrl(e.key);
      check('本地拦截 ${e.key} → ${e.value.name}',
          !r.ok && r.failure == e.value, '${r.failure} / ${r.message}');
    }
  }

  // loopback 的明文 http 是刻意放开的（本地自测/内网直连），不能被上面那条规则误杀。
  check('loopback 判定覆盖 127.0.0.0/8 与 localhost',
      isLoopbackHost('127.0.0.1') &&
          isLoopbackHost('127.1.2.3') &&
          isLoopbackHost('localhost') &&
          isLoopbackHost('::1') &&
          !isLoopbackHost('192.168.1.10') &&
          !isLoopbackHost('example.com'));
}

// ---------------------------------------------------------------------------
// B. 真实下载边界
// ---------------------------------------------------------------------------
Future<void> _networkBoundary(ConfigServer server) async {
  final config = sampleSourceConfigJson(
      baseUrl: 'https://demo.invalid', ruleName: 'legacy');

  server.routes['/ok.json'] = (req) => _text(req, config);
  server.routes['/bom.json'] = (req) => _text(req, '\uFEFF$config');
  server.routes['/hop.json'] =
      (req) => _text(req, config); // 同主机重定向的落点
  server.routes['/redirect.json'] = (req) {
    req.response.statusCode = 302;
    req.response.headers.set(HttpHeaders.locationHeader, '/hop.json');
    req.response.close();
  };
  server.routes['/redirect-other.json'] = (req) {
    req.response.statusCode = 302;
    req.response.headers
        .set(HttpHeaders.locationHeader, 'http://example.invalid/evil.json');
    req.response.close();
  };
  server.routes['/302-loop.json'] = (req) {
    req.response.statusCode = 302;
    req.response.headers.set(HttpHeaders.locationHeader, '/302-loop.json');
    req.response.close();
  };
  server.routes['/missing.json'] = (req) => _text(req, 'not found', status: 404);
  server.routes['/big.json'] = (req) {
    final big = '{"pad":"${'x' * (300 * 1024)}"}';
    _text(req, big);
  };
  server.routes['/binary.json'] = (req) => _bytes(req, <int>[0x50, 0x4b, 0x03, 0x04, 0x00, 0x01]);
  server.routes['/latin.json'] = (req) => _bytes(req, <int>[0xFF, 0xFE, 0x7B, 0x7D]);
  server.routes['/empty.json'] = (req) => _text(req, '   ');
  server.routes['/slow.json'] = (req) async {
    await Future<void>.delayed(const Duration(seconds: 3));
    _text(req, config);
  };

  final ok = await fetchSourceConfigUrl('${server.base}/ok.json');
  check('正常下载成功', ok.ok, ok.message);
  check('下载到的文本与源一致', ok.text == config, '${ok.text?.length}');
  check('来源标签只保留 host:port（不含 query）',
      ok.originLabel == '127.0.0.1:${Uri.parse(server.base).port}',
      '${ok.originLabel}');

  // query 里可能带私有 token：绝不能原样回显到 UI / 日志。
  final withToken =
      await fetchSourceConfigUrl('${server.base}/ok.json?token=secret-abc');
  check('来源标签不回显 URL query（防 token 泄漏）',
      withToken.ok &&
          !withToken.originLabel!.contains('secret') &&
          !withToken.originLabel!.contains('token'),
      '${withToken.originLabel}');

  final bom = await fetchSourceConfigUrl('${server.base}/bom.json');
  check('剥掉 UTF-8 BOM 后可正常解析', bom.ok && !bom.text!.startsWith('\uFEFF'));

  final hop = await fetchSourceConfigUrl('${server.base}/redirect.json');
  check('同主机重定向被跟随', hop.ok, hop.message);

  final other = await fetchSourceConfigUrl('${server.base}/redirect-other.json');
  check('跨主机重定向被拒绝',
      !other.ok && other.failure == SourceConfigUrlFailure.redirect,
      '${other.failure} / ${other.message}');

  final loop = await fetchSourceConfigUrl('${server.base}/302-loop.json');
  check('重定向自环被跳数上限拦下',
      !loop.ok && loop.failure == SourceConfigUrlFailure.redirect, '${loop.message}');

  final missing = await fetchSourceConfigUrl('${server.base}/missing.json');
  check('404 不被当成配置', !missing.ok && missing.failure == SourceConfigUrlFailure.httpStatus,
      '${missing.failure}');

  final big = await fetchSourceConfigUrl('${server.base}/big.json');
  check('超过 256KB 上限被中止',
      !big.ok && big.failure == SourceConfigUrlFailure.tooLarge, '${big.failure}');

  final binary = await fetchSourceConfigUrl('${server.base}/binary.json');
  check('二进制内容（含 NUL）被拒绝',
      !binary.ok && binary.failure == SourceConfigUrlFailure.binary,
      '${binary.failure}');

  final latin = await fetchSourceConfigUrl('${server.base}/latin.json');
  check('非法 UTF-8 被拒绝（不做有损替换）',
      !latin.ok && latin.failure == SourceConfigUrlFailure.notUtf8, '${latin.failure}');

  final empty = await fetchSourceConfigUrl('${server.base}/empty.json');
  check('空响应体被拒绝', !empty.ok && empty.text == null, '${empty.failure}');

  final slow = await fetchSourceConfigUrl('${server.base}/slow.json',
      timeout: const Duration(milliseconds: 300));
  check('慢响应按总超时失败（不挂住引导）',
      !slow.ok && slow.failure == SourceConfigUrlFailure.timeout, '${slow.failure}');
}

// ---------------------------------------------------------------------------
// C. 与服务层编排：注册 / 落盘 / 失败隔离 / 坏配置回退 / 重复导入替换
// ---------------------------------------------------------------------------
Future<void> _serviceIntegration(ConfigServer server) async {
  final config = sampleSourceConfigJson(
      baseUrl: 'https://demo.invalid', ruleName: 'legacy');
  server.routes['/ok2.json'] = (req) => _text(req, config);
  server.routes['/empty-config.json'] =
      (req) => _text(req, jsonEncode(<String, dynamic>{'version': 1, 'sources': <Object?>[]}));

  final h = Harness();
  await h.flow.acceptDisclaimer();

  final first = await h.svc.importFromUrl('${server.base}/ok2.json');
  check('链接导入成功并生效', first.ok && first.kind == ImportOutcomeKind.applied,
      '${first.kind} / ${first.message}');
  check('导入后源真的注册进注册表',
      first.sourceIds.isNotEmpty && h.registry.get(first.sourceIds.first) != null);
  check('来源标签带到结果里（供 UI 展示）',
      first.originLabel == '127.0.0.1:${Uri.parse(server.base).port}',
      '${first.originLabel}');
  check('净化配置已落盘', h.savedText != null && h.savedText!.isNotEmpty);
  final firstIds = List<String>.of(first.sourceIds);

  // 下载失败不能清空上一次已生效的源（与文件导入同一不变量）。
  final failed = await h.svc.importFromUrl('${server.base}/missing.json');
  check('下载失败返回拒绝', !failed.ok);
  check('下载失败后旧源仍在注册表',
      firstIds.every((id) => h.registry.get(id) != null), '${h.registry.ids}');
  check('下载失败不清空已落盘配置', h.savedText != null && h.savedText!.isNotEmpty);

  // 坏配置（零可用源）：不注册、不落盘、但保留来源标签便于用户排查。
  final beforeText = h.savedText;
  final bad = await h.svc.importFromUrl('${server.base}/empty-config.json');
  check('零可用源的配置被拒绝', !bad.ok);
  check('零可用源时不覆盖已落盘配置', h.savedText == beforeText);
  check('失败结果仍带来源标签',
      bad.originLabel == '127.0.0.1:${Uri.parse(server.base).port}',
      '${bad.originLabel}');

  // 再次成功导入：旧源必须被注销（否则留下指向旧站点的孤儿源）。
  final again = await h.svc.importFromUrl('${server.base}/ok2.json');
  check('重复导入成功', again.ok);
  check('重复导入注销旧源（无孤儿）',
      firstIds.every((id) => h.registry.get(id) == null ||
          again.sourceIds.contains(id)),
      '${h.registry.ids}');
  h.close();
}
