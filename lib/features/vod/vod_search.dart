/// 1.0.5 / G3 点播片库本地检索（纯 Dart，裸 `dart run` 可回归）。
///
/// 关键约束：**空查询必须原样返回传入列表**，这样 1.0.4 的浏览顺序、
/// 卡片数量、点击行为都不受 1.0.5 影响；筛选只在用户真的输入后才发生。
///
/// 第十次修：检索对象从「片名 / 简介 / 分集」扩到本地检索记录的四个
/// 基本字段 —— 片名、类型（`type_name` + `vod_class`）、上映年份、地区，
/// 并支持 `类型:喜剧 地区:大陆 年份:2026` 这种按字段检索写法。
/// 之所以把字段解析放在纯 Dart 层：本地记录是唯一的检索源，检索不能
/// 反过来再去请求接口，否则「系统加载时优先读取本地记录」就名不副实。
library;

import 'vod_catalog.dart';

/// 计数文案。空查询时与 1.0.4 的「N 部 · 公开授权示例片库」逐字相同。
String vodCountLabel(int count, int total) => count == total
    ? '$count 部 · 公开授权示例片库'
    : '$count / $total 部 · 已筛选';

/// 字段前缀名 → 规范化字段名。
const Map<String, String> kVodSearchFieldNames = <String, String>{
  '片名': 'title',
  '标题': 'title',
  '类型': 'type',
  '分类': 'type',
  '地区': 'area',
  '年份': 'year',
  '上映': 'year',
};

/// 一次检索意图：若干「字段=值」约束 + 一段自由文本，两者是**与**关系。
class VodSearchQuery {
  const VodSearchQuery(this.text, this.fields);

  /// 去掉字段前缀后的自由文本（已小写、已 trim）。
  final String text;

  /// 规范化字段名 → 检索值（已小写）。
  final Map<String, String> fields;

  bool get isEmpty => text.isEmpty && fields.isEmpty;
  bool get hasFields => fields.isNotEmpty;
}

final RegExp _fieldToken = RegExp(
    r'(片名|标题|类型|分类|地区|年份|上映)\s*[:：]\s*([^\s:：]+)');

/// 解析 `类型:喜剧 地区:大陆 2026` 这类查询。
///
/// 只认中文前缀（与界面提示一致），值里不允许冒号和空白；
/// 解析不出来的部分按自由文本处理，用户随手打片名依旧能搜到。
VodSearchQuery parseVodSearchQuery(String raw) {
  final fields = <String, String>{};
  for (final m in _fieldToken.allMatches(raw)) {
    final canonical = kVodSearchFieldNames[m.group(1)!];
    final value = m.group(2)!.trim().toLowerCase();
    if (canonical != null && value.isNotEmpty) fields[canonical] = value;
  }
  final text = raw.replaceAll(_fieldToken, ' ').trim().toLowerCase();
  return VodSearchQuery(text, fields);
}

/// 本地检索记录的可检索字段拼成一个串（只用于自由文本匹配）。
String vodSearchBlob(VodItem item) => <String>[
      item.title,
      item.subtitle,
      item.description,
      item.typeName,
      item.genre,
      item.area,
      item.year,
      for (final e in item.episodes) e.title,
    ].join(' ').toLowerCase();

String _fieldValue(VodItem item, String field) => switch (field) {
      'title' => item.title,
      'type' => '${item.typeName} ${item.genre}',
      'area' => item.area,
      'year' => item.year,
      _ => vodSearchBlob(item),
    }.toLowerCase();

bool vodMatches(VodItem item, String q) {
  final parsed = parseVodSearchQuery(q);
  if (parsed.isEmpty) return true;
  for (final e in parsed.fields.entries) {
    if (!_fieldValue(item, e.key).contains(e.value)) return false;
  }
  if (parsed.text.isEmpty) return true;
  return vodSearchBlob(item).contains(parsed.text);
}

List<VodItem> filterVodItems(List<VodItem> all, String query) {
  if (parseVodSearchQuery(query).isEmpty) return all;
  return all.where((i) => vodMatches(i, query)).toList(growable: false);
}
