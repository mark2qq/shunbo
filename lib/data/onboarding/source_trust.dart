// E9 补完：URL / 订阅导入的「来源可信度与签名校验」。
//
// `source_config_url.dart` 已经把**传输层**收紧到极致（仅 https、禁 userinfo、
// 逐跳同源、禁降级、字节/UTF-8/超时上限），但那只能证明「这 256KB 是从用户
// 填的那个主机拿来的」，证不了「这个主机今天下发的内容还是用户上次认可的那份」，
// 更证不了「换个镜像/被劫持后仍是同一个发布者」。下载成功 ≠ 内容可信。
//
// 本模块补的是**内容层**四道闸：
// 1. 首次使用信任（TOFU）：第一次从某 origin 下载必须用户显式确认，确认后固定
//    规范化文本的 SHA-256 摘要与路径；以后内容一变就再次要求确认。
// 2. 来源绑定：信任记录按 origin(scheme+host+port) + path 索引，换主机、换路径、
//    https→http 降级一律不复用旧结论。
// 3. 可选签名：发布者在响应头给 `X-Shunbo-Signature: sha256=<HMAC-SHA256>`，
//    用户在本机填对应共享密钥。验签通过的内容更新可**自动**放行（发布者已授权）。
//    这是 webhook 式共享密钥，不是公钥签名：能防镜像替换/中间人改包，
//    防不了「拿到密钥的人」；因此密钥只保存在本机、不随配置导出。
// 4. 防降级：一条曾经带有效签名的来源，后来给出无签名或验签失败的响应，
//    即使有用户点确认也一律拒绝——否则攻击者只要诱导用户点一次「确定」
//    就能把签名保护整个摘掉。
//
// 纯 Dart（只依赖已缓存的 package:crypto），裸 `dart run` 回归可直接 import。
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'source_config_url.dart';

/// 最多记住多少个来源，防止信任库无限膨胀。
const int kMaxTrustedSources = 32;

/// 共享密钥长度上限。
const int kMaxTrustSecretLength = 256;

final RegExp _sha256Hex = RegExp(r'^[0-9a-f]{64}$');

/// 规范化：去 BOM、CRLF→LF、逐行去尾部空白、整体去首尾空白。
///
/// 目的不是「美化配置」，而是让「服务器只是把行尾空格改了」不触发一次
/// 无意义的人工确认；同时任何实质字符变化都必然改变摘要。
String canonicalizeSourceText(String text) {
  var s = text;
  if (s.startsWith('\uFEFF')) s = s.substring(1);
  s = s.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  return s.split('\n').map((l) => l.trimRight()).join('\n').trim();
}

/// 规范化文本的内容摘要。
String sourceContentDigest(String text) =>
    sha256.convert(utf8.encode(canonicalizeSourceText(text))).toString();

/// 来源身份：`scheme://host[:非默认端口]`。不含 path / query / userinfo。
///
/// 返回 null 表示这个地址根本不配进入信任库（非 https、明文外网、内联凭据…）。
String? sourceOriginOf(String rawUrl) {
  final u = Uri.tryParse(rawUrl.trim());
  if (u == null || u.host.isEmpty) return null;
  if (u.userInfo.isNotEmpty) return null;
  if (u.scheme != 'https' && u.scheme != 'http') return null;
  if (u.scheme == 'http' && !isLoopbackHost(u.host)) return null;
  final defaultPort = u.scheme == 'https' ? 443 : 80;
  final port = (u.hasPort && u.port != defaultPort) ? ':${u.port}' : '';
  return '${u.scheme}://${u.host.toLowerCase()}$port';
}

/// 一条已确认来源的固定结论。
class SourceTrustRecord {
  const SourceTrustRecord({
    required this.origin,
    required this.path,
    required this.digest,
    required this.signed,
    required this.firstSeenAt,
    required this.updatedAt,
    this.keyId = '',
  });

  final String origin;
  final String path;
  final String digest;
  final bool signed;
  final String firstSeenAt;
  final String updatedAt;
  final String keyId;

