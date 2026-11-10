// DLNA 投屏的回归：投屏是「把播放地址交给局域网陌生人 + 按对方给的地址发请求」，
// 天然兼具 SSRF 与播放地址外泄两条风险，所以每条收紧都必须被钉住。
//
// 全部走真实 socket：本机起 UDP 端模拟 SSDP 应答（多台设备共用同端口，贴近真实网段），
// 每台设备一个 HttpServer 提供描述与控制端点。不用 Mock —— 这类 bug 基本都长在
// 「真实报文长什么样」上（大小写、相对路径、XML 实体、Fault 状态码）。
//
// 运行：dart run tooling/verify_dlna_cast.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shunbo/core/cast/cast_fallback.dart';
import 'package:shunbo/core/cast/dlna/dlna_transport.dart';
import 'package:shunbo/core/diagnostics/diagnostic_sink.dart';

int _checkCount = 0;
int _failCount = 0;

void check(String name, bool ok, [String? detail]) {
  if (!ok) {
    _failCount++;
    print('FAIL: $name${detail == null ? '' : ' —— $detail'}');
    return;
  }
  _checkCount++;
  print('PASS: $name');
}

/// 一次 SOAP 调用的记录。
class SoapCall {
  final String action;
  final String body;
  final String soapActionHeader;

  SoapCall(this.action, this.body, this.soapActionHeader);
}

/// 一台模拟渲染器：HTTP（描述 + 控制）+ 生成自己的 SSDP 应答报文。
class FakeRenderer {
  final String name;
  final String udn;
  final String serviceType;
  String controlUrl;
  final int port;

  HttpServer? _http;

  /// 覆盖 LOCATION（用于公网 / 非法 scheme 用例）；null 时用真实回环地址。
  String? locationOverride;

  /// 描述体附加的填充字节（测体积上限）。
  int descPadding = 0;

  /// 描述体写成非法 UTF-8。
  bool descInvalidUtf8 = false;

  /// 控制端点整体返回该状态码。
  int controlStatus = 200;

  /// 这些 action 返回 500 + UPnPError。
  final Set<String> failActions = <String>{};

  /// 前 N 次 Seek 失败（模拟不支持 STOPPED 状态定位的设备）。
  int seekFailsFirst = 0;

  /// 控制端点挂住不返回（测客户端超时）。
  bool hangControl = false;

  /// GetPositionInfo 返回的 RelTime。
  String relTime = '00:10:00';

  /// GetPositionInfo 返回的额外体积（测 SOAP 应答上限）。
  int positionPadding = 0;

  /// 收到的调用序列。
  final List<SoapCall> calls = <SoapCall>[];
  int seekCalls = 0;

  FakeRenderer({
    required this.name,
    required this.udn,
    this.serviceType = 'urn:schemas-upnp-org:service:AVTransport:1',
    this.controlUrl = '/control',
    this.port = 80,
  });

