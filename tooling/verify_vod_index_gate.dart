// 进入点播的「片源索引目录校验 + 分支加载」回归（1.0.5 第十六次修）。
//
// 这段代码决定「初始进入点播时列表里有没有片、片是哪来的」。分支全藏在
// 网络与文件 IO 后面，真机上只表现为「空白页」「明明有索引还在转圈」，
// 靠手点几乎复现不了。这里把 IO 全换成可控回调，把五个状态、两条提交分支、
// 来源唯一不变式、生成目录的编解码与接线护栏逐条钉死。
//
// 运行：dart run tooling/verify_vod_index_gate.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:shunbo/data/onboarding/vod_index_directory_store.dart';
import 'package:shunbo/data/onboarding/vod_index_updater.dart';
import 'package:shunbo/features/vod/vod_builtin_index.dart';
import 'package:shunbo/features/vod/vod_builtin_service.dart';
import 'package:shunbo/features/vod/vod_build_progress.dart';
import 'package:shunbo/features/vod/vod_catalog.dart';
import 'package:shunbo/features/vod/vod_index_gate.dart';

int _pass = 0;
int _fail = 0;
final List<String> _failures = <String>[];

void check(String name, bool ok, [String detail = '']) {
  if (ok) {
    _pass++;
  } else {
    _fail++;
    _failures.add(detail.isEmpty ? name : '$name —— $detail');
    stdout.writeln('  FAIL $name${detail.isEmpty ? '' : ' —— $detail'}');
  }
}

const String kUrl = 'http://47.96.82.41:5188/config.json';
const String kOther = 'http://example.com/config.json';
final DateTime _now = DateTime.utc(2026, 11, 12, 12, 0, 0);

VodIndexSnapshot _snap(VodIndexOrigin origin,
        {String url = kUrl, int total = 605106}) =>
    VodIndexSnapshot(
      origin: origin,
      sourceUrl: url,
      total: total,
      generatedAt: _now,
    );

VodItem _item(String id, String title,
        {VodSection section = VodSection.movies, String type = '剧情'}) =>
    VodItem(
      id: id,
      title: title,
      subtitle: '测试源',
      description: '简介',
      license: 'test',
      section: section,
      episodes: const <VodEpisode>[
        VodEpisode(number: 1, title: '第1集', url: 'https://example.com/a.m3u8'),
      ],
      sourceId: 'src',
      typeName: type,
    );

// ── A. 值对象 ────────────────────────────────────────────────────
void testValues() {
  check('A01 有片源且记着地址才算有效', _snap(VodIndexOrigin.builtin).valid);
  check('A02 条数为 0 无效', !_snap(VodIndexOrigin.builtin, total: 0).valid);
  check('A03 没记接口地址的目录无效',
      !_snap(VodIndexOrigin.builtin, url: '').valid);
  check('A04 地址逐字匹配（含尾空格归一）',
      _snap(VodIndexOrigin.builtin).matches(' $kUrl '));
  check('A05 地址不同不匹配', !_snap(VodIndexOrigin.builtin).matches(kOther));
  check('A06 无效目录不会匹配任何地址',
      !_snap(VodIndexOrigin.builtin, total: 0).matches(kUrl));
  check('A07 未设定接口时 hasAddress 为假',
      !const VodIndexSettings(configured: false, selectedUrl: kUrl).hasAddress);
  check('A08 保存过但选内置片库（空地址）仍算未设定',
      !const VodIndexSettings(configured: true, selectedUrl: '').hasAddress);
  check('A09 显式设定过且地址非空才算已设定',
      const VodIndexSettings(configured: true, selectedUrl: kUrl).hasAddress);
  check('A10 verdict.ready 要求 phase 与 origin 同时成立',
      const VodIndexGateVerdict(
        phase: VodIndexGatePhase.ready,
        reason: 'x',
        note: 'x',
      ).ready ==
          false);
}

// ── B. 进入点播的三分支判定 ──────────────────────────────────────
void testGateVerdict() {
  final builtin = _snap(VodIndexOrigin.builtin);
  final generated = _snap(VodIndexOrigin.generated);

  final first = evaluateVodIndexGate(
      configured: false, selectedUrl: '', builtin: builtin);
  check('B01 初次未设定接口 ⇒ needAddress', first.needsAddress);
  check('B02 初次未设定接口的理由写明「初次使用」',
      first.reason.contains('初次使用'));
  check('B03 初次未设定时来源为 null（不允许偷偷用内置）',
      first.origin == null);

  final configuredNoUrl = evaluateVodIndexGate(
      configured: true, selectedUrl: '', builtin: builtin);
  check('B04 保存过但地址为空仍走输入流程', configuredNoUrl.needsAddress);

  final matched = evaluateVodIndexGate(
      configured: true, selectedUrl: kUrl, builtin: builtin);
  check('B05 内置索引匹配且有效 ⇒ ready', matched.ready);
  check('B06 ready 的唯一来源是 builtin',
      matched.origin == VodIndexOrigin.builtin);
  check('B07 ready 带上索引总条数', matched.total == 605106);
  check('B08 ready 文案说明是内置索引', matched.note.contains('内置'));

  final both = evaluateVodIndexGate(
      configured: true,
      selectedUrl: kUrl,
      builtin: builtin,
      generated: generated);
  check('B09 两份都匹配时优先用户生成的目录',
      both.origin == VodIndexOrigin.generated);
  check('B10 优先分支仍然只有一个 origin', both.origin != null);

  final mismatch = evaluateVodIndexGate(
      configured: true, selectedUrl: kOther, builtin: builtin);
  check('B11 地址不一致 ⇒ needAddress', mismatch.needsAddress);
  check('B12 地址不一致的理由点明「地址」',
      mismatch.reason.contains('不一致') || mismatch.reason.contains('地址'));
  check('B13 地址不一致时来源为 null', mismatch.origin == null);

  final missing = evaluateVodIndexGate(
      configured: true, selectedUrl: kUrl);
  check('B14 索引缺失 ⇒ needAddress', missing.needsAddress);
  check('B15 索引缺失的理由与地址不匹配不同',
      missing.reason != mismatch.reason && missing.reason.contains('缺失'));

  final emptyIndex = evaluateVodIndexGate(
      configured: true,
      selectedUrl: kUrl,
      builtin: _snap(VodIndexOrigin.builtin, total: 0));
  check('B16 索引不含有效片源 ⇒ needAddress', emptyIndex.needsAddress);
  check('B17 空索引的理由是「缺失或不含有效片源」',
      emptyIndex.reason.contains('缺失'));

  final staleGenerated = evaluateVodIndexGate(
      configured: true,
      selectedUrl: kUrl,
      builtin: builtin,
      generated: _snap(VodIndexOrigin.generated, url: kOther));
  check('B18 生成目录地址不匹配时回落到内置目录',
      staleGenerated.ready &&
          staleGenerated.origin == VodIndexOrigin.builtin);

  check('B19 任何非 ready 状态的 origin 必须为 null',
      <VodIndexGateVerdict>[first, configuredNoUrl, mismatch, missing,
        emptyIndex].every((v) => !v.ready && v.origin == null));
}

