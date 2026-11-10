// 源配置「从文件导入」的**唯一 IO 边界**（E9）。
//
// 为什么单独成模块：导入服务刻意不依赖 dart:io，以便裸 `dart run` 验证状态一致性；
// 而真正读文件时又必须处理一堆只有本地文件才有的暗坑——Windows 记事本保存的
// UTF-8 BOM 会让 jsonDecode 直接报错、复制过来的路径常带引号或 `file://` URI、
// 符号链接可能指向用户无意公开的文件、超大文件不能先读进内存再判大小。
//
// 安全模型：读取的是**用户本机自己选的文件**，因此不做目录沙箱（那会挡住 U 盘 /
// 共享目录等正常用法）；但必须保证「只把可解析的纯文本交给 JSON 解析器」，
// 且任何失败都以结构化结果返回，绝不把裸异常或原始字节抛给 UI。
//
// 纯 dart:io，不依赖 package:flutter，可在裸 `dart run` 下完整验证。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// 单个配置文件允许的最大字节数。与 `kMaxImportTextLength`（256K 字符）对齐：
/// UTF-8 解码后的字符数恒 ≤ 字节数，因此读入的文件必然不会再撞导入长度上限。
const int kMaxSourceConfigFileBytes = 256 * 1024;

/// 路径长度上限（防超长路径把异常文本与 UI 一起撑爆）。
const int kMaxSourceConfigPathLength = 4096;

/// 文件读取失败类别。UI 只展示 [SourceConfigFileResult.message]。
enum SourceConfigFileFailure {
  emptyPath,
  invalidPath,
  remotePath,
  tooLongPath,
  notFound,
  notAFile,
  symlink,
  tooLarge,
  empty,
  binary,
  invalidEncoding,
  readError,
}

/// 读取结果：成功时 [text] 非空；失败时 [failure] 非空且给出可读原因。
class SourceConfigFileResult {
  final String? text;
  final String? fileName;
  final int bytes;
  final SourceConfigFileFailure? failure;
  final String message;

  const SourceConfigFileResult._({
    required this.message,
    this.text,
    this.fileName,
    this.bytes = 0,
    this.failure,
  });

  factory SourceConfigFileResult.ok({
    required String text,
    required String fileName,
    required int bytes,
  }) =>
      SourceConfigFileResult._(
        text: text,
        fileName: fileName,
        bytes: bytes,
        message: '已读取 $fileName（$bytes 字节）',
      );

  factory SourceConfigFileResult.fail(
    SourceConfigFileFailure failure,
    String message, {
    String? fileName,
  }) =>
      SourceConfigFileResult._(
        failure: failure,
        message: message,
        fileName: fileName,
      );

  bool get ok => failure == null && text != null;

  @override
  String toString() => ok ? message : '[$failure] $message';
}

/// 路径归一化：处理用户在文件管理器里「复制路径」得到的各种形态。
///
/// - 首尾空白；
/// - 首尾成对引号（Windows 复制带空格路径时最常见）；
/// - `file:///C:/...` / `file:///home/...` URI（部分文件选择器返回 URI 而非路径）；
/// - 路径里的 NUL 会在后续以 [SourceConfigFileFailure.invalidPath] 拒绝。
///
/// 纯函数，无 IO，便于回归覆盖。URI 解析失败时原样返回，让后续按路径处理。
String normalizeSourceConfigPath(String raw) {
  var s = raw.trim();
  if (s.length >= 2) {
    final first = s.codeUnitAt(0);
    final last = s.codeUnitAt(s.length - 1);
    if ((first == 0x22 && last == 0x22) ||
        (first == 0x27 && last == 0x27)) {
      s = s.substring(1, s.length - 1).trim();
    }
  }
  if (s.toLowerCase().startsWith('file:')) {
    final uri = Uri.tryParse(s);
    if (uri != null && uri.scheme == 'file') {
      try {
        s = uri.toFilePath();
      } catch (_) {
        // 非 Windows 平台上解析 Windows file URI 会抛异常：保留原串，
        // 由读取阶段按「路径不存在」给出明确结果。
      }
    }
  }
  return s;
}

/// 只取文件名供 UI 展示，避免把完整本机路径回显到界面/日志；超长时截断。
String sourceConfigFileName(String path) {
  final name = path.split(RegExp(r'[\\/]')).where((p) => p.isNotEmpty).toList();
  final base = name.isEmpty ? '配置' : name.last;
  return base.length <= 80 ? base : '${base.substring(0, 77)}...';
}

/// 路径合法性检查结果。
///
/// 读（导入）与写（导出）共用**同一套**路径规则：远程/UNC 拒绝、长度上限、
/// NUL 拒绝。分开写两份迟早会漂移 —— 而这类漂移就是漏洞。
class _PathCheck {
  final String path;
  final String name;
  final SourceConfigFileFailure? failure;
  final String message;

