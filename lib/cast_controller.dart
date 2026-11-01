import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dlna_core/dlna_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'native.dart';

class LogEntry {
  LogEntry(this.message, {this.error = false}) : at = DateTime.now();
  final String message;
  final bool error;
  final DateTime at;
}

/// App state: the renderers found, the chosen one, the cast in progress and the activity log.
class CastController extends ChangeNotifier {
  CastController() {
    _nativeEvents = NativeBridge.events.listen(_onNativeEvent);
  }

  static const _lastDeviceKey = 'lastDevice';
  static const _maxLog = 200;

  final devices = <Device>[];
  final log = <LogEntry>[];
  Device? selected;
  bool discovering = false;
  CastSession? session;
  CastSnapshot? snapshot;
  String? busy; // What is starting, shown while it does.
  Future<void> Function()? cancelBusy; // Set while the busy work (a conversion) can be cancelled.
  StreamSubscription<Device>? _discovery;
  StreamSubscription<Map<Object?, Object?>>? _nativeEvents;
  StreamSubscription<CastSnapshot>? _statusSubscription;
  Timer? _statsTimer;
  int _nativeBytes = 0;
  String? _converting;

  void _log(String message, {bool error = false}) {
    log.insert(0, LogEntry(message, error: error));
    if (log.length > _maxLog) log.removeLast();
    notifyListeners();
  }

