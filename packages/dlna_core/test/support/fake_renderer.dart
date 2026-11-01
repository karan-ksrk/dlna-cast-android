// A loopback DLNA renderer for tests, ported from dlna-cast's fixtures/fake-renderer.mjs. It serves a description,
// answers unicast M-SEARCH (unless `silentSearch`, like renderers that only send NOTIFY), can announce itself with
// NOTIFY, advertises formats through ConnectionManager, and on Play pulls the media like a TV would: HEAD, then a
// range and the full body for files, or the first packets of a live stream.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

const _sink = 'http-get:*:video/mp4:*,http-get:*:video/MP2T:*,http-get:*:audio/mpeg:*';
const liveSampleBytes = 188 * 200;

String _decode(String s) => s
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&apos;', "'")
    .replaceAll('&amp;', '&');

String _description(int port) =>
    '''<?xml version="1.0"?>
<root xmlns="urn:schemas-upnp-org:device-1-0">
  <specVersion><major>1</major><minor>0</minor></specVersion>
  <URLBase>http://203.0.113.9:$port/</URLBase>
  <device>
    <deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType>
    <friendlyName>Fake Goggles &amp; TV</friendlyName>
    <manufacturer>Test Co</manufacturer>
    <modelName>FR-1</modelName>
    <UDN>uuid:fake-renderer-0001</UDN>
    <serviceList>
      <service>
        <serviceType>urn:schemas-upnp-org:service:AVTransport:2</serviceType>
        <serviceId>urn:upnp-org:serviceId:Decoy</serviceId>
        <controlURL>http://198.51.100.7/hijack</controlURL>
      </service>
      <service>
        <serviceType>urn:schemas-upnp-org:service:RenderingControl:1</serviceType>
        <serviceId>urn:upnp-org:serviceId:RenderingControl</serviceId>
        <controlURL>/RenderingControl/control</controlURL>
      </service>
      <service>
        <serviceType>urn:schemas-upnp-org:service:ConnectionManager:1</serviceType>
        <serviceId>urn:upnp-org:serviceId:ConnectionManager</serviceId>
        <controlURL>/ConnectionManager/control</controlURL>
      </service>
      <service>
        <serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>
        <serviceId>urn:upnp-org:serviceId:AVTransport</serviceId>
        <controlURL>/AVTransport/control</controlURL>
      </service>
    </serviceList>
  </device>
</root>''';

String _soapReply(String action, [String body = '']) =>
    '<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body>'
    '<u:${action}Response xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">$body</u:${action}Response>'
    '</s:Body></s:Envelope>';

String _soapFault(int code, String description) =>
    '<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><s:Fault>'
    '<faultcode>s:Client</faultcode><faultstring>UPnPError</faultstring><detail>'
    '<UPnPError xmlns="urn:schemas-upnp-org:control-1-0"><errorCode>$code</errorCode>'
    '<errorDescription>$description</errorDescription></UPnPError></detail></s:Fault></s:Body></s:Envelope>';

String _clock(num seconds) {
  final s = seconds.floor();
  String pad(int n) => n.toString().padLeft(2, '0');
  return '${s ~/ 3600}:${pad((s % 3600) ~/ 60)}:${pad(s % 60)}';
}

class Pulled {
  Pulled({this.error, this.head, this.range, this.full, this.live});
  final String? error;
  final ({int status, Map<String, String> headers})? head;
  final ({int status, String? contentRange, List<int> body})? range;
  final ({int status, List<int> body})? full;
  final ({int status, Map<String, String> headers, List<int> sample})? live;
}

class FakeRendererState {
  String transport = 'NO_MEDIA_PRESENT';
  String? uri;
  String? metadata;
  final actions = <String>[];
  final soapActions = <String>[];
  final renderingActions = <String>[];
  final searches = <String>[];
  Pulled? pulled;
  num position = 5;
  num duration = 60;
  int volume = 40;
  bool muted = false;
}

Map<String, String> _headers(HttpClientResponse response) {
  final headers = <String, String>{};
  response.headers.forEach((name, values) => headers[name.toLowerCase()] = values.join(', '));
  return headers;
}