  Future<void> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _http = server;
    server.listen((req) async {
      try {
        if (req.uri.path == '/desc.xml') {
          await _writeDesc(req);
          return;
        }
        if (req.uri.path == '/control') {
          await _handleSoap(req);
          return;
        }
        req.response.statusCode = 404;
        await req.response.close();
      } catch (e) {
        // 客户端超时/中断会让写响应抛错，属预期；但夹具自身错误必须可见，
        // 否则又会表现成「被测代码莫名超时」。
        stderr.writeln('fixture[$name] ${req.uri.path}: $e');
      }
    });
  }

  int get httpPort => _http!.port;

  String get location =>
      locationOverride ?? 'http://127.0.0.1:$httpPort/desc.xml';

  /// SSDP 200 OK 应答。头名故意混用大小写，验证客户端解析不区分大小写。
  String ssdpResponse() => 'HTTP/1.1 200 OK\r\n'
      'CACHE-CONTROL: max-age=1800\r\n'
      'Location: $location\r\n'
      'SERVER: TestFixture/1.0 UPnP/1.1 ShunboFake/0.1\r\n'
      'ST: urn:schemas-upnp-org:device:MediaRenderer:1\r\n'
      'USN: uuid:$udn::urn:schemas-upnp-org:device:MediaRenderer:1\r\n'
      '\r\n';

  Future<void> _writeDesc(HttpRequest req) async {
    final service = serviceType.isEmpty
        ? ''
        : '<service>'
            '<serviceType>$serviceType</serviceType>'
            '<serviceId>urn:upnp-org:serviceId:AVTransport</serviceId>'
            '<controlURL>$controlUrl</controlURL>'
            '<eventSubURL>/evt</eventSubURL>'
            '<SCPDURL>/scpd.xml</SCPDURL>'
            '</service>';
    final pad = descPadding > 0 ? '<!--${'p' * descPadding}-->' : '';
    final xml = '<?xml version="1.0"?>'
        '<root xmlns="urn:schemas-upnp-org:device-1-0"><device>'
        '<deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType>'
        '<friendlyName>$name</friendlyName>'
        '<UDN>uuid:$udn</UDN>'
        '<serviceList>$service</serviceList>'
        '</device></root>$pad';

    req.response.headers.contentType =
        ContentType.parse('text/xml; charset="utf-8"');
    req.response.add(descInvalidUtf8 ? <int>[0x3C, 0xFF, 0xFE, 0x3E] : utf8.encode(xml));
    await req.response.close();
  }

  Future<void> _handleSoap(HttpRequest req) async {
    final header = req.headers.value('soapaction') ?? '';
    final body = await utf8.decodeStream(req);
    final action = header.replaceAll('"', '').split('#').last.trim();
    calls.add(SoapCall(action, body, header));

    if (hangControl) {
      // 比客户端 requestTimeout 长得多，制造真实的「设备不响应」。
      await Future<void>.delayed(const Duration(seconds: 3));
      return;
    }

    final resp = req.response;
    if (controlStatus != 200) {
      resp.statusCode = controlStatus;
      resp.add(utf8.encode('<html>nope</html>'));
      await resp.close();
      return;
    }
    if (failActions.contains(action)) {
      resp.statusCode = 500;
      resp.headers.contentType =
          ContentType.parse('text/xml; charset="utf-8"');
      resp.add(utf8.encode('<?xml version="1.0"?>'
          '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">'
          '<s:Body><s:Fault><detail><UPnPError>'
          '<errorCode>701</errorCode><errorDescription>Transition not available'
          '</errorDescription></UPnPError></detail></s:Fault></s:Body>'
          '</s:Envelope>'));
      await resp.close();
      return;
    }
    if (action == 'Seek') {
      seekCalls++;
      if (seekCalls <= seekFailsFirst) {
        resp.statusCode = 500;
        resp.add(utf8.encode('<s:Fault>not supported</s:Fault>'));
        await resp.close();
        return;
      }
    }

    final payload = switch (action) {
      'GetTransportInfo' =>
        '<CurrentTransportState>PLAYING</CurrentTransportState>'
            '<CurrentTransportStatus>OK</CurrentTransportStatus>',
      'GetPositionInfo' =>
        '<Track>1</Track><RelTime>$relTime</RelTime>'
            '<TrackDuration>01:00:00</TrackDuration>'
            '${positionPadding > 0 ? '<!--${'q' * positionPadding}-->' : ''}',
      _ => '',
    };
    resp.statusCode = 200;
    resp.headers.contentType = ContentType.parse('text/xml; charset="utf-8"');
    resp.add(utf8.encode('<?xml version="1.0"?>'
        '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">'
        '<s:Body><u:${action}Response xmlns:u="$serviceType">$payload'
        '</u:${action}Response></s:Body></s:Envelope>'));
    await resp.close();
  }

  /// 该设备上出现过的 action 名字。
  List<String> get actions => calls.map((c) => c.action).toList();

  SoapCall? callOf(String action) {
    for (final c in calls) {
      if (c.action == action) return c;
    }
    return null;
  }

  Future<void> close() async {
    await _http?.close(force: true);
    _http = null;
  }
}

