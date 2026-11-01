import 'package:dlna_cast/cast_controller.dart';
import 'package:dlna_cast/main.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(const MethodChannel('dlna_cast/native'), (_) async => null);
    messenger.setMockStreamHandler(const EventChannel('dlna_cast/events'), MockStreamHandler.inline(onListen: (_, _) {}));
  });

  testWidgets('home shows the renderer card and cast actions, disabled until a renderer is picked', (tester) async {
    // Reduced motion skips the intro, which would otherwise cover the home screen.
    tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await tester.pumpWidget(DlnaCastApp(controller: CastController()));

    expect(find.text('RENDERER'), findsOneWidget);
    expect(find.textContaining('Nothing answered'), findsOneWidget);
    expect(find.text('Share screen'), findsOneWidget);
    expect(find.text('Videos'), findsOneWidget);

    await tester.tap(find.text('Share screen'));
    await tester.pumpAndSettle();
    expect(find.text('Start sharing'), findsNothing, reason: 'nothing to share to yet');
  });
}
