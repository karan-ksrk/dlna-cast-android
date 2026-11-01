import 'dart:async';
import 'dart:io';

import 'cast.dart';
import 'description.dart';
import 'media_server.dart';
import 'soap.dart';

int _clampVolume(num level) => level.clamp(0, 100).round();

class IgnoredCommandError implements Exception {
  IgnoredCommandError(this.message);
  final String message;
  @override
  String toString() => message;
}

typedef DeviceStatus = ({String state, double? position, double? duration, String? uri, int? volume, bool? muted});

/// Reads a renderer's state without a cast session: transport state, position and volume.
Future<DeviceStatus> readDeviceStatus(Device device) async {
  final transport = AVTransport(device);
  final rendering = RenderingControl(device);
  final (info, position, volume, muted) = await (
    transport.transportInfo(),
    transport.positionInfo().catchError((Object _) => <String, String>{}),
    rendering.supported
        ? rendering.getVolume().then<int?>((v) => v, onError: (Object _) => null)
        : Future<int?>.value(),
    rendering.supported
        ? rendering.getMute().then<bool?>((m) => m, onError: (Object _) => null)
        : Future<bool?>.value(),
  ).wait;
  final uri = position['TrackURI'];
  return (
    state: info['CurrentTransportState'] ?? 'UNKNOWN',
    position: parseTime(position['RelTime']),
    duration: parseTime(position['TrackDuration']),
    uri: uri == null || uri.isEmpty ? null : uri,
    volume: volume,
    muted: muted,
  );
}

/// Pauses and confirms: some renderers answer 200 to Pause and keep playing.
Future<String> pauseAndConfirm(Device device) async {
  final transport = AVTransport(device);
  // Renderers that are stopped either refuse Pause (UPnP 701, transition not available) or accept and ignore it.
  final refusal = await transport.pause().then<Object?>((_) => null, onError: (Object error) => error);
  if (refusal != null && !(refusal is UpnpError && refusal.code == 701)) throw refusal;
  final state = (await transport.transportInfo().catchError((Object _) => <String, String>{}))['CurrentTransportState'];
  final stopped = state == 'STOPPED' || state == 'NO_MEDIA_PRESENT';
  if (refusal != null && !stopped) throw refusal;
  if (state == 'PLAYING') throw IgnoredCommandError('${device.friendlyName} accepted Pause but kept playing');
  if (stopped) throw IgnoredCommandError("Nothing is playing on ${device.friendlyName}, so there's nothing to pause");
  return state ?? 'PAUSED_PLAYBACK';
}

/// Sets the volume and reads it back. Some renderers (the Platinum-based goggles among them) answer SetVolume
/// with 200 and change nothing; that is reported instead of pretending it worked.
Future<int> setVolumeAndConfirm(Device device, num level) async {
  final rendering = RenderingControl(device);
  final requested = _clampVolume(level);
  await rendering.setVolume(requested);
  final reported = await rendering.getVolume().then<int?>((v) => v, onError: (Object _) => null);
  if (reported != null && (reported - requested).abs() > 1) {
    throw IgnoredCommandError(
      "${device.friendlyName} accepted the volume change but still reports $reported; it doesn't support remote "
      "volume. Use the device's own buttons.",
    );
  }
  return reported ?? requested;
}

Future<bool> setMuteAndConfirm(Device device, bool muted) async {
  final rendering = RenderingControl(device);
  await rendering.setMute(muted);
  final reported = await rendering.getMute().then<bool?>((m) => m, onError: (Object _) => null);
  if (reported != null && reported != muted) {
    throw IgnoredCommandError(
      "${device.friendlyName} accepted ${muted ? 'mute' : 'unmute'} but didn't change; it doesn't support remote "
      "mute. Use the device's own buttons.",
    );
  }
  return muted;
}

enum CastKind { file, screen }

class CastSnapshot {
  const CastSnapshot({
    required this.kind,
    required this.title,
    required this.device,
    required this.state,
    required this.position,
    required this.duration,
    required this.volume,
    required this.muted,
    required this.volumeSupported,
    required this.volumeIgnored,
    required this.elapsed,
    required this.bytesSent,
    required this.ended,
    required this.details,
  });