/// 一个「网段」：一个 UDP 端口，收到 M-SEARCH 后让所有设备各自应答。
class SsdpSegment {
  RawDatagramSocket? _socket;
  final List<FakeRenderer> devices;

  /// 收到过多少次 M-SEARCH（用于钉住「客户端会重发」这条不变量）。
  int searchCount = 0;

  SsdpSegment(this.devices);

  Future<int> start() async {
    final s = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    _socket = s;
    s.listen((event) {
      if (event != RawSocketEvent.read) return;
      final dg = s.receive();
      if (dg == null) return;
      searchCount++;
      // 不 await：应答按设备错开几毫秒再发。真实网段里各台设备是独立进程、
      // 独立网卡，不会在同一毫秒一起回包；若在夹具里一口气发 10 条回环 UDP，
      // 会人为制造突发丢包，让「某类恶意 LOCATION 没被标注」这种假失败随机出现。
      _reply(s, dg);
    });
    return s.port;
  }

  /// 每台设备两条应答（真实设备会因子服务类型重复应答），设备之间错开 3ms。
  Future<void> _reply(RawDatagramSocket s, Datagram dg) async {
    for (final d in devices) {
      try {
        s.send(utf8.encode(d.ssdpResponse()), dg.address, dg.port);
        s.send(utf8.encode(d.ssdpResponse()), dg.address, dg.port);
      } catch (_) {
        // 客户端已关闭端口，忽略。
      }
      await Future<void>.delayed(const Duration(milliseconds: 3));
    }
  }

  int get port => _socket!.port;

  void close() {
    _socket?.close();
    _socket = null;
  }
}

/// 一套夹具：网段 + 若干净设备。
Future<DlnaCastTransport> _transportFor(SsdpSegment seg,
        {int maxDevices = 32,
        int maxDescriptionBytes = 256 * 1024,
        int maxSoapResponseBytes = 64 * 1024,
        Duration requestTimeout = const Duration(seconds: 2),
        bool allowPublic = false}) =>
    Future.value(DlnaCastTransport(
      config: DlnaConfig(
        multicastAddress: '127.0.0.1',
        multicastPort: seg.port,
        discoverTimeout: const Duration(milliseconds: 800),
        requestTimeout: requestTimeout,
        // 生产默认会重发：UDP 丢包在真实网段是常态，单发一次会「电视时有时无」。
        resendCount: 3,
        resendInterval: const Duration(milliseconds: 120),
        maxDevices: maxDevices,
        maxDescriptionBytes: maxDescriptionBytes,
        maxSoapResponseBytes: maxSoapResponseBytes,
        allowPublicAddresses: allowPublic,
      ),
    ));

Future<void> _main() async {
  await _discoveryGroup();
  await _boundaryGroup();
  await _controlGroup();
  await _endToEndGroup();
}