// ── C. 提交地址后的两条分支 ──────────────────────────────────────
void testSubmitPlan() {
  final builtin = _snap(VodIndexOrigin.builtin);
  final generated = _snap(VodIndexOrigin.generated);

  final direct = decideVodIndexSubmit(
      submittedUrl: kUrl, builtin: builtin);
  check('C01 填内置索引记录的同一地址 ⇒ 直接加载',
      direct.action == VodIndexSubmitAction.loadExisting);
  check('C02 直接加载指明用 builtin',
      direct.origin == VodIndexOrigin.builtin);

  final directGenerated = decideVodIndexSubmit(
      submittedUrl: kUrl, builtin: builtin, generated: generated);
  check('C03 两份都在时直接加载优先生成目录',
      directGenerated.origin == VodIndexOrigin.generated);

  final rebuild = decideVodIndexSubmit(
      submittedUrl: kOther, builtin: builtin);
  check('C04 地址不一致 ⇒ 重新获取并生成',
      rebuild.action == VodIndexSubmitAction.rebuild);
  check('C05 重新生成分支不带 origin', rebuild.origin == null);

  final noIndex = decideVodIndexSubmit(submittedUrl: kUrl);
  check('C06 没有索引目录 ⇒ 重新生成',
      noIndex.action == VodIndexSubmitAction.rebuild);

  final emptyUrl = decideVodIndexSubmit(
      submittedUrl: '  ', builtin: builtin);
  check('C07 空地址不触发生成（由输入页拦下）',
      emptyUrl.action != VodIndexSubmitAction.rebuild);

  final trimmed = decideVodIndexSubmit(
      submittedUrl: ' $kUrl ', builtin: builtin);
  check('C08 地址首尾空格归一后仍能命中直接加载',
      trimmed.action == VodIndexSubmitAction.loadExisting);
}

// ── D. 控制器全流程（IO 全替身） ─────────────────────────────────
class _Rig {
  _Rig({this.configured = false, this.selectedUrl = ''});

  bool configured;
  String selectedUrl;
  VodIndexSnapshot? builtin;
  VodIndexSnapshot? generated;
  String? rebuildFailure;
  int rebuildCalls = 0;
  int saveCalls = 0;
  bool externalCodeSetting = true;
  bool? lastExternalCode;
  final List<VodIndexGatePhase> phases = <VodIndexGatePhase>[];
  late final VodIndexGateController controller;

  VodIndexGateController build() {
    controller = VodIndexGateController(
      readSettings: () async => VodIndexSettings(
          configured: configured,
          selectedUrl: selectedUrl,
          allowExternalCode: externalCodeSetting),
      readBuiltin: () async => builtin,
      readGenerated: () async => generated,
      saveSettings: (url, insecure) async {
        saveCalls++;
        configured = true;
        selectedUrl = url;
      },
      rebuild: (url, insecure, externalCode) async {
        rebuildCalls++;
        lastExternalCode = externalCode;
        if (rebuildFailure != null) return rebuildFailure;
        // 模拟「新目录文件已落盘」：readGenerated 之后能读到它。
        generated = VodIndexSnapshot(
          origin: VodIndexOrigin.generated,
          sourceUrl: url,
          total: 4321,
          generatedAt: _now,
        );
        return null;
      },
    );
    controller.addListener(() => phases.add(controller.phase));
    return controller;
  }
}

Future<void> testController() async {
  // D1 初次进入：needAddress，且一次网络都不发。
  final r1 = _Rig()..builtin = _snap(VodIndexOrigin.builtin);
  final c1 = r1.build();
  final v1 = await c1.check();
  check('D01 初次进入判 needAddress', v1.needsAddress);
  check('D02 初次进入不发网络', r1.rebuildCalls == 0);
  check('D03 状态通知序列 checking → needAddress',
      r1.phases.length == 2 &&
          r1.phases[0] == VodIndexGatePhase.checking &&
          r1.phases[1] == VodIndexGatePhase.needAddress);

  // D2 提交与内置索引一致的地址：直接加载，零 rebuild。
  final v1b = await c1.submit(kUrl, allowInsecureHttp: true);
  check('D04 提交同地址后 ready', v1b.ready);
  check('D05 提交同地址后采用 builtin',
      v1b.origin == VodIndexOrigin.builtin);
  check('D06 「地址一致直接加载」不重新获取片源', r1.rebuildCalls == 0);
  check('D07 提交会落一次接口设定', r1.saveCalls == 1);
  check('D08 落设定后 configured 生效', r1.configured);

  // D3 提交另一个地址：走 rebuild，生成后 ready(generated)。
  final r2 = _Rig(configured: true, selectedUrl: kUrl)
    ..builtin = _snap(VodIndexOrigin.builtin);
  final c2 = r2.build();
  await c2.check();
  r2.phases.clear();
  final v2 = await c2.submit(kOther, allowInsecureHttp: false);
  check('D09 换地址触发生成', r2.rebuildCalls == 1);
  check('D10 生成后 ready', v2.ready);
  check('D11 生成后唯一来源切到 generated',
      v2.origin == VodIndexOrigin.generated);
  check('D12 生成后总条数来自新目录', v2.total == 4321);
  check('D13 生成过程状态序列 building → checking → ready',
      r2.phases.length == 3 &&
          r2.phases[0] == VodIndexGatePhase.building &&
          r2.phases[1] == VodIndexGatePhase.checking &&
          r2.phases[2] == VodIndexGatePhase.ready);

  // D4 再次进入（冷启动等价）：直接读生成目录，不发网络。
  final r3 = _Rig(configured: true, selectedUrl: kOther)
    ..builtin = _snap(VodIndexOrigin.builtin)
    ..generated = _snap(VodIndexOrigin.generated, url: kOther, total: 4321);
  final c3 = r3.build();
  r3.phases.clear();
  final v3 = await c3.check();
  check('D14 后续进入直接加载已生成的目录',
      v3.ready && v3.origin == VodIndexOrigin.generated);
  check('D15 后续进入零网络', r3.rebuildCalls == 0);
  check('D16 后续进入不弹输入流程', !v3.needsAddress);

  // D5 生成失败：failed，来源 null，允许重试。
  final r4 = _Rig(configured: true, selectedUrl: kUrl)
    ..builtin = _snap(VodIndexOrigin.builtin)
    ..rebuildFailure = '接口不可达';
  final c4 = r4.build();
  await c4.check();
  final v4 = await c4.submit(kOther, allowInsecureHttp: false);
  check('D17 生成失败落到 failed',
      v4.phase == VodIndexGatePhase.failed);
  check('D18 失败时来源为 null', v4.origin == null);
  check('D19 失败理由透传到文案', v4.note.contains('接口不可达'));
  check('D20 失败后列表来源不残留', !c4.ready && c4.activeOrigin == null);

  // D6 空地址提交：留在输入流程，不生成。
  final r5 = _Rig()..builtin = _snap(VodIndexOrigin.builtin);
  final c5 = r5.build();
  final v5 = await c5.submit('  ', allowInsecureHttp: false);
  check('D21 空地址提交落回 needAddress', v5.needsAddress);
  check('D22 空地址提交不写设定、不生成',
      r5.saveCalls == 0 && r5.rebuildCalls == 0);

  // D7 settled：未开始立刻返回；已开始能等到结论。
  final r6 = _Rig(configured: true, selectedUrl: kUrl)
    ..builtin = _snap(VodIndexOrigin.builtin);
  final c6 = r6.build();
  await c6.settled;
  check('D23 未开始时 settled 不阻塞', c6.phase == VodIndexGatePhase.checking);
  final pending = c6.check();
  await c6.settled;
  await pending;
  check('D24 settled 等到结论后是 ready', c6.ready);

  // D8 读取设定抛异常 ⇒ failed，不炸到 UI。
  final broken = VodIndexGateController(
    readSettings: () async => throw StateError('bad config'),
    readBuiltin: () async => null,
    readGenerated: () async => null,
    saveSettings: (_, __) async {},
    rebuild: (_, __, ___) async => null,
  );
  final vb = await broken.check();
  check('D25 读设定异常落到 failed 而不是抛给调用方',
      vb.phase == VodIndexGatePhase.failed);

  // D9 生成索引时尊重设置页「允许执行外部代码」的开关。
  final r7 = _Rig(configured: true, selectedUrl: kUrl)
    ..builtin = _snap(VodIndexOrigin.builtin)
    ..externalCodeSetting = false;
  final c7 = r7.build();
  await c7.check();
  await c7.submit(kOther, allowInsecureHttp: false);
  check('D26 生成索引透传 allowExternalCode=false（不硬编码 true）',
      r7.rebuildCalls == 1 && r7.lastExternalCode == false);
}

