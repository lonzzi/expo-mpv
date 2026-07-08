# Changelog

## 0.1.11

### iOS

- **Unified playback state machine.** `onPlaybackStateChange` now reports a
  `state` of `idle | loading | playing | paused | buffering | ended`, derived
  natively from mpv's `eof-reached` / `paused-for-cache` / `pause` / `core-idle`.
  Fixes "loading" mismatches (e.g. spinner hiding before the first frame) and
  premature state transitions.
- **Buffering progress & rate.** `onProgress` gained:
  - `bufferedPosition` — absolute buffered timeline position (`demuxer-cache-time`),
    for drawing the buffered range on a seek bar.
  - `bufferRate` — network read rate in bytes/sec (`demuxer-cache-state.raw-input-rate`).
  - `bufferingPercent` — cache fill 0–100 while stalled (`cache-buffering-state`).
- **HDR / Dolby Vision detection.** libplacebo (vo=gpu-next) decodes and tone-maps
  HDR & DV content. New `onHdrStateChange` event
  (`{ isHdr, hdrActive, sigPeak, hdrFormat }`) and `getMediaInfo()` now includes
  `isHdr` / `hdrFormat`.
  (Note: `target-colorspace-hint`/HDR passthrough is not forced on iOS — it can break
  hardware decode with vo=gpu-next.)
- **External subtitles now show by default.** `addSubtitle` defaults its flag to
  `select` (mpv's own default) instead of `auto`, so an added subtitle is displayed
  immediately. Pass `auto` to add without selecting.
- **External audio.** New `addAudio(path, flag?, title?, lang?)` and
  `removeAudio(trackId)` (mpv `audio-add` / `audio-remove`).

### JavaScript

- Every imperative ref method now resolves to a `Promise` even before the native
  view is mounted (`?? Promise.resolve()`), fixing "cannot read 'then' of undefined"
  crashes. `seekTo` / `seekBy` guard against non-finite arguments.

### Types

- New `PlaybackState` and `HdrStateChangeEvent` exports; `ProgressEvent`,
  `PlaybackStateChangeEvent`, `MediaInfo`, and `ExpoMpvViewRef` extended accordingly.

### Notes

- Requires iOS deployment target **16.4** when used with Expo SDK 57 / React Native 0.86.
- Xcode 26.1.x + Expo SDK 57 may fail to compile `expo-modules-jsi` (`weak let` /
  Sendable under Swift 6). This is an Expo/toolchain issue, not expo-mpv; work around
  it with `patch-package` (`nonisolated(unsafe) weak var`) or a compatible Xcode.