Future<void> _discoveryGroup() async {
  print('\n== A. 发现与设备描述 ==');

  final tv = FakeRenderer(name: '客厅电视', udn: 'tv-living');
  final box = FakeRenderer(name: '卧室盒子', udn: 'box-bed');
  await tv.start();
  await box.start();
  final seg = SsdpSegment(<FakeRenderer>[tv, box]);
  await seg.start();

  final t = await _transportFor(seg);
  final devices = await t.discover();
  check('发现 2 台设备', devices.length == 2, '${devices.length}');
  check('按 friendlyName 命名',
      devices.map((d) => d.name).toSet().containsAll(<String>['客厅电视', '卧室盒子']),
      '${devices.map((d) => d.name).toList()}');
  check('设备 id 用 UDN',
      devices.any((d) => d.id == 'uuid:tv-living'),
      '${devices.map((d) => d.id).toList()}');
  check('重复 SSDP 应答去重（每台只出现一次）',
      devices.length == 2 && devices.map((d) => d.id).toSet().length == 2);
  check('协议标注为 dlna', devices.every((d) => d.protocol == 'dlna'));
  check('M-SEARCH 会重发（UDP 丢包常态，单发会漏设备）',
      seg.searchCount >= 2, '${seg.searchCount}');

  // 相对 controlURL 必须解析到设备自己的 origin。
  check('相对 controlURL 解析成绝对地址',
      t.discovered['uuid:tv-living'] != null, '${t.discovered.keys}');

  await t.discover();
  check('再次 discover 重建端点表（不累积旧设备）', t.discovered.length == 2);

  seg.close();
  await tv.close();
  await box.close();

  // 无 AVTransport 服务的设备（如纯 MediaServer）不应当作投屏目标。
  final server = FakeRenderer(name: 'NAS', udn: 'nas', serviceType: '');
  await server.start();
  final seg2 = SsdpSegment(<FakeRenderer>[server]);
  await seg2.start();
  final t2 = await _transportFor(seg2);
  final d2 = await t2.discover();
  check('无 AVTransport 的设备被过滤', d2.isEmpty, '${d2.length}');
  check('过滤原因可读（供 UI 排查）',
      t2.discoveryNotes.any((n) => n.contains('AVTransport')),
      '${t2.discoveryNotes}');
  seg2.close();
  await server.close();

  // 没有任何应答：靠超时收尾，返回空列表而不是抛异常。
  final seg3 = SsdpSegment(const <FakeRenderer>[]);
  await seg3.start();
  final t3 = await _transportFor(seg3);
  final clock = DateTime.now();
  final d3 = await t3.discover();
  final elapsed = DateTime.now().difference(clock);
  check('无设备时返回空列表', d3.isEmpty);
  check('无设备时按 discoverTimeout 收尾（不挂死）',
      elapsed.inMilliseconds < 2000, '${elapsed.inMilliseconds}ms');
  seg3.close();
}