// ── E. 生成目录文件的编解码 ──────────────────────────────────────
void testDirectoryDocument() {
  final doc = VodIndexDocument(
    sourceUrl: kUrl,
    generatedAt: _now,
    items: <VodItem>[
      _item('a', '电影甲'),
      _item('b', '电影乙'),
      _item('c', '剧集甲', section: VodSection.series),
    ],
  );
  check('E01 total 等于条目数', doc.total == 3);
  check('E02 sections 按栏目分节',
      doc.sections['movies'] == 2 && doc.sections['series'] == 1);
  check('E03 inSection 只给本栏目', doc.inSection(VodSection.movies).length == 2);
  check('E04 snapshot 标成 generated 且带地址',
      doc.snapshot.origin == VodIndexOrigin.generated &&
          doc.snapshot.sourceUrl == kUrl &&
          doc.snapshot.total == 3);

  final encoded = encodeVodIndexDocument(doc);
  check('E05 编码带 format / version',
      encoded['format'] == kVodIndexDirectoryFormat &&
          encoded['version'] == kVodIndexDirectoryVersion);
  check('E06 编码带 sourceUrl / generatedAt / total',
      encoded['sourceUrl'] == kUrl &&
          encoded['total'] == 3 &&
          encoded['generatedAt'] is String);
  check('E07 编码的 sections 与默认 manifest 同构（key/label/records）',
      (encoded['sections'] as List).every((s) =>
          s is Map &&
          s.containsKey('key') &&
          s.containsKey('label') &&
          s.containsKey('records')));

  final roundTrip = decodeVodIndexDocument(
      jsonDecode(jsonEncode(encoded)));
  check('E08 编码→JSON→解码可往返', roundTrip != null);
  check('E09 往返后条目数与地址不变',
      roundTrip!.total == 3 && roundTrip.sourceUrl == kUrl);
  check('E10 往返后剧集地址仍在（点开即播）',
      roundTrip.items.every((i) => i.episodes.isNotEmpty));
  check('E11 往返后栏目归属保持',
      roundTrip.inSection(VodSection.series).length == 1);

  check('E12 format 不符返回 null',
      decodeVodIndexDocument(<String, dynamic>{
        ...encoded,
        'format': 'other',
      }) == null);
  check('E13 version 不符返回 null',
      decodeVodIndexDocument(<String, dynamic>{
        ...encoded,
        'version': 99,
      }) == null);
  check('E14 缺 sourceUrl 返回 null',
      decodeVodIndexDocument(<String, dynamic>{
        ...encoded,
        'sourceUrl': '',
      }) == null);
  check('E15 没有可播条目的目录返回 null',
      decodeVodIndexDocument(<String, dynamic>{
        ...encoded,
        'items': <Object>[],
      }) == null);
  check('E16 坏行（无 episodes）被跳过而不炸整份',
      decodeVodIndexDocument(<String, dynamic>{
        ...encoded,
        'items': <Object>[
          (encoded['items'] as List).first,
          <String, dynamic>{'id': 'x', 'title': '坏条目'},
        ],
      })!.total ==
          1);
  check('E17 同一 id 只留一张卡',
      decodeVodIndexDocument(<String, dynamic>{
        ...encoded,
        'items': <Object>[
          (encoded['items'] as List).first,
          (encoded['items'] as List).first,
        ],
      })!.total ==
          1);
  check('E18 非 http(s) 播放地址被丢弃',
      decodeVodIndexDocument(<String, dynamic>{
        ...encoded,
        'items': <Object>[
          <String, dynamic>{
            ...(encoded['items'] as List).first as Map,
            'episodes': <Object>[
              <Object>[1, '第1集', 'file:///etc/passwd'],
            ],
          },
        ],
      }) ==
          null);
  check('E19 非 Map 输入返回 null', decodeVodIndexDocument('junk') == null);
}

// ── F. 浏览采样（scanner.collect） ───────────────────────────────
BuiltinIndexManifest _manifest() => BuiltinIndexManifest(
      version: kBuiltinIndexVersion,
      generatedAt: _now,
      sourceUrl: kUrl,
      sites: const <BuiltinIndexSite>[
        BuiltinIndexSite(key: 's', name: '站', api: 'http://s/api', total: 10),
      ],
      types: const <String>['电影'],
      shards: const <BuiltinIndexShard>[
        BuiltinIndexShard(
            key: 'movies',
            label: '电影',
            file: 'movies.tsv.gz',
            records: 10,
            gzBytes: 1,
            sha256: 'f'),
      ],
      total: 10,
    );

String _body() {
  final lines = <String>[];
  for (var i = 0; i < 10; i++) {
    // prefix=0 ⇒ 每行片名独立，便于断言行号与片名一一对应。
    lines.add('0\tid$i\t0\t0\t片名$i');
  }
  return lines.join('\n');
}

void testCollect() {
  final scanner = BuiltinIndexScanner(manifest: _manifest(), sectionKey: 'movies');
  final body = _body();

  final all = scanner.collect(body, stride: 1, limit: 0);
  check('F01 stride=1 顺序收齐全部行', all.length == 10);
  check('F02 collect 还原片名正确',
      all.first.name == '片名0' && all.last.name == '片名9');
  check('F03 collect 带上栏目键', all.every((h) => h.section == 'movies'));
  check('F04 collect 带上站点与 vod_id',
      all.first.siteIndex == 0 && all.first.vodId == 'id0');

  final sampled = scanner.collect(body, stride: 5, limit: 0);
  check('F05 stride=5 等距采样覆盖全片', sampled.length == 2);
  check('F06 等距采样取的是第 0 与第 5 行',
      sampled[0].name == '片名0' && sampled[1].name == '片名5');

  final p0 = scanner.collect(body, offset: 0, stride: 5, limit: 0);
  final p1 = scanner.collect(body, offset: 1, stride: 5, limit: 0);
  check('F07 续载取每段的下一张，条数相同', p0.length == p1.length);
  check('F08 续载与首屏不重复',
      p0.map((h) => h.vodId).toSet().intersection(
          p1.map((h) => h.vodId).toSet()).isEmpty);
  // 位移 0..stride-1 恰好把整片不重不漏地取完；超过 stride 会与第 0 轮
  // 重叠，因此由 [BuiltinIndexService.browse] 的 `page >= stride` 提前挡下
  // （见 G07）。这里守住「覆盖全片」这一条，两边合起来才完整。
  check('F09 位移 0..stride-1 恰好覆盖全片且不重复', () {
    final seen = <String>{};
    for (var p = 0; p < 5; p++) {
      for (final h in scanner.collect(body, offset: p, stride: 5)) {
        if (!seen.add(h.vodId)) return false;
      }
    }
    return seen.length == 10;
  }());
  check('F10 limit 生效',
      scanner.collect(body, stride: 1, limit: 3).length == 3);
  check('F11 stride=0 钳到 1 不崩',
      scanner.collect(body, stride: 0, limit: 0).length == 10);

  // 前端编码必须逐行维护 previous：第 1 行留前缀，第 2 行复用它。
  const coded = '0\tidA\t0\t0\t斗罗大陆\n0\tidB\t0\t3\t2绝世唐门';
  final c = scanner.collect(coded, stride: 1);
  check('F12 collect 逐行维护前端编码前缀',
      c.length == 2 && c[1].name == '斗罗大2绝世唐门',
      c.length == 2 ? c[1].name : 'length=${c.length}');

  // 坏行不该炸整片。
  const withBad = '0\tidA\t0\t0\t甲\nbroken\n0\tidB\t0\t0\t乙';
  check('F13 坏行跳过但后续行仍可解析',
      scanner.collect(withBad, stride: 1).length == 2);
}

