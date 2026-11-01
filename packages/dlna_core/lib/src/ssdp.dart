import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'description.dart';
import 'lan.dart';

const ssdpAddress = '239.255.255.250';
const ssdpPort = 1900;
const rendererSearchTargets = [
  'urn:schemas-upnp-org:device:MediaRenderer:1',
  'urn:schemas-upnp-org:service:AVTransport:1',
  'upnp:rootdevice',
];
const _searchInterval = Duration(seconds: 3);

// Description paths common renderers use, tried when a device answers HTTP but not SSDP.
const _descriptionPaths = [
  '/',
  '/description.xml',
  '/desc.xml',
  '/rootDesc.xml',
  '/upnp/rootDesc.xml',
  '/upnp/dev/description.xml',
  '/dmr/SatipServerDesc.xml',
];

String buildSearchRequest(String searchTarget, {String host = '$ssdpAddress:$ssdpPort', int mx = 2}) =>
    'M-SEARCH * HTTP/1.1\r\n'
    'HOST: $host\r\n'
    'MAN: "ssdp:discover"\r\n'
    'MX: $mx\r\n'
    'ST: $searchTarget\r\n\r\n';

({String startLine, Map<String, String> headers}) parseSsdpMessage(String text) {
  final lines = text.split(RegExp(r'\r?\n'));
  final headers = <String, String>{};
  for (final line in lines.skip(1)) {
    final colon = line.indexOf(':');
    if (colon > 0) headers[line.substring(0, colon).trim().toLowerCase()] = line.substring(colon + 1).trim();
  }
  return (startLine: lines.first.trim(), headers: headers);
}

/// Trust a LOCATION only on a LAN address matching the host that sent it.
bool acceptableLocation(String location, String senderIp) {
  final url = Uri.tryParse(location);
  return url != null && url.scheme == 'http' && url.host == senderIp && isLanAddress(senderIp);
}

final _okStatus = RegExp(r'^HTTP/1\.[01] 200', caseSensitive: false);
final _notify = RegExp(r'^NOTIFY ', caseSensitive: false);
final _alive = RegExp(r'ssdp:alive', caseSensitive: false);

/// A device's LOCATION from either an M-SEARCH reply or an ssdp:alive NOTIFY, or null.
String? advertisedLocation(String text) {
  final (:startLine, :headers) = parseSsdpMessage(text);
  final location = headers['location'];
  if (location == null) return null;
  if (_okStatus.hasMatch(startLine)) return location;
  if (_notify.hasMatch(startLine) && _alive.hasMatch(headers['nts'] ?? '')) return location;
  return null;
}