Future<void> _boundaryGroup() async {
  print('\n== B. 来自网络的不可信输入 ==');

  // 公网 LOCATION：SSDP 应答可以把客户端指到任意地方，必须丢弃。
  final pub = FakeRenderer(name: '公网诱饵', udn: 'pub')
    ..locationOverride = 'http://8.8.8.8/desc.xml';
  final pub2 = FakeRenderer(name: '明文陷阱', udn: 'pub2')
    ..locationOverride = 'file:///c:/windows/win.ini';
  final pub3 = FakeRenderer(name: 'HTTPS', udn: 'pub3')
    ..locationOverride = 'https://127.0.0.1:9/desc.xml';
  final pub4 = FakeRenderer(name: '带凭据', udn: 'pub4')
    ..locationOverride = 'http://user:pass@127.0.0.1:9/desc.xml';
  final pub5 = FakeRenderer(name: '未知域名', udn: 'pub5')
    ..locationOverride = 'http://evil.example.com/desc.xml';
  for (final d in <FakeRenderer>[pub, pub2, pub3, pub4, pub5]) {
    await d.start();
  }

  final seg = SsdpSegment(<FakeRenderer>[pub, pub2, pub3, pub4, pub5]);
  await seg.start();
  final t = await _transportFor(seg);
  final d = await t.discover();
  check('公网 / 非 http / 内联凭据 / 未知域名的 LOCATION 全部丢弃', d.isEmpty, '${d.length}');
  check('公网地址被明确标注原因',
      t.discoveryNotes.any((n) => n.contains('公网')), '${t.discoveryNotes}');
  check('非 http scheme 被标注',
      t.discoveryNotes.any((n) => n.contains('非 http')), '${t.discoveryNotes}');
  check('内联凭据被标注',
      t.discoveryNotes.any((n) => n.contains('凭据')), '${t.discoveryNotes}');
  seg.close();
  for (final x in <FakeRenderer>[pub, pub2, pub3, pub4, pub5]) {
    await x.close();
  }

  // 跨 origin 的 controlURL：一张设备描述就能指使客户端把 SOAP 发给第三方。
  final evil = FakeRenderer(name: '重定向控制端', udn: 'evil')
    ..controlUrl = 'http://127.0.0.1:9/control';
  await evil.start();
  final seg2 = SsdpSegment(<FakeRenderer>[evil]);
  await seg2.start();
  final t2 = await _transportFor(seg2);
  final d2 = await t2.discover();
  check('跨 origin 的 controlURL 被拒绝', d2.isEmpty, '${d2.length}');
  check('跨 origin 原因可读',
      t2.discoveryNotes.any((n) => n.contains('跨 origin')), '${t2.discoveryNotes}');
  seg2.close();
  await evil.close();

  // 描述体超限：设备可能吐无限流，必须边读边截断。
  final huge = FakeRenderer(name: '超大描述', udn: 'huge')..descPadding = 400 * 1024;
  await huge.start();
  final seg3 = SsdpSegment(<FakeRenderer>[huge]);
  await seg3.start();
  final t3 = await _transportFor(seg3, maxDescriptionBytes: 64 * 1024);
  final d3 = await t3.discover();
  check('描述超过体积上限时丢弃该设备', d3.isEmpty, '${d3.length}');
  seg3.close();
  await huge.close();

  // 描述体不是 UTF-8：解码失败不能当作「空名字设备」放行。
  final bad = FakeRenderer(name: '坏编码', udn: 'bad')..descInvalidUtf8 = true;
  await bad.start();
  final seg4 = SsdpSegment(<FakeRenderer>[bad]);
  await seg4.start();
  final t4 = await _transportFor(seg4);
  final d4 = await t4.discover();
  check('非法 UTF-8 的描述被丢弃', d4.isEmpty, '${d4.length}');
  seg4.close();
  await bad.close();

  // 设备数上限：恶意/密集网段不能把发现过程拖成 O(n) 个 HTTP 请求。
  final many = <FakeRenderer>[];
  for (var i = 0; i < 4; i++) {
    final r = FakeRenderer(name: '设备$i', udn: 'm$i');
    await r.start();
    many.add(r);
  }
  final seg5 = SsdpSegment(many);
  await seg5.start();
  final t5 = await _transportFor(seg5, maxDevices: 2);
  final d5 = await t5.discover();
  check('设备数不超过 maxDevices', d5.length <= 2, '${d5.length}');
  seg5.close();
  for (final r in many) {
    await r.close();
  }

  // XML 实体：设备名里的 &amp; 要还原，否则 UI 会显示 `客厅 &amp; 影音`。
  final ent = FakeRenderer(name: '客厅 &amp; 影音', udn: 'ent');
  await ent.start();
  final seg6 = SsdpSegment(<FakeRenderer>[ent]);
  await seg6.start();
  final t6 = await _transportFor(seg6);
  final d6 = await t6.discover();
  check('friendlyName 中的 XML 实体被还原',
      d6.length == 1 && d6.first.name == '客厅 & 影音', '${d6.map((e) => e.name).toList()}');
  seg6.close();
  await ent.close();
}