// ── G. 服务的浏览入口 ────────────────────────────────────────────
Future<void> testBrowseService() async {
  final gz = Uint8List.fromList(gzip.encode(utf8.encode(_body())));
  final svc = BuiltinIndexService(
    loadManifest: () async => _manifest(),
    loadShardBytes: (file) async => file == 'movies.tsv.gz' ? gz : null,
    fetchDetail: (hit) async => null,
  );
  await svc.ensureManifest();
  check('G01 manifest 就绪', svc.ready);

  final p0 = await svc.browse('movies', page: 0, limit: 5);
  check('G02 browse 首屏按等距采样给出片源', p0.isNotEmpty);
  check('G03 browse 首屏不超过 limit', p0.length <= 5);
  check('G04 browse 结果都属本栏目',
      p0.every((h) => h.section == 'movies'));

  final p1 = await svc.browse('movies', page: 1, limit: 5);
  check('G05 browse 续载能给出另一批',
      p1.isNotEmpty &&
          p0.map((h) => h.vodId).toSet().intersection(
              p1.map((h) => h.vodId).toSet()).isEmpty);
  check('G06 不存在的栏目返回空',
      (await svc.browse('series', page: 0, limit: 5)).isEmpty);

  final far = await svc.browse('movies', page: 999, limit: 5);
  check('G07 超出采样上限返回空（列表不会无限续载）', far.isEmpty);

  final again = await svc.browse('movies', page: 0, limit: 5);
  check('G08 同一页命中缓存（列表实例相同）', identical(again, p0));

  // 同名归并：两行同名不同 vod_id 只出一张卡，另一条进备选。
  final dupGz = Uint8List.fromList(gzip.encode(utf8.encode(
      '0\tidA\t0\t0\t同一部片\n0\tidB\t0\t0\t同一部片')));
  final dup = BuiltinIndexService(
    loadManifest: () async => _manifest(),
    loadShardBytes: (_) async => dupGz,
    fetchDetail: (hit) async => null,
  );
  await dup.ensureManifest();
  final dupHits = await dup.browse('movies', page: 0, limit: 10);
  check('G09 浏览与检索共用同名归并（不出现两张卡）', dupHits.length == 1);
  check('G10 归并掉的另一条进换源备选',
      dup.altCountFor(dupHits.first.id) == 1);

  svc.clearCache();
  check('G11 clearCache 后 manifest 与分片缓存一起失效', !svc.ready);
}

