// E9 来源可信度与签名校验回归。
//
// 传输层（`verify_url_import.dart`）已经证明「这段文本来自用户填的主机」；
// 这一套钉的是「下载成功 ≠ 内容可信」之后那半句：
//   A. 规范化摘要与来源身份（BOM/CRLF/端口/userInfo/明文降级）
//   B. TOFU：首次必须确认、内容/路径/主机变化必须重新确认
//   C. HMAC 签名：有效签名可自动放行变更，但绝不允许「曾签名 → 无签名」降级
//   D. 落盘：损坏记录跳过、数量上限、写盘失败如实上报
//   E. 真 socket 验证只回显签名头，不把 Cookie 之类带进导入链路
//   F. 与 SourceImportService 的真实串联：未确认不注册、不落盘、不推进
//
// 运行：dart run tooling/verify_source_trust.dart
library;

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
import 'package:shunbo/data/onboarding/source_trust.dart';

int _pass = 0;
int _fail = 0;

void check(String name, bool ok, [String? detail]) {
  if (!ok) {
    _fail++;
    print('FAIL: $name${detail == null ? '' : ' —— $detail'}');
    return;
  }
  _pass++;
  print('PASS: $name');
}

const String kUrl = 'https://pub.example.com/list.m3u';
const String kUrl2 = 'https://pub.example.com/other.m3u';
const String kOtherOrigin = 'https://mirror.example.com/list.m3u';
const String kSecret = 'publisher-shared-secret';

String _cfg([String tag = 'a']) => sampleSourceConfigJson(
      baseUrl: 'https://demo-$tag.invalid', ruleName: 'legacy');

Map<String, String> _sig(String origin, String text, {String keyId = 'k1'}) =>
    <String, String>{
      kSourceSignatureHeader: signSourceContent(
          origin: origin, text: text, secret: kSecret),
      kSourceKeyIdHeader: keyId,
    };

