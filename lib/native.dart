import 'package:flutter/services.dart';

enum ScreenAudio { device, mic, none }

enum Quality {
  light('Light', '720p, 30 fps, gentle on Wi-Fi', 1280, 720, 30, 3000),
  balanced('Balanced', '1080p, 30 fps', 1920, 1080, 30, 6000),
  smooth('Smooth', '1080p, 60 fps, needs strong Wi-Fi', 1920, 1080, 60, 10000);

  const Quality(this.label, this.description, this.width, this.height, this.fps, this.bitrateKbps);
  final String label;
  final String description;
  final int width;
  final int height;
  final int fps;
  final int bitrateKbps;
}

typedef ScreenShare = ({String url, String encoder, String audio});

/// The Kotlin side: multicast lock, the foreground service, and the screen capture pipeline.
class NativeBridge {
  static const _channel = MethodChannel('dlna_cast/native');
  static const _events = EventChannel('dlna_cast/events');

  /// {"event": "screenStopped", "error": ...}, {"event": "stopRequested"}, {"event": "status", "message": ...} or
  /// {"event": "convertProgress", "percent": ...}.
  static final Stream<Map<Object?, Object?>> events = _events.receiveBroadcastStream().map(
    (event) => event as Map<Object?, Object?>,
  );

  static Future<void> setMulticastLock(bool held) => _channel.invokeMethod('setMulticastLock', held);

  static Future<void> startMediaService({required String title, required String device}) =>
      _channel.invokeMethod('startMediaService', {'title': title, 'device': device});

  /// Asks for screen capture consent, then starts capture and serves the stream to [allow] only.
  static Future<ScreenShare> startScreen({
    required String host,
    required List<String> allow,
    required String device,
    required Quality quality,
    required ScreenAudio audio,
  }) async {
    final reply = await _channel.invokeMapMethod<String, Object?>('startScreen', {
      'host': host,
      'allow': allow,
      'device': device,
      'width': quality.width,
      'height': quality.height,
      'fps': quality.fps,
      'bitrateKbps': quality.bitrateKbps,
      'audio': audio.name,
    });
    return (url: reply!['url'] as String, encoder: reply['encoder'] as String, audio: reply['audio'] as String);
  }

  /// Streams a still photo as live video (for renderers without image support), served to [allow] only.
  static Future<ScreenShare> startPhoto({
    required String path,
    required String host,
    required List<String> allow,
    required String device,
  }) async {
    const quality = Quality.balanced;
    final reply = await _channel.invokeMapMethod<String, Object?>('startPhoto', {
      'path': path,
      'host': host,
      'allow': allow,
      'device': device,
      'width': quality.width,
      'height': quality.height,
      'fps': quality.fps,
      'bitrateKbps': quality.bitrateKbps,
      'audio': ScreenAudio.none.name,
    });
    return (url: reply!['url'] as String, encoder: reply['encoder'] as String, audio: reply['audio'] as String);
  }

  /// Swaps the photo in the running photo stream. False when there is none.
  static Future<bool> showPhoto(String path) async =>
      await _channel.invokeMethod<bool>('showPhoto', {'path': path}) ?? false;

  /// The first video track's MIME type, e.g. "video/hevc", or null.
  static Future<String?> videoMimeType(String path) => _channel.invokeMethod<String>('videoMimeType', path);

  /// Re-encodes to H.264 and returns the converted file's path. Progress arrives as "convertProgress" events.
  static Future<String> convertVideo(String path) async => (await _channel.invokeMethod<String>('convertVideo', path))!;

  static Future<void> cancelConvert() => _channel.invokeMethod('cancelConvert');

  /// Plays the intro sound; false when the phone is on silent or vibrate, or music is playing.
  static Future<bool> playLaunchSound() async => await _channel.invokeMethod<bool>('playLaunchSound') ?? false;

  static Future<void> stopLaunchSound() => _channel.invokeMethod('stopLaunchSound');

  /// Opens a web page in the user's browser. False if no app can open it.
  static Future<bool> openUrl(String url) async => await _channel.invokeMethod<bool>('openUrl', url) ?? false;

  static Future<void> stopCast() => _channel.invokeMethod('stopCast');

  static Future<({int bytesSent, int clients})> screenStats() async {
    final stats = await _channel.invokeMapMethod<String, Object?>('screenStats');
    return (bytesSent: (stats?['bytesSent'] as int?) ?? 0, clients: (stats?['clients'] as int?) ?? 0);
  }
}