// ── H. 源码静态护栏：接线真的接上了 ──────────────────────────────
void testWiring() {
  final page = File('lib/ui/vod/vod_page.dart').readAsStringSync();
  final mainDart = File('lib/main.dart').readAsStringSync();
  final services = File('lib/app/services.dart').readAsStringSync();
  final paths = File('lib/data/app_paths.dart').readAsStringSync();
  final store = File('lib/data/onboarding/vod_source_address_store.dart')
      .readAsStringSync();
  final dialog = File('lib/ui/vod/vod_source_input_dialog.dart')
      .readAsStringSync();
  final service = File('lib/features/vod/vod_builtin_service.dart')
      .readAsStringSync();
  final scanner = File('lib/features/vod/vod_builtin_index.dart')
      .readAsStringSync();
  final library = File('lib/features/vod/vod_library.dart').readAsStringSync();
  final gates = File('tooling/verify_all.dart').readAsStringSync();

  check('H01 进入栏目触发索引校验',
      page.contains('_enterIndexGate()') && page.contains('vodIndexGate.check()'));
  check('H02 页面监听索引状态',
      page.contains('vodIndexGate.addListener(') &&
          page.contains('vodIndexGate.removeListener('));
  check('H03 needAddress 进入接口输入流程',
      page.contains('VodIndexGatePhase.needAddress') &&
          page.contains('showVodSourceInputDialog('));
  check('H04 初次使用必弹输入页（不要求 configured 才弹）',
      page.contains('_maybePromptAddress()') &&
          page.contains('widget.active'));
  check('H05 提交走 gate.submit 并带明文放行标记',
      page.contains('gate.submit(result.url') &&
          page.contains('allowInsecureHttp: result.allowInsecureHttp'));
  // 第二十一次修：生成目录改为按当前接口地址读独立文件，不再读固定的
  // `vod-index.json`。断言同步改成锁「按地址读」这条更强的约束。
  check('H06 两个来源都真的实现了加载（生成目录按地址读独立文件）',
      page.contains('origin == VodIndexOrigin.builtin') &&
          page.contains('vodBuiltin.browse(') &&
          page.contains('vodIndexStore.loadFor(') &&
          page.contains('_generatedIndexDoc()'));
  check('H07 生成目录分支按栏目分页且批量挂进播放链路',
      page.contains('doc.inSection(widget.section)') &&
          page.contains('vodLibrary.adoptMany(') &&
          library.contains('int adoptMany('));
  check('H08 来源唯一守卫在列表取数处',
      page.contains('sameSource ? _indexPool') &&
          page.contains('_poolOrigin == gate.activeOrigin'));
  check('H09 滚到底续载同一份索引',
      page.contains('if (gate.ready)') && page.contains('_loadIndexPage()'));
  check('H10 后台全量同步让位给索引目录',
      page.contains('await widget.services.vodIndexGate.settled') &&
          page.contains('if (gate.ready ||'));
  check('H11 状态行覆盖五个状态且给出操作入口',
      page.contains('_gateRow()') &&
          page.contains('VodIndexGatePhase.failed') &&
          page.contains('设定片源接口'));
  // 第二十六次修（用户红标）：这行原来是「安装包内置索引目录记录的接口」，
  // 固定显示随包默认地址，初次使用的人会以为它已经生效。现在只显示
  // **用户设定过的**接口地址，没设过就是空，另加一句简短免责说明。
  check('H12 输入页显示「当前接口」而不是随包默认地址，并带免责说明',
      dialog.contains('currentSourceUrl') &&
          dialog.contains('当前接口：') &&
          !dialog.contains('安装包内置索引目录记录的接口') &&
          dialog.contains('仅聚合第三方公开接口的索引信息') &&
          dialog.contains('填入默认源地址'));
  check('H13 输入页默认放行明文 http（默认源就是 http）',
      dialog.contains("startsWith('http://')") &&
          dialog.contains('allowInsecureHttp'));
  check('H14 输入页不用可聚焦的滚动容器（电视端不吞 OK）',
      !dialog.contains('child: SingleChildScrollView(') &&
          !dialog.contains('SelectableText('));
  check('H15 store 能区分「从未设定」与「设定过」',
      store.contains('Future<bool> isConfigured()') &&
          store.contains('usesBuiltIn'));
  check('H16 数据目录声明生成索引文件名',
      paths.contains("vodIndexFile = 'vod-index.json'"));
  check('H17 main 装配 gate 与目录文件',
      mainDart.contains('VodIndexGateController(') &&
          mainDart.contains('VodIndexDirectoryStore.at(') &&
          mainDart.contains('rebuild: (url, insecure, externalCode) async'));
  // 第二十一次修：按接口地址独立存放。旧断言锁「写回同一个 vod-index.json」，
  // 与新需求「新接口索引独立存放、不得覆盖默认索引记录」直接冲突，
  // 按项目惯例改写成更强的新断言（不是放宽）：写独立文件 + 默认地址零网络。
  check('H18 rebuild 按地址写独立目录；默认地址不可用时给明确理由（不静默成功）',
      mainDart.contains('vodIndexStore.saveFor(') &&
          mainDart.contains('VodIndexDocument(') &&
          mainDart.contains('随包默认索引目录不可用') &&
          // 第二十六次修：静默 `return null` 会让闸门再判 needAddress 又弹回
          // 输入页，形成「对话框一直闪」的循环。必须回一句可读的失败理由。
          !mainDart.contains(
              'if (!vodIndexStore.isIndependentSource(url)) return null;'));
  check('H19 services 暴露三个新依赖',
      services.contains('final VodIndexGateController vodIndexGate;') &&
          services.contains('final VodIndexDirectoryStore vodIndexStore;') &&
          services.contains('final String vodBuiltinSourceUrl;'));
  check('H20 索引服务提供浏览入口',
      service.contains('Future<List<BuiltinIndexHit>> browse('));
  check('H21 扫描器提供等距采样',
      scanner.contains('List<BuiltinIndexHit> collect('));
  check('H22 新回归已接入统一门禁',
      gates.contains("'vod-index-gate'") &&
          gates.contains('verify_vod_index_gate.dart'));
  check('H23 生成索引模式下检索查同一份目录（不落到内置索引）',
      page.contains('VodIndexOrigin.generated') &&
          page.contains('doc?.inSection(widget.section)') &&
          page.contains('filterVodItems(section, q)') &&
          page.contains('_indexHitsTotal = all.length'));
  check('H24 切换来源时清空旧检索结果并让在途结果作废',
      page.contains('_indexHits = const <VodItem>[];') &&
          page.contains('_indexSeq++;'));
  check('H25 只有激活页加载分片（六页共享一个 gate 不一起解压）',
      page.contains('if (!widget.active) return;'));
  final gateSrc = File('lib/features/vod/vod_index_gate.dart').readAsStringSync();
  check('H26 生成索引透传「允许执行外部代码」设定',
      mainDart.contains('allowExternalCode: externalCode') &&
          gateSrc.contains('current.allowExternalCode'));
  // 二十二修：点卡片**直接进播放页**，中间的详情页整个删掉（剧情介绍搬到
  // 播放页右栏）。所以这里锁三件事：不再有 detail 视图、不再有 _buildDetail、
  // 进播放页仍然是「乐观切视图 + 回源放后台」。
  final openIdx = page.indexOf('Future<void> _openAndPlay');
  final openEnd = page.indexOf('Future<void> _playResolved');
  final openBody =
      (openIdx >= 0 && openEnd > openIdx) ? page.substring(openIdx, openEnd) : '';
  check('H27 点卡片直连播放页（详情页已删除，回源仍在后台）',
      openBody.contains('final seq = ++_resolveSeq;') &&
          openBody.contains('_view = _VodView.playing;') &&
          !openBody.contains('vodBuiltin.resolve(') &&
          !page.contains('_VodView.detail') &&
          !page.contains('Widget _buildDetail()'));
  check('H28 回源失败留在播放页并可重试，不退回列表',
      page.contains('_resolveError = ') &&
          page.contains('Future<void> _retryOpen()') &&
          page.contains('onPressed: _retryOpen') &&
          page.contains('暂时取不到播放地址'));
  check('H29 回源代次隔离 + 离开播放页作废在途回包 + 空剧集有话说',
      page.contains('if (!mounted || seq != _resolveSeq) return;') &&
          page.contains('_resolveSeq++;') &&
          page.contains('这个片源没有可播放的剧集'));

  // ── 第二十一次修：设置-点播源模块的静态反向锁死 ──────────────────
  final section = File('lib/ui/settings/vod_source_section.dart')
      .readAsStringSync();
  final storeSrc = File('lib/data/onboarding/vod_index_directory_store.dart')
      .readAsStringSync();
  final updater = File('lib/data/onboarding/vod_index_updater.dart')
      .readAsStringSync();
  final autoSrc = File('lib/features/vod/vod_auto_source.dart')
      .readAsStringSync();
  check('H30 设置页只剩一个输入框（无开关 / 候选列表 / 多按钮）',
      section.contains('TextField(') &&
          !section.contains('SwitchListTile(') &&
          !section.contains('for (final c in kVodSourceCandidates)') &&
          !section.contains('添加并使用') &&
          !section.contains('应用当前地址') &&
          !section.contains('恢复默认') &&
          (RegExp(r'TextField\(').allMatches(section).length == 1) &&
          (RegExp(r'OutlinedButton\.icon\(').allMatches(section).length == 1));
  check('H31 输入完成自动提交既有闸门（回车 + 失焦，判断逻辑不改）',
      section.contains('onSubmitted:') &&
          section.contains('_onFocusLost') &&
          section.contains('vodIndexGate.submit(') &&
          gateSrc.contains('decideVodIndexSubmit(') &&
          gateSrc.contains('builtin.matches(url)'));
  check('H32 默认地址一致时零网络复用默认记录（rebuild 双保险）',
      mainDart.contains('if (!vodIndexStore.isIndependentSource(url)) {') &&
          mainDart.contains('随包默认索引目录不可用') &&
          storeSrc.contains('isDefaultVodIndexSource(') &&
          storeSrc.contains('默认片源索引是随包只读资产'));
  check('H33 明文 http 仍需显式确认 + 风险声明检查（界面无开关但策略不放宽）',
      section.contains('_confirmInsecure') &&
          section.contains('放行并获取') &&
          section.contains('disclaimerAccepted') &&
          !section.contains('SwitchListTile('));
  check('H34 手动获取入口与定时更新共用同一条追加链路',
      section.contains('立即获取最新片源') &&
          section.contains('vodIndexUpdater.runOnce(force: true)') &&
          updater.contains('final result = await append(settings.url, items);'));
  check('H35 更新周期由设置档位决定，定时器按 1 小时 tick 查一次',
      updater.contains(
              'const Duration kVodIndexUpdateInterval = Duration(days: 1);') &&
          updater.contains(
              'const Duration kVodIndexUpdateTick = Duration(hours: 1);') &&
          updater.contains('Timer.periodic(kVodIndexUpdateTick') &&
          updater.contains('shouldUpdate(last, now(), settings.interval)') &&
          mainDart.contains('vodIndexUpdater.start();') &&
          mainDart.contains('addPostFrameCallback'));
  check('H36 定时更新让位启动校验与点播闸门，只写盘不打断播放',
      mainDart.contains('await vodBoot.settled;') &&
          mainDart.contains('await vodIndexGate.settled;') &&
          updater.contains('await waitForIdle();') &&
          updater.contains('不 `gate.check()`'));
  check('H37 闸门按当前设定地址读生成目录，不读固定旧文件',
      mainDart.contains('return vodIndexStore.snapshotFor(s.effectiveUrl);') &&
          page.contains('vodIndexStore.loadFor(') &&
          (RegExp(r'vodIndexStore\.load\(\)').allMatches(page).isEmpty));
  check('H38 存储层按地址派生独立文件、默认地址永不落盘',
      storeSrc.contains('String vodIndexFileForUrl(String raw,') &&
          storeSrc.contains(".toRadixString(16).padLeft(8, '0')") &&
          storeSrc.contains('if (name.isEmpty) return null;') &&
          storeSrc.contains('sourceUrl.trim() != url.trim()') &&
          storeSrc.contains('throw StateError(\'默认片源索引地址不生成独立目录'));
  check('H39 追加合并按 id 去重、旧条目不删、只写自己的文件',
      storeSrc.contains('mergeVodIndexItems(') &&
          storeSrc.contains('seen.add(item.id)') &&
          storeSrc.contains('await _writeTo(target, doc);') &&
          storeSrc.contains('loadFor(url)'));
  check('H40 排查结论：VodAutoSource 仍是一次性装载器，定时更新是独立能力',
      autoSrc.contains('不重试') &&
          autoSrc.contains('_pending != null') &&
          updater.contains('没有**定时自动更新') &&
          mainDart.contains('final vodIndexUpdater = VodIndexAutoUpdater('));
  check('H41 增量取数只拿各站最新一页，不遍历全量分页、不碰 VodLibrary',
      updater.contains('final batch = await pager.next();') &&
          updater.contains('kMaxVodUpdateRounds') &&
          updater.contains('kVodIndexUpdateBudget') &&
          !updater.contains('vodLibrary.append') &&
          !updater.contains('VodSession('));
  // 第二十四次修：那行长文案按红标删掉，改成「七档可选 + 一句免责版权」。
  // 旧断言锁的是被删掉的那句，按项目惯例改写成等价强度的新约束（不是放宽）：
  // 「按 id 去重 / 只追加不重取 / 默认接口可追加」这三条口径现在由说明行
  // 之外的断言（H41 / I19 / D53 等）与下面的免责文案一起保证。
  check('H42 设置页不再写死 24 小时；改为免责版权说明 + 七档可选',
      !section.contains('每 24 小时自动更新一次片源') &&
          section.contains('不提供、不存储、不传播任何影音内容') &&
          section.contains('自动更新间隔') &&
          section.contains('VodUpdateCadence.values') &&
          // 第二十三次修：那句「随包只读、无需更新」按用户红标删掉了 ——
          // 它把「点了按钮不取数」说成了理所当然。
          !section.contains('默认片源索引随包只读，无需更新'));
  check('H43 输入框不再挂「默认留空…」说明行（用户红标：去除）',
      !section.contains('helperText') &&
          !section.contains('默认留空，不回填当前地址'));
  check('H44 点播页把默认接口的本地增补并进浏览 / 检索 / 条件 / 条数',
      page.contains('loadSupplementFor(') &&
          page.contains('_withSupplement(') &&
          page.contains('mergeVodFacets(') &&
          page.contains('adoptMany(extra)'));
  // 第二十六次修：提交后仍未通过就断开自动重弹 —— 以前「提交 → 未通过 →
  // needAddress → 再弹」会一直循环，用户看到的就是对话框反复闪。
  check('H45 提交后未通过不再自动弹回输入页（断开死循环）',
      page.contains('final verdict = await gate.submit(') &&
          page.contains('if (!verdict.ready) {') &&
          page.contains('_addressPromptDismissed = true;') &&
          page.contains('_toast(verdict.note);'));
}

