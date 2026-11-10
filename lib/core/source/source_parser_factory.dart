import 'dart_backend.dart';
import 'parsed_source_adapter.dart';
import 'rule_source_parser.dart';
import 'site_rule.dart';
import 'source_adapter.dart';
import 'source_fetcher.dart';
import 'source_parser.dart';
import 'source_profile.dart';

/// 桌面/TV 解析后端工厂（E2 Dart 子集）。
///
/// 桌面/TV 共用 Dart 解析子集。不传 [rule] 时走内置的 `DartSourceParser`
/// （保持旧 demo 行为）；传入经 E9 白名单 + [validateSiteRule] 校验过的纯数据
/// [SiteRule] 时，改用规则驱动的 [RuleSourceParser]，可覆盖多种真实站点结构。
///
/// 关于「jar 不可跨端」落差：Android 端因 jar 须在 Android 运行时执行，不能在此通用工厂内
/// 引用（会向非 Android 编译引入 MethodChannel 依赖）。Android 后端请直接使用
/// `jar_backend.dart` 中的 [JarSourceParser] + [JarFetcher] 构造 [ParsedSourceAdapter]，
/// 并将 [SourceAdapter.supportedPlatforms] 设为仅 `{android}`，由 [SourceRegistry] 按平台裁剪。
SourceParser createParser({SiteRule? rule}) =>
    rule == null ? DartSourceParser() : RuleSourceParser(rule);

SourceFetcher createFetcher({required String baseUrl}) =>
    DartHttpFetcher(baseUrl);

/// 按目标平台创建完整真实适配器（parser + fetcher 均为 Dart 子集）。
///
/// [rule] 为外部导入的站点规则，**调用方必须先跑 E9 `validateSourceConfig`**
/// （内含 `validateSiteRuleMap`）与 `validateSiteRule`，否则拒绝构造。
ParsedSourceAdapter createAdapterForPlatform({
  required String id,
  required SourceProfile profile,
  required Set<SourcePlatform> supportedPlatforms,
  required String baseUrl,
  SiteRule? rule,
}) {
  return ParsedSourceAdapter(
    id: id,
    profile: profile,
    parser: createParser(rule: rule),
    fetcher: DartHttpFetcher(baseUrl),
    supportedPlatforms: supportedPlatforms,
  );
}
