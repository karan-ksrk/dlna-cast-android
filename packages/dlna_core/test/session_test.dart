import 'dart:io';

import 'package:dlna_core/dlna_core.dart';
import 'package:test/test.dart';

import 'support/fake_renderer.dart';

late Directory tmpDir;
late File mediaFile;

Future<void> waitFor(bool Function() predicate, {Duration timeout = const Duration(seconds: 3)}) async {
  final started = DateTime.now();
  while (!predicate()) {
    if (DateTime.now().difference(started) > timeout) throw StateError('Timed out waiting');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

Future<(FakeRenderer, Device)> startRenderer({bool ignorePause = false, bool ignoreVolume = false}) async {
  final renderer = await FakeRenderer.start(ignorePause: ignorePause, ignoreVolume: ignoreVolume);
  addTearDown(renderer.close);
  return (renderer, await fetchDescription(Uri.parse(renderer.location)));
}

void main() {
  setUpAll(() async {
    tmpDir = await Directory.systemTemp.createTemp('dlna-core-session-');
    mediaFile = File('${tmpDir.path}/clip.mp4');
    await mediaFile.writeAsBytes(List<int>.filled(4096, 1));
  });
  tearDownAll(() => tmpDir.delete(recursive: true));

  test('RenderingControl reads and sets volume and mute on the Master channel', () async {
    final (renderer, device) = await startRenderer();
    final rendering = RenderingControl(device);
    expect(rendering.supported, isTrue);
    expect(await rendering.getVolume(), 40);
    await rendering.setVolume(140);
    expect(renderer.state.volume, 100, reason: 'volume is clamped to 0-100');
    await rendering.setMute(true);
    expect(await rendering.getMute(), isTrue);
    expect(RenderingControl(Device(friendlyName: 'x', location: Uri.parse('http://10.0.0.1/'))).supported, isFalse);
  });

  test('CastSession pauses, resumes, seeks, changes volume and stops', () async {
    final (renderer, device) = await startRenderer();
    final session = await CastSession.startFile(device, mediaFile, title: 'clip');
    final statuses = <CastSnapshot>[];
    session.status.listen(statuses.add);
    session.start(const Duration(milliseconds: 50));
    await waitFor(() => session.snapshot().state == 'PLAYING' && session.snapshot().volume == 40);
    expect(session.snapshot().duration, 60);

    await session.pause();
    expect(renderer.state.transport, 'PAUSED_PLAYBACK');
    await session.togglePause();
    expect(renderer.state.transport, 'PLAYING');

    expect(await session.seek(10, relative: true), 15);
    expect(renderer.state.position, 15);
    expect(await session.seek(500), 59, reason: 'seeks clamp to just before the end');

    expect(await session.setVolume(70), 70);
    expect(await session.changeVolume(-80), 0);
    expect(renderer.state.volume, 0);
    expect(await session.toggleMute(), isTrue);
    expect(renderer.state.muted, isTrue);

    await session.stop();
    expect(await session.ended, (reason: 'stopped', error: null, detail: null));
    expect(renderer.state.transport, 'STOPPED');
    expect(session.isEnded, isTrue);
    expect(statuses.any((s) => s.state == 'PAUSED_PLAYBACK'), isTrue);
    expect(session.snapshot().bytesSent, 10 + 4096, reason: 'the renderer pulled a 10-byte range, then the file');
  });

  test('CastSession ends when the renderer stops playing for two polls', () async {
    final (renderer, device) = await startRenderer();
    final session = await CastSession.startFile(device, mediaFile, title: 'clip');
    session.start(const Duration(milliseconds: 40));
    await waitFor(() => session.snapshot().state == 'PLAYING');
    renderer.state.transport = 'STOPPED';
    expect((await session.ended).reason, 'renderer-stopped');
  });

  test('pauseAndConfirm reports a renderer that ignores Pause', () async {
    final (_, device) = await startRenderer(ignorePause: true);
    final session = await CastSession.startFile(device, mediaFile, title: 'clip');
    try {
      await expectLater(
        pauseAndConfirm(device),
        throwsA(
          isA<IgnoredCommandError>().having((e) => e.message, 'message', contains('accepted Pause but kept playing')),
        ),
      );
    } finally {
      await session.stop();
    }
  });

  test('pauseAndConfirm says so when nothing is playing', () async {
    final (_, device) = await startRenderer();
    await expectLater(
      pauseAndConfirm(device),
      throwsA(isA<IgnoredCommandError>().having((e) => e.message, 'message', contains("there's nothing to pause"))),
    );
  });

  test('live sessions refuse to seek and report the native byte counter', () async {
    final (_, device) = await startRenderer();
    var stopped = false;
    final session = CastSession(
      device: device,
      kind: CastKind.screen,
      title: 'Phone screen',
      transport: AVTransport(device),
      close: () async => stopped = true,
      bytesSent: () => 1234,
    );
    await expectLater(session.seek(10), throwsStateError);
    expect(session.snapshot().bytesSent, 1234);
    expect(session.snapshot().seekable, isFalse);
    await session.sourceStopped('Screen capture stopped');
    expect((await session.ended).reason, 'capture-stopped');
    expect(stopped, isTrue);
  });

  test('readDeviceStatus reports state, position and volume', () async {
    final (_, device) = await startRenderer();
    expect(await readDeviceStatus(device), (
      state: 'NO_MEDIA_PRESENT',
      position: 5.0,
      duration: 60.0,
      uri: null,
      volume: 40,
      muted: false,
    ));
  });

  test('a renderer that ignores volume and mute is reported, and the session stops offering them', () async {
    final (_, device) = await startRenderer(ignoreVolume: true);
    final session = await CastSession.startFile(device, mediaFile, title: 'clip');
    try {
      await expectLater(
        session.setVolume(70),
        throwsA(isA<IgnoredCommandError>().having((e) => e.message, 'message', contains('still reports 40'))),
      );
      expect(session.snapshot().volumeSupported, isFalse);
      expect(session.snapshot().volumeIgnored, isTrue);
      expect(session.snapshot().volume, 40, reason: 'the reported volume is kept, not the requested one');
      await expectLater(session.toggleMute(), throwsA(isA<StateError>()));
    } finally {
      await session.stop();
    }
  });
}
