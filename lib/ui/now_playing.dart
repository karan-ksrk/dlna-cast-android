import 'package:dlna_core/dlna_core.dart';
import 'package:flutter/material.dart';

import '../cast_controller.dart';
import 'theme.dart';

String _clock(num seconds) {
  final s = seconds.floor();
  String pad(int n) => n.toString().padLeft(2, '0');
  return s >= 3600 ? '${s ~/ 3600}:${pad((s % 3600) ~/ 60)}:${pad(s % 60)}' : '${(s % 3600) ~/ 60}:${pad(s % 60)}';
}

String _stateLabel(String state) => switch (state) {
  'PLAYING' => 'Playing',
  'PAUSED_PLAYBACK' => 'Paused',
  'TRANSITIONING' => 'Starting',
  'STOPPED' => 'Stopped',
  'NO_MEDIA_PRESENT' => 'Idle',
  _ => state,
};

/// The goggles-shaped now-playing view from the desktop app, with transport and volume controls.
class NowPlaying extends StatefulWidget {
  const NowPlaying({super.key, required this.controller, required this.snapshot});
  final CastController controller;
  final CastSnapshot snapshot;

  @override
  State<NowPlaying> createState() => _NowPlayingState();
}

class _NowPlayingState extends State<NowPlaying> {
  double? _dragPosition;
  double? _dragVolume;
  int _lastBytes = 0;
  DateTime _lastAt = DateTime.now();
  double _mbps = 0;