Future<void> _controlGroup() async {
  print('\n== C. 连接 / 起播 / 定位 / 断开 ==');

  final tv = FakeRenderer(name: '客厅电视', udn: 'tv-ctl');
  await tv.start();
  final seg = SsdpSegment(<FakeRenderer>[tv]);
  await seg.start();
  final t = await _transportFor(seg);
  await t.discover();

  check('connect 未发现的设备返回 false', !await t.connect('uuid:nope'));
  check('connect 成功后发出 GetTransportInfo',
      await t.connect('uuid:tv-ctl') && tv.actions.contains('GetTransportInfo'),
      '${tv.actions}');
  tv.calls.clear();

  final ok = await t.play(
      url: 'https://cdn.example.com/a.m3u8?token=x&sig=y', positionSeconds: 3725.4);
  check('play 成功', ok);
  check('SOAP 序列为 SetAVTransportURI → Play → Seek',
      tv.actions.join('>') == 'SetAVTransportURI>Play>Seek', '${tv.actions}');
  final setUri = tv.callOf('SetAVTransportURI');
  check('SetAVTransportURI 中的 URL 做了 XML 转义',
      setUri != null && setUri.body.contains('&amp;') && !setUri.body.contains('x&sig'),
      '${setUri?.body}');
  check('SOAPACTION 头形如 "serviceType#Action"',
      setUri?.soapActionHeader ==
          '"urn:schemas-upnp-org:service:AVTransport:1#SetAVTransportURI"',
      '${setUri?.soapActionHeader}');
  final seek = tv.callOf('Seek');
  check('Seek 目标换算为 HH:MM:SS（3725.4s → 01:02:05）',
      seek != null && seek.body.contains('<Target>01:02:05</Target>'),
      '${seek?.body}');
  check('Seek 使用 REL_TIME',
      seek != null && seek.body.contains('<Unit>REL_TIME</Unit>'));

  // 位置 0 不该发 Seek（多发一次无意义请求会拖慢起播）。
  tv.calls.clear();
  await t.play(url: 'https://cdn.example.com/b.m3u8', positionSeconds: 0);
  check('位置为 0 时不发 Seek',
      tv.actions.join('>') == 'SetAVTransportURI>Play', '${tv.actions}');

  // 位置读取
  tv.calls.clear();
  tv.relTime = '01:23:45';
  check('GetPositionInfo 解析 RelTime=01:23:45 → 5025s',
      (await t.currentPositionSeconds()) == 5025.0,
      '${await t.currentPositionSeconds()}');
  tv.relTime = '00:00:07.500';
  check('带毫秒的 RelTime 也被解析',
      (await t.currentPositionSeconds()) == 7.5);
  tv.relTime = 'NOT_IMPLEMENTED';
  var threw = false;
  try {
    await t.currentPositionSeconds();
  } on DlnaCastException catch (e) {
    threw = e.reason == DlnaFailure.positionUnavailable;
  }
  check('RelTime=NOT_IMPLEMENTED 抛 positionUnavailable', threw);
  tv.relTime = '00:10:00';

  await t.disconnect();
  check('disconnect 发出 Stop', tv.actions.contains('Stop'), '${tv.actions}');
  var afterStop = false;
  try {
    await t.currentPositionSeconds();
  } on DlnaCastException catch (e) {
    afterStop = e.reason == DlnaFailure.unknownDevice;
  }
  check('disconnect 后位置读取报 unknownDevice（不乱报旧值）', afterStop);
  tv.calls.clear();
  await t.disconnect();
  check('重复 disconnect 不发第二次 Stop（幂等）', tv.calls.isEmpty, '${tv.actions}');

  seg.close();
  await tv.close();

  // SetAVTransportURI 失败：必须返回 false，交给上层降级。
  final broken = FakeRenderer(name: '起播失败', udn: 'broken')
    ..failActions.add('SetAVTransportURI');
  await broken.start();
  final seg2 = SsdpSegment(<FakeRenderer>[broken]);
  await seg2.start();
  final t2 = await _transportFor(seg2);
  await t2.discover();
  await t2.connect('uuid:broken');
  check('SetAVTransportURI 返回 UPnP Fault → play 失败',
      !await t2.play(url: 'https://x/y.m3u8', positionSeconds: 10));
  check('起播失败不误发 Play',
      !broken.actions.contains('Play'), '${broken.actions}');
  seg2.close();
  await broken.close();

  // Seek 失败 → Pause→Seek→Play 退化重试
  final picky = FakeRenderer(name: '不支持直接定位', udn: 'picky')..seekFailsFirst = 1;
  await picky.start();
  final seg3 = SsdpSegment(<FakeRenderer>[picky]);
  await seg3.start();
  final t3 = await _transportFor(seg3);
  await t3.discover();
  await t3.connect('uuid:picky');
  picky.calls.clear();
  final retried = await t3.play(url: 'https://x/z.m3u8', positionSeconds: 100);
  check('首次 Seek 失败后经 Pause→Seek→Play 恢复', retried,
      '${picky.actions}');
  check('退化路径序列正确',
      picky.actions.join('>') ==
          'SetAVTransportURI>Play>Seek>Pause>Seek>Play',
      '${picky.actions}');
  seg3.close();
  await picky.close();

  // 两次 Seek 都失败 → 放弃投屏（「从 0 秒开始播」比失败更糟）
  final noSeek = FakeRenderer(name: '完全不支持定位', udn: 'noseek')
    ..seekFailsFirst = 99;
  await noSeek.start();
  final seg4 = SsdpSegment(<FakeRenderer>[noSeek]);
  await seg4.start();
  final t4 = await _transportFor(seg4);
  await t4.discover();
  await t4.connect('uuid:noseek');
  check('两次 Seek 都失败 → play 返回 false，让上层降级',
      !await t4.play(url: 'https://x/w.m3u8', positionSeconds: 100));
  check('放弃原因可读',
      t4.discoveryNotes.any((n) => n.contains('不支持定位')), '${t4.discoveryNotes}');
  seg4.close();
  await noSeek.close();

  // 探活失败（设备在线但控制端点异常）→ connect false
  final sick = FakeRenderer(name: '控制异常', udn: 'sick')..controlStatus = 503;
  await sick.start();
  final seg5 = SsdpSegment(<FakeRenderer>[sick]);
  await seg5.start();
  final t5 = await _transportFor(seg5);
  await t5.discover();
  check('探活返回 503 → connect false', !await t5.connect('uuid:sick'));
  seg5.close();
  await sick.close();

  // 控制端点挂住 → 客户端按 requestTimeout 放弃
  final hang = FakeRenderer(name: '不响应', udn: 'hang')..hangControl = true;
  await hang.start();
  final seg6 = SsdpSegment(<FakeRenderer>[hang]);
  await seg6.start();
  final t6 = await _transportFor(seg6,
      requestTimeout: const Duration(milliseconds: 300));
  await t6.discover();
  final clock = DateTime.now();
  final hungOk = await t6.connect('uuid:hang');
  final ms = DateTime.now().difference(clock).inMilliseconds;
  check('设备不响应时 connect 在超时后返回 false', !hungOk);
  check('超时生效（未无限等待）', ms < 2500, '${ms}ms');
  seg6.close();
  await hang.close();

  // SOAP 应答超限
  final fat = FakeRenderer(name: '超大应答', udn: 'fat')..positionPadding = 32 * 1024;
  await fat.start();
  final seg7 = SsdpSegment(<FakeRenderer>[fat]);
  await seg7.start();
  final t7 = await _transportFor(seg7, maxSoapResponseBytes: 8 * 1024);
  await t7.discover();
  await t7.connect('uuid:fat');
  var cappedThrew = false;
  try {
    await t7.currentPositionSeconds();
  } on DlnaCastException catch (e) {
    cappedThrew = e.reason == DlnaFailure.soapFailed;
  }
  check('SOAP 应答超过上限即中断并抛错', cappedThrew);
  seg7.close();
  await fat.close();

  // play 前没 connect
  final emptySeg = SsdpSegment(const <FakeRenderer>[]);
  await emptySeg.start();
  final t8 = await _transportFor(emptySeg);
  check('未连接时 play 返回 false',
      !await t8.play(url: 'https://x/y.m3u8', positionSeconds: 1));
}

