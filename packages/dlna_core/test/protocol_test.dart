import 'dart:async';
import 'dart:io';

import 'package:dlna_core/dlna_core.dart';
import 'package:test/test.dart';

import 'support/fake_renderer.dart';

late Directory tmpDir;
late File mediaFile;
final mediaBytes = List<int>.generate(1000, (i) => i % 256);

Future<int> freeUdpPort() async {
  final socket = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  socket.close();
  return port;
}

Future<HttpClientResponse> fetch(String url, {String method = 'GET', Map<String, String> headers = const {}}) async {
  final client = HttpClient();
  final request = await client.openUrl(method, Uri.parse(url));
  headers.forEach(request.headers.set);
  final response = await request.close();
  client.close();
  return response;
}

Future<List<int>> bodyOf(HttpClientResponse response) =>
    response.fold<List<int>>(<int>[], (all, chunk) => all..addAll(chunk));

void main() {
  setUpAll(() async {
    tmpDir = await Directory.systemTemp.createTemp('dlna-core-');
    mediaFile = File('${tmpDir.path}/Holiday Clip.mp4');
    await mediaFile.writeAsBytes(mediaBytes);
  });
  tearDownAll(() => tmpDir.delete(recursive: true));

  test('isLanAddress accepts private, loopback and link-local IPv4 only', () {
    for (final ip in [
      '10.1.2.3',
      '172.16.0.1',
      '172.31.255.255',
      '192.168.1.20',
      '169.254.3.4',
      '100.64.0.1',
      '127.0.0.1',
    ]) {
      expect(isLanAddress(ip), isTrue, reason: ip);
    }
    for (final ip in ['8.8.8.8', '172.32.0.1', '100.128.0.1', '::1', 'example.com', '192.168.1.256']) {
      expect(isLanAddress(ip), isFalse, reason: ip);
    }
  });

  test('pickLocalAddress picks the interface on the renderer\'s subnet, never the renderer itself', () async {
    const phone = ['100.72.10.5', '192.168.43.1', '192.168.1.20'];
    expect(pickLocalAddress('192.168.1.42', phone), '192.168.1.20');
    expect(pickLocalAddress('192.168.43.120', phone), '192.168.43.1');
    expect(pickLocalAddress('10.0.0.7', phone), '100.72.10.5');
    expect(pickLocalAddress('192.168.1.42', []), isNull);
    expect(await localAddressFor('127.0.0.1'), '127.0.0.1');
  });

  test('SSDP request and reply parsing', () {
    expect(
      buildSearchRequest('ssdp:all'),
      'M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: "ssdp:discover"\r\nMX: 2\r\nST: ssdp:all\r\n\r\n',
    );
    final (:startLine, :headers) = parseSsdpMessage(
      'HTTP/1.1 200 OK\r\nLocation: http://192.168.1.5:8080/d.xml\r\nusn: uuid:x\r\n\r\n',
    );
    expect(startLine, 'HTTP/1.1 200 OK');
    expect(headers['location'], 'http://192.168.1.5:8080/d.xml');
    expect(headers['usn'], 'uuid:x');
  });

  test('LOCATION must match the sender and be on the LAN', () {
    expect(acceptableLocation('http://192.168.1.5:8080/d.xml', '192.168.1.5'), isTrue);
    expect(acceptableLocation('http://192.168.1.9:8080/d.xml', '192.168.1.5'), isFalse);
    expect(acceptableLocation('http://8.8.8.8/d.xml', '8.8.8.8'), isFalse);
    expect(acceptableLocation('not a url', '192.168.1.5'), isFalse);
  });

  test('advertisedLocation accepts search replies and ssdp:alive, ignores byebye and searches', () {
    const alive = 'NOTIFY * HTTP/1.1\r\nLOCATION: http://192.168.1.42:2039/\r\nNTS: ssdp:alive\r\n\r\n';
    const byebye = 'NOTIFY * HTTP/1.1\r\nLOCATION: http://192.168.1.42:2039/\r\nNTS: ssdp:byebye\r\n\r\n';
    const reply = 'HTTP/1.1 200 OK\r\nLOCATION: http://192.168.1.42:2039/\r\n\r\n';
    expect(advertisedLocation(alive), 'http://192.168.1.42:2039/');
    expect(advertisedLocation(reply), 'http://192.168.1.42:2039/');
    expect(advertisedLocation(byebye), isNull);
    expect(advertisedLocation(buildSearchRequest('ssdp:all')), isNull);
  });

  test('parseDescription resolves control URLs and drops foreign hosts', () {
    const xml = '''<root><URLBase>http://203.0.113.1/</URLBase><device>
      <friendlyName>Living Room &amp; Den</friendlyName><UDN>uuid:abc</UDN>
      <serviceList>
        <service><serviceType>urn:schemas-upnp-org:service:AVTransport:2</serviceType><controlURL>ctl/av</controlURL></service>
        <service><serviceType>urn:schemas-upnp-org:service:RenderingControl:1</serviceType><controlURL>http://203.0.113.1/rc</controlURL></service>
      </serviceList></device></root>''';
    final device = parseDescription(xml, Uri.parse('http://192.168.1.50:49152/desc/root.xml'));
    expect(device.friendlyName, 'Living Room & Den');
    expect(device.udn, 'uuid:abc');
    expect(device.host, '192.168.1.50');
    // The foreign URLBase is ignored, so the relative URL resolves against the description location.
    expect(device.avTransport?.serviceType, 'urn:schemas-upnp-org:service:AVTransport:2');
    expect(device.avTransport?.controlUrl.toString(), 'http://192.168.1.50:49152/desc/ctl/av');
    expect(device.renderingControl, isNull);
    expect(Device.fromJson(device.toJson()).avTransport?.controlUrl, device.avTransport?.controlUrl);
  });

  test('parseRange handles explicit, open, suffix, invalid and unsatisfiable ranges', () {
    expect(parseRange(null, 100), isNull);
    expect(parseRange('bytes=0-9', 100), const ByteRange(0, 9));
    expect(parseRange('bytes=90-', 100), const ByteRange(90, 99));
    expect(parseRange('bytes=50-500', 100), const ByteRange(50, 99));
    expect(parseRange('bytes=-10', 100), const ByteRange(90, 99));
    expect(parseRange('bytes=-500', 100), const ByteRange(0, 99));
    expect(parseRange('bytes=9-3', 100), isNull);
    expect(parseRange('bytes=0-1,5-6', 100), isNull);
    expect(parseRange('items=0-1', 100), isNull);
    expect(parseRange('bytes=100-', 100), isA<Unsatisfiable>());
    expect(parseRange('bytes=-0', 100), isA<Unsatisfiable>());
  });

  test('media server serves full files, ranges and HEAD, and rejects everything else', () async {
    final seen = <int>[];
    final media = await MediaServer.start(file: mediaFile, host: '127.0.0.1', onRequest: (r) => seen.add(r.status));
    try {
      expect(media.url, matches(RegExp(r'^http://127\.0\.0\.1:\d+/media/[0-9a-f]{32}/media\.mp4$')));

      final full = await fetch(media.url);
      expect(full.statusCode, 200);
      expect(full.headers.value('content-type'), 'video/mp4');
      expect(full.headers.value('accept-ranges'), 'bytes');
      expect(full.headers.value('transfermode.dlna.org'), 'Streaming');
      expect(full.headers.value('contentfeatures.dlna.org'), startsWith('DLNA.ORG_OP=01;'));
      expect(await bodyOf(full), mediaBytes);

      final part = await fetch(media.url, headers: {'Range': 'bytes=-100'});
      expect(part.statusCode, 206);
      expect(part.headers.value('content-range'), 'bytes 900-999/1000');
      expect(await bodyOf(part), mediaBytes.sublist(900));

      final head = await fetch(media.url, method: 'HEAD');
      expect(head.statusCode, 200);
      expect(head.headers.value('content-length'), '1000');
      await head.drain<void>();

      Future<int> status(String url, {String method = 'GET', Map<String, String> headers = const {}}) async {
        final response = await fetch(url, method: method, headers: headers);
        await response.drain<void>();
        return response.statusCode;
      }

      expect(await status(media.url, headers: {'Range': 'bytes=5000-'}), 416);
      expect(await status(media.url, method: 'POST'), 405);
      expect(await status(media.url.replaceFirst(RegExp(r'[0-9a-f]{32}'), '0' * 32)), 404);
      expect(seen, [200, 206, 200, 416, 405, 404]);
    } finally {
      await media.close();
    }
  });

  test('media server only answers allowed addresses', () async {
    final media = await MediaServer.start(file: mediaFile, host: '127.0.0.1', allow: ['192.168.1.77']);
    try {
      final response = await fetch(media.url);
      await response.drain<void>();
      expect(response.statusCode, 403);
    } finally {
      await media.close();
    }
  });

  test('DIDL metadata survives SOAP escaping', () {
    final didl = buildDidl(
      url: 'http://192.168.1.2:9000/media/x/media.mp4?v=1&a=2',
      title: 'Tom & Jerry <HD>',
      mimeType: 'video/mp4',
      size: 1000,
    );
    expect(didl, contains('<dc:title>Tom &amp; Jerry &lt;HD&gt;</dc:title>'));
    expect(didl, contains('<upnp:class>object.item.videoItem</upnp:class>'));
    expect(
      didl,
      contains(
        'protocolInfo="http-get:*:video/mp4:DLNA.ORG_OP=01;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=01700000000000000000000000000000" size="1000"',
      ),
    );
    expect(didl, contains('media.mp4?v=1&amp;a=2</res>'));

    final envelope = buildEnvelope('urn:schemas-upnp-org:service:AVTransport:1', 'SetAVTransportURI', [
      ('CurrentURIMetaData', didl),
    ]);
    expect(envelope, isNot(contains('<DIDL-Lite')), reason: 'DIDL must be escaped inside the SOAP body');
    expect(envelope, contains('&lt;DIDL-Lite'));
  });

  test('SOAP response and fault parsing', () {
    const reply =
        '<s:Envelope><s:Body><u:GetPositionInfoResponse xmlns:u="x"><Track>1</Track><TrackURI/><RelTime>0:00:05</RelTime>'
        '<TrackMetaData>&lt;DIDL-Lite/&gt;</TrackMetaData></u:GetPositionInfoResponse></s:Body></s:Envelope>';
    expect(parseActionResponse(reply, 'GetPositionInfo'), {
      'Track': '1',
      'TrackURI': '',
      'RelTime': '0:00:05',
      'TrackMetaData': '<DIDL-Lite/>',
    });
    const fault =
        '<s:Fault><detail><UPnPError xmlns="urn:schemas-upnp-org:control-1-0"><errorCode>714</errorCode>'
        '<errorDescription>Illegal MIME-type</errorDescription></UPnPError></detail></s:Fault>';
    expect(parseFault(fault), (code: 714, description: 'Illegal MIME-type'));
    expect(parseFault('<html>500</html>'), isNull);
    expect(formatTime(3725.9), '1:02:05');
  });

  test('parseTime reads renderer clocks', () {
    expect(parseTime('0:00:05'), 5);
    expect(parseTime('01:02:03.500'), 3723.5);
    expect(parseTime('NOT_IMPLEMENTED'), isNull);
    expect(parseTime(''), isNull);
    expect(parseTime(null), isNull);
  });

  test("pickMimeType uses the renderer's spelling and flags unsupported types", () {
    final sinks = ['http-get:*:video/mp4:*', 'http-get:*:video/MP2T:*'];
    expect(pickMimeType(sinks, 'video/mp2t'), (mimeType: 'video/MP2T', supported: true));
    expect(pickMimeType(sinks, 'video/x-matroska'), (mimeType: 'video/x-matroska', supported: false));
    expect(pickMimeType(['http-get:*:*:*'], 'video/webm'), (mimeType: 'video/webm', supported: true));
    expect(pickMimeType(null, 'video/mp4'), (mimeType: 'video/mp4', supported: null));
  });

  group('against the fake renderer', () {
    test('unicast SSDP probe finds the fake renderer', () async {
      final renderer = await FakeRenderer.start();
      try {
        final devices = await probeDevice(
          '127.0.0.1',
          port: renderer.ssdpPort,
          notifyPort: await freeUdpPort(),
          timeout: const Duration(seconds: 2),
        );
        expect(devices, hasLength(1));
        expect(devices.single.friendlyName, 'Fake Goggles & TV');
        expect(
          devices.single.avTransport?.controlUrl.toString(),
          '${Uri.parse(renderer.location).origin}/AVTransport/control',
        );
        expect(renderer.state.searches.first, matches(RegExp(r'^M-SEARCH \* HTTP/1\.1\r\n[\s\S]*ST: ssdp:all')));
      } finally {
        await renderer.close();
      }
    });

    test('discovery finds a renderer that only announces itself with NOTIFY', () async {
      final renderer = await FakeRenderer.start(silentSearch: true);
      try {
        final notifyPort = await freeUdpPort();
        final discovery = discoverRenderers(
          multicast: false,
          notifyPort: notifyPort,
          timeout: const Duration(seconds: 3),
          settle: Duration.zero,
        ).toList();
        Timer(const Duration(milliseconds: 200), () => renderer.announce(notifyPort));
        final devices = await discovery;
        expect(devices.map((d) => d.udn), ['uuid:fake-renderer-0001']);
      } finally {
        await renderer.close();
      }
    });

    test('probing a NOTIFY-only device by IP still finds it', () async {
      final renderer = await FakeRenderer.start(silentSearch: true);
      try {
        final notifyPort = await freeUdpPort();
        final probing = probeDevice(
          '127.0.0.1',
          port: renderer.ssdpPort,
          notifyPort: notifyPort,
          timeout: const Duration(seconds: 3),
        );
        Timer(const Duration(milliseconds: 300), () => renderer.announce(notifyPort));
        final devices = await probing;
        expect(devices.firstOrNull?.udn, 'uuid:fake-renderer-0001');
        expect(renderer.state.searches, isNotEmpty, reason: 'a unicast M-SEARCH was still sent');
      } finally {
        await renderer.close();
      }
    });

    test('castFile serves the file, sets the URI with DIDL and plays end to end', () async {
      final renderer = await FakeRenderer.start();
      try {
        final device = await fetchDescription(Uri.parse(renderer.location));
        final (:media, :transport) = await castFile(device, mediaFile, title: 'Holiday Clip');
        try {
          final state = renderer.state;
          expect(state.actions, ['Stop', 'SetAVTransportURI', 'Play']);
          expect(state.soapActions[1], '"urn:schemas-upnp-org:service:AVTransport:1#SetAVTransportURI"');
          expect(state.uri, media.url);
          expect(
            state.metadata,
            matches(
              RegExp(
                r'^<DIDL-Lite .*<dc:title>Holiday Clip</dc:title>.*<res protocolInfo="http-get:\*:video/mp4:DLNA\.ORG_OP=01;',
              ),
            ),
          );

          final pulled = state.pulled!;
          expect(pulled.error, isNull);
          expect(pulled.head?.status, 200);
          expect(pulled.range?.status, 206);
          expect(pulled.range?.contentRange, 'bytes 10-19/1000');
          expect(pulled.range?.body, mediaBytes.sublist(10, 20));
          expect(pulled.full?.body, mediaBytes);

          expect((await transport.transportInfo())['CurrentTransportState'], 'PLAYING');
          expect((await transport.positionInfo())['RelTime'], '0:00:05');
          await transport.stop();
          expect((await transport.transportInfo())['CurrentTransportState'], 'STOPPED');
        } finally {
          await media.close();
        }
      } finally {
        await renderer.close();
      }
    });

    test('castLiveStream sends live DIDL with the renderer\'s spelling of MPEG-TS', () async {
      final renderer = await FakeRenderer.start();
      final live = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      live.listen((request) async {
        final response = request.response;
        response.headers.set('Content-Type', 'video/MP2T');
        response.headers.set('Accept-Ranges', 'none');
        if (request.method == 'HEAD') return response.close();
        response.add(List<int>.filled(liveSampleBytes, 0x47));
        await response.flush();
      });
      try {
        final device = await fetchDescription(Uri.parse(renderer.location));
        await castLiveStream(device, 'http://127.0.0.1:${live.port}/media/x/media.ts', title: 'Phone screen');
        expect(renderer.state.metadata, contains('http-get:*:video/MP2T:DLNA.ORG_OP=00;DLNA.ORG_CI=1;'));
        expect(renderer.state.pulled?.live?.sample.length, greaterThanOrEqualTo(liveSampleBytes));
      } finally {
        await live.close(force: true);
        await renderer.close();
      }
    });

    test('a renderer without image support refuses Play on a photo with 501, before fetching it', () async {
      final renderer = await FakeRenderer.start(rejectImages: true);
      final photo = File('${tmpDir.path}/photo.jpg')..writeAsBytesSync(mediaBytes);
      try {
        final device = await fetchDescription(Uri.parse(renderer.location));
        await expectLater(
          castFile(device, photo, title: 'Photo'),
          throwsA(isA<UpnpError>().having((e) => e.code, 'code', 501)),
        );
        expect(renderer.state.pulled, isNull);
        expect(renderer.state.metadata, contains('object.item.imageItem.photo'));
      } finally {
        await renderer.close();
      }
    });

    test('renderer faults surface as UpnpError with the UPnP code', () async {
      final renderer = await FakeRenderer.start();
      try {
        final device = await fetchDescription(Uri.parse(renderer.location));
        final transport = AVTransport(device);
        await expectLater(
          transport.play(),
          throwsA(isA<UpnpError>().having((e) => e.code, 'code', 701).having((e) => e.status, 'status', 500)),
        );
        await expectLater(transport.pause(), throwsA(isA<UpnpError>().having((e) => e.code, 'code', 701)));
        await expectLater(
          invoke(device.avTransport, 'Bogus'),
          throwsA(isA<UpnpError>().having((e) => e.code, 'code', 401)),
        );
      } finally {
        await renderer.close();
      }
    });
  });
}