/// Finds renderers two ways at once: active M-SEARCH (repeated every few seconds) and a passive listener for the
/// NOTIFY announcements devices multicast on their own. Some renderers (the Platinum-based goggles among them) only
/// do the latter. On Android the app must hold a `WifiManager.MulticastLock` or the NOTIFYs never arrive.
///
/// - [ip] restricts discovery to one device: unicast M-SEARCH to it, and only its NOTIFYs count.
/// - [settle] ends discovery that long after the first renderer appears, instead of waiting for [timeout].
///
/// The stream emits each renderer once, as soon as its description loads, and closes when discovery ends;
/// cancelling the subscription ends it early.
Stream<Device> discoverRenderers({
  Duration timeout = const Duration(seconds: 8),
  Duration? settle,
  String? ip,
  int port = ssdpPort,
  int notifyPort = ssdpPort,
  bool multicast = true,
  List<String> searchTargets = rendererSearchTargets,
}) {
  final sockets = <RawDatagramSocket>[];
  final timers = <Timer>[];
  final seenLocations = <String>{};
  final found = <String>{};
  final pending = <Future<void>>{};
  var finished = false;
  late final StreamController<Device> controller;

  Future<void> finish() async {
    if (finished) return;
    finished = true;
    for (final timer in timers) {
      timer.cancel();
    }
    for (final socket in sockets) {
      socket.close();
    }
    await Future.wait(pending);
    await controller.close();
  }

  void consider(String location, String from) {
    if (finished || seenLocations.contains(location)) return;
    if (ip != null && from != ip) return;
    if (!acceptableLocation(location, from)) return;
    seenLocations.add(location);
    late final Future<void> lookup;
    lookup = fetchDescription(Uri.parse(location))
        .then((device) {
          if (finished || device.avTransport == null || !found.add(device.key)) return;
          controller.add(device);
          if (settle != null && found.length == 1) timers.add(Timer(settle, finish));
        })
        .catchError((Object _) {
          // Allow a later announcement to retry a description that failed to load.
          seenLocations.remove(location);
        })
        .whenComplete(() => pending.remove(lookup));
    pending.add(lookup);
  }

  void listen(RawDatagramSocket socket) {
    sockets.add(socket);
    socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      final datagram = socket.receive();
      if (datagram == null) return;
      final location = advertisedLocation(utf8.decode(datagram.data, allowMalformed: true));
      if (location != null) consider(location, datagram.address.address);
    }, onError: (Object _) => socket.close());
  }

  Future<void> start() async {
    final interfaces = await lanInterfaces();

    // Passive: devices announce themselves to 239.255.255.250:1900 every few seconds.
    try {
      final listener = await RawDatagramSocket.bind(InternetAddress.anyIPv4, notifyPort, reuseAddress: true);
      if (finished) return listener.close();
      listen(listener);
      final group = InternetAddress(ssdpAddress);
      for (final lan in interfaces) {
        try {
          listener.joinMulticast(group, lan.networkInterface);
        } catch (_) {
          // Interface without multicast; others may still work.
        }
      }
      if (interfaces.isEmpty) {
        try {
          listener.joinMulticast(group);
        } catch (_) {
          // No multicast at all; unicast searches still work.
        }
      }
    } on SocketException {
      // Another app holds port 1900 without SO_REUSEADDR; searches still work.
    }

    // Active: M-SEARCH from each interface, or unicast to one device.
    final searches = <({InternetAddress bind, String destination})>[
      if (ip != null)
        (bind: InternetAddress.anyIPv4, destination: ip)
      else if (multicast)
        for (final bind in interfaces.isEmpty ? [InternetAddress.anyIPv4] : interfaces.map((i) => i.address))
          (bind: bind, destination: ssdpAddress),
    ];
    for (final (:bind, :destination) in searches) {
      final RawDatagramSocket socket;
      try {
        socket = await RawDatagramSocket.bind(bind, 0, reuseAddress: true);
      } on SocketException {
        continue;
      }
      if (finished) return socket.close();
      listen(socket);
      if (destination == ssdpAddress && bind != InternetAddress.anyIPv4) {
        try {
          socket.multicastHops = 2;
          socket.setRawOption(
            RawSocketOption(
              RawSocketOption.levelIPv4,
              RawSocketOption.IPv4MulticastInterface,
              Uint8List.fromList(bind.rawAddress),
            ),
          );
        } catch (_) {
          // Keep the OS default route.
        }
      }
      final target = InternetAddress(destination);
      void sendAll() {
        if (finished) return;
        for (final st in searchTargets) {
          socket.send(utf8.encode(buildSearchRequest(st, host: '$destination:$port')), target, port);
        }
      }

      // UDP drops packets, and some devices wake up late: repeat the search until discovery ends.
      sendAll();
      timers.add(Timer(const Duration(milliseconds: 300), sendAll));
      timers.add(Timer.periodic(_searchInterval, (_) => sendAll()));
    }
  }

  controller = StreamController<Device>(
    onListen: () {
      timers.add(Timer(timeout, finish));
      start();
    },
    onCancel: finish,
  );
  return controller.stream;
}

/// One known device: common description paths if an HTTP port is known, then unicast M-SEARCH plus its NOTIFYs.
Future<List<Device>> probeDevice(
  String ip, {
  int port = ssdpPort,
  int notifyPort = ssdpPort,
  int? httpPort,
  Duration timeout = const Duration(seconds: 8),
}) async {
  if (!isLanAddress(ip)) throw ArgumentError('$ip is not a local network IPv4 address');
  if (httpPort != null) {
    for (final path in _descriptionPaths) {
      try {
        final device = await fetchDescription(
          Uri(scheme: 'http', host: ip, port: httpPort, path: path),
          timeout: const Duration(milliseconds: 1500),
        );
        if (device.avTransport != null) return [device];
      } catch (_) {
        // Try the next path.
      }
    }
  }
  return discoverRenderers(
    ip: ip,
    port: port,
    notifyPort: notifyPort,
    timeout: timeout,
    settle: Duration.zero,
    searchTargets: ['ssdp:all', ...rendererSearchTargets],
  ).toList();
}