void testCanonicalAndOrigin() {
  print('\n== A. 摘要规范化与来源身份 ==');
  check('SHA-256 测试向量吻合',
      sourceContentDigest('abc') ==
          'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
  check('BOM 不改变摘要',
      sourceContentDigest('\uFEFF{"a":1}') == sourceContentDigest('{"a":1}'));
  check('CRLF 不改变摘要',
      sourceContentDigest('#EXTM3U\r\n#EXTINF:-1,A\r\nhttp://x/1.ts\r\n') ==
          sourceContentDigest('#EXTM3U\n#EXTINF:-1,A\nhttp://x/1.ts'));
  check('行尾空格不改变摘要',
      sourceContentDigest('a  \nb\t') == sourceContentDigest('a\nb'));
  check('实质内容变化必改摘要',
      sourceContentDigest('http://x/1.ts') !=
          sourceContentDigest('http://x/2.ts'));

  check('默认端口归一',
      sourceOriginOf('https://Pub.Example.com:443/a?x=1') ==
          'https://pub.example.com');
  check('非默认端口保留',
      sourceOriginOf('https://pub.example.com:8443/a') ==
          'https://pub.example.com:8443');
  check('query 不进身份',
      sourceOriginOf('https://pub.example.com/a?token=SECRET') ==
          'https://pub.example.com');
  check('拒绝内联凭据', sourceOriginOf('https://u:p@pub.example.com/a') == null);
  check('拒绝明文外网', sourceOriginOf('http://pub.example.com/a') == null);
  check('允许本机明文（回归用）',
      sourceOriginOf('http://127.0.0.1:8080/a') == 'http://127.0.0.1:8080');
  check('拒绝 file 协议', sourceOriginOf('file:///C:/a.m3u') == null);
  check('拒绝缺主机', sourceOriginOf('https:///a') == null);
  check('拒绝空串', sourceOriginOf('   ') == null);
}

Future<void> testTofu() async {
  print('\n== B. 首次使用信任 / 变更重确认 ==');
  final p = SourceTrustPolicy();
  final first = await p.check(url: kUrl, text: _cfg());
  check('首次使用要求确认', first.needsApproval);
  check('首次确认理由点明来源', first.reason.contains('pub.example.com'));
  check('未确认前信任库为空', p.length == 0);

  final a = await p.approve(url: kUrl, text: _cfg());
  check('确认后放行', a.approved);
  check('确认后落了一条记录', p.length == 1);
  check('记录带上摘要', p.records['https://pub.example.com']?.digest == a.digest);
  check('状态行不回显完整 URL', !p.statusOf(kUrl).contains('list.m3u'));

  final same = await p.check(url: kUrl, text: _cfg());
  check('内容不变直接放行', same.approved && !same.changed);

  final changed = _cfg('b');
  final bump = await p.check(url: kUrl, text: changed);
  check('内容变化要求重新确认', bump.needsApproval && bump.changed);
  check('变化理由含新旧摘要片段', bump.reason.contains('原 ') && bump.reason.contains('新 '));
  check('未确认变更不改写记录',
      p.records['https://pub.example.com']?.digest == a.digest);
  await p.approve(url: kUrl, text: changed);
  check('确认变更后记录更新',
      p.records['https://pub.example.com']?.digest == sourceContentDigest(changed));

  final pathChange = await p.check(url: kUrl2, text: changed);
  check('路径变化要求重新确认', pathChange.needsApproval);
  final otherOrigin = await p.check(url: kOtherOrigin, text: changed);
  check('换主机视作全新来源', otherOrigin.needsApproval);

  final bad = await p.check(url: 'file:///C:/x', text: changed);
  check('非法地址直接拒绝', bad.rejected);
}

Future<void> testSignature() async {
  print('\n== C. HMAC 签名与防降级 ==');
  final p = SourceTrustPolicy();
  await p.approve(url: kUrl, text: _cfg());
  await p.setSecret('https://pub.example.com', kSecret);
  check('密钥已配置', p.hasSecret('https://pub.example.com'));

  final next = _cfg('b');
  final good = _sig('https://pub.example.com', next);
  final auto = await p.check(url: kUrl, text: next, headers: good);
  check('有效签名自动放行内容更新', auto.approved && auto.changed);
  check('自动放行标记了验签成功', auto.signatureVerified);
  check('签名更新后记录转为 signed',
      p.records['https://pub.example.com']?.signed == true);
  check('签名更新后摘要已刷新',
      p.records['https://pub.example.com']?.digest == sourceContentDigest(next));

  final downgrade = await p.check(url: kUrl, text: next);
  check('曾签名来源的无签名响应被拒绝', downgrade.rejected);
  check('拒绝理由点明降级', downgrade.reason.contains('拒绝降级'));

  final manual = await p.approve(url: kUrl, text: _cfg('c'));
  check('人工确认也不能绕过签名降级', manual.rejected);

  final wrong = <String, String>{
    kSourceSignatureHeader: 'sha256=${'0' * 64}',
    kSourceKeyIdHeader: 'k1',
  };
  check('错误签名被拒绝',
      (await p.check(url: kUrl, text: _cfg('c'), headers: wrong)).rejected);

  final keyChanged = _sig('https://pub.example.com', next, keyId: 'k2');
  check('密钥标识不匹配被拒绝',
      (await p.check(url: kUrl, text: next, headers: keyChanged)).rejected);

  final q = SourceTrustPolicy();
  await q.setSecret('https://pub.example.com', kSecret);
  final signedFirst = await q.check(url: kUrl, text: _cfg(), headers: _sig('https://pub.example.com', _cfg()));
  check('首次使用即使签名有效也要人工确认', signedFirst.needsApproval);
  check('但决策里如实标记验签成功', signedFirst.signatureVerified);
  final signedApprove = await q.approve(
      url: kUrl, text: _cfg(), headers: _sig('https://pub.example.com', _cfg()));
  check('首签确认后启用签名校验',
      signedApprove.approved && q.records['https://pub.example.com']?.signed == true);

  final noSecret = SourceTrustPolicy();
  await noSecret.approve(url: kUrl, text: _cfg());
  check('没配密钥时签名头不产生任何授信',
      (await noSecret.check(
              url: kUrl,
              text: _cfg('b'),
              headers: _sig('https://pub.example.com', _cfg('b'))))
          .needsApproval);
}

Future<void> testPersistence() async {
  print('\n== D. 信任库落盘与容错 ==');
  Map<String, dynamic>? saved;
  var writes = 0;
  final p = SourceTrustPolicy(persist: (json) async {
    saved = json;
    writes++;
  });
  await p.approve(url: kUrl, text: _cfg());
  await p.setSecret('https://pub.example.com', kSecret);
  check('落盘被调用', writes == 2 && saved != null);
  check('落盘带版本号', saved?['v'] == 1);
  check('落盘不回显完整 URL 的 query', !jsonEncode(saved).contains('token='));

  final restored = SourceTrustPolicy(state: saved);
  check('重启后记录恢复', restored.length == 1);
  check('重启后密钥恢复', restored.hasSecret('https://pub.example.com'));
  check('重启后内容不变仍直接放行',
      (await restored.check(url: kUrl, text: _cfg())).approved);

  final corrupt = SourceTrustPolicy(state: <String, Object?>{
    'records': <String, Object?>{
      'https://ok.example.com': <String, Object?>{'digest': 'not-hex'},
      'https://bad\n.example.com': <String, Object?>{
        'origin': 'https://bad\n.example.com',
        'path': '/a',
        'digest': 'a' * 64,
      },
      'https://mismatch.example.com': <String, Object?>{
        'origin': 'https://ok.example.com',
        'path': '/a',
        'digest': 'a' * 64,
      },
    },
    'secrets': <String, Object?>{'https://ok.example.com': 'x'},
  });
  check('损坏/伪造记录全部跳过', corrupt.length == 0);
  check('非法 origin 的密钥不保留', !corrupt.hasSecret('https://bad\n.example.com'));

  final capped = SourceTrustPolicy();
  for (var i = 0; i < kMaxTrustedSources + 3; i++) {
    await capped.approve(url: 'https://s$i.example.com/a', text: _cfg('$i'));
  }
  check('信任库有数量上限', capped.length == kMaxTrustedSources);
  final overflow = await capped.approve(url: 'https://overflow.example.com/a', text: _cfg());
  check('超限新来源被拒绝', overflow.rejected);

  final failing = SourceTrustPolicy(persist: (_) async => throw StateError('disk full'));
  final degraded = await failing.approve(url: kUrl, text: _cfg());
  check('写盘失败不打断导入', degraded.approved);
  check('写盘失败如实标记 persisted=false', !degraded.persisted);

  final forgotten = SourceTrustPolicy(state: saved);
  await forgotten.forget('https://pub.example.com');
  check('移除来源同时移除密钥',
      forgotten.length == 0 && !forgotten.hasSecret('https://pub.example.com'));
}

class _TrustServer {
  late HttpServer _server;
  String get base => 'http://127.0.0.1:${_server.port}';

  Future<void> start(String config) async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((req) async {
      switch (req.uri.path) {
        case '/signed':
          req.response.headers.set(kSourceSignatureHeader, 'sha256=${'a' * 64}');
          req.response.headers.set(kSourceKeyIdHeader, 'k1');
          req.response.headers.set('Set-Cookie', 'session=VERY_SECRET');
          req.response.headers.add('X-Private-Token', 'leak-me');
          req.response.write(config);
          await req.response.close();
        case '/long':
          req.response.headers.set(kSourceSignatureHeader, 'a' * 300);
          req.response.write(config);
          await req.response.close();
        case '/redirect':
          req.response.statusCode = 302;
          // 中间跳给的签名不应被当成终点签名。
          req.response.headers.set(kSourceSignatureHeader, 'sha256=${'b' * 64}');
          req.response.headers.set(HttpHeaders.locationHeader, '/signed');
          await req.response.close();
        default:
          req.response.statusCode = 404;
          await req.response.close();
      }
    });
  }

  Future<void> stop() => _server.close(force: true);
}

