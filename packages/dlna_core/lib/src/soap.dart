import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'description.dart';
import 'xml.dart';

class UpnpError implements Exception {
  UpnpError(this.action, this.status, this.code, this.description);
  final String action;
  final int status;
  final int? code;
  final String? description;

  @override
  String toString() {
    final detail = code != null ? 'UPnP $code${description != null ? ' $description' : ''}' : 'HTTP $status';
    return '$action failed: $detail';
  }
}

String buildEnvelope(String serviceType, String action, List<(String, String)> args) {
  final body = args.map((arg) => '<${arg.$1}>${xmlEscape(arg.$2)}</${arg.$1}>').join();
  return '<?xml version="1.0" encoding="utf-8"?>\n'
      '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
      's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body>'
      '<u:$action xmlns:u="${xmlEscape(serviceType)}">$body</u:$action>'
      '</s:Body></s:Envelope>';
}

({int? code, String? description})? parseFault(String xml) {
  final error = elementContent(xml, 'UPnPError');
  if (error == null) return null;
  return (
    code: int.tryParse(elementText(error, 'errorCode') ?? ''),
    description: elementText(error, 'errorDescription'),
  );
}

final _emptyElement = RegExp(r'<([\w-]+)\s*/>');
final _valueElement = RegExp(r'<([\w-]+)(?:\s[^>]*)?>([\s\S]*?)</\1>');

Map<String, String> parseActionResponse(String xml, String action) {
  final block = elementContent(xml, '${action}Response');
  if (block == null) return {};
  return {
    for (final m in _emptyElement.allMatches(block)) m[1]!: '',
    for (final m in _valueElement.allMatches(block)) m[1]!: decodeXml(m[2]!),
  };
}

Future<Map<String, String>> invoke(
  UpnpService? service,
  String action, [
  List<(String, String)> args = const [],
  Duration timeout = const Duration(seconds: 8),
]) async {
  if (service == null) throw StateError('The device has no service for $action');
  final client = HttpClient()..connectionTimeout = timeout;
  try {
    final request = await client.postUrl(service.controlUrl).timeout(timeout);
    request.followRedirects = false;
    // Some renderers match header names case-sensitively; Dart lowercases them unless asked not to.
    request.headers.set('Content-Type', 'text/xml; charset="utf-8"', preserveHeaderCase: true);
    request.headers.set('SOAPACTION', '"${service.serviceType}#$action"', preserveHeaderCase: true);
    request.add(utf8.encode(buildEnvelope(service.serviceType, action, args)));
    final response = await request.close().timeout(timeout);
    final text = await utf8.decoder.bind(response).join().timeout(timeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final fault = parseFault(text);
      throw UpnpError(action, response.statusCode, fault?.code, fault?.description);
    }
    return parseActionResponse(text, action);
  } finally {
    client.close(force: true);
  }
}

String formatTime(num totalSeconds) {
  final s = totalSeconds.floor().clamp(0, 1 << 31);
  String pad(int n) => n.toString().padLeft(2, '0');
  return '${s ~/ 3600}:${pad((s % 3600) ~/ 60)}:${pad(s % 60)}';
}

final _clock = RegExp(r'^\s*(\d+):(\d{1,2}):(\d{1,2}(?:\.\d+)?)\s*$');

/// Parses a renderer time ("1:02:03", "00:01:05.500") into seconds; null for "NOT_IMPLEMENTED" or blanks.
double? parseTime(String? text) {
  final match = _clock.firstMatch(text ?? '');
  if (match == null) return null;
  return int.parse(match[1]!) * 3600 + int.parse(match[2]!) * 60 + double.parse(match[3]!);
}

/// AVTransport calls use the service type the device advertised (AVTransport:1 or :2), on instance 0.
class AVTransport {
  AVTransport(Device device) : _service = device.avTransport;
  final UpnpService? _service;

  Future<Map<String, String>> _call(String action, [List<(String, String)> args = const []]) =>
      invoke(_service, action, [('InstanceID', '0'), ...args]);

  Future<void> setUri(String uri, [String metadata = '']) =>
      _call('SetAVTransportURI', [('CurrentURI', uri), ('CurrentURIMetaData', metadata)]);
  Future<void> play() => _call('Play', [('Speed', '1')]);
  Future<void> pause() => _call('Pause');
  Future<void> stop() => _call('Stop');
  Future<void> seek(num seconds) => _call('Seek', [('Unit', 'REL_TIME'), ('Target', formatTime(seconds))]);
  Future<Map<String, String>> transportInfo() => _call('GetTransportInfo');
  Future<Map<String, String>> positionInfo() => _call('GetPositionInfo');
}

/// RenderingControl volume and mute on the Master channel. Volume is 0–100 on virtually every renderer.
class RenderingControl {
  RenderingControl(Device device) : _service = device.renderingControl;
  final UpnpService? _service;

  bool get supported => _service != null;

  Future<Map<String, String>> _call(String action, [List<(String, String)> args = const []]) =>
      invoke(_service, action, [('InstanceID', '0'), ('Channel', 'Master'), ...args]);

  Future<int> getVolume() async {
    final volume = int.tryParse((await _call('GetVolume'))['CurrentVolume']?.trim() ?? '');
    if (volume == null) throw const FormatException('GetVolume returned no volume');
    return volume;
  }

  Future<void> setVolume(num level) => _call('SetVolume', [('DesiredVolume', level.clamp(0, 100).round().toString())]);

  Future<bool> getMute() async =>
      const ['1', 'true'].contains((await _call('GetMute'))['CurrentMute']?.trim().toLowerCase());

  Future<void> setMute(bool muted) => _call('SetMute', [('DesiredMute', muted ? '1' : '0')]);
}