Future<List<int>> _body(HttpClientResponse response) =>
    response.fold<List<int>>(<int>[], (all, chunk) => all..addAll(chunk));

Future<Pulled> _pull(String uri) async {
  final client = HttpClient();
  try {
    final url = Uri.parse(uri);
    final head = await (await client.openUrl('HEAD', url)).close();
    await head.drain<void>();
    final headInfo = (status: head.statusCode, headers: _headers(head));
    if (headInfo.headers['accept-ranges'] == 'none') {
      final live = await (await client.getUrl(url)).close();
      final sample = <int>[];
      final done = Completer<void>();
      late final StreamSubscription<List<int>> subscription;
      subscription = live.listen((chunk) {
        sample.addAll(chunk);
        if (sample.length >= liveSampleBytes && !done.isCompleted) done.complete();
      }, onDone: () => done.isCompleted ? null : done.complete());
      await done.future.timeout(const Duration(seconds: 10));
      await subscription.cancel();
      return Pulled(head: headInfo, live: (status: live.statusCode, headers: _headers(live), sample: sample));
    }
    final rangeRequest = await client.getUrl(url);
    rangeRequest.headers.set(HttpHeaders.rangeHeader, 'bytes=10-19');
    final range = await rangeRequest.close();
    final rangeBody = await _body(range);
    final full = await (await client.getUrl(url)).close();
    return Pulled(
      head: headInfo,
      range: (status: range.statusCode, contentRange: range.headers.value('content-range'), body: rangeBody),
      full: (status: full.statusCode, body: await _body(full)),
    );
  } finally {
    client.close(force: true);
  }
}

class FakeRenderer {
  FakeRenderer._(this.state, this._server, this._ssdp, this.location);

  final FakeRendererState state;
  final HttpServer _server;
  final RawDatagramSocket _ssdp;
  final String location;

  int get ssdpPort => _ssdp.port;

