# dlna-cast for Android

A standalone Android app (Flutter + Kotlin) that casts the phone's **screen** (with its sound) and **gallery media**
to DLNA/UPnP renderers. The main target is a pair of video goggles on the Platinum UPnP stack. It's the Android
companion to the desktop/CLI project at `C:\Users\Karan\Desktop\dlna-cast` (Node.js, zero deps), whose `src/`
protocol layer this repo ports.

## Decisions (settled with the user, don't re-propose)

- **Android only.** No iOS (ReplayKit screen capture and Apple's multicast entitlement were judged not worth it).
- **Separate repo** from dlna-cast, not a `mobile/` folder inside it.
- **Standalone caster.** The phone does discovery, serving and control itself. It is **not** a remote for casts
  running on the PC (that would break the desktop app's loopback + per-launch-token security model).
- minSdk 29 (Android 10) for AudioPlaybackCapture.

## Status

- Done: `dlna_core` Dart port (28 tests pass), Flutter UI, Kotlin screen pipeline, foreground service. Debug APK
  builds. TsMuxer unit tests pass, including an ffmpeg decode check.
- **Phase 0 passed (2026-11-01)** on a Redmi Note 7 Pro (Android 13): the goggles play the hand-muxed screen share
  and H.264 MP4 files.
- Goggles quirks found on real hardware (the goggles answer each with a bare UPnP 501 on Play):
  - **No HEVC decoder.** Phone cameras record HEVC, so `castVideo` converts non-H.264 video first
    (`media/VideoConverter.kt`, Media3 Transformer → H.264 main in a 1920x1080 frame, cached in `cacheDir/converted`).
  - **No image support at all** (any size, format or DIDL; they don't even fetch it). Photos go out as a live
    stream instead: `PhotoSource` draws the bitmap into the screen-share encoder. In the fake renderer: `rejectImages`.
- Photo streams and HEVC conversion confirmed working on the goggles (2026-11-01).
- Done (2026-11-01): Beam logo (play button + broadcast arcs), adaptive/monochrome/notification icons, splash,
  launch animation with synthesised sound, branded home screen. Next: Play Store release.
- Debug on device with: `adb logcat -s ScreenStreamer LiveServer CastService VideoConverter flutter` plus the in-app
  Activity log (file-cast errors only show there; request lines go to the `flutter` tag).
- Git: initialised on `main`; the initial commit and GitHub remote are not done yet (the `gh` CLI isn't installed).
  Commit only when asked.
- Known warning: `photo_manager` applies the Kotlin Gradle Plugin, which a future Flutter will reject. It works today.

## Layout

```
packages/dlna_core/        pure Dart, no dependencies; port of dlna-cast src/
  lib/src/ssdp.dart        M-SEARCH + passive NOTIFY listener (goggles only send NOTIFY)
  lib/src/description.dart device description; control URLs must stay on the describing host
  lib/src/soap.dart        AVTransport / RenderingControl; preserveHeaderCase for picky renderers
  lib/src/didl.dart        DIDL-Lite + DLNA flags (files 017…, live 8D1…)
  lib/src/media_server.dart file serving with byte ranges, nonce URL, allow-list = renderer IP
  lib/src/cast.dart        castFile, castLiveStream, pickMimeType (renderer's MIME spelling)
  lib/src/session.dart     CastSession: 1 s polling, two-STOPPED-polls rule, read-back confirmation
  test/support/fake_renderer.dart  Dart port of dlna-cast's fixtures/fake-renderer.mjs
lib/
  native.dart              MethodChannel "dlna_cast/native" + EventChannel "dlna_cast/events"; Quality presets
  cast_controller.dart     app state (ChangeNotifier): devices, selection, session, activity log
  ui/                      home_page, now_playing (goggles view), screen_share_sheet, gallery_page, theme
  ui/brand.dart            BeamMark, Wordmark, BeamArcs; the mark's geometry (shared with the intro)
  ui/intro.dart            launch animation over the app; IntroTimeline beats match launch_sound.py
design/brand/              beam.svg (logo master), play-store-icon-512.png, launch_sound.py (regenerates res/raw)
android/app/src/main/kotlin/io/github/karan_ksrk/dlna_cast/
  MainActivity.kt          channel handler: multicast lock, permissions, MediaProjection consent
  CastService.kt           foreground service (mediaProjection | mediaPlayback), Wi-Fi + wake locks, notification
  screen/ScreenStreamer.kt VideoSource → MediaCodec H.264; AudioPlaybackCapture/mic/silence → AAC
  screen/VideoSource.kt    ScreenSource (VirtualDisplay) and PhotoSource (still photo, swappable)
  media/VideoConverter.kt  HEVC etc. → H.264 MP4 via Media3 Transformer, for renderers that only decode H.264
  screen/TsMuxer.kt        hand-written MPEG-TS muxer (Android's MediaMuxer can't write TS; ffmpeg-kit is retired)
  screen/LiveServer.kt     LiveBroadcast fan-out + HTTP server for the live stream
android/app/src/test/.../TsMuxerTest.kt  structural checks + ffmpeg decode test (skipped if ffmpeg isn't on PATH)
```

File casts are served from Dart; screen shares are captured, muxed **and served** in Kotlin (no video crosses the
platform channel), and Dart only sends SetAVTransportURI/Play and polls.

## Stream format (mirrors the desktop ffmpeg settings the goggles accept)

H.264 main profile, no B-frames, CBR, keyframe every 1 s, `KEY_REPEAT_PREVIOUS_FRAME_AFTER` so a static screen
still produces frames; AUD + SPS/PPS before each keyframe; PAT/PMT before every video frame; PCR at least every
20 ms; discontinuity flag on each PID's first packet; PIDs PMT 0x1000 / video 0x100 / audio 0x101; AAC-LC
48 kHz stereo 128 kbps in ADTS, always present (silence when needed). Fixed 16:9 encoder size, so the system
letterboxes a portrait screen. Live HTTP: chunked for HTTP/1.1, DLNA headers with exact case.

Quality presets (same as the desktop app): Light 720p30 3 Mbit/s, Balanced 1080p30 6 Mbit/s, Smooth 1080p60 10 Mbit/s.

## Commands

The toolchain is at Flutter `C:\src\flutter\bin`, Android SDK `%LOCALAPPDATA%\Android\Sdk`, JDK = Android Studio's
`C:\Program Files\Android\Android Studio\jbr`; set `JAVA_HOME` to it in Git Bash or Gradle fails. ffmpeg (winget
Gyan.FFmpeg, not on PATH in every shell; it's under `%LOCALAPPDATA%\Microsoft\WinGet\Packages`) is needed for the
muxer decode test. The phone is on wireless adb, so pass `-s <ip:port>` (it's listed twice).

```sh
(cd packages/dlna_core && dart analyze && dart test)
flutter analyze && flutter test
flutter build apk --debug                 # first build is slow (Gradle downloads)
(cd android && ./gradlew :app:testDebugUnitTest)
adb install build/app/outputs/flutter-apk/app-debug.apk
```

## Brand

Beam mark on graphite (#1B1E22); amber #F2A541 (gradient #FFC56D→#EC8429), violet #9A8CF8 (#B8ADFF→#7D6CF2).
Wordmark "dlnacast" in Unbounded 700 (bundled, OFL), "cast" in amber. Android icons are vector drawables traced
from beam.svg in its 512-unit space; keep them in sync with it. The splash shows the mark at 288dp, the intro's
first frame matches it exactly, and the system splash exits without a fade. The intro is frame-paced (max 50 ms per
frame) so startup jank slows it instead of skipping it; reduced motion skips it, and its sound only plays in normal
ringer mode with no music playing. Changing a beat means changing IntroTimeline and launch_sound.py together.

## Conventions

- Match the dlna-cast code style: short comments that explain *why* (device quirks, protocol rules), no
  narration. Keep `dlna_core` dependency-free and behaviourally identical to the Node modules it ports.
- Dart formatter page width is 120 (`analysis_options.yaml`).
- Security rules carried over from dlna-cast: only accept LAN description/control URLs on the host that answered,
  serve media only to the renderer's IP at an unguessable path.
- When a renderer quirk is discovered on real hardware, add it to the fake renderer and a test.
