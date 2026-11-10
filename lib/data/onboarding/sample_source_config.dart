// App 内置的「一键示例」源配置：与 tooling/serve_fixture_site.dart 的本地样本站点配套。
//
// 单独成模块的原因：UI 里的示例按钮、演示服务打印的粘贴内容、回归脚本验证的
// 输入必须是**同一份数据**。否则很容易出现「示例配置通不过白名单」的假功能 ——
// 用户点了一键填入，导入却报错，而所有自动化验证都是绿的。
//
// 纯 Dart，不依赖 package:flutter，可在裸 dart run 下与真实 HTTP 链路一起验证。
import 'dart:convert';

import '../../core/source/site_rule.dart';

/// 演示服务默认端口（App 示例与 `serve_fixture_site.dart` 的约定值）。
const int kDefaultFixturePort = 56782;

/// 示例源 id。刻意避开内置源 id，防止触发「外部配置覆盖内置画像」拒绝规则。
const String kSampleSourceId = 'local-fixture';

/// 构造示例配置对象（纯数据，无可执行字段）。
///
/// [baseUrl] 为空时使用默认本地端口；[ruleName] 见 [SiteRulePresets.all]。
Map<String, dynamic> sampleSourceConfig({
  String? baseUrl,
  String ruleName = 'legacy',
}) {
  final base = (baseUrl == null || baseUrl.isEmpty)
      ? 'http://127.0.0.1:$kDefaultFixturePort'
      : baseUrl;
  final rule = SiteRulePresets.all[ruleName] ?? SiteRulePresets.legacy;
  return <String, dynamic>{
    'name': '本地样本源',
    'version': 1,
    'sources': <Object?>[
      <String, dynamic>{
        'id': kSampleSourceId,
        'name': '本地样本站点',
        'baseUrl': base,
        'parser': 'regex',
        'searchPath': 'search?q={keyword}',
        'playPath': 'detail/{mediaId}',
        'platforms': <String>['desktop', 'tv'],
        'rules': <String, dynamic>{
          ...rule.toJson(),
          'baseUrl': base,
        },
      },
    ],
  };
}

/// 可直接粘贴进导入框的格式化 JSON 文本。
String sampleSourceConfigJson({
  String? baseUrl,
  String ruleName = 'legacy',
}) =>
    const JsonEncoder.withIndent('  ').convert(
      sampleSourceConfig(baseUrl: baseUrl, ruleName: ruleName),
    );
