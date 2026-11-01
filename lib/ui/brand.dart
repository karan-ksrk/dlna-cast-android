import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'theme.dart';

// The Beam mark's geometry, in the 512-unit space of design/brand/beam.svg.
const beamTriangle = [Offset(120, 176), Offset(120, 336), Offset(248, 256)];
const beamTriangleCentre = Offset(162.7, 256);
const beamArcCentre = Offset(248, 256);
const beamArcRadii = [62.0, 106.0, 150.0];
const beamArcAlpha = [1.0, 0.72, 0.45];
const beamAmberLight = Color(0xFFFFC56D);
const beamAmberDeep = Color(0xFFEC8429);
const beamVioletLight = Color(0xFFB8ADFF);
const beamVioletDeep = Color(0xFF7D6CF2);

/// The Beam mark (a play button broadcasting), cropped to its own bounds.
class BeamMark extends StatelessWidget {
  const BeamMark({super.key, this.size = 32});
  final double size;

  @override
  Widget build(BuildContext context) => CustomPaint(size: Size.square(size), painter: const _BeamPainter());
}

class _BeamPainter extends CustomPainter {
  const _BeamPainter();

  @override
  void paint(Canvas canvas, Size size) {
    // The mark spans x 94-416 and y 137-375 of its 512 space; fit that box, centred.
    const bounds = Rect.fromLTRB(94, 130, 416, 382);
    final unit = min(size.width / bounds.width, size.height / bounds.height);
    final origin = size.center(Offset.zero) - bounds.center * unit;
    Offset map(Offset p) => origin + p * unit;

    final violet = ui.Gradient.linear(map(const Offset(290, 150)), map(const Offset(370, 362)), [
      beamVioletLight,
      beamVioletDeep,
    ]);
    for (var i = 0; i < 3; i++) {
      canvas.drawArc(
        Rect.fromCircle(center: map(beamArcCentre), radius: beamArcRadii[i] * unit),
        -pi / 4,
        pi / 2,
        false,
        Paint()
          ..shader = violet
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeWidth = 26 * unit
          ..color = Colors.white.withValues(alpha: beamArcAlpha[i]),
      );
    }
    final amber = ui.Gradient.linear(map(const Offset(102, 158)), map(const Offset(266, 354)), [
      beamAmberLight,
      beamAmberDeep,
    ]);
    final triangle = Path()..addPolygon(beamTriangle.map(map).toList(), true);
    canvas.drawPath(triangle, Paint()..shader = amber);
    canvas.drawPath(
      triangle,
      Paint()
        ..shader = amber
        ..style = PaintingStyle.stroke
        ..strokeJoin = StrokeJoin.round
        ..strokeWidth = 36 * unit,
    );
  }

  @override
  bool shouldRepaint(_BeamPainter old) => false;
}

/// "dlnacast" in the intro's face: dlna in ink, cast in amber.
class Wordmark extends StatelessWidget {
  const Wordmark({super.key, this.size = 22});
  final double size;

  @override
  Widget build(BuildContext context) {
    TextStyle style(Color color) => TextStyle(
      fontFamily: 'Unbounded',
      fontSize: size,
      fontVariations: const [FontVariation.weight(700)],
      letterSpacing: -0.3,
      color: color,
      height: 1.1,
    );
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(text: 'dlna', style: style(Palette.ink)),
          TextSpan(text: 'cast', style: style(Palette.amber)),
        ],
      ),
      semanticsLabel: 'dlna cast',
    );
  }
}

/// Faint broadcast arcs, the mark's motif, for decorating cards.
class BeamArcs extends StatelessWidget {
  const BeamArcs({super.key, this.size = 160, this.color = beamVioletLight, this.opacity = 0.14});
  final double size;
  final Color color;
  final double opacity;

  @override
  Widget build(BuildContext context) => CustomPaint(
    size: Size.square(size),
    painter: _ArcsPainter(color.withValues(alpha: opacity)),
  );
}

class _ArcsPainter extends CustomPainter {
  const _ArcsPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final centre = Offset(0, size.height / 2);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = size.width * 0.07
      ..color = color;
    for (final fraction in [0.35, 0.62, 0.89]) {
      canvas.drawArc(Rect.fromCircle(center: centre, radius: size.width * fraction), -pi / 4, pi / 2, false, paint);
    }
  }

  @override
  bool shouldRepaint(_ArcsPainter old) => old.color != color;
}