  SourceTrustRecord copyWith({
    String? path,
    String? digest,
    bool? signed,
    String? updatedAt,
    String? keyId,
  }) =>
      SourceTrustRecord(
        origin: origin,
        path: path ?? this.path,
        digest: digest ?? this.digest,
        signed: signed ?? this.signed,
        firstSeenAt: firstSeenAt,
        updatedAt: updatedAt ?? this.updatedAt,
        keyId: keyId ?? this.keyId,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'origin': origin,
        'path': path,
        'digest': digest,
        'signed': signed,
        'keyId': keyId,
        'firstSeenAt': firstSeenAt,
        'updatedAt': updatedAt,
      };

  /// 损坏 / 伪造的落盘记录一律跳过，绝不让一条脏数据把整个信任库带崩。
  static SourceTrustRecord? tryDecode(Object? raw) {
    if (raw is! Map) return null;
    final origin = raw['origin'];
    final path = raw['path'];
    final digest = raw['digest'];
    if (origin is! String ||
        path is! String ||
        digest is! String ||
        origin.isEmpty ||
        origin.length > 253 ||
        path.length > 512 ||
        !_sha256Hex.hasMatch(digest.toLowerCase())) {
      return null;
    }
    if (origin.contains('\n') || path.contains('\n')) return null;
    return SourceTrustRecord(
      origin: origin,
      path: path,
      digest: digest.toLowerCase(),
      signed: raw['signed'] == true,
      keyId: raw['keyId'] is String ? (raw['keyId'] as String) : '',
      firstSeenAt: raw['firstSeenAt'] is String ? raw['firstSeenAt'] as String : '',
      updatedAt: raw['updatedAt'] is String ? raw['updatedAt'] as String : '',
    );
  }
}

enum SourceTrustVerdict { approved, needsApproval, rejected }

class SourceTrustDecision {
  const SourceTrustDecision({
    required this.verdict,
    required this.reason,
    required this.origin,
    required this.digest,
    this.changed = false,
    this.signatureVerified = false,
    this.persisted = true,
  });

  final SourceTrustVerdict verdict;
  final String reason;
  final String origin;
  final String digest;

  /// 内容相对上次确认发生了变化。
  final bool changed;

  /// 本次响应的分离签名有效。
  final bool signatureVerified;

  /// 信任记录是否成功落盘。false 时重启会回到「首次使用」状态。
  final bool persisted;

  bool get approved => verdict == SourceTrustVerdict.approved;
  bool get needsApproval => verdict == SourceTrustVerdict.needsApproval;
  bool get rejected => verdict == SourceTrustVerdict.rejected;
}

