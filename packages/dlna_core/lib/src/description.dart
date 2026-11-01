import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'lan.dart';
import 'xml.dart';

const _maxDescriptionBytes = 1024 * 1024;

class UpnpService {
  const UpnpService(this.serviceType, this.controlUrl);
  final String serviceType;
  final Uri controlUrl;

  Map<String, Object?> toJson() => {'serviceType': serviceType, 'controlURL': controlUrl.toString()};
  static UpnpService? fromJson(Object? json) =>
      json is Map ? UpnpService(json['serviceType'] as String, Uri.parse(json['controlURL'] as String)) : null;
}

/// A MediaRenderer as described by its device description.
class Device {
  const Device({
    required this.friendlyName,
    required this.location,
    this.manufacturer,
    this.modelName,
    this.deviceType,
    this.udn,
    this.avTransport,
    this.renderingControl,
    this.connectionManager,
  });

  final String friendlyName;
  final String? manufacturer;
  final String? modelName;
  final String? deviceType;
  final String? udn;
  final Uri location;
  final UpnpService? avTransport;
  final UpnpService? renderingControl;
  final UpnpService? connectionManager;

  String get host => location.host;

  /// The identity used to tell devices apart across searches.
  String get key => udn ?? location.toString();

  Map<String, Object?> toJson() => {
    'friendlyName': friendlyName,
    'manufacturer': manufacturer,
    'modelName': modelName,
    'deviceType': deviceType,
    'udn': udn,
    'location': location.toString(),
    'avTransport': avTransport?.toJson(),
    'renderingControl': renderingControl?.toJson(),
    'connectionManager': connectionManager?.toJson(),
  };

  factory Device.fromJson(Map<String, Object?> json) => Device(
    friendlyName: json['friendlyName'] as String? ?? 'Unknown device',
    manufacturer: json['manufacturer'] as String?,
    modelName: json['modelName'] as String?,
    deviceType: json['deviceType'] as String?,
    udn: json['udn'] as String?,
    location: Uri.parse(json['location'] as String),
    avTransport: UpnpService.fromJson(json['avTransport']),
    renderingControl: UpnpService.fromJson(json['renderingControl']),
    connectionManager: UpnpService.fromJson(json['connectionManager']),
  );

  @override
  String toString() => '$friendlyName ($host)';
}

/// Control URLs must stay on the host that served the description, so a device can't redirect our SOAP calls
/// elsewhere.
Device parseDescription(String xml, Uri location) {
  bool sameHost(Uri url) => url.scheme == 'http' && url.host == location.host;

  var base = location;
  final urlBase = elementText(xml, 'URLBase');
  if (urlBase != null) {
    final candidate = Uri.tryParse(urlBase);
    // A malformed or foreign URLBase is ignored: resolve against the description location instead.
    if (candidate != null && candidate.hasScheme && sameHost(candidate)) base = candidate;
  }

  final services = <UpnpService>[];
  for (final block in elementBlocks(xml, 'service')) {
    final serviceType = elementText(block, 'serviceType');
    final control = elementText(block, 'controlURL');
    if (serviceType == null || serviceType.isEmpty || control == null || control.isEmpty) continue;
    final Uri controlUrl;
    try {
      controlUrl = base.resolve(control);
    } on FormatException {
      continue;
    }
    if (sameHost(controlUrl)) services.add(UpnpService(serviceType, controlUrl));
  }
  UpnpService? service(String kind) =>
      services.where((s) => s.serviceType.startsWith('urn:schemas-upnp-org:service:$kind:')).firstOrNull;

  return Device(
    friendlyName: elementText(xml, 'friendlyName') ?? 'Unknown device',
    manufacturer: elementText(xml, 'manufacturer'),
    modelName: elementText(xml, 'modelName'),
    deviceType: elementText(xml, 'deviceType'),
    udn: elementText(xml, 'UDN'),
    location: location,
    avTransport: service('AVTransport'),
    renderingControl: service('RenderingControl'),
    connectionManager: service('ConnectionManager'),
  );
}

Future<Device> fetchDescription(Uri location, {Duration timeout = const Duration(seconds: 4)}) async {
  if (location.scheme != 'http' || !isLanAddress(location.host)) {
    throw ArgumentError('Refusing non-LAN description URL $location');
  }
  final client = HttpClient()..connectionTimeout = timeout;
  try {
    final request = await client.getUrl(location).timeout(timeout);
    request.followRedirects = false;
    final response = await request.close().timeout(timeout);
    if (response.statusCode != 200) {
      await response.drain<void>();
      throw HttpException('Description $location returned HTTP ${response.statusCode}', uri: location);
    }
    final bytes = <int>[];
    await for (final chunk in response.timeout(timeout)) {
      bytes.addAll(chunk);
      if (bytes.length > _maxDescriptionBytes) {
        throw HttpException('Device description exceeds $_maxDescriptionBytes bytes', uri: location);
      }
    }
    return parseDescription(utf8.decode(bytes, allowMalformed: true), location);
  } finally {
    client.close(force: true);
  }
}
