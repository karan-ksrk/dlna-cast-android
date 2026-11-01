import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'cast_controller.dart';
import 'ui/home_page.dart';
import 'ui/intro.dart';
import 'ui/theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks(['Unbounded'], await rootBundle.loadString('assets/fonts/OFL.txt'));
  });
  final controller = CastController()..start();
  runApp(DlnaCastApp(controller: controller));
}

class DlnaCastApp extends StatelessWidget {
  const DlnaCastApp({super.key, required this.controller});
  final CastController controller;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'dlnacast',
    debugShowCheckedModeBanner: false,
    theme: buildTheme(),
    home: HomePage(controller: controller),
    builder: (context, child) => IntroOverlay(child: child!),
  );
}