/// 信任策略：判定 + 记录 + 落盘。
///
/// [persist] 由装配层注入（复用 `FileConfigStore.saveState` 的原子写）。
/// 不注入时策略仍完全可用，只是不跨重启——回归就走这条路。
class SourceTrustPolicy {
  SourceTrustPolicy({
    Map<String, Object?>? state,
    this.persist,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now {
    if (state != null) load(state);
  }

  final DateTime Function() _clock;
  final Future<void> Function(Map<String, dynamic> json)? persist;

  final Map<String, SourceTrustRecord> _records = <String, SourceTrustRecord>{};
  final Map<String, String> _secrets = <String, String>{};

  int get length => _records.length;

  Map<String, SourceTrustRecord> get records =>
      Map<String, SourceTrustRecord>.unmodifiable(_records);

  bool hasSecret(String origin) => (_secrets[origin] ?? '').isNotEmpty;

  /// 诊断/设置页只回显短摘要，绝不回显完整 URL（query 里可能有私有 token）
  /// 也不回显密钥。
  String statusOf(String rawUrl) {
    final origin = sourceOriginOf(rawUrl);
    if (origin == null) return '地址不合法';
    final r = _records[origin];
    if (r == null) return '未确认来源';
    return '已固定 ${r.digest.substring(0, 12)}…'
        '${r.signed ? ' · 签名校验' : ''}'
        '${hasSecret(origin) ? ' · 已配置密钥' : ''}';
  }

  void load(Map<String, Object?> state) {
    _records.clear();
    _secrets.clear();
    final records = state['records'];
    if (records is Map) {
      for (final entry in records.entries) {
        if (_records.length >= kMaxTrustedSources) break;
        final r = SourceTrustRecord.tryDecode(entry.value);
        final key = '${entry.key}';
        if (r == null || r.origin != key || sourceOriginOf(key) == null) continue;
        _records[key] = r;
      }
    }
    final secrets = state['secrets'];
    if (secrets is Map) {
      for (final entry in secrets.entries) {
        if (_secrets.length >= kMaxTrustedSources) break;
        final key = '${entry.key}';
        final value = entry.value;
        if (value is! String || value.isEmpty || value.length > kMaxTrustSecretLength) {
          continue;
        }
        // 允许「先配密钥、后首次确认」；但只保留 origin 本身合法的密钥，
        // 不给损坏/伪造的键留下可被引用的秘密。
        if (sourceOriginOf(key) == null) continue;
        _secrets[key] = value;
      }
    }
  }

  Map<String, dynamic> encode() => <String, dynamic>{
        'v': 1,
        'records': <String, dynamic>{
          for (final e in _records.entries) e.key: e.value.toJson(),
        },
        'secrets': <String, dynamic>{..._secrets},
      };

  Future<void> setSecret(String origin, String secret) async {
    if (sourceOriginOf(origin) == null) return;
    final trimmed = secret.trim();
    if (trimmed.isEmpty || trimmed.length > kMaxTrustSecretLength) {
      _secrets.remove(origin);
    } else {
      _secrets[origin] = trimmed;
    }
    await _flush();
  }

  Future<void> forget(String origin) async {
    _records.remove(origin);
    _secrets.remove(origin);
    await _flush();
  }

  /// 判定一次下载。验签通过的内容更新会在这里自动放行并落盘。
  Future<SourceTrustDecision> check({
    required String url,
    required String text,
    Map<String, String> headers = const <String, String>{},
  }) async {
    final origin = sourceOriginOf(url);
    if (origin == null) {
      return SourceTrustDecision(
        verdict: SourceTrustVerdict.rejected,
        reason: '来源地址不合法（需要 https，明文 http 只允许本机）',
        origin: '',
        digest: '',
      );
    }
    final digest = sourceContentDigest(text);
    final u = Uri.tryParse(url.trim());
    final path = u?.path ?? '';
    final record = _records[origin];
    final sig = _verifySignature(origin, digest, headers);

    if (record == null) {
      // 即便签名有效，首次使用也必须人工确认：否则任何持有共享密钥的人
      // 都能在用户不知情时给 App 增加一个「已信任」的发布来源。
      return SourceTrustDecision(
        verdict: SourceTrustVerdict.needsApproval,
        reason: '首次使用来源 $origin，确认后将固定其内容摘要；'
            '以后内容变化会再次询问',
        origin: origin,
        digest: digest,
        signatureVerified: sig,
      );
    }
    if (record.signed && !sig) {
      return SourceTrustDecision(
        verdict: SourceTrustVerdict.rejected,
        reason: '该来源此前使用签名校验，本次没有有效签名，拒绝降级',
        origin: origin,
        digest: digest,
      );
    }
    if (record.path != path && !sig) {
      return SourceTrustDecision(
        verdict: SourceTrustVerdict.needsApproval,
        reason: '来源路径从 ${record.path} 变为 $path，请确认后重新固定摘要',
        origin: origin,
        digest: digest,
      );
    }
    if (record.digest != digest) {
      if (!sig) {
        return SourceTrustDecision(
          verdict: SourceTrustVerdict.needsApproval,
          reason: '来源内容已变化（原 ${record.digest.substring(0, 12)}… / '
              '新 ${digest.substring(0, 12)}…），请确认是否接受新版本',
          origin: origin,
          digest: digest,
          changed: true,
        );
      }
      final next = record.copyWith(
        path: path,
        digest: digest,
        signed: true,
        keyId: _keyId(headers, fallback: record.keyId),
        updatedAt: _now(),
      );
      _records[origin] = next;
      final persisted = await _flush();
      return SourceTrustDecision(
        verdict: SourceTrustVerdict.approved,
        reason: '发布者签名有效，已自动接受内容更新',
        origin: origin,
        digest: digest,
        changed: true,
        signatureVerified: true,
        persisted: persisted,
      );
    }
    if (record.signed && !_keyIdMatches(record, headers)) {
      return SourceTrustDecision(
        verdict: SourceTrustVerdict.rejected,
        reason: '签名密钥标识与上次确认的不一致，已拒绝',
        origin: origin,
        digest: digest,
      );
    }
    return SourceTrustDecision(
      verdict: SourceTrustVerdict.approved,
      reason: record.signed ? '摘要一致且签名有效' : '摘要与上次确认一致',
      origin: origin,
      digest: digest,
      signatureVerified: sig,
    );
  }

  /// 用户确认后固定（或更新）一条来源。
  ///
  /// 注意：已有的「签名来源」无签名更新在这里同样拒绝，避免绕过 [check]
  /// 的防降级判定。
  Future<SourceTrustDecision> approve({
    required String url,
    required String text,
    Map<String, String> headers = const <String, String>{},
  }) async {
    final origin = sourceOriginOf(url);
    if (origin == null) {
      return const SourceTrustDecision(
        verdict: SourceTrustVerdict.rejected,
        reason: '来源地址不合法',
        origin: '',
        digest: '',
      );
    }
    final digest = sourceContentDigest(text);
    final sig = _verifySignature(origin, digest, headers);
    final existing = _records[origin];
    if (existing != null && existing.signed && !sig) {
      return SourceTrustDecision(
        verdict: SourceTrustVerdict.rejected,
        reason: '该来源此前使用签名校验，未验签的更新不能人工放行',
        origin: origin,
        digest: digest,
      );
    }
    if (existing == null && _records.length >= kMaxTrustedSources) {
      return SourceTrustDecision(
        verdict: SourceTrustVerdict.rejected,
        reason: '信任来源数量已达上限（$kMaxTrustedSources），请先移除一条',
        origin: origin,
        digest: digest,
      );
    }
    final now = _now();
    _records[origin] = SourceTrustRecord(
      origin: origin,
      path: Uri.tryParse(url.trim())?.path ?? '',
      digest: digest,
      signed: sig,
      firstSeenAt: existing?.firstSeenAt ?? now,
      updatedAt: now,
      keyId: _keyId(headers, fallback: existing?.keyId ?? ''),
    );
    final persisted = await _flush();
    return SourceTrustDecision(
      verdict: SourceTrustVerdict.approved,
      reason: sig ? '已确认来源并启用签名校验' : '已确认来源并固定内容摘要',
      origin: origin,
      digest: digest,
      changed: existing != null,
      signatureVerified: sig,
      persisted: persisted,
    );
  }

  bool _verifySignature(
      String origin, String digest, Map<String, String> headers) {
    final secret = _secrets[origin];
    if (secret == null || secret.isEmpty) return false;
    final raw = headers[kSourceSignatureHeader];
    if (raw == null || !raw.startsWith('sha256=')) return false;
    final got = raw.substring(7).toLowerCase();
    if (!_sha256Hex.hasMatch(got)) return false;
    final expected = Hmac(sha256, utf8.encode(secret))
        .convert(utf8.encode('$origin\n$digest'))
        .toString();
    return _constantTimeEquals(got, expected);
  }

  static String _keyId(Map<String, String> headers, {required String fallback}) {
    final v = headers[kSourceKeyIdHeader]?.trim() ?? '';
    if (v.isEmpty || v.length > 64) return fallback;
    return v;
  }

  static bool _keyIdMatches(
          SourceTrustRecord record, Map<String, String> headers) =>
      record.keyId.isEmpty || _keyId(headers, fallback: record.keyId) == record.keyId;

  static bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }

  /// 返回是否成功落盘；写失败不抛，但会在决策理由里如实提示。
  Future<bool> _flush() async {
    final p = persist;
    if (p == null) return true;
    try {
      await p(encode());
      return true;
    } catch (_) {
      return false;
    }
  }

  String _now() => _clock().toUtc().toIso8601String().split('.').first + 'Z';
}

/// 生成发布者侧签名（工具/回归用；App 本身只验签）。
String signSourceContent({
  required String origin,
  required String text,
  required String secret,
}) {
  final digest = sourceContentDigest(text);
  return 'sha256=' +
      Hmac(sha256, utf8.encode(secret))
          .convert(utf8.encode('$origin\n$digest'))
          .toString();
}
