# expo-mpv

An Expo module wrapping [libmpv](https://mpv.io/) for advanced video playback on iOS and Android.

On iOS it uses [MPVKit](https://github.com/mpvkit/MPVKit). On Android it integrates native `libmpv` binaries from the [mpv-android](https://github.com/mpv-android/mpv-android) releases and wires them into an Expo Module view/component API.

## Features

- iOS and Android support
- Hardware-accelerated video playback via libmpv
- iOS Metal rendering via MoltenVK (Vulkan -> Metal)
- Android `SurfaceView` rendering with `gpu` + `gpu-context=android`
- Runtime hardware decode selection (`videotoolbox` / `mediacodec` / software)
- Media info inspection: codec, resolution, fps, bitrate, hwdec status, pixel format, colorspace
- Play/pause, seek, speed, volume, mute, loop
- Subtitle track selection (embedded + external)
- Audio track selection
- External subtitle loading (`sub-add`)
- Runtime `hwdec` selection (iOS: `videotoolbox`, Android: `mediacodec`)
- Track inspection via `getTrackList()` and `getCurrentTrackIds()`
- Media info via `getMediaInfo()` (codec, resolution, fps, bitrate, hwdec status)
- Progress, buffering, error, and playback state events
- CJK subtitle support with bundled Noto Sans CJK SC font

## Installation

```bash
npx expo install expo-mpv
```

This package ships an Expo config plugin and is intended to be used in a custom dev client / prebuild workflow.

If your app does not already use `expo-build-properties`, install it as well:

```bash
npx expo install expo-build-properties
```

Add both plugins to your `app.json` / `app.config.ts`:

```json
{
  "plugins": [
    "expo-mpv",
    [
      "expo-build-properties",
      {
        "ios": {
          "deploymentTarget": "16.0"
        }
      }
    ]
  ]
}
```

Then run:

```bash
npx expo prebuild
```

### What the plugin does

- iOS: downloads the required MPVKit XCFrameworks during prebuild
- Android: Gradle downloads the `libmpv` native libraries automatically before build

There is no separate Android setup script to run.

### iOS notes

- Minimum deployment target: iOS 16.0
- The plugin downloads MPVKit dependencies into `node_modules/expo-mpv/ios/Frameworks`
- The first prebuild / native build can take a while because the media stack is large

### Android notes

- Minimum SDK: Android 21
- Supported ABIs: `armeabi-v7a`, `arm64-v8a`, `x86`, `x86_64`
- `libmpv` shared libraries are downloaded from `mpv-android` releases during Gradle build
- The module replaces merged `libc++_shared.so` with the `mpv-android` version so `libmpv.so` can load correctly at runtime
- Default hardware decode mode on Android is `mediacodec`

If you use network streams on Android, make sure your app networking/security setup allows them as usual for your project.

## Usage

```tsx
import { ExpoMpvView } from "expo-mpv";
import type { ExpoMpvViewRef } from "expo-mpv";
import { useRef } from "react";

export default function Player() {
  const playerRef = useRef<ExpoMpvViewRef>(null);

  return (
    <ExpoMpvView
      ref={playerRef}
      source="https://example.com/video.mp4"
      style={{ width: "100%", aspectRatio: 16 / 9 }}
      onLoad={({ nativeEvent }) => {
        console.log("Duration:", nativeEvent.duration);
      }}
      onProgress={({ nativeEvent }) => {
        console.log("Position:", nativeEvent.position);
      }}
      onError={({ nativeEvent }) => {
        console.error("Error:", nativeEvent.error);
      }}
    />
  );
}
```

### Imperative API (via ref)

```ts
playerRef.current?.play();
playerRef.current?.pause();
playerRef.current?.togglePlay();
playerRef.current?.seekTo(120); // seconds
playerRef.current?.seekBy(-10); // relative seconds
playerRef.current?.setSpeed(1.5);
playerRef.current?.setVolume(80); // 0-100
playerRef.current?.setMuted(true);
playerRef.current?.setSubtitleTrack(2);
playerRef.current?.setAudioTrack(1);
playerRef.current?.addSubtitle("https://example.com/subs.srt");
playerRef.current?.removeSubtitle(3);
playerRef.current?.reloadSubtitles();
playerRef.current?.setSubtitleDelay(-0.5); // seconds
playerRef.current?.setPropertyString("cache", "yes");

const info = await playerRef.current?.getPlaybackInfo();
const tracks = await playerRef.current?.getTrackList();
const currentTracks = await playerRef.current?.getCurrentTrackIds();
const media = await playerRef.current?.getMediaInfo();
// media.hwdecCurrent, media.videoCodec, media.width, media.height,
// media.fps, media.videoBitrate, media.pixelFormat, etc.
```

### Props

| Prop | Type | Description |
|------|------|-------------|
| `source` | `string` | Media URL or local file path |
| `paused` | `boolean` | Pause/resume playback |
| `speed` | `number` | Playback speed (default: 1.0) |
| `volume` | `number` | Volume 0-100 (default: 100) |
| `muted` | `boolean` | Mute audio |
| `loop` | `boolean` | Loop current file |
| `hwdec` | `string` | Hardware decode mode. Defaults to `videotoolbox` on iOS and `mediacodec` on Android |

### Events

| Event | Payload | Description |
|-------|---------|-------------|
| `onPlaybackStateChange` | `{ state, isPlaying }` | Play/pause state changed |
| `onProgress` | `{ position, duration, bufferedDuration }` | Periodic progress update |
| `onLoad` | `{ duration, width, height }` | Media loaded and ready |
| `onError` | `{ error }` | Error occurred |
| `onEnd` | `{ reason }` | Playback ended |
| `onBuffer` | `{ isBuffering }` | Buffering state changed |
| `onSeek` | `{}` | Seek completed |
| `onVolumeChange` | `{ volume, muted }` | Volume/mute changed |

### Imperative API

`ExpoMpvViewRef` exposes:

- `play()`
- `pause()`
- `togglePlay()`
- `stop()`
- `seekTo(position)`
- `seekBy(offset)`
- `setSpeed(speed)`
- `setVolume(volume)`
- `setMuted(muted)`
- `setSubtitleTrack(trackId)`
- `setAudioTrack(trackId)`
- `addSubtitle(path, flag?, title?, lang?)`
- `removeSubtitle(trackId)`
- `reloadSubtitles()`
- `setSubtitleDelay(seconds)`
- `setPropertyString(name, value)`
- `getPlaybackInfo()`
- `getTrackList()`
- `getCurrentTrackIds()`
- `getMediaInfo()` — returns codec, resolution, fps, bitrate, hwdec status, pixel format, colorspace

## CJK Subtitle Rendering

This module bundles [Noto Sans CJK SC](https://github.com/notofonts/noto-cjk) (SIL Open Font License) for Chinese/Japanese/Korean subtitle rendering.

**Why a bundled font is necessary:**

Starting with iOS 18, Apple changed system fonts (PingFang, Heiti, etc.) to a proprietary HVGL variable font format. FreeType — the font rasterizer used by libass (mpv's subtitle renderer) — cannot parse HVGL fonts. This means system CJK fonts are invisible to libass, causing Chinese characters to render as empty boxes (tofu).

This is a known issue across the ecosystem:
- [libass/libass#912](https://github.com/libass/libass/issues/912) — FreeType HVGL support tracking
- [mpv-player/mpv#14878](https://github.com/mpv-player/mpv/issues/14878) — PingFang broken on macOS 15
- [iina/iina#5176](https://github.com/iina/iina/issues/5176) — IINA Chinese subtitle garbling
- [arthenica/ffmpeg-kit#1001](https://github.com/arthenica/ffmpeg-kit/issues/1001) — ffmpeg-kit iOS 18 subtitle issue

The bundled Noto Sans CJK SC Regular (~16MB) covers Simplified Chinese, Traditional Chinese, Japanese, and Korean. It uses the [SIL Open Font License](https://openfontlicense.org/), which permits free use, embedding, and redistribution.

## Architecture

```
React Native (JS)
  └─ ExpoMpvView (native view)
       └─ mpv (libmpv C API)
            ├─ FFmpeg (demuxing, decoding)
            ├─ iOS: VideoToolbox + MoltenVK + Metal
            ├─ Android: MediaCodec + SurfaceView
            └─ libass + FreeType + Noto Sans CJK (subtitle rendering)
```

On simulator, `vo=gpu` is used instead of `vo=gpu-next` to avoid a crash in `MTLSimDriver` caused by XPC shared memory size limits when libplacebo uploads video frame textures.

## License

[GPL-3.0](./LICENSE)