  /// Tries the remembered renderer first, then searches.
  Future<void> start() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_lastDeviceKey);
    if (saved != null) {
      try {
        final remembered = Device.fromJson(jsonDecode(saved) as Map<String, Object?>);
        final fresh = await fetchDescription(remembered.location, timeout: const Duration(seconds: 2));
        if (fresh.avTransport != null) {
          _addDevice(fresh);
          selected = fresh;
          _log('Found ${fresh.friendlyName} where it was last time');
        }
      } catch (_) {
        // It moved or is off; the search below finds it again if it's around.
      }
    }
    await discover();
  }

  void _addDevice(Device device) {
    final index = devices.indexWhere((d) => d.key == device.key);
    if (index >= 0) {
      devices[index] = device;
    } else {
      devices.add(device);
    }
    notifyListeners();
  }

  /// Searches for 15 s. Renderers that only send NOTIFY (the goggles) can take a few seconds to show up.
  Future<void> discover() async {
    await _discovery?.cancel();
    discovering = true;
    notifyListeners();
    await NativeBridge.setMulticastLock(true);
    final done = Completer<void>();
    _discovery = discoverRenderers(timeout: const Duration(seconds: 15)).listen((device) {
      final known = devices.any((d) => d.key == device.key);
      _addDevice(device);
      if (!known) _log('Found ${device.friendlyName} at ${device.host}');
      selected ??= device;
      notifyListeners();
    }, onDone: done.complete);
    await done.future;
    discovering = false;
    // Holding the lock costs battery; only discovery needs it.
    await NativeBridge.setMulticastLock(false);
    if (devices.isEmpty) _log('No renderers found. Make sure the device is on and on the same Wi-Fi.', error: true);
    notifyListeners();
  }

  /// A device that doesn't answer searches can be added by its IP address.
  Future<void> addByIp(String ip) async {
    _log('Looking for a renderer at $ip…');
    try {
      final found = await probeDevice(ip.trim(), httpPort: null);
      if (found.isEmpty) return _log('Nothing at $ip answered as a renderer', error: true);
      _addDevice(found.first);
      select(found.first);
      _log('Found ${found.first.friendlyName} at $ip');
    } catch (error) {
      _log('$error', error: true);
    }
  }

  void select(Device device) {
    selected = device;
    notifyListeners();
    SharedPreferences.getInstance().then((prefs) => prefs.setString(_lastDeviceKey, jsonEncode(device.toJson())));
  }

  Future<T?> _starting<T>(String what, Future<T> Function(Device) start) async {
    final device = selected;
    if (device == null) {
      _log('Pick a renderer first', error: true);
      return null;
    }
    await stop();
    busy = what;
    notifyListeners();
    try {
      return await start(device);
    } catch (error) {
      _log('$error', error: true);
      return null;
    } finally {
      busy = null;
      notifyListeners();
    }
  }

  Future<void> castFile(File file, {required String title, String? mimeType}) =>
      _starting('Starting $title', (device) async {
        _log('Casting $title to ${device.friendlyName}');
        await NativeBridge.startMediaService(title: title, device: device.friendlyName);
        try {
          final session = await CastSession.startFile(
            device,
            file,
            title: title,
            mimeType: mimeType,
            onWarning: (warning) => _log(warning, error: true),
            onRequest: (r) => debugPrint('${r.method} ${r.range ?? ''} → ${r.status} (${r.remote})'),
          );
          _attach(session);
        } catch (_) {
          await NativeBridge.stopCast();
          rethrow;
        }
      });

  /// Plays H.264 as is and converts anything else first: the goggles only decode H.264, and phone cameras record
  /// HEVC. Their answer to a video they can't decode is a bare UPnP 501 on Play, after reading the file's header.
  Future<void> castVideo(File file, {required String title, String? mimeType}) async {
    final device = selected;
    if (device == null) return _log('Pick a renderer first', error: true);
    final codec = await NativeBridge.videoMimeType(file.path);
    if (codec == null || codec == 'video/avc') return castFile(file, title: title, mimeType: mimeType);

    await stop();
    final what = 'Converting $title for ${device.friendlyName}';
    _log('$title is ${_codecName(codec)}, which ${device.friendlyName} may not decode; converting it to H.264');
    busy = what;
    cancelBusy = NativeBridge.cancelConvert;
    _converting = what;
    notifyListeners();
    String? converted;
    try {
      await NativeBridge.startMediaService(title: what, device: device.friendlyName);
      converted = await NativeBridge.convertVideo(file.path);
    } catch (error) {
      await NativeBridge.stopCast();
      _log(error is PlatformException ? error.message ?? error.code : '$error', error: true);
    } finally {
      busy = null;
      cancelBusy = null;
      _converting = null;
      notifyListeners();
    }
    if (converted != null) await castFile(File(converted), title: title, mimeType: 'video/mp4');
  }

  /// Renderers without image support (the goggles answer Play on any image with UPnP 501) get the photo as a live
  /// video stream. Picking another photo while one is showing swaps it in place.
  Future<void> castPhoto(File file, {required String title}) async {
    final current = session;
    if (current != null &&
        !current.isEnded &&
        current.details['photo'] == true &&
        current.device.key == selected?.key) {
      try {
        if (await NativeBridge.showPhoto(file.path)) return _log('Showing $title');
      } catch (error) {
        return _log(error is PlatformException ? error.message ?? error.code : '$error', error: true);
      }
    }
    await _starting('Starting $title', (device) async {
      final host = await reachableHost(device);
      final share = await NativeBridge.startPhoto(
        path: file.path,
        host: host,
        allow: [device.host],
        device: device.friendlyName,
      );
      _log('Showing $title on ${device.friendlyName} as a video stream');
      await _startLive(
        device,
        share,
        title: 'Photos',
        details: {'photo': true, 'quality': 'Photo', 'encoder': share.encoder, 'audio': share.audio},
      );
    });
  }

  Future<void> shareScreen({required Quality quality, required ScreenAudio audio}) =>
      _starting('Starting screen share', (device) async {
        final host = await reachableHost(device);
        final share = await NativeBridge.startScreen(
          host: host,
          allow: [device.host],
          device: device.friendlyName,
          quality: quality,
          audio: audio,
        );
        _log('Sharing the screen with ${share.encoder}, sound: ${share.audio}');
        await _startLive(
          device,
          share,
          title: 'Phone screen',
          details: {'encoder': share.encoder, 'audio': share.audio, 'quality': quality.label},
        );
      });

  Future<void> _startLive(
    Device device,
    ScreenShare share, {
    required String title,
    required Map<String, Object?> details,
  }) async {
    try {
      final session = await CastSession.startLive(
        device,
        share.url,
        title: title,
        stop: NativeBridge.stopCast,
        bytesSent: () => _nativeBytes,
        details: details,
      );
      _nativeBytes = 0;
      _statsTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
        _nativeBytes = (await NativeBridge.screenStats()).bytesSent;
      });
      _attach(session);
    } catch (_) {
      await NativeBridge.stopCast();
      rethrow;
    }
  }

  void _attach(CastSession session) {
    this.session = session;
    snapshot = session.snapshot();
    _statusSubscription = session.status.listen((s) {
      snapshot = s;
      notifyListeners();
    });
    session.ended.then((end) {
      _statsTimer?.cancel();
      _statusSubscription?.cancel();
      // Lets the foreground service go; a screen share has already stopped it through the session's close.
      if (!session.live) NativeBridge.stopCast();
      if (identical(this.session, session)) {
        this.session = null;
        snapshot = null;
      }
      final reason = switch (end.reason) {
        'stopped' => 'Stopped',
        'renderer-stopped' => '${session.device.friendlyName} finished playing',
        _ => end.error ?? end.reason,
      };
      _log(reason, error: end.error != null);
    });
    session.start();
    notifyListeners();
  }

  /// Runs a control and logs its failure (an ignored volume change, a refused pause) instead of throwing.
  Future<void> control(Future<Object?> Function(CastSession) action) async {
    final current = session;
    if (current == null) return;
    try {
      await action(current);
    } catch (error) {
      _log('$error', error: true);
    }
    notifyListeners();
  }

  Future<void> stop() async {
    final current = session;
    if (current == null) return;
    await current.stop();
  }

  void _onNativeEvent(Map<Object?, Object?> event) {
    switch (event['event']) {
      case 'stopRequested':
        if (_converting != null) NativeBridge.cancelConvert();
        stop();
      case 'screenStopped':
        session?.sourceStopped('${event['error'] ?? 'Screen sharing stopped'}');
      case 'status':
        _log('${event['message']}');
      case 'convertProgress':
        if (_converting case final what?) {
          busy = '$what (${event['percent']}%)';
          notifyListeners();
        }
    }
  }

  @override
  void dispose() {
    _discovery?.cancel();
    _nativeEvents?.cancel();
    _statsTimer?.cancel();
    session?.stop();
    super.dispose();
  }
}

String _codecName(String mimeType) => switch (mimeType) {
  'video/hevc' => 'HEVC (H.265)',
  'video/av01' => 'AV1',
  'video/x-vnd.on2.vp9' => 'VP9',
  'video/x-vnd.on2.vp8' => 'VP8',
  _ => mimeType,
};
