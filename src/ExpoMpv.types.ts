import type { StyleProp, ViewStyle } from 'react-native';

// MARK: - Event Payloads

export type PlaybackStateChangeEvent = {
  state: 'playing' | 'paused' | 'stopped';
  isPlaying: boolean;
};

export type ProgressEvent = {
  position: number;
  duration: number;
  bufferedDuration: number;
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
  /** Load an external subtitle file (local path or URL). */
  addSubtitle: (path: string, flag?: string, title?: string, lang?: string) => Promise<void>;
  /** Remove a subtitle track by ID. */
  removeSubtitle: (trackId: number) => Promise<void>;
  /** Reload current subtitles. */
  reloadSubtitles: () => Promise<void>;
  /** Set subtitle delay in seconds (positive = later, negative = earlier). */
  setSubtitleDelay: (seconds: number) => Promise<void>;
  /** Set an mpv property by name (string value). */
  setPropertyString: (name: string, value: string) => Promise<void>;
  getPlaybackInfo: () => Promise<PlaybackInfo>;
  getTrackList: () => Promise<TrackInfo[]>;
  getCurrentTrackIds: () => Promise<CurrentTrackIds>;
};
