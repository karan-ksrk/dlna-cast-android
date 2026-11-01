# dlnacast privacy policy

Effective 1 November 2026

dlnacast is an Android app that casts your phone's screen, videos, photos and music to TVs, video goggles and other
DLNA/UPnP devices on your own Wi-Fi network. This policy explains what the app accesses and what happens to it.

## The short version

dlnacast doesn't collect, store or share any personal data. It has no accounts, no ads, no analytics and no tracking,
and it never sends anything to the developer or to any other server on the internet. Everything it does happens
between your phone and the device you choose to cast to, on your local network.

## What the app accesses, and why

| Access | Why | Where it goes |
|---|---|---|
| **Your screen** (when you start a screen share and accept Android's prompt) | To show your screen on the device you picked | Encoded on the phone and streamed only to that device over your Wi-Fi. Never recorded or saved. |
| **Microphone / audio recording** | To include your phone's sound (or the microphone, if you choose it) in a screen share | Streamed with the screen to the same device. Never recorded or saved. |
| **Photos, videos and music** | So you can pick media to cast | The file you pick is served only to the device you chose. Nothing is uploaded anywhere. |
| **Local network** (Wi-Fi, multicast) | To find DLNA devices on your network and control playback | Stays on your local network. |
| **Notifications** | To show that a cast is running, with a Stop button | Shown on your phone only. |

Media is served only to the IP address of the device you chose, at a random, unguessable address that changes with
every cast.

## Data stored on your phone

- **The last device you used**, so the app can find it again quickly. It's stored only in the app's private storage.
- **Converted videos.** Some devices can't play the HEVC video that phone cameras record, so the app converts those
  videos to H.264 and keeps the three most recently used conversions in its cache to replay them instantly. Android
  can clear this cache at any time, and so can you (Settings → Apps → dlnacast → Storage → Clear cache).

Uninstalling the app removes all of this.

## Children

dlnacast isn't directed at children and doesn't knowingly collect data from anyone, including children.

## Changes

If this policy changes, the new version will be published at this address with a new effective date.

## Contact

Questions about this policy: Karan Singh, karanksrk2000@outlook.com
Source code: https://github.com/karan-ksrk/dlna-cast-android
