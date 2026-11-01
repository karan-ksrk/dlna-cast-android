import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../native.dart';
import 'brand.dart';
import 'theme.dart';

/// The intro's beats in milliseconds. design/brand/launch_sound.py is timed to the same numbers.
abstract final class IntroTimeline {
  static const total = 2950;
  static const impact = 650;
  static const arcs = [1000, 1200, 1400];
  static const arcDraw = 320;
  static const lockup = 1450;
  static const lockupEnd = 1850;
  static const name = 1600;
  static const nameEnd = 2000;
  static const tagline = 1750;
  static const taglineEnd = 2050;
  static const exit = 2400;
}

/// The launch animation, played once over the app: the Beam mark winds up, punches out a shockwave, broadcasts its
/// three arcs, settles beside the name, then the app is revealed through the growing play triangle. It starts from
/// the splash screen's exact picture (the mark at 288 dp on graphite), so the hand-off is invisible. Tap to skip.
class IntroOverlay extends StatefulWidget {
  const IntroOverlay({super.key, required this.child});
  final Widget child;

  @override
  State<IntroOverlay> createState() => _IntroOverlayState();
}

class _IntroOverlayState extends State<IntroOverlay> with SingleTickerProviderStateMixin {
  late final _ticker = createTicker(_tick);
  final _ms = ValueNotifier<double>(0);
  var _lastTick = Duration.zero;
  var _done = false;
  var _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    // Reduced motion skips the intro entirely, sound included.
    if (MediaQuery.disableAnimationsOf(context)) {
      _done = true;
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _begin());
  }

  // The first frames after launch are the slowest (engine warm-up, discovery starting). They show the same picture
  // as the splash, so waiting them out costs nothing visible.
  Future<void> _begin() async {
    await Future<void>.delayed(const Duration(milliseconds: 250));
    if (!mounted || _ticker.isActive) return; // Skipped while waiting.
    NativeBridge.playLaunchSound().catchError((Object _) => false);
    _ticker.start();
  }

  // Frame-paced with a cap per frame, so a hitch slows the intro down instead of skipping whole beats of it.
  void _tick(Duration elapsed) {
    final step = min((elapsed - _lastTick).inMicroseconds / 1000, 50.0);
    _lastTick = elapsed;
    _ms.value = min(_ms.value + step, IntroTimeline.total.toDouble());
    if (_ms.value >= IntroTimeline.total) {
      _ticker.stop();
      setState(() => _done = true);
    }
  }

  void _skip() {
    if (_ms.value >= IntroTimeline.exit) return;
    NativeBridge.stopLaunchSound().catchError((Object _) {});
    _ms.value = IntroTimeline.exit.toDouble();
    if (!_ticker.isActive) _ticker.start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _ms.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_done) return widget.child;
    return ValueListenableBuilder<double>(
      valueListenable: _ms,
      child: widget.child,
      builder: (context, ms, child) {
        // The app eases in from slightly larger as the triangle opens onto it.
        final settle = Curves.easeOutCubic.transform(_progress(ms, IntroTimeline.exit, IntroTimeline.total));
        return Stack(
          fit: StackFit.expand,
          children: [
            Transform.scale(scale: 1.06 - 0.06 * settle, child: child),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _skip,
              child: CustomPaint(painter: _IntroPainter(ms), size: Size.infinite),
            ),
          ],
        );
      },
    );
  }
}

double _progress(double ms, num start, num end) => ((ms - start) / (end - start)).clamp(0.0, 1.0);

const _markBox = 288.0; // The splash icon's size in dp.
const _background = Color(0xFF1B1E22);

class _IntroPainter extends CustomPainter {
  _IntroPainter(this.ms);
  final double ms;

  static final _particles = List.generate(28, (i) {
    final random = Random(i * 7919 + 13);
    return (
      angle: random.nextDouble() * 2 * pi,
      distance: 0.55 + random.nextDouble() * 0.5,
      size: 1.5 + random.nextDouble() * 2.5,
    );
  });

  static final _name = _text('dlna', Palette.ink, 'cast', Palette.amber, 34, 700);
  static final _tagline = _text(
    'CAST YOUR PHONE TO ANY SCREEN',
    Palette.inkDim,
    '',
    Palette.inkDim,
    11,
    500,
    spacing: 2.6,
  );

  static TextPainter _text(
    String a,
    Color ca,
    String b,
    Color cb,
    double size,
    double weight, {
    double spacing = -0.3,
  }) {
    TextStyle style(Color color) => TextStyle(
      fontFamily: 'Unbounded',
      fontSize: size,
      fontVariations: [FontVariation.weight(weight)],
      letterSpacing: spacing,
      color: color,
    );
    return TextPainter(
      text: TextSpan(
        children: [
          TextSpan(text: a, style: style(ca)),
          TextSpan(text: b, style: style(cb)),
        ],
      ),
      textDirection: TextDirection.ltr,
    )..layout();
  }