Future<void> testHeaderBoundary() async {
  print('\n== E. 真实 HTTP 响应头采集边界 ==');
  final server = _TrustServer();
  await server.start(_cfg());
  try {
    final r = await fetchSourceConfigUrl('${server.base}/signed',
        useSystemProxy: false);
    check('下载成功', r.ok, r.message);
    check('签名头按小写键采集',
        r.headers[kSourceSignatureHeader] == 'sha256=${'a' * 64}');
    check('密钥标识头采集', r.headers[kSourceKeyIdHeader] == 'k1');
    check('Set-Cookie 不外泄', !r.headers.containsKey('set-cookie'));
    check('其它自定义头不外泄', !r.headers.containsKey('x-private-token'));
    check('只采到两个头', r.headers.length == 2);

    final l = await fetchSourceConfigUrl('${server.base}/long',
        useSystemProxy: false);
    check('超长签名值被丢弃', l.ok && l.headers.isEmpty);

    final red = await fetchSourceConfigUrl('${server.base}/redirect',
        useSystemProxy: false);
    check('同主机重定向可跟随', red.ok, red.message);
    check('只采终点签名，不采中间跳',
        red.headers[kSourceSignatureHeader] == 'sha256=${'a' * 64}');
  } finally {
    await server.stop();
  }
}