  final CastKind kind;
  final String title;
  final Device device;
  final String state;
  final double? position;
  final double? duration;
  final int? volume;
  final bool? muted;
  final bool volumeSupported;
  final bool volumeIgnored;
  final Duration elapsed;
  final int bytesSent;
  final bool ended;
  final Map<String, Object?> details;

  bool get live => kind == CastKind.screen;
  bool get seekable => !live;
  bool get playing => state == 'PLAYING';
}

typedef CastEnd = ({String reason, String? error, String? detail});

/// One cast in progress: polls the renderer, exposes pause/resume/seek/volume/mute/stop, and ends itself when
/// the renderer stops playback or stops answering. A live source that dies reports it through [sourceStopped].
class CastSession {
  CastSession({
    required this.device,
    required this.kind,
    required this.title,
    required this.transport,
    required Future<void> Function() close,
    required int Function() bytesSent,
    this.details = const {},
  }) : rendering = RenderingControl(device),
       // Private fields can't be named parameters, so they're assigned here.
       // ignore: prefer_initializing_formals
       _close = close,
       // ignore: prefer_initializing_formals
       _bytesSent = bytesSent;

  final Device device;
  final CastKind kind;
  final String title;
  final AVTransport transport;
  final RenderingControl rendering;
  final Map<String, Object?> details;
  final Future<void> Function() _close;
  final int Function() _bytesSent;
  final DateTime startedAt = DateTime.now();

  final _status = StreamController<CastSnapshot>.broadcast();
  final _ended = Completer<CastEnd>();
  Timer? _timer;
  var _busy = false;
  var _failures = 0;
  var _stoppedPolls = 0;
  var _sawPlaying = false;
  var volumeIgnored = false;

  String _state = 'TRANSITIONING';
  double? _position;
  double? _duration;
  int? _volume;
  bool? _muted;

  /// Snapshots on every change and poll.
  Stream<CastSnapshot> get status => _status.stream;

  /// Completes once, when the cast ends for any reason.
  Future<CastEnd> get ended => _ended.future;
  bool get isEnded => _ended.isCompleted;
  bool get live => kind == CastKind.screen;

  static Future<CastSession> startFile(
    Device device,
    File file, {
    required String title,
    String? mimeType,
    void Function(RequestReport)? onRequest,
    void Function(String)? onWarning,
  }) async {
    final (:media, :transport) = await castFile(
      device,
      file,
      title: title,
      mimeType: mimeType,
      onRequest: onRequest,
      onWarning: onWarning,
    );
    return CastSession(
      device: device,
      kind: CastKind.file,
      title: title,
      transport: transport,
      close: media.close,
      bytesSent: () => media.stats.bytesServed,
      details: {'path': file.path, 'mimeType': media.mimeType, 'size': media.size},
    );
  }

  /// [stop] shuts the native stream down; [bytesSent] reads its counter.
  static Future<CastSession> startLive(
    Device device,
    String url, {
    required String title,
    required Future<void> Function() stop,
    required int Function() bytesSent,
    Map<String, Object?> details = const {},
  }) async {
    final transport = await castLiveStream(device, url, title: title);
    return CastSession(
      device: device,
      kind: CastKind.screen,
      title: title,
      transport: transport,
      close: stop,
      bytesSent: bytesSent,
      details: details,
    );
  }

  CastSnapshot snapshot() => CastSnapshot(
    kind: kind,
    title: title,
    device: device,
    state: _state,
    position: _position,
    duration: _duration,
    volume: _volume,
    muted: _muted,
    volumeSupported: rendering.supported && !volumeIgnored,
    volumeIgnored: volumeIgnored,
    elapsed: DateTime.now().difference(startedAt),
    bytesSent: _bytesSent(),
    ended: isEnded,
    details: details,
  );

  CastSession start([Duration interval = const Duration(seconds: 1)]) {
    _refreshVolume();
    _timer = Timer.periodic(interval, (_) => refresh());
    refresh();
    return this;
  }