  @override
  void didUpdateWidget(NowPlaying old) {
    super.didUpdateWidget(old);
    // Throughput from the change in bytes between updates, smoothed so the number doesn't jitter.
    final now = DateTime.now();
    final seconds = now.difference(_lastAt).inMilliseconds / 1000;
    final bytes = widget.snapshot.bytesSent;
    if (seconds >= 0.5) {
      final sample = bytes >= _lastBytes ? (bytes - _lastBytes) * 8 / seconds / 1e6 : 0.0;
      _mbps = _mbps == 0 ? sample : _mbps * 0.6 + sample * 0.4;
      _lastBytes = bytes;
      _lastAt = now;
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.snapshot;
    final controller = widget.controller;
    final duration = s.duration ?? 0;
    final position = _dragPosition ?? s.position ?? 0;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _GogglesView(snapshot: s, clock: s.live ? _clock(s.elapsed.inSeconds) : _clock(position)),
            const SizedBox(height: 12),
            if (s.seekable && duration > 0) ...[
              Slider(
                value: position.clamp(0, duration).toDouble(),
                max: duration,
                onChanged: (value) => setState(() => _dragPosition = value),
                onChangeEnd: (value) async {
                  await controller.control((session) => session.seek(value));
                  if (mounted) setState(() => _dragPosition = null);
                },
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(_clock(position), style: const TextStyle(color: Palette.inkFaint, fontSize: 12)),
                    Text(_clock(duration), style: const TextStyle(color: Palette.inkFaint, fontSize: 12)),
                  ],
                ),
              ),
            ],
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (s.seekable)
                  IconButton(
                    tooltip: 'Back 10 seconds',
                    onPressed: () => controller.control((session) => session.seek(-10, relative: true)),
                    icon: const Icon(Icons.replay_10),
                  ),
                const SizedBox(width: 8),
                IconButton.filled(
                  iconSize: 32,
                  tooltip: s.playing ? 'Pause' : 'Resume',
                  onPressed: () => controller.control((session) => session.togglePause()),
                  icon: Icon(s.playing ? Icons.pause : Icons.play_arrow),
                ),
                const SizedBox(width: 8),
                if (s.seekable)
                  IconButton(
                    tooltip: 'Forward 10 seconds',
                    onPressed: () => controller.control((session) => session.seek(10, relative: true)),
                    icon: const Icon(Icons.forward_10),
                  ),
                const SizedBox(width: 8),
                IconButton(
                  tooltip: 'Stop',
                  onPressed: controller.stop,
                  icon: const Icon(Icons.stop_circle_outlined, color: Palette.coral),
                ),
              ],
            ),
            const SizedBox(height: 4),
            if (s.volumeSupported)
              Row(
                children: [
                  IconButton(
                    tooltip: s.muted == true ? 'Unmute' : 'Mute',
                    onPressed: () => controller.control((session) => session.toggleMute()),
                    icon: Icon(s.muted == true ? Icons.volume_off : Icons.volume_up),
                  ),
                  Expanded(
                    child: Slider(
                      value: (_dragVolume ?? s.volume ?? 0).toDouble().clamp(0, 100),
                      max: 100,
                      onChanged: (value) => setState(() => _dragVolume = value),
                      onChangeEnd: (value) async {
                        await controller.control((session) => session.setVolume(value));
                        if (mounted) setState(() => _dragVolume = null);
                      },
                    ),
                  ),
                  SizedBox(
                    width: 32,
                    child: Text(
                      '${s.volume ?? '–'}',
                      textAlign: TextAlign.end,
                      style: const TextStyle(color: Palette.inkDim),
                    ),
                  ),
                ],
              )
            else
              Text(
                s.volumeIgnored
                    ? "${s.device.friendlyName} ignores remote volume. Use the device's own buttons."
                    : "${s.device.friendlyName} doesn't offer remote volume.",
                textAlign: TextAlign.center,
                style: const TextStyle(color: Palette.inkFaint, fontSize: 12.5),
              ),
            const SizedBox(height: 8),
            Text(
              [
                if (s.live) ...[s.details['quality'], s.details['encoder'], 'sound: ${s.details['audio']}'],
                '${_mbps.toStringAsFixed(1)} Mbit/s',
              ].whereType<Object>().join(' · '),
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Palette.inkFaint,
                fontSize: 12,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _GogglesView extends StatelessWidget {
  const _GogglesView({required this.snapshot, required this.clock});
  final CastSnapshot snapshot;
  final String clock;

  @override
  Widget build(BuildContext context) {
    final live = snapshot.live;
    final accent = live ? Palette.violet : Palette.amber;
    return CustomPaint(
      painter: _GogglesPainter(accent),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 22),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(live ? Icons.sensors : Icons.cast_connected, size: 14, color: accent),
                const SizedBox(width: 6),
                Text(
                  '${live ? 'LIVE' : _stateLabel(snapshot.state).toUpperCase()} · ${snapshot.device.friendlyName}',
                  style: TextStyle(color: accent, fontSize: 11.5, letterSpacing: 1.1, fontWeight: FontWeight.w600),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              snapshot.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: Palette.ink),
            ),
            const SizedBox(height: 2),
            Text(
              clock,
              style: const TextStyle(
                fontSize: 36,
                fontWeight: FontWeight.w300,
                color: Palette.ink,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
            if (live && snapshot.state != 'PLAYING')
              Text(_stateLabel(snapshot.state), style: const TextStyle(color: Palette.inkDim, fontSize: 12.5)),
          ],
        ),
      ),
    );
  }
}

/// Two lenses joined by a bridge, the outline the desktop app draws around its now-playing view.
class _GogglesPainter extends CustomPainter {
  _GogglesPainter(this.accent);
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final bridge = w * 0.08;
    final notch = h * 0.16;
    final r = h * 0.32;
    final path = Path()
      ..moveTo(r, 0)
      ..lineTo(w - r, 0)
      ..quadraticBezierTo(w, 0, w, r)
      ..lineTo(w, h - r)
      ..quadraticBezierTo(w, h, w - r, h)
      ..lineTo(w / 2 + bridge, h)
      ..quadraticBezierTo(w / 2, h - notch * 1.6, w / 2 - bridge, h)
      ..lineTo(r, h)
      ..quadraticBezierTo(0, h, 0, h - r)
      ..lineTo(0, r)
      ..quadraticBezierTo(0, 0, r, 0)
      ..close();
    canvas.drawPath(path, Paint()..color = Palette.graphite);
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = accent.withValues(alpha: 0.55),
    );
  }

  @override
  bool shouldRepaint(_GogglesPainter old) => old.accent != accent;
}