/// 与真实 SourceImportService 串联：下载器注入假响应，重点看「没确认就不注册」。
class _Harness {
  _Harness({
    required this.config,
    required this.policy,
    required this.headers,
    required this.prompts,
    required this.agree,
  }) {
    final builtin = MemorySourceAdapter(
      id: 'builtin',
      profile: const SourceProfile(name: 'builtin'),
      episodes: <String, List<EpisodeInfo>>{},
      urls: <String, List<PlayUrl>>{},
    );
    registry.register(builtin);
    catalog.register(builtin.profile);
    flow = OnboardingFlow(persist: (s) async {});
    svc = SourceImportService(
      registry: registry,
      catalog: catalog,
      flow: flow,
      readSaved: () async => null,
      writeSaved: (t) async => savedText = t,
      readUrl: (url) async => SourceConfigUrlResult.ok(
        text: config,
        originLabel: 'pub.example.com',
        bytes: utf8.encode(config).length,
        headers: headers,
      ),
      trust: policy,
      confirmTrust: (reason) async {
        prompts.add(reason);
        return agree();
      },
    );
  }

  final String config;
  final SourceTrustPolicy policy;
  final Map<String, String> headers;
  final List<String> prompts;
  final bool Function() agree;
  final SourceRegistry registry = SourceRegistry();
  final SourceCatalog catalog = SourceCatalog();
  late final OnboardingFlow flow;
  late final SourceImportService svc;
  String? savedText;
}

Future<void> testServiceIntegration() async {
  print('\n== F. 与导入服务串联 ==');
  var allow = false;
  final prompts = <String>[];
  final policy = SourceTrustPolicy();
  final h = _Harness(
    config: _cfg(),
    policy: policy,
    headers: const <String, String>{},
    prompts: prompts,
    agree: () => allow,
  );
  await h.flow.acceptDisclaimer();

  final denied = await h.svc.importFromUrl(kUrl);
  check('用户未确认 → 拒绝', denied.kind == ImportOutcomeKind.untrustedSource);
  check('拒绝时确实弹过确认', prompts.length == 1);
  check('拒绝时不注册任何源', h.svc.activeSourceIds.isEmpty);
  check('拒绝时不落盘配置', h.savedText == null);
  check('拒绝时信任库仍为空', policy.length == 0);

  allow = true;
  final accepted = await h.svc.importFromUrl(kUrl);
  check('确认后导入成功', accepted.kind == ImportOutcomeKind.applied, accepted.message);
  check('确认后源真的注册', h.svc.activeSourceIds.isNotEmpty);
  check('确认后配置落盘', h.savedText != null);
  check('确认提示累计两次', prompts.length == 2);

  final again = await h.svc.importFromUrl(kUrl);
  check('同一份内容再次导入不再打扰', again.ok && prompts.length == 2);

  // 内容变化：新建一个服务实例但复用同一信任库与入口。
  allow = false;
  final h2 = _Harness(
    config: _cfg('b'),
    policy: policy,
    headers: const <String, String>{},
    prompts: prompts,
    agree: () => allow,
  );
  await h2.flow.acceptDisclaimer();
  final changed = await h2.svc.importFromUrl(kUrl);
  check('内容变化 → 拒绝并提示确认',
      changed.kind == ImportOutcomeKind.untrustedSource && prompts.length == 3);
  check('拒绝的内容变化没有覆盖已生效源', h2.savedText == null);

  // 曾签名来源的无签名响应：即使 confirmTrust 会同意也必须被策略拒绝。
  final origin = sourceOriginOf(kUrl)!;
  await policy.setSecret(origin, kSecret);
  final signedText = _cfg('c');
  await policy.approve(
      url: kUrl, text: signedText, headers: _sig(origin, signedText));
  check('已建立签名来源', policy.records[origin]?.signed == true);
  allow = true;
  final h3 = _Harness(
    config: signedText,
    policy: policy,
    headers: const <String, String>{},
    prompts: prompts,
    agree: () => allow,
  );
  await h3.flow.acceptDisclaimer();
  final down = await h3.svc.importFromUrl(kUrl);
  check('无签名降级被服务层拒绝',
      down.kind == ImportOutcomeKind.untrustedSource &&
          down.message.contains('拒绝降级'));
  check('降级被拒时连确认框都不弹', prompts.length == 3);
}

Future<void> main() async {
  testCanonicalAndOrigin();
  await testTofu();
  await testSignature();
  await testPersistence();
  await testHeaderBoundary();
  await testServiceIntegration();
  print('\n回归通过：$_pass/${_pass + _fail} 断言通过');
  if (_fail > 0) exitCode = 1;
}