  Future<void> refresh() async {
    if (_busy || isEnded) return;
    _busy = true;
    try {
      final (info, position) = await (
        transport.transportInfo(),
        transport.positionInfo().catchError((Object _) => <String, String>{}),
      ).wait;
      _failures = 0;
      final state = info['CurrentTransportState'] ?? 'UNKNOWN';
      if (state == 'PLAYING') _sawPlaying = true;
      _stoppedPolls = state == 'STOPPED' || state == 'NO_MEDIA_PRESENT' ? _stoppedPolls + 1 : 0;
      _state = state;
      // Renderers report 0 for live streams; elapsed time stands in for position there.
      _position = live ? null : parseTime(position['RelTime']);
      _duration = live ? null : parseTime(position['TrackDuration']);
      _emitStatus();
      // Two polls in a row, so a renderer that blips through STOPPED during a seek isn't taken as finished.
      if (_sawPlaying && _stoppedPolls >= 2) await _end(reason: 'renderer-stopped');
    } catch (error) {
      if (++_failures >= 5) {
        await _end(reason: 'renderer-lost', error: 'Lost contact with ${device.friendlyName}: $error');
      }
    } finally {
      _busy = false;
    }
  }

  Future<void> pause() async {
    _state = await pauseAndConfirm(device);
    _emitStatus();
  }

  Future<void> resume() async {
    await transport.play();
    _state = 'PLAYING';
    _emitStatus();
  }

  Future<void> togglePause() => _state == 'PLAYING' ? pause() : resume();

  Future<double> seek(double seconds, {bool relative = false}) async {
    if (live) throw StateError("A live screen stream can't be seeked");
    var target = seconds;
    if (relative) {
      final reported = parseTime((await transport.positionInfo())['RelTime']);
      target = (reported ?? _position ?? 0) + seconds;
    }
    final duration = _duration;
    target = (duration != null && duration > 0 ? target.clamp(double.negativeInfinity, duration - 1) : target)
        .clamp(0, double.infinity)
        .toDouble();
    await transport.seek(target);
    _position = target;
    _emitStatus();
    return target;
  }

  void _requireVolume() {
    if (!rendering.supported) throw StateError("${device.friendlyName} doesn't offer volume control");
    if (volumeIgnored) {
      throw StateError("${device.friendlyName} ignores remote volume and mute; use the device's own buttons");
    }
  }

  // A renderer that ignored one volume or mute command ignores the rest; stop offering them for this cast.
  Future<T> _confirmed<T>(Future<T> Function() command) async {
    try {
      return await command();
    } on IgnoredCommandError {
      volumeIgnored = true;
      await _refreshVolume();
      rethrow;
    }
  }

  Future<int> setVolume(num level) async {
    _requireVolume();
    final volume = await _confirmed(() => setVolumeAndConfirm(device, level));
    _volume = volume;
    _emitStatus();
    return volume;
  }

  Future<int> changeVolume(int delta) async {
    _requireVolume();
    final current = _volume ?? await rendering.getVolume();
    return setVolume(current + delta);
  }

  Future<bool> setMute(bool muted) async {
    _requireVolume();
    await _confirmed(() => setMuteAndConfirm(device, muted));
    _muted = muted;
    _emitStatus();
    return muted;
  }

  Future<bool> toggleMute() => setMute(!(_muted ?? false));

  Future<void> stop() async {
    if (isEnded) return;
    await transport.stop().catchError((Object _) {});
    await _end(reason: 'stopped');
  }

  /// Called when the live source (screen capture) dies on its own.
  Future<void> sourceStopped(String error, {String? detail}) async {
    await transport.stop().catchError((Object _) {});
    await _end(reason: 'capture-stopped', error: error, detail: detail);
  }

  Future<void> _refreshVolume() async {
    if (!rendering.supported) return;
    final (volume, muted) = await (
      rendering.getVolume().then<int?>((v) => v, onError: (Object _) => null),
      rendering.getMute().then<bool?>((m) => m, onError: (Object _) => null),
    ).wait;
    if (volume != null) _volume = volume;
    if (muted != null) _muted = muted;
    _emitStatus();
  }

  void _emitStatus() {
    if (!isEnded) _status.add(snapshot());
  }

  Future<void> _end({required String reason, String? error, String? detail}) async {
    if (isEnded) return;
    _timer?.cancel();
    _state = 'STOPPED';
    _ended.complete((reason: reason, error: error, detail: detail));
    await _close().catchError((Object _) {});
    await _status.close();
  }
}