// ── 第二十一次修：设置-点播源模块的纯函数 / 文件 IO / 调度回归 ──────
//
// 这一组专门验「独立存放 + 追加去重 + 24 小时定时」三件事。全部用临时目录
// 与注入回调，不起 HttpServer、不碰真实数据目录，冷启动门禁可在任意机器跑。
Future<void> testSourceModule() async {
  const def = 'http://47.96.82.41:5188/config.json';
  const a = 'https://a.example.com/vod.json';
  const b = 'https://b.example.com/vod.json';
  const c = 'https://c.example.com/vod.json';

  // ① 文件名派生 / 默认地址只读判定
  check('I01 默认地址被识别为只读默认源',
      isDefaultVodIndexSource(def, def));
  check('I02 其它地址不是默认源', !isDefaultVodIndexSource(a, def));
  check('I03 默认地址不派生文件名',
      vodIndexFileForUrl(def, defaultSourceUrl: def).isEmpty);
  check('I04 空地址不派生文件名',
      vodIndexFileForUrl('', defaultSourceUrl: def).isEmpty);
  final fa = vodIndexFileForUrl(a, defaultSourceUrl: def);
  final fb = vodIndexFileForUrl(b, defaultSourceUrl: def);
  check('I05 不同地址得到不同且合法的文件名',
      fa != fb &&
          fa.startsWith('vod-index-') &&
          fa.endsWith('.json') &&
          !fa.contains('/') &&
          !fa.contains(':'),
      '$fa / $fb');
  check('I06 同一地址（含首尾空格）文件名稳定',
      vodIndexFileForUrl('  $a  ', defaultSourceUrl: def) == fa);

  // ② 追加合并去重
  final i1 = _item('id1', '片1');
  final i2 = _item('id2', '片2');
  final i3 = _item('id3', '片3');
  final m = mergeVodIndexItems(<VodItem>[i1, i2],
      <VodItem>[i2, i3, _item('', '空 id 的坏条目')]);
  check('I07 追加只加新条目', m.added == 1 && m.total == 3);
  check('I08 重复项与空 id 都被计数并剔除', m.duplicates == 2);
  check('I09 旧条目一条不删且顺序稳定',
      m.items[0].id == 'id1' &&
          m.items[1].id == 'id2' &&
          m.items[2].id == 'id3');
  check('I10 空现有列表也能合并去重',
      mergeVodIndexItems(const <VodItem>[], <VodItem>[i1, i1]).total == 1);

  // ③ 真实文件 IO：独立存放、互不覆盖、默认地址不落盘
  final dir = await Directory.systemTemp.createTemp('shunbo_vod_index_');
  try {
    final store = VodIndexDirectoryStore.at(
        '${dir.path}${Platform.pathSeparator}vod-index.json',
        defaultSourceUrl: def);
    final stamp = DateTime.utc(2026, 11, 13, 8);
    await store.saveFor(
        a,
        VodIndexDocument(
            sourceUrl: a, generatedAt: stamp, items: <VodItem>[i1, i2]));
    check('I11 saveFor 写进地址专属文件',
        store.fileFor(a) != null && await store.fileFor(a)!.exists());
    check('I12 默认地址不产生文件、也读不到目录',
        store.fileFor(def) == null && await store.loadFor(def) == null);
    check('I13 snapshotFor 按地址拿到正确条数',
        (await store.snapshotFor(a))?.total == 2);
    check('I14 另一地址读不到前一个地址的目录',
        await store.snapshotFor(b) == null);
    await store.saveFor(
        b,
        VodIndexDocument(
            sourceUrl: b, generatedAt: stamp, items: <VodItem>[i3]));
    check('I15 写 B 不覆盖 A',
        (await store.snapshotFor(a))?.total == 2 &&
            (await store.snapshotFor(b))?.total == 1);
    final r = await store.appendFor(a, <VodItem>[i2, i3]);
    check('I16 追加合并只加新条目并报出重复数',
        r.ok && r.added == 1 && r.duplicates == 1 && r.total == 3,
        '${r.added}/${r.duplicates}/${r.total}');
    check('I17 追加后 A 目录完整', (await store.snapshotFor(a))?.total == 3);
    check('I18 追加不动 B 目录', (await store.snapshotFor(b))?.total == 1);
    // 第二十三次修（用户红标「不是只读不能获取」）：默认地址的追加写进
    // **本地增补**文件，随包索引一个字节不动，闸门也读不到这份增补
    // （`loadFor` 仍返回 null），所以「默认记录被覆盖」这条红线没有破。
    final sup = await store.appendFor(def, <VodItem>[i1]);
    final supFile = store.supplementFileFor(def);
    check('I19 默认地址追加写进本地增补文件（随包索引不动、闸门读不到）',
        sup.ok &&
            sup.added == 1 &&
            store.fileFor(def) == null &&
            supFile != null &&
            await supFile.exists() &&
            (await store.loadSupplementFor(def))?.total == 1 &&
            await store.loadFor(def) == null);
    final sup2 = await store.appendFor(def, <VodItem>[i1, i2]);
    check('I19b 增补文件同样按 id 去重、只加不删',
        sup2.ok && sup2.added == 1 && sup2.duplicates == 1 &&
            (await store.loadSupplementFor(def))?.total == 2);
    check('I19c 非默认地址不读增补通道（它的目录本身就是全量）',
        await store.loadSupplementFor(a) == null);
    var threw = false;
    try {
      await store.saveFor(
          def,
          VodIndexDocument(
              sourceUrl: def, generatedAt: stamp, items: <VodItem>[i1]));
    } catch (_) {
      threw = true;
    }
    check('I20 默认地址 saveFor 直接抛错（写盘层双保险）', threw);
    check('I21 旧单文件从未被写入（只写派生文件）',
        !(await store.file.exists()));
  } finally {
    await dir.delete(recursive: true);
  }

  // ④ 升级兼容：老版本共用文件在地址一致时仍认得
  final legacyDir = await Directory.systemTemp.createTemp('shunbo_vod_legacy_');
  try {
    final legacy = VodIndexDirectoryStore.at(
        '${legacyDir.path}${Platform.pathSeparator}vod-index.json',
        defaultSourceUrl: def);
    await legacy.file.writeAsString(jsonEncode(encodeVodIndexDocument(
        VodIndexDocument(
            sourceUrl: c,
            generatedAt: DateTime.utc(2026, 11, 12),
            items: <VodItem>[i1]))));
    check('I22 旧单文件在地址一致时仍可读',
        (await legacy.loadFor(c))?.total == 1);
    check('I23 旧单文件在地址不一致时不被误读',
        await legacy.loadFor(a) == null);
  } finally {
    await legacyDir.delete(recursive: true);
  }

  // ⑤ 调度器：周期、让位、单飞、默认地址、失败重试
  final now = DateTime.utc(2026, 11, 13, 12);
  DateTime? last;
  var idleCalls = 0;
  var fetchCalls = 0;
  var appendCalls = 0;
  var writeCalls = 0;
  var settings = VodIndexUpdateSettings(url: a);
  var fetchFails = false;
  final scheduler = VodIndexAutoUpdater(
    readSettings: () async => settings,
    fetchLatest: (_) async {
      fetchCalls++;
      return fetchFails ? <VodItem>[] : <VodItem>[i3];
    },
    append: (_, __) async {
      appendCalls++;
      return const VodIndexAppendResult(
          ok: true, added: 1, duplicates: 0, total: 3);
    },
    readLastUpdateAt: () async => last,
    writeLastUpdateAt: (t) async {
      writeCalls++;
      last = t;
    },
    waitForIdle: () async {
      idleCalls++;
    },
    now: () => now,
  );
  check('I24 默认档位一天；tick 一小时；七档表固定',
      kVodIndexUpdateInterval == const Duration(days: 1) &&
          kVodIndexUpdateTick == const Duration(hours: 1) &&
          VodUpdateCadence.values.length == 7 &&
          VodUpdateCadence.values.map((c) => c.days).join(',') ==
              '1,3,7,30,90,180,365' &&
          VodUpdateCadence.values.map((c) => c.label).join(',') ==
              '一天,三天,一周,一月,一季度,半年,一年');
  check('I25 从未更新过允许立即跑', scheduler.shouldUpdate(null, now));
  check('I26 距上次 23 小时不跑',
      !scheduler.shouldUpdate(now.subtract(const Duration(hours: 23)), now));
  check('I27 距上次满 24 小时才跑',
      scheduler.shouldUpdate(now.subtract(const Duration(hours: 24)), now));
  // 第二十四次修：周期改成用户可选档位，纯函数按传入周期判断。
  check('I27b 选「三天」：过两天不跑、满三天跑',
      !scheduler.shouldUpdate(
          now.subtract(const Duration(days: 2)), now, const Duration(days: 3)) &&
          scheduler.shouldUpdate(now.subtract(const Duration(days: 3)), now,
              const Duration(days: 3)));
  check('I27c 选「一年」：过半年不跑、满一年跑',
      !scheduler.shouldUpdate(now.subtract(const Duration(days: 180)), now,
              const Duration(days: 365)) &&
          scheduler.shouldUpdate(now.subtract(const Duration(days: 365)), now,
              const Duration(days: 365)));
  var outcome = await scheduler.runOnce();
  check('I28 首次更新走完让位→取数→追加→写时间戳',
      outcome.ok &&
          outcome.added == 1 &&
          idleCalls == 1 &&
          fetchCalls == 1 &&
          appendCalls == 1 &&
          writeCalls == 1 &&
          last == now);
  outcome = await scheduler.runOnce();
  check('I29 周期未满直接跳过、不再取数',
      outcome.status == VodIndexUpdateStatus.skipped && fetchCalls == 1);
  // 第二十四次修：周期读**设置里的档位**，不读构造参数 —— 用户在设置页
  // 改成「三天」后，下一次 tick 就该按三天判断。
  settings = VodIndexUpdateSettings(url: a, updateIntervalDays: 3);
  last = now.subtract(const Duration(days: 2));
  outcome = await scheduler.runOnce();
  check('I29b 周期跟随设置档位：选三天且只过两天 ⇒ 跳过并写明档位',
      outcome.status == VodIndexUpdateStatus.skipped &&
          outcome.message.contains('三天') &&
          fetchCalls == 1);
  last = now;
  settings = VodIndexUpdateSettings(url: a);
  outcome = await scheduler.runOnce(force: true);
  check('I30 手动 force 忽略周期但仍走同一条追加链路',
      outcome.ok && fetchCalls == 2 && appendCalls == 2);
  settings = VodIndexUpdateSettings(url: def);
  outcome = await scheduler.runOnce(force: true);
  check('I31 默认接口也照走同一条更新链路（不再跳过）',
      outcome.ok && fetchCalls == 3 && appendCalls == 3);
  settings = VodIndexUpdateSettings(url: '', enabled: false);
  outcome = await scheduler.runOnce(force: true);
  check('I32 未设定接口跳过更新',
      outcome.status == VodIndexUpdateStatus.skipped && fetchCalls == 3);
  settings = VodIndexUpdateSettings(url: a);
  last = null;
  fetchFails = true;
  final writesBefore = writeCalls;
  outcome = await scheduler.runOnce();
  check('I33 取数失败不写时间戳（下次定时器仍会重试）',
      outcome.status == VodIndexUpdateStatus.failed &&
          writeCalls == writesBefore &&
          appendCalls == 3);
  fetchFails = false;
  final gate = Completer<List<VodItem>>();
  final slow = VodIndexAutoUpdater(
    readSettings: () async => settings,
    fetchLatest: (_) => gate.future,
    append: (_, __) async => const VodIndexAppendResult(
        ok: true, added: 1, duplicates: 0, total: 1),
    readLastUpdateAt: () async => null,
    writeLastUpdateAt: (_) async {},
    waitForIdle: () async {},
    now: () => now,
  );
  final first = slow.runOnce(force: true);
  await Future<void>.delayed(const Duration(milliseconds: 5));
  final second = await slow.runOnce(force: true);
  check('I34 单飞：并发的第二次直接 busy，不会重复写盘',
      second.status == VodIndexUpdateStatus.busy);
  gate.complete(<VodItem>[i3]);
  await first;
}

