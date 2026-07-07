import type { StyleProp, ViewStyle } from 'react-native';

// MARK: - Event Payloads

/**
 * High-level playback state derived natively from mpv properties.
 *
 * - `idle`: no source loaded (before loadfile, or after stop).
 * - `loading`: source is loading — from loadfile until the first frame is
 *   rendered (mpv `core-idle` true but not stalled on cache).
 * - `playing`: actively rendering frames.
 * - `paused`: paused by the user.
 * - `buffering`: playback stalled waiting for the network cache
 *   (mpv `paused-for-cache`).
 * - `ended`: playback reached end of file.
 */
export type PlaybackState = 'idle' | 'loading' | 'playing' | 'paused' | 'buffering' | 'ended';

export type PlaybackStateChangeEvent = {
  state: PlaybackState;
  /** Whether the user intends playback to run (i.e. not paused). */
  isPlaying: boolean;
};

export type ProgressEvent = {
  /** Current playback position in seconds. */
  position: number;
  /** Total duration in seconds. */
  duration: number;
  /**
   * Seconds of media buffered ahead of the current position
   * (mpv `demuxer-cache-duration`).
   */
  bufferedDuration: number;
  /**
   * Absolute timeline position (seconds) up to which media is buffered
   * (mpv `demuxer-cache-time`). Use `bufferedPosition / duration` to draw the
   * buffered range on a seek bar. May be 0 when mpv can't estimate it.
   */
  bufferedPosition: number;
  /**
   * Network read rate in bytes per second
   * (mpv `demuxer-cache-state.raw-input-rate`). 0 when unknown / local file.
   */
  bufferRate: number;
  /**
   * Cache fill percentage (0-100) while stalled for buffering
   * (mpv `cache-buffering-state`). 100 when not buffering.
   */
  bufferingPercent: number;
};

export type LoadEvent = {
  duration: number;
  width: number;
  height: number;
};

export type ErrorEvent = {
  error: string;
};

export type EndEvent = {
  reason: 'ended' | 'error' | 'stopped' | 'unknown';
};

export type BufferEvent = {
  isBuffering: boolean;
};

export type SeekEvent = {};

export type VolumeChangeEvent = {
  volume: number;
  muted: boolean;
};

export type HdrStateChangeEvent = {
  /** The current media is HDR (mpv `video-params/sig-peak` > 1). */
  isHdr: boolean;
  /**
   * HDR is actually being displayed: the media is HDR AND the screen supports
   * EDR (`potentialEDRHeadroom` > 1). When false on HDR media, the device/screen
   * can't show HDR and mpv tone-maps to SDR.
   */
  hdrActive: boolean;
  /** Reference peak brightness relative to SDR (mpv `video-params/sig-peak`). */
  sigPeak: number;
  /** Transfer function: "pq" (HDR10/Dolby Vision), "hlg", or "" for SDR. */
  hdrFormat: string;
};

export type PlaybackInfo = {
  position: number;
  duration: number;
  isPlaying: boolean;
  speed: number;
  volume: number;
  muted: boolean;
};

export type TrackInfo = {
  id: number;
  type: 'video' | 'audio' | 'sub' | string;
  title: string;
  lang: string;
  codec: string;
  selected: boolean;
  isDefault: boolean;
  isExternal: boolean;
  // audio-specific
  channelCount?: number;
  sampleRate?: number;
  // video-specific
  width?: number;
  height?: number;
  fps?: number;
};

export type CurrentTrackIds = {
  vid: number;
  aid: number;
  sid: number;
};

export type MediaInfo = {
  /** Configured hardware decode mode (e.g. "videotoolbox", "mediacodec", "no") */
  hwdec: string;
  /** Actually active hardware decoder (empty string = software decoding) */
  hwdecCurrent: string;
  /** Video codec name (e.g. "h264", "hevc", "av1") */
  videoCodec: string;
  /** Audio codec name (e.g. "aac", "opus") */
  audioCodec: string;
  /** Video width in pixels */
  width: number;
  /** Video height in pixels */
  height: number;
  /** Video frame rate */
  fps: number;
  /** Video bitrate in bits per second */
  videoBitrate: number;
  /** Audio bitrate in bits per second */
  audioBitrate: number;
  /** Pixel format (e.g. "yuv420p", "nv12") */
  pixelFormat: string;
  /** Color space (e.g. "bt.709", "bt.2020-ncl") */
  colorspace: string;
  /** Whether the media is HDR (transfer function is PQ or HLG). */
  isHdr: boolean;
  /** Transfer function / gamma (e.g. "pq", "hlg", "bt.1886"). */
  hdrFormat: string;
};

