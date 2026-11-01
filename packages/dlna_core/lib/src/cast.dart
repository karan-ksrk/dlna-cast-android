import 'dart:io';

import 'description.dart';
import 'didl.dart';
import 'lan.dart';
import 'media_server.dart';
import 'soap.dart';

/// The protocolInfo entries the renderer accepts (ConnectionManager GetProtocolInfo Sink), or null if unknown.
Future<List<String>?> rendererSinks(Device device) async {
  if (device.connectionManager == null) return null;
  try {
    final reply = await invoke(device.connectionManager, 'GetProtocolInfo', const [], const Duration(seconds: 4));
    return (reply['Sink'] ?? '').split(',').map((entry) => entry.trim()).where((e) => e.isNotEmpty).toList();
  } catch (_) {
    return null;
  }
}

/// Uses the renderer's own spelling of a MIME type (e.g. "video/MP2T"); some compare it case-sensitively.
/// `supported` is null when the renderer didn't say, false when its list excludes the type.
({String mimeType, bool? supported}) pickMimeType(List<String>? sinks, String mimeType) {
  if (sinks == null) return (mimeType: mimeType, supported: null);
  final advertised = [
    for (final entry in sinks)
      if (entry.split(':') case [_, _, final type, ...] when type.isNotEmpty) type,
  ];
  final exact = advertised.where((m) => m.toLowerCase() == mimeType.toLowerCase()).firstOrNull;
  if (exact != null) return (mimeType: exact, supported: true);
  return (mimeType: mimeType, supported: advertised.contains('*'));
}

Future<AVTransport> _startPlayback(Device device, String url, String metadata) async {
  final transport = AVTransport(device);
  // Some renderers reject a new URI while they still hold the previous one.
  await transport.stop().catchError((Object _) {});
  await transport.setUri(url, metadata);
  await transport.play();
  return transport;
}

/// The address on this phone the renderer can fetch media from.
Future<String> reachableHost(Device device) async {
  if (device.avTransport == null) throw StateError('${device.friendlyName} has no AVTransport service');
  final host = await localAddressFor(device.host);
  if (host == null) throw StateError('No local network address can reach ${device.host}');
  return host;
}

/// Serves the file on the interface the renderer can reach, then hands it the URL and starts playback.
Future<({MediaServer media, AVTransport transport})> castFile(
  Device device,
  File file, {
  required String title,
  String? mimeType,
  int port = 0,
  void Function(RequestReport)? onRequest,
  void Function(String)? onWarning,
}) async {
  final host = await reachableHost(device);
  final picked = pickMimeType(await rendererSinks(device), mimeType ?? mimeTypeFor(file.path));
  if (picked.supported == false) {
    onWarning?.call(
      "${device.friendlyName} doesn't list ${picked.mimeType} among its formats; it may refuse the file (UPnP 714).",
    );
  }

  final media = await MediaServer.start(
    file: file,
    host: host,
    port: port,
    mimeType: picked.mimeType,
    allow: [device.host],
    onRequest: onRequest,
  );
  try {
    final transport = await _startPlayback(
      device,
      media.url,
      buildDidl(url: media.url, title: title, mimeType: media.mimeType, size: media.size),
    );
    return (media: media, transport: transport);
  } catch (_) {
    await media.close();
    rethrow;
  }
}

/// Points the renderer at a live MPEG-TS stream that something else (the native screen pipeline) is serving.
Future<AVTransport> castLiveStream(Device device, String url, {String title = 'Phone screen'}) async {
  final (:mimeType, supported: _) = pickMimeType(await rendererSinks(device), 'video/mp2t');
  return _startPlayback(device, url, buildDidl(url: url, title: title, mimeType: mimeType, live: true));
}