// ── J. 生成进度与「不许死循环」（第二十六次修） ──────────────────
//
// 用户红标：「正常能获取时要有进度条，无法获取时会一直闪，当获取不到要有
// 提醒，不能死循环」。这里逐条钉死：进度怎么算、什么时候清、超时怎么兜、
// 生成结束后迟到的上报必须被丢掉（否则界面会从「失败」跳回「正在获取 87%」）。
Future<void> testBuildProgress() async {
  // J1 纯模型：五个阶段的 fraction / note 逐值核对。
  const connecting = VodBuildProgress.connecting();
  check('J01 连接阶段没有确定进度（走不确定进度条）',
      connecting.fraction == null && connecting.note.contains('连接'));

  const zero = VodBuildProgress(
      stage: VodBuildStage.fetching, sitesDone: 0, sitesTotal: 45);
  check('J02 刚开始取页时留一点点进度（0/45 不能是空的）',
      zero.fraction != null && (zero.fraction! - 0.02).abs() < 1e-9);

  const mid = VodBuildProgress(
      stage: VodBuildStage.fetching,
      sitesDone: 23,
      sitesTotal: 45,
      items: 1200);
  check('J03 取页进度按站点数算，并写明已取条数',
      mid.fraction != null &&
          (mid.fraction! - 23 / 45).abs() < 1e-6 &&
          mid.note.contains('23/45') &&
          mid.note.contains('1200'));

  const full = VodBuildProgress(
      stage: VodBuildStage.fetching, sitesDone: 45, sitesTotal: 45);
  check('J04 站点翻完也封顶 90%（写盘还没完成，不能先到 100%）',
      full.fraction != null && (full.fraction! - 0.9).abs() < 1e-9);

  const unknown = VodBuildProgress(
      stage: VodBuildStage.fetching, items: 88);
  check('J05 站点总数未知时退化成不确定进度，但条数照报',
      unknown.fraction == null && unknown.note.contains('88'));

  const saving = VodBuildProgress(stage: VodBuildStage.saving, items: 300);
  check('J06 写盘阶段给 95% 并说明正在写',
      (saving.fraction! - 0.95).abs() < 1e-9 && saving.note.contains('写入'));
  check('J07 终态：done 满格、failed 不给假进度',
      const VodBuildProgress(stage: VodBuildStage.done).fraction == 1 &&
          const VodBuildProgress(stage: VodBuildStage.failed).fraction ==
              null);

  check('J08 进度快照可按值比较（UI 用相等判有没有变化）',
      mid ==
              const VodBuildProgress(
                  stage: VodBuildStage.fetching,
                  sitesDone: 23,
                  sitesTotal: 45,
                  items: 1200) &&
          mid !=
              const VodBuildProgress(
                  stage: VodBuildStage.fetching,
                  sitesDone: 24,
                  sitesTotal: 45,
                  items: 1200));

  // J2 控制器生命周期：构建期间广播、结束即清、迟到上报丢弃。
  VodIndexSnapshot? generated;
  var selected = kUrl;
  late final VodIndexGateController ctrl;
  final seen = <VodBuildProgress>[];
  ctrl = VodIndexGateController(
    readSettings: () async =>
        VodIndexSettings(configured: true, selectedUrl: selected),
    readBuiltin: () async => _snap(VodIndexOrigin.builtin),
    readGenerated: () async => generated,
    saveSettings: (url, _) async => selected = url,
    rebuild: (url, insecure, externalCode) async {
      ctrl.reportBuildProgress(const VodBuildProgress.connecting());
      ctrl.reportBuildProgress(const VodBuildProgress(
          stage: VodBuildStage.fetching,
          sitesDone: 1,
          sitesTotal: 4,
          items: 30));
      ctrl.reportBuildProgress(const VodBuildProgress(
          stage: VodBuildStage.fetching,
          sitesDone: 4,
          sitesTotal: 4,
          items: 120));
      ctrl.reportBuildProgress(
          const VodBuildProgress(stage: VodBuildStage.saving, items: 120));
      generated = _snap(VodIndexOrigin.generated, url: url, total: 120);
      return null;
    },
  );
  ctrl.addListener(() {
    final p = ctrl.buildProgress;
    if (p != null) seen.add(p);
  });
  await ctrl.check();
  final verdict = await ctrl.submit(kOther, allowInsecureHttp: false);
  // 第一步 `connecting` 与 `_submit` 里设的初值是同一个对象，被去重是**对的**
  // （界面已经在显示它），所以这里只期望后面三次真正变化的进度。
  check('J09 构建期间每次进度变化都广播到界面（初值相同则去重）',
      seen.length == 3 &&
          seen.first.stage == VodBuildStage.fetching &&
          seen.first.items == 30 &&
          seen.last.stage == VodBuildStage.saving &&
          seen.last.items == 120);
  check('J10 构建一结束进度就被清掉（不会留一条不动的进度条）',
      ctrl.buildProgress == null && verdict.ready,
      'progress=${ctrl.buildProgress} phase=${verdict.phase} '
          'origin=${verdict.origin} note=${verdict.note}');
  final before = seen.length;
  ctrl.reportBuildProgress(const VodBuildProgress(
      stage: VodBuildStage.fetching, sitesDone: 1, sitesTotal: 9));
  check('J11 结束之后迟到的上报一律丢弃（超时后底层还在跑的情况）',
      ctrl.buildProgress == null && seen.length == before);

  // J3 源码护栏：超时兜底 + 失败文案 + 两处界面都绑真实进度。
  final gateSrc = File('lib/features/vod/vod_index_gate.dart')
      .readAsStringSync();
  final page = File('lib/ui/vod/vod_page.dart').readAsStringSync();
  final section = File('lib/ui/settings/vod_source_section.dart')
      .readAsStringSync();
  check('J12 生成过程有硬截止时间（3 分钟）且到点判失败',
      kVodIndexBuildDeadline == const Duration(minutes: 3) &&
          gateSrc.contains('.timeout(') &&
          gateSrc.contains('kVodIndexBuildDeadline') &&
          gateSrc.contains('获取超时'));
  check('J13 失败文案直接告诉用户怎么办',
      gateSrc.contains('可改地址或重试'));
  check('J14 点播页与设置页都显示真实进度条',
      page.contains('gate.buildProgress') &&
          page.contains('p?.fraction') &&
          section.contains('LinearProgressIndicator(') &&
          section.contains('p?.fraction'));
}

Future<void> main() async {
  testValues();
  testGateVerdict();
  testSubmitPlan();
  await testController();
  testDirectoryDocument();
  testCollect();
  await testBrowseService();
  testWiring();
  await testSourceModule();
  await testBuildProgress();
  stdout.writeln('');
  if (_fail == 0) {
    stdout.writeln('回归通过：$_pass/$_pass 断言通过');
  } else {
    stdout.writeln('回归失败：$_pass 通过 / $_fail 失败');
    for (final f in _failures) {
      stdout.writeln('  - $f');
    }
    exit(1);
  }
}
