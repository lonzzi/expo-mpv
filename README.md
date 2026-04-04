# expo-mpv

An Expo module wrapping [libmpv](https://mpv.io/) for video playback on iOS, powered by [MPVKit](https://github.com/mpvkit/MPVKit).

> **Note:** Currently only **iOS** is supported. Android support is planned.

## Features

- Hardware-accelerated video playback via libmpv + VideoToolbox
- Metal rendering via MoltenVK (Vulkan → Metal)
- Play/pause, seek, speed, volume, mute, loop
- Subtitle track selection (embedded + external)
- Audio track selection
- External subtitle loading (`sub-add`)
- Progress, buffering, error, and playback state events
- CJK subtitle support with bundled Noto Sans CJK SC font

## Installation

```bash
npx expo install expo-mpv
```

This package requires `expo-build-properties` to set the iOS deployment target to 16.0:

```bash
npx expo install expo-build-properties
```

Add to your `app.json`:

```json
{
  "plugins": [
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

### MPVKit XCFrameworks

Before building, download the pre-built MPVKit xcframeworks:

```bash
cd node_modules/expo-mpv/ios
bash download-mpvkit.sh
```

This downloads ~28 xcframeworks (libmpv, FFmpeg, MoltenVK, libass, etc.) from the [MPVKit releases](https://github.com/mpvkit/MPVKit/releases).

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
playerRef.current?.setSubtitleDelay(-0.5); // seconds

const info = await playerRef.current?.getPlaybackInfo();
const tracks = await playerRef.current?.getTrackList();
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
            ├─ VideoToolbox (hardware decoding)
            ├─ libplacebo → Vulkan → MoltenVK → Metal (rendering, device only)
            ├─ gpu → Vulkan → MoltenVK → Metal (rendering, simulator)
            └─ libass + FreeType + Noto Sans CJK (subtitle rendering)
```

On simulator, `vo=gpu` is used instead of `vo=gpu-next` to avoid a crash in `MTLSimDriver` caused by XPC shared memory size limits when libplacebo uploads video frame textures.

## License

[MIT](./LICENSE)