  static Future<FakeRenderer> start({
    bool silentSearch = false,
    bool ignorePause = false,
    bool ignoreVolume = false,
    bool rejectImages = false,
  }) async {
    final state = FakeRendererState();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final port = server.port;
    final location = 'http://127.0.0.1:$port/description.xml';

    server.listen((req) async {
      final res = req.response;
      Future<void> send(int status, String body, [String type = 'text/xml']) async {
        res.statusCode = status;
        res.headers.contentType = ContentType.parse(type);
        res.write(body);
        await res.close();
      }

      if (req.method == 'GET' && req.uri.path == '/description.xml') return send(200, _description(port));
      if (req.method != 'POST') return send(404, '');

      final body = await utf8.decoder.bind(req).join();
      final soapAction = req.headers.value('soapaction') ?? '';
      final action = RegExp(r'#(\w+)"?$').firstMatch(soapAction)?[1] ?? '';
      Future<void> ok([String inner = '']) => send(200, _soapReply(action, inner), 'text/xml; charset="utf-8"');
      Future<void> fault(int code, String text) => send(500, _soapFault(code, text));
      String arg(String name) => _decode(RegExp('<$name>([\\s\\S]*?)</$name>').firstMatch(body)?[1] ?? '');

      if (req.uri.path == '/ConnectionManager/control') {
        return action == 'GetProtocolInfo' ? ok('<Source></Source><Sink>$_sink</Sink>') : fault(401, 'Invalid Action');
      }
      if (req.uri.path == '/RenderingControl/control') {
        state.renderingActions.add(action);
        if (arg('Channel') != 'Master') return fault(402, 'Invalid Args');
        switch (action) {
          case 'GetVolume':
            return ok('<CurrentVolume>${state.volume}</CurrentVolume>');
          // With ignoreVolume, both setters answer 200 and change nothing, like the Platinum-based goggles.
          case 'SetVolume':
            if (!ignoreVolume) state.volume = int.parse(arg('DesiredVolume'));
            return ok();
          case 'GetMute':
            return ok('<CurrentMute>${state.muted ? 1 : 0}</CurrentMute>');
          case 'SetMute':
            if (!ignoreVolume) state.muted = arg('DesiredMute') == '1';
            return ok();
          default:
            return fault(401, 'Invalid Action');
        }
      }
      if (req.uri.path != '/AVTransport/control') return send(404, '');

      state.soapActions.add(soapAction);
      state.actions.add(action);
      switch (action) {
        case 'Stop':
          state.transport = state.uri != null ? 'STOPPED' : 'NO_MEDIA_PRESENT';
          return ok();
        case 'SetAVTransportURI':
          state.uri = arg('CurrentURI');
          state.metadata = arg('CurrentURIMetaData');
          state.transport = 'STOPPED';
          return ok();
        case 'Pause':
          if (state.transport != 'PLAYING') return fault(701, 'Transition not available');
          if (!ignorePause) state.transport = 'PAUSED_PLAYBACK';
          return ok();
        case 'Seek':
          if (arg('Unit') != 'REL_TIME') return fault(710, 'Seek mode not supported');
          state.position = arg('Target').split(':').fold<num>(0, (total, part) => total * 60 + num.parse(part));
          return ok();
        case 'Play':
          if (state.uri == null) return fault(701, 'Transition not available');
          if (state.transport == 'PAUSED_PLAYBACK') {
            state.transport = 'PLAYING';
            return ok();
          }
          // With rejectImages, like the goggles: a bare 501 for any image item, without fetching it.
          if (rejectImages && (state.metadata ?? '').contains('object.item.imageItem')) {
            return fault(501, 'Action Failed');
          }
          try {
            state.pulled = await _pull(state.uri!);
          } catch (error) {
            state.pulled = Pulled(error: '$error');
            return fault(716, 'Resource not found');
          }
          state.transport = 'PLAYING';
          return ok();
        case 'GetTransportInfo':
          return ok(
            '<CurrentTransportState>${state.transport}</CurrentTransportState>'
            '<CurrentTransportStatus>OK</CurrentTransportStatus><CurrentSpeed>1</CurrentSpeed>',
          );
        case 'GetPositionInfo':
          return ok(
            '<Track>1</Track><TrackDuration>${_clock(state.duration)}</TrackDuration><TrackURI/>'
            '<RelTime>${_clock(state.position)}</RelTime>',
          );
        default:
          return fault(401, 'Invalid Action');
      }
    });

    final ssdp = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    ssdp.listen((event) {
      if (event != RawSocketEvent.read) return;
      final datagram = ssdp.receive();
      if (datagram == null) return;
      final text = utf8.decode(datagram.data);
      if (!text.startsWith('M-SEARCH')) return;
      state.searches.add(text);
      if (silentSearch) return;
      final reply =
          'HTTP/1.1 200 OK\r\nCACHE-CONTROL: max-age=1800\r\nEXT:\r\n'
          'LOCATION: $location\r\nSERVER: Fake/1.0 UPnP/1.0\r\n'
          'ST: urn:schemas-upnp-org:device:MediaRenderer:1\r\n'
          'USN: uuid:fake-renderer-0001::urn:schemas-upnp-org:device:MediaRenderer:1\r\n\r\n';
      ssdp.send(utf8.encode(reply), datagram.address, datagram.port);
    });

    return FakeRenderer._(state, server, ssdp, location);
  }

  /// Sends an ssdp:alive NOTIFY to a listener port on loopback, as a device does on its own.
  void announce(int notifyPort) {
    final notify =
        'NOTIFY * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nCACHE-CONTROL: max-age=1800\r\n'
        'LOCATION: $location\r\nNT: urn:schemas-upnp-org:device:MediaRenderer:1\r\nNTS: ssdp:alive\r\n'
        'SERVER: Fake/1.0 UPnP/1.0\r\nUSN: uuid:fake-renderer-0001::urn:schemas-upnp-org:device:MediaRenderer:1\r\n\r\n';
    _ssdp.send(utf8.encode(notify), InternetAddress.loopbackIPv4, notifyPort);
  }

  Future<void> close() async {
    _ssdp.close();
    await _server.close(force: true);
  }
}