Future<void> _endToEndGroup() async {
  print('\n== D. 与 CastFallbackController 的端到端 ==');

  final diag = _RecordingSink();
  final tv = FakeRenderer(name: '客厅电视', udn: 'e2e')..relTime = '00:20:00';
  await tv.start();
  final seg = SsdpSegment(<FakeRenderer>[tv]);
  await seg.start();
  final transport = await _transportFor(seg);
  final ctrl = CastFallbackController(transport: transport, diagnostics: diag);

  final ok = await ctrl.startCast(
    mediaId: 'm1',
    url: 'https://cdn.example.com/e2e.m3u8',
    rawEpisode: 3,
    rawSeconds: 600,
  );
  check('端到端投屏成功', ok.casting, '${ok.attempts}');
  check('成功结果带回设备信息', ok.device?.name == '客厅电视');
  check('成功埋点 castStarted',
      diag.kinds.contains(DiagnosticKind.castStarted), '${diag.kinds}');
  check('投屏携带的仍是源原始坐标（不做内容换算）',
      ok.rawEpisode == 3 && ok.rawSeconds == 600);

  // 播放中断：位置只能前进，不能因设备上报更小值而倒退。
  tv.relTime = '00:05:00'; // 600s，与本地已知相同
  final lost = await ctrl.onConnectionLost(
      mediaId: 'm1', rawEpisode: 3, lastKnownRawSeconds: 700);
  check('连接中断降级回本机', !lost.casting);
  check('降级原因 connectionLost', lost.reason == CastFailureReason.connectionLost);
  check('设备位置更小时保留本地进度（不倒退）',
      lost.rawSeconds == 700, '${lost.rawSeconds}');
  check('降级埋点 castFallback',
      diag.kinds.contains(DiagnosticKind.castFallback));

  // 中断后 transport 已断开（position 读不到，只会回本地值），所以要重新投屏
  // 再制造一次中断，才能验证「设备报的位置更大时采纳设备位置」。
  await ctrl.startCast(
    mediaId: 'm1',
    url: 'https://cdn.example.com/e2e.m3u8',
    rawEpisode: 3,
    rawSeconds: 700,
  );
  tv.relTime = '00:12:00'; // 720s，比本地更大
  final advanced = await ctrl.onConnectionLost(
      mediaId: 'm1', rawEpisode: 3, lastKnownRawSeconds: 700);
  check('设备位置更大时采纳设备位置（进度前进）',
      advanced.rawSeconds == 720, '${advanced.rawSeconds}');

  seg.close();
  await tv.close();

  // 设备全不可用 → 自动降级，且坐标原样带回，用户能就地继续看。
  final dead = FakeRenderer(name: '坏设备', udn: 'dead')..controlStatus = 503;
  await dead.start();
  final seg2 = SsdpSegment(<FakeRenderer>[dead]);
  await seg2.start();
  final t2 = await _transportFor(seg2);
  final r2 = await CastFallbackController(transport: t2).startCast(
    mediaId: 'm2',
    url: 'https://cdn.example.com/x.m3u8',
    rawEpisode: 5,
    rawSeconds: 321.5,
  );
  check('所有设备不可用时降级回本机', !r2.casting);
  check('降级保留原始坐标（可直接续播）',
      r2.rawEpisode == 5 && r2.rawSeconds == 321.5);
  check('降级给出可执行提示',
      r2.userMessage.contains('已切回本机播放'), r2.userMessage);
  check('连接失败原因记为 connectFailed',
      r2.reason == CastFailureReason.connectFailed, '${r2.reason}');
  seg2.close();
  await dead.close();
}

class _RecordingSink implements DiagnosticSink {
  final List<DiagnosticKind> kinds = <DiagnosticKind>[];
  final List<DiagnosticEvent> events = <DiagnosticEvent>[];

  @override
  void record(DiagnosticEvent event) {
    kinds.add(event.kind);
    events.add(event);
  }
}

Future<void> main() async {
  await _main();
  final total = _checkCount + _failCount;
  print('\n$_checkCount/$total 断言通过'
      '${_failCount == 0 ? '' : '（失败 $_failCount 项）'}');
  if (_failCount > 0) {
    exitCode = 1;
  }
  // 夹具里有挂住的连接（超时用例），不强行退出会拖住进程。
  exit(exitCode);
}
