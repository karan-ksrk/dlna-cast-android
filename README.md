<img src="design/brand/play-store-icon-512.png" alt="" width="96" align="right">

# dlna-cast for Android

**Cast your phone's screen, videos, photos and music to DLNA video goggles and smart TVs.**

The Android companion to [dlna-cast](https://github.com/karan-ksrk/dlna-cast). It's a standalone app: the phone finds
renderers, serves the media and controls playback itself, using only open standards (SSDP, HTTP and UPnP SOAP).
No PC, cloud service or vendor app is involved.

## Features

- **Finds renderers automatically.** It sends SSDP `M-SEARCH` and also listens for `NOTIFY` announcements, which is
  how the Platinum-based goggles make themselves known. It remembers the last device you used, and you can add a
  device by IP address.
- **Share the phone's screen live** as hardware-encoded H.264 in MPEG-TS, **with the phone's sound** (Android 10+
  playback capture), the microphone or silence. Light, Balanced and Smooth quality presets match the desktop app. The
  stream is a fixed 16:9 picture, so rotating the phone doesn't interrupt it.
- **Cast gallery videos, photos and music** straight from their files, with byte-range seeking. The format is matched
  to what the renderer says it accepts.
- **Plays what the renderer can't decode.** Phone cameras record HEVC, which many renderers (the goggles among them)
  can't play, so those videos are converted to H.264 on the phone first. Photos go out as a live video stream for
  renderers with no image support.
- **Full remote control:** pause, resume, seek, volume and mute. Each command is checked against what the renderer
  reports, so devices that silently ignore a command are called out rather than trusted.
- **Keeps going in the background** with a foreground service and a Stop button in the notification.
- **Safe on your network:** media is served only to the renderer you chose, at an unguessable URL.

## Requirements

- Android 10 or newer
- A DLNA renderer on the same Wi-Fi network as the phone

Protected apps (Netflix and similar) appear black in a screen share, and apps that opt out of audio capture are
silent. Android enforces both.

## Building

You need Flutter (stable) and the Android SDK.

```sh
flutter pub get
flutter run                 # on a connected phone
flutter build apk --release
```

## Tests

```sh
(cd packages/dlna_core && dart test)        # protocol layer against a simulated renderer
flutter test                                # app widgets
(cd android && ./gradlew :app:testDebugUnitTest)   # MPEG-TS muxer; decodes its output with ffmpeg when installed
```

## How it works

```
 discover               control                          serve
┌──────────────┐   ┌──────────────────────────┐   ┌──────────────────────────────────┐
│ SSDP M-SEARCH│   │ SOAP over HTTP           │   │ files: dart:io HTTP server with   │
│ + NOTIFY     │──▶│ AVTransport: SetURI,     │──▶│ byte ranges                       │
│ (Dart)       │   │ Play, Pause, Seek        │   │ screen: Kotlin foreground service │
└──────────────┘   │ RenderingControl: volume │   │ MediaProjection → MediaCodec H.264│
                   └──────────────────────────┘   │ playback capture → AAC → MPEG-TS  │
                                                  └──────────────────────────────────┘
```

```
packages/dlna_core/   pure Dart protocol layer, ported from dlna-cast's src/ (ssdp, description, soap, didl,
                      media server, cast session) with its tests and fake renderer
lib/                  Flutter app: CastController (state) and the UI
android/app/src/main/kotlin/.../
  MainActivity.kt     the "dlna_cast/native" channel: multicast lock, screen-capture consent, service control
  CastService.kt      foreground service, Wi-Fi and wake locks, notification
  screen/             ScreenStreamer (encoders), VideoSource (screen or still photo), TsMuxer, LiveServer
  media/              VideoConverter: HEVC and others to H.264 with Media3 Transformer
design/brand/         the Beam logo (SVG master, Play Store icon) and the launch sound's generator
```

The MPEG-TS stream copies the ffmpeg settings the desktop app uses, which the goggles are known to accept: PAT/PMT
before every frame, a PCR at least every 20 ms, a keyframe every second with SPS/PPS repeated, main profile with no
B-frames, and an AAC track that is always present (silent if needed).

## License

[MIT](LICENSE) © Karan ([karan-ksrk](https://github.com/karan-ksrk))
