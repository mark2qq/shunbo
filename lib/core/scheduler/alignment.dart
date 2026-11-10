import '../source/source_profile.dart';

/// 换源对齐核心算法（M0 验证，Dart 移植）。
///
/// 以「规范内容坐标 (episode, contentSeconds)」为全局基准（去掉广告后的真实内容位置），
/// 每个源用 [SourceProfile] 映射到「源原始坐标 (rawEpisode, rawSeconds)」（含广告）。
/// 换源 = 源A原始 → 规范 → 源B原始，确保用户续播在「正确内容位置」而非原始时间戳。
///
/// 返回统一用 Dart Record `(int episode, double seconds)`，跨库可见。

/// 源原始坐标 → 规范内容坐标。
(int, double) rawToContent(SourceProfile p, int rawEpisode, double rawSeconds) {
  final canonicalEpisode = rawEpisode - p.episodeOffset;
  final contentSeconds = rawSeconds - p.adSeconds(rawSeconds);
  return (canonicalEpisode, contentSeconds);
}

/// 规范内容坐标 → 源原始坐标（广告锯齿映射的精确逆运算）。
(int, double) contentToRaw(SourceProfile p, int canonicalEpisode, double contentSeconds) {
  final rawEpisode = canonicalEpisode + p.episodeOffset;
  if (p.adInterval <= 0 || p.adDuration <= 0) {
    return (rawEpisode, contentSeconds);
  }
  // 求 k 使 raw = content + k*adDuration 且 floor(raw/adInterval) == k
  for (var k = 0; k < 100000; k++) {
    final rawSeconds = contentSeconds + k * p.adDuration;
    if ((rawSeconds / p.adInterval).floor() == k) {
      return (rawEpisode, rawSeconds);
    }
  }
  throw ArgumentError('contentToRaw: 无法在合理范围内求解广告逆映射');
}

/// 在 from 源某原始位置，换到 to 源应落在的原始位置（内容对齐）。
(int, double) switchSource(
  SourceProfile fromP,
  SourceProfile toP,
  int fromRawEpisode,
  double fromRawSeconds,
) {
  final c = rawToContent(fromP, fromRawEpisode, fromRawSeconds);
  return contentToRaw(toP, c.$1, c.$2);
}

/// 用一次「用户确认两源同一内容位置」的样本，反解 to 源的偏移与广告时长。
///
/// 假设 toP 的 [SourceProfile.adInterval] 已知（沿用入参值），仅求 episodeOffset 与 adDuration。
/// 若样本落在首个广告前（floor(toRawSeconds/adInterval)==0），广告时长无法唯一确定，保持入参值。
SourceProfile calibrate(
  SourceProfile fromP,
  SourceProfile toP,
  int fromRawEpisode,
  double fromRawSeconds,
  int toRawEpisode,
  double toRawSeconds,
) {
  final c = rawToContent(fromP, fromRawEpisode, fromRawSeconds);
  final newOffset = toRawEpisode - c.$1;
  var newDuration = toP.adDuration;
  if (toP.adInterval > 0) {
    final k = (toRawSeconds / toP.adInterval).floor();
    if (k > 0) newDuration = (toRawSeconds - c.$2) / k;
  }
  return SourceProfile(
    name: toP.name,
    episodeOffset: newOffset,
    adInterval: toP.adInterval,
    adDuration: newDuration,
  );
}