  @override
  void paint(Canvas canvas, Size size) {
    final centre = size.center(Offset.zero);
    final exit = _progress(ms, IntroTimeline.exit, IntroTimeline.total);
    final fadeOut = 1 - Curves.easeOut.transform(_progress(ms, IntroTimeline.exit, IntroTimeline.exit + 220));

    // Lockup: the mark shrinks and slides left to sit beside the name.
    final lock = Curves.easeInOutCubic.transform(_progress(ms, IntroTimeline.lockup, IntroTimeline.lockupEnd));
    final markScale = 1 - 0.5 * lock;
    final unit = _markBox / 512 * markScale;
    const markVisualWidth = (403 - 94) / 512 * _markBox * 0.5;
    const gap = 18.0;
    final lockupWidth = markVisualWidth + gap + _name.width;
    final markCentreLocked = Offset(centre.dx - lockupWidth / 2 + markVisualWidth / 2, centre.dy - 12);
    final markCentre = Offset.lerp(centre, markCentreLocked, lock)!;
    Offset map(Offset p) => markCentre + (p - const Offset(256, 256)) * unit;

    // The triangle: squashed during the wind-up, then punched out with an elastic overshoot.
    final windUp = Curves.easeInCubic.transform(_progress(ms, 0, IntroTimeline.impact));
    final punch = Curves.elasticOut.transform(_progress(ms, IntroTimeline.impact, IntroTimeline.impact + 600));
    final triangleScale = ms < IntroTimeline.impact ? 1 - 0.14 * windUp : 0.86 + 0.14 * punch;
    final triangleCentre = map(beamTriangleCentre);
    Path trianglePath(double scale) {
      final points = beamTriangle.map((p) => triangleCentre + (map(p) - triangleCentre) * scale).toList();
      return Path()..addPolygon(points, true);
    }

    final opening = exit > 0;
    if (opening) {
      // Exit: the background is cut away through a growing triangle, revealing the app beneath.
      final farthest = [
        size.topLeft(Offset.zero),
        size.topRight(Offset.zero),
        size.bottomLeft(Offset.zero),
        size.bottomRight(Offset.zero),
      ].map((c) => (c - triangleCentre).distance).reduce(max);
      final inradius = (162.7 - 120 + 18) * unit;
      final holeScale = Curves.easeInCubic.transform(exit) * farthest / inradius * 1.25;
      final hole = trianglePath(holeScale);
      canvas.drawPath(
        Path.combine(PathOperation.difference, Path()..addRect(Offset.zero & size), hole),
        Paint()..color = _background,
      );
      canvas.drawPath(
        hole,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeJoin = StrokeJoin.round
          ..strokeWidth = 36 * unit * (1 + holeScale * 0.08)
          ..color = beamAmberLight.withValues(alpha: pow(1 - exit, 2) * 0.85),
      );
    } else {
      canvas.drawColor(_background, BlendMode.src);
    }
    if (fadeOut <= 0) return;

    canvas.saveLayer(Offset.zero & size, Paint()..color = Colors.white.withValues(alpha: fadeOut));

    // A violet glow behind the arcs that swells with the wind-up and breathes after.
    final breathe = ms > IntroTimeline.lockupEnd ? 0.08 * sin((ms - IntroTimeline.lockupEnd) / 140) : 0.0;
    final glowStrength = (0.25 + 0.35 * windUp + breathe).clamp(0.0, 1.0);
    canvas.drawCircle(
      map(const Offset(317, 256)),
      300 * unit * 1.6,
      Paint()
        ..shader = ui.Gradient.radial(map(const Offset(317, 256)), 300 * unit * 1.6, [
          beamVioletDeep.withValues(alpha: 0.45 * glowStrength),
          beamVioletDeep.withValues(alpha: 0),
        ]),
    );

    // Particles drawn into the triangle during the wind-up.
    if (ms < IntroTimeline.impact) {
      final shortSide = size.shortestSide;
      for (final particle in _particles) {
        final travel = 1 - windUp;
        final position =
            triangleCentre + Offset(cos(particle.angle), sin(particle.angle)) * shortSide * particle.distance * travel;
        canvas.drawCircle(
          position,
          particle.size,
          Paint()..color = beamAmberLight.withValues(alpha: (0.2 + 0.8 * windUp) * travel.clamp(0.2, 1)),
        );
      }
    }

    // Impact: a flash and two shockwaves rolling out across the screen.
    final diagonal = size.longestSide * 1.2;
    final flash = 1 - _progress(ms, IntroTimeline.impact, IntroTimeline.impact + 180);
    if (ms >= IntroTimeline.impact && flash > 0) {
      canvas.drawRect(Offset.zero & size, Paint()..color = beamAmberLight.withValues(alpha: 0.16 * flash));
    }
    for (final (delay, color, width) in [(0, beamAmberLight, 10.0), (90, beamVioletLight, 6.0)]) {
      final wave = _progress(ms, IntroTimeline.impact + delay, IntroTimeline.impact + delay + 650);
      if (wave <= 0 || wave >= 1) continue;
      canvas.drawCircle(
        triangleCentre,
        Curves.easeOutCubic.transform(wave) * diagonal,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = width * (1 - wave) + 1
          ..color = color.withValues(alpha: 0.6 * (1 - wave)),
      );
    }

    // The arcs: shown at rest on the splash frame, pulled in during the wind-up, then drawn out one by one, each
    // sending a faint ripple ahead of it.
    final arcCentre = map(beamArcCentre);
    final violet = ui.Gradient.linear(map(const Offset(290, 150)), map(const Offset(370, 362)), [
      beamVioletLight,
      beamVioletDeep,
    ]);
    for (var i = 0; i < 3; i++) {
      final start = IntroTimeline.arcs[i];
      double sweep;
      double alpha;
      double radius = beamArcRadii[i] * unit;
      if (ms < IntroTimeline.impact) {
        sweep = pi / 2;
        alpha = 1 - windUp;
        radius *= 1 - 0.3 * windUp;
      } else {
        final draw = Curves.easeOutCubic.transform(_progress(ms, start, start + IntroTimeline.arcDraw));
        sweep = pi / 2 * draw;
        alpha = draw;
      }
      if (alpha > 0 && sweep > 0) {
        canvas.drawArc(
          Rect.fromCircle(center: arcCentre, radius: radius),
          -sweep / 2,
          sweep,
          false,
          Paint()
            ..shader = violet
            ..style = PaintingStyle.stroke
            ..strokeCap = StrokeCap.round
            ..strokeWidth = 26 * unit
            ..color = Colors.white.withValues(alpha: beamArcAlpha[i] * alpha),
        );
      }
      final ripple = _progress(ms, start, start + 650);
      if (ripple > 0 && ripple < 1) {
        canvas.drawArc(
          Rect.fromCircle(
            center: arcCentre,
            radius: radius + Curves.easeOutCubic.transform(ripple) * size.shortestSide * 0.6,
          ),
          -pi / 4,
          pi / 2,
          false,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeCap = StrokeCap.round
            ..strokeWidth = 3
            ..color = beamVioletLight.withValues(alpha: 0.35 * (1 - ripple)),
        );
      }
    }

    // The triangle itself, drawn last so it sits over the glow and waves.
    if (!opening) {
      final triangle = trianglePath(triangleScale);
      final amber = ui.Gradient.linear(map(const Offset(102, 158)), map(const Offset(266, 354)), [
        beamAmberLight,
        beamAmberDeep,
      ]);
      canvas.drawPath(triangle, Paint()..shader = amber);
      canvas.drawPath(
        triangle,
        Paint()
          ..shader = amber
          ..style = PaintingStyle.stroke
          ..strokeJoin = StrokeJoin.round
          ..strokeWidth = 36 * unit * triangleScale,
      );
    }

    // The name wipes in from behind the mark, never over it while the mark is still sliding; the tagline follows.
    final reveal = Curves.easeOutCubic.transform(_progress(ms, IntroTimeline.name, IntroTimeline.nameEnd));
    if (reveal > 0) {
      final nameLeft = markCentreLocked.dx + markVisualWidth / 2 + gap;
      final nameTop = markCentreLocked.dy - _name.height / 2;
      final clipLeft = max(nameLeft, map(const Offset(403, 256)).dx + gap / 2);
      final clipRight = nameLeft + _name.width * reveal + 4;
      if (clipRight > clipLeft) {
        canvas.save();
        canvas.clipRect(Rect.fromLTRB(clipLeft, nameTop - 8, clipRight, nameTop + _name.height + 8));
        _name.paint(canvas, Offset(nameLeft - 24 * (1 - reveal), nameTop));
        canvas.restore();
      }
    }
    final tagline = Curves.easeOut.transform(_progress(ms, IntroTimeline.tagline, IntroTimeline.taglineEnd));
    if (tagline > 0) {
      canvas.saveLayer(null, Paint()..color = Colors.white.withValues(alpha: tagline));
      _tagline.paint(canvas, Offset(centre.dx - _tagline.width / 2, markCentreLocked.dy + 56 + 8 * (1 - tagline)));
      canvas.restore();
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(_IntroPainter old) => old.ms != ms;
}
