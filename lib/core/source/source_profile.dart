/// 源画像：描述单个「源」的集数偏移与广告插入模型。
///
/// 设计稿 #1 暗坑（换源无感切换 + 集数/时间错位对齐）的核心数据模型。
/// 该结构由 M0 纯逻辑原型（spike/）验证，此处为 Dart 移植，语义 1:1 对应。
///
/// - [episodeOffset]：rawEpisode = canonicalEpisode + episodeOffset
/// - [adInterval] / [adDuration]：两次广告间隔秒数 / 每次广告时长（0 表示无广告）
class SourceProfile {
  final String name;
  final int episodeOffset;
  final double adInterval;
  final double adDuration;

  const SourceProfile({
    required this.name,
    this.episodeOffset = 0,
    this.adInterval = 0.0,
    this.adDuration = 0.0,
  });

  /// 原始时间戳对应的广告累计秒数。
  double adSeconds(double rawSeconds) {
    if (adInterval <= 0 || adDuration <= 0) return 0.0;
    return adDuration * (rawSeconds / adInterval).floorToDouble();
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SourceProfile &&
          other.name == name &&
          other.episodeOffset == episodeOffset &&
          other.adInterval == adInterval &&
          other.adDuration == adDuration;

  @override
  int get hashCode =>
      name.hashCode ^
      episodeOffset.hashCode ^
      adInterval.hashCode ^
      adDuration.hashCode;

  @override
  String toString() =>
      'SourceProfile(name=$name, epOff=$episodeOffset, adInt=$adInterval, adDur=$adDuration)';
}