  const _PathCheck(this.path, this.name, this.failure, this.message);

  bool get ok => failure == null;

  factory _PathCheck.passed(String path) =>
      _PathCheck(path, sourceConfigFileName(path), null, '');

  factory _PathCheck.failed(
          SourceConfigFileFailure failure, String message,
          {String name = ''}) =>
      _PathCheck('', name, failure, message);
}

_PathCheck _checkPath(String rawPath) {
  final rawLength = rawPath.trim().length;
  if (rawLength == 0) {
    return _PathCheck.failed(
        SourceConfigFileFailure.emptyPath, '请先填写配置文件路径');
  }
  if (rawLength > kMaxSourceConfigPathLength * 2) {
    return _PathCheck.failed(
        SourceConfigFileFailure.tooLongPath, '路径过长（超过字符上限）');
  }

  final path = normalizeSourceConfigPath(rawPath);
  final name = sourceConfigFileName(path);
  if (path.isEmpty) {
    return _PathCheck.failed(
        SourceConfigFileFailure.emptyPath, '请先填写配置文件路径');
  }
  if (path.length > kMaxSourceConfigPathLength) {
    return _PathCheck.failed(
        SourceConfigFileFailure.tooLongPath, '路径过长（超过字符上限）',
        name: name);
  }
  if (path.contains('\u0000')) {
    return _PathCheck.failed(
        SourceConfigFileFailure.invalidPath, '路径含非法字符',
        name: name);
  }
  // 立项前提是纯本地、不扩网络攻击面：`file://host/...` 与 UNC 路径会让一次
  // 看似本地的读写变成 SMB 请求，显式拒绝；`\\?\` 是 Windows 本地扩展长度前缀，
  // 放行。`localhost` 作为 file URI 的 host 等价于本机。
  var candidate = rawPath.trim();
  if (candidate.length >= 2) {
    final first = candidate.codeUnitAt(0);
    final last = candidate.codeUnitAt(candidate.length - 1);
    if ((first == 0x22 && last == 0x22) ||
        (first == 0x27 && last == 0x27)) {
      candidate = candidate.substring(1, candidate.length - 1).trim();
    }
  }
  if (candidate.toLowerCase().startsWith('file:')) {
    final uri = Uri.tryParse(candidate);
    if (uri != null &&
        uri.scheme == 'file' &&
        uri.host.isNotEmpty &&
        uri.host.toLowerCase() != 'localhost') {
      return _PathCheck.failed(
          SourceConfigFileFailure.remotePath,
          '不支持远程主机路径（file://host/...）',
          name: name);
    }
  }
  if ((path.startsWith(r'\\') && !path.startsWith(r'\\?\')) ||
      (path.startsWith('//') && !path.startsWith('///'))) {
    return _PathCheck.failed(
        SourceConfigFileFailure.remotePath, '不支持 UNC 网络路径',
        name: name);
  }
  return _PathCheck.passed(path);
}

/// 读取一份本地源配置文件。
///
/// 检查顺序刻意是「路径 → 类型（不跟随链接）→ 体积 → 字节 → 编码」：
/// 先用 stat 挡超大文件，避免把几百 MB 读进内存后才拒绝。
Future<SourceConfigFileResult> readSourceConfigFile(
  String rawPath, {
  int maxBytes = kMaxSourceConfigFileBytes,
}) async {
  final check = _checkPath(rawPath);
  if (!check.ok) {
    return SourceConfigFileResult.fail(
      check.failure!,
      check.message,
      fileName: check.name.isEmpty ? null : check.name,
    );
  }
  final path = check.path;
  final name = check.name;

  FileSystemEntityType type;
  try {
    // followLinks:false 是关键：若允许跟随，用户可能无意中把指向系统文件
    // 的链接当成普通 JSON 读进来，且后续 stat/readAsBytes 都会跟着走。
    type = await FileSystemEntity.type(path, followLinks: false);
  } catch (_) {
    return SourceConfigFileResult.fail(
        SourceConfigFileFailure.readError, '无法访问 $name',
        fileName: name);
  }
  if (type == FileSystemEntityType.notFound) {
    return SourceConfigFileResult.fail(
        SourceConfigFileFailure.notFound, '文件不存在：$name',
        fileName: name);
  }
  if (type == FileSystemEntityType.link) {
    return SourceConfigFileResult.fail(
        SourceConfigFileFailure.symlink, '不支持符号链接，请改选实际文件：$name',
        fileName: name);
  }
  if (type != FileSystemEntityType.file) {
    return SourceConfigFileResult.fail(
        SourceConfigFileFailure.notAFile, '这不是普通文件（可能是目录）：$name',
        fileName: name);
  }

  final file = File(path);
  int size;
  try {
    final stat = await file.stat();
    if (stat.type == FileSystemEntityType.notFound) {
      return SourceConfigFileResult.fail(
          SourceConfigFileFailure.notFound, '文件不存在：$name',
          fileName: name);
    }
    size = stat.size;
  } catch (_) {
    return SourceConfigFileResult.fail(
        SourceConfigFileFailure.readError, '无法读取 $name 的文件信息',
        fileName: name);
  }
  if (size > maxBytes) {
    return SourceConfigFileResult.fail(
        SourceConfigFileFailure.tooLarge,
        '文件过大（$size 字节，上限 ${maxBytes ~/ 1024} KB）',
        fileName: name);
  }
  if (size == 0) {
    return SourceConfigFileResult.fail(
        SourceConfigFileFailure.empty, '文件为空：$name',
        fileName: name);
  }

  Uint8List bytes;
  try {
    bytes = await file.readAsBytes();
  } catch (_) {
    return SourceConfigFileResult.fail(
        SourceConfigFileFailure.readError, '读取失败：$name',
        fileName: name);
  }
  // TOCTOU 二次校验：stat 之后文件可能已被别的进程替换/追加。
  if (bytes.length > maxBytes) {
    return SourceConfigFileResult.fail(
        SourceConfigFileFailure.tooLarge,
        '文件过大（${bytes.length} 字节，上限 ${maxBytes ~/ 1024} KB）',
        fileName: name);
  }
  if (bytes.isEmpty) {
    return SourceConfigFileResult.fail(
        SourceConfigFileFailure.empty, '文件为空：$name',
        fileName: name);
  }

  var start = 0;
  if (bytes.length >= 3 &&
      bytes[0] == 0xEF &&
      bytes[1] == 0xBB &&
      bytes[2] == 0xBF) {
    start = 3; // UTF-8 BOM：jsonDecode 不接受，剥离后再解析。
  }
  final body = bytes.sublist(start);
  if (body.isEmpty) {
    return SourceConfigFileResult.fail(
        SourceConfigFileFailure.empty, '文件仅含 BOM，没有配置内容：$name',
        fileName: name);
  }
  for (final b in body) {
    if (b == 0) {
      return SourceConfigFileResult.fail(
          SourceConfigFileFailure.binary, '这不是文本文件（含 NUL 字节）：$name',
          fileName: name);
    }
  }

  String text;
  try {
    text = utf8.decode(body, allowMalformed: false);
  } catch (_) {
    return SourceConfigFileResult.fail(
        SourceConfigFileFailure.invalidEncoding,
        '文件不是 UTF-8 编码（请另存为 UTF-8）：$name',
        fileName: name);
  }
  // 双重 BOM 或 BOM 位于解码文本首部时 jsonDecode 仍会失败。
  while (text.startsWith('\uFEFF')) {
    text = text.substring(1);
  }
  if (text.trim().isEmpty) {
    return SourceConfigFileResult.fail(
        SourceConfigFileFailure.empty, '文件没有配置内容：$name',
        fileName: name);
  }
  return SourceConfigFileResult.ok(
    text: text,
    fileName: name,
    bytes: bytes.length,
  );
}

// ---------------------------------------------------------------------------
// 导出（与导入对称：同一套路径规则、同一体积上限、同样只碰纯文本）
// ---------------------------------------------------------------------------

/// 写入失败类别。路径类失败与读取共用同一套判定。
enum SourceConfigFileWriteFailure {
  emptyPath,
  invalidPath,
  remotePath,
  tooLongPath,
  notAFile,
  symlink,
  parentMissing,
  alreadyExists,
  tooLarge,
  noContent,
  writeError,
}

/// 写入结果。成功时 [bytes] 为真实写入字节数。
class SourceConfigFileWriteResult {
  final String? fileName;
  final int bytes;
  final SourceConfigFileWriteFailure? failure;
  final String message;

  const SourceConfigFileWriteResult._({
    required this.message,
    this.fileName,
    this.bytes = 0,
    this.failure,
  });

  factory SourceConfigFileWriteResult.written({
    required String fileName,
    required int bytes,
  }) =>
      SourceConfigFileWriteResult._(
        fileName: fileName,
        bytes: bytes,
        message: '已导出到 $fileName（$bytes 字节）',
      );

  factory SourceConfigFileWriteResult.fail(
    SourceConfigFileWriteFailure failure,
    String message, {
    String? fileName,
  }) =>
      SourceConfigFileWriteResult._(
        failure: failure,
        message: message,
        fileName: fileName,
      );

  bool get ok => failure == null;

  @override
  String toString() => ok ? message : '[$failure] $message';
}

SourceConfigFileWriteFailure _mapPathFailure(SourceConfigFileFailure f) {
  switch (f) {
    case SourceConfigFileFailure.emptyPath:
      return SourceConfigFileWriteFailure.emptyPath;
    case SourceConfigFileFailure.invalidPath:
      return SourceConfigFileWriteFailure.invalidPath;
    case SourceConfigFileFailure.remotePath:
      return SourceConfigFileWriteFailure.remotePath;
    case SourceConfigFileFailure.tooLongPath:
      return SourceConfigFileWriteFailure.tooLongPath;
    case SourceConfigFileFailure.notAFile:
      return SourceConfigFileWriteFailure.notAFile;
    case SourceConfigFileFailure.symlink:
      return SourceConfigFileWriteFailure.symlink;
    default:
      return SourceConfigFileWriteFailure.writeError;
  }
}

/// 把源配置文本写到本机文件（配置备份 / 迁移用）。
///
/// 刻意保守的三点：
/// 1. **默认不覆盖已有文件**，需显式 `overwrite: true`；覆盖时先备份再换名，
///    失败会回滚，避免把用户原文件写坏一半；
/// 2. **不创建父目录**——路径写错时应该报错，而不是在磁盘上默默长出一串目录；
/// 3. 拒绝目录、符号链接与远程/UNC 路径，与读取侧完全一致。
Future<SourceConfigFileWriteResult> writeSourceConfigFile(
  String rawPath,
  String text, {
  bool overwrite = false,
  int maxBytes = kMaxSourceConfigFileBytes,
}) async {
  final check = _checkPath(rawPath);
  if (!check.ok) {
    return SourceConfigFileWriteResult.fail(
      _mapPathFailure(check.failure!),
      check.message,
      fileName: check.name.isEmpty ? null : check.name,
    );
  }
  final path = check.path;
  final name = check.name;

  if (text.trim().isEmpty) {
    return SourceConfigFileWriteResult.fail(
        SourceConfigFileWriteFailure.noContent, '没有可导出的配置内容',
        fileName: name);
  }
  final data = utf8.encode(text);
  if (data.length > maxBytes) {
    return SourceConfigFileWriteResult.fail(
        SourceConfigFileWriteFailure.tooLarge,
        '配置过大（${data.length} 字节，上限 ${maxBytes ~/ 1024} KB）',
        fileName: name);
  }

  FileSystemEntityType type;
  try {
    type = await FileSystemEntity.type(path, followLinks: false);
  } catch (_) {
    return SourceConfigFileWriteResult.fail(
        SourceConfigFileWriteFailure.writeError, '无法访问 $name',
        fileName: name);
  }
  if (type == FileSystemEntityType.link) {
    return SourceConfigFileWriteResult.fail(
        SourceConfigFileWriteFailure.symlink, '不支持写入符号链接：$name',
        fileName: name);
  }
  if (type != FileSystemEntityType.notFound &&
      type != FileSystemEntityType.file) {
    return SourceConfigFileWriteResult.fail(
        SourceConfigFileWriteFailure.notAFile, '这不是普通文件（可能是目录）：$name',
        fileName: name);
  }
  final exists = type == FileSystemEntityType.file;
  if (exists && !overwrite) {
    return SourceConfigFileWriteResult.fail(
        SourceConfigFileWriteFailure.alreadyExists,
        '目标文件已存在（勾选「允许覆盖」后重试）：$name',
        fileName: name);
  }

  final target = File(path);
  try {
    if (!await target.parent.exists()) {
      return SourceConfigFileWriteResult.fail(
          SourceConfigFileWriteFailure.parentMissing,
          '目标目录不存在：$name',
          fileName: name);
    }
  } catch (_) {
    return SourceConfigFileWriteResult.fail(
        SourceConfigFileWriteFailure.writeError, '无法访问目标目录：$name',
        fileName: name);
  }

  // 后缀带 shunbo 前缀，避免与用户自己恰好同名的 .tmp/.bak 冲突。
  final tmp = File('$path.shunbo-tmp');
  final bak = File('$path.shunbo-bak');
  try {
    await tmp.writeAsString(text, flush: true);
    if (exists) {
      if (await bak.exists()) await bak.delete();
      await target.rename(bak.path);
      try {
        await tmp.rename(path);
      } catch (_) {
        // 换名失败：把备份换回去，绝不留下「目标文件消失了」的状态。
        if (await bak.exists() && !await target.exists()) {
          await bak.rename(path);
        }
        rethrow;
      }
      if (await bak.exists()) await bak.delete();
    } else {
      await tmp.rename(path);
    }
  } catch (e) {
    try {
      if (await tmp.exists()) await tmp.delete();
    } catch (_) {
      // 清理失败可忽略：临时文件不会影响目标文件。
    }
    return SourceConfigFileWriteResult.fail(
        SourceConfigFileWriteFailure.writeError, '写入失败：$name（$e）',
        fileName: name);
  }
  return SourceConfigFileWriteResult.written(
      fileName: name, bytes: data.length);
}
