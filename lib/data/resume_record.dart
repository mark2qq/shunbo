/// 续播记录（E6 跨端续播的数据模型）。
///
/// 设计要点：只存 **去广告的规范内容坐标**（[canonicalEpisode] / [canonicalSeconds]），
/// **不存源原始坐标**。无论用户上次用哪个源、该源是否有广告，换端/换源后都能由调度层
/// （alignment.dart）重新对齐到正确的物理位置——这是"跨端续播"的核心前提。
class ResumeRecord {
  final String mediaId;
  final String title;

  /// 上次所用源（仅作提示；续播时可回退到其他当前平台可用源）。
  final String sourceId;

  /// 规范集数（去广告）。
  final int canonicalEpisode;

  /// 规范内容秒（去广告）。
  final double canonicalSeconds;

  /// 该集是否已播完（E6 片尾判定）。
  ///
  /// 只存坐标而不存这个标记，会出现「下次续播从最后 30 秒开始」——用户明明看完了，
  /// 却被送回片尾字幕。有了它，上层可以选择「直接播下一集」或「重看本集」。
  ///
  /// 缺省 false，保证旧版本落盘数据（无此字段）读回来仍然是「未看完」。
  final bool finished;

  final DateTime updatedAt;

  const ResumeRecord({
    required this.mediaId,
    required this.title,
    required this.sourceId,
    required this.canonicalEpisode,
    required this.canonicalSeconds,
    this.finished = false,
    required this.updatedAt,
  });

  /// JSON 序列化（[FileResumeStore] 落盘用；字段缺省值兼容旧版本数据）。
  Map<String, dynamic> toJson() => <String, dynamic>{
        'mediaId': mediaId,
        'title': title,
        'sourceId': sourceId,
        'canonicalEpisode': canonicalEpisode,
        'canonicalSeconds': canonicalSeconds,
        // 只在为 true 时写，让「未看完」的记录与旧版本字节级一致，减少同步噪声。
        if (finished) 'finished': true,
        'updatedAt': updatedAt.toIso8601String(),
      };

  factory ResumeRecord.fromJson(Map<String, dynamic> j) => ResumeRecord(
        mediaId: j['mediaId'] as String? ?? '',
        title: j['title'] as String? ?? '',
        sourceId: j['sourceId'] as String? ?? '',
        canonicalEpisode: (j['canonicalEpisode'] as num?)?.toInt() ?? 1,
        canonicalSeconds: (j['canonicalSeconds'] as num?)?.toDouble() ?? 0.0,
        finished: j['finished'] as bool? ?? false,
        updatedAt: DateTime.tryParse(j['updatedAt'] as String? ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0),
      );

  ResumeRecord copyWith({
    String? mediaId,
    String? title,
    String? sourceId,
    int? canonicalEpisode,
    double? canonicalSeconds,
    bool? finished,
    DateTime? updatedAt,
  }) =>
      ResumeRecord(
        mediaId: mediaId ?? this.mediaId,
        title: title ?? this.title,
        sourceId: sourceId ?? this.sourceId,
        canonicalEpisode: canonicalEpisode ?? this.canonicalEpisode,
        canonicalSeconds: canonicalSeconds ?? this.canonicalSeconds,
        finished: finished ?? this.finished,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ResumeRecord &&
          other.mediaId == mediaId &&
          other.sourceId == sourceId &&
          other.canonicalEpisode == canonicalEpisode &&
          other.canonicalSeconds == canonicalSeconds &&
          other.finished == finished;

  @override
  int get hashCode =>
      mediaId.hashCode ^
      sourceId.hashCode ^
      canonicalEpisode.hashCode ^
      canonicalSeconds.hashCode ^
      finished.hashCode;
}
