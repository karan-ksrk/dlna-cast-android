import 'package:flutter/material.dart';

// The desktop app's palette: graphite panels, warm ink, an amber accent and violet for focus and live state.
abstract final class Palette {
  static const graphite = Color(0xFF23272C);
  static const panel = Color(0xFF2D3238);
  static const field = Color(0xFF363C43);
  static const line = Color(0xFF444B53);
  static const ink = Color(0xFFECE8E1);
  static const inkDim = Color(0xFFAAA59C);
  static const inkFaint = Color(0xFF7D7A74);
  static const amber = Color(0xFFF2A541);
  static const amberInk = Color(0xFF2A1D08);
  static const violet = Color(0xFF9A8CF8);
  static const coral = Color(0xFFF0907F);
}

ThemeData buildTheme() {
  final scheme = const ColorScheme.dark(
    surface: Palette.graphite,
    onSurface: Palette.ink,
    surfaceContainer: Palette.panel,
    surfaceContainerHigh: Palette.field,
    primary: Palette.amber,
    onPrimary: Palette.amberInk,
    secondary: Palette.violet,
    error: Palette.coral,
    outline: Palette.line,
    outlineVariant: Palette.line,
    onSurfaceVariant: Palette.inkDim,
  );
  return ThemeData(
    colorScheme: scheme,
    scaffoldBackgroundColor: Palette.graphite,
    appBarTheme: const AppBarTheme(backgroundColor: Palette.graphite, foregroundColor: Palette.ink, centerTitle: false),
    cardTheme: CardThemeData(
      color: Palette.panel,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
    ),
    sliderTheme: const SliderThemeData(
      activeTrackColor: Palette.amber,
      thumbColor: Palette.amber,
      inactiveTrackColor: Palette.line,
    ),
    bottomSheetTheme: const BottomSheetThemeData(backgroundColor: Palette.panel),
  );
}