// MARK: - Module Events (non-view)

export type ExpoMpvModuleEvents = {};

// MARK: - View Props

export type ExpoMpvViewProps = {
  /**
   * Media source URL to play. Can be a remote URL or a local file path.
   */
  source?: string;

  /**
   * Whether playback is paused.
   */
  paused?: boolean;

  /**
   * Playback speed multiplier. Default is 1.0.
   */
  speed?: number;

  /**
   * Volume level (0-100). Default is 100.
   */
  volume?: number;

  /**
   * Whether audio is muted.
   */
  muted?: boolean;

  /**
   * Whether to loop the current file.
   */
  loop?: boolean;

  /**
   * Hardware decoding mode. Default is 'mediacodec' on Android, 'auto' on iOS.
   * Use 'no' to force software decoding, 'mediacodec' for Android HW decode,
   * 'mediacodec-copy' for HW decode with CPU copy.
   */
  hwdec?: string;

  /**
   * Called when playback state changes (play/pause).
   */
  onPlaybackStateChange?: (event: { nativeEvent: PlaybackStateChangeEvent }) => void;

  /**
   * Called periodically with current playback progress.
   */
  onProgress?: (event: { nativeEvent: ProgressEvent }) => void;

  /**
   * Called when a media file has been loaded and is ready to play.
   */
  onLoad?: (event: { nativeEvent: LoadEvent }) => void;

  /**
   * Called when an error occurs.
   */
  onError?: (event: { nativeEvent: ErrorEvent }) => void;

  /**
   * Called when playback reaches the end.
   */
  onEnd?: (event: { nativeEvent: EndEvent }) => void;

  /**
   * Called when buffering state changes.
   */
  onBuffer?: (event: { nativeEvent: BufferEvent }) => void;

  /**
   * Called when a seek operation completes.
   */
  onSeek?: (event: { nativeEvent: SeekEvent }) => void;

  /**
   * Called when volume or mute state changes.
   */
  onVolumeChange?: (event: { nativeEvent: VolumeChangeEvent }) => void;

  /**
   * Called when the HDR state changes (HDR content detected / display support).
   */
  onHdrStateChange?: (event: { nativeEvent: HdrStateChangeEvent }) => void;

  style?: StyleProp<ViewStyle>;
};

// MARK: - View Ref Methods

export type ExpoMpvViewRef = {
  play: () => Promise<void>;
  pause: () => Promise<void>;
  togglePlay: () => Promise<void>;
  stop: () => Promise<void>;
  seekTo: (position: number) => Promise<void>;
  seekBy: (offset: number) => Promise<void>;
  setSpeed: (speed: number) => Promise<void>;
  setVolume: (volume: number) => Promise<void>;
  setMuted: (muted: boolean) => Promise<void>;
  setSubtitleTrack: (trackId: number) => Promise<void>;
  setAudioTrack: (trackId: number) => Promise<void>;
  /**
   * Load an external subtitle file (local path or URL).
   * `flag` defaults to `"select"` (shows the subtitle immediately). Pass
   * `"auto"` to add it without selecting, then call `setSubtitleTrack`.
   */
  addSubtitle: (path: string, flag?: string, title?: string, lang?: string) => Promise<void>;
  /** Remove a subtitle track by ID. */
  removeSubtitle: (trackId: number) => Promise<void>;
  /**
   * Load an external audio file (local path or URL).
   * `flag` defaults to `"select"` (makes it the active audio track). Pass
   * `"auto"` to add it without selecting, then call `setAudioTrack`.
   */
  addAudio: (path: string, flag?: string, title?: string, lang?: string) => Promise<void>;
  /** Remove an audio track by ID. */
  removeAudio: (trackId: number) => Promise<void>;
  /** Reload current subtitles. */
  reloadSubtitles: () => Promise<void>;
  /** Set subtitle delay in seconds (positive = later, negative = earlier). */
  setSubtitleDelay: (seconds: number) => Promise<void>;
  /** Set an mpv property by name (string value). */
  setPropertyString: (name: string, value: string) => Promise<void>;
  getPlaybackInfo: () => Promise<PlaybackInfo>;
  getTrackList: () => Promise<TrackInfo[]>;
  getCurrentTrackIds: () => Promise<CurrentTrackIds>;
  getMediaInfo: () => Promise<MediaInfo>;
};
