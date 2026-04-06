import { ExpoMpvView } from "expo-mpv";
import type {
  ExpoMpvViewRef,
  ProgressEvent,
  LoadEvent,
  PlaybackStateChangeEvent,
  ErrorEvent,
  EndEvent,
  BufferEvent,
  TrackInfo,
  MediaInfo,
} from "expo-mpv";
import { useCallback, useRef, useState } from "react";
import {
  ActivityIndicator,
  Platform,
  ScrollView,
  StatusBar,
  StyleSheet,
  Text,
  TextInput,
  TouchableOpacity,
  View,
} from "react-native";
import { SafeAreaView, SafeAreaProvider } from "react-native-safe-area-context";

interface TestVideo {
  label: string;
  url: string;
  tags: string[];
}

const TEST_VIDEOS: TestVideo[] = [
  {
    label: "Big Buck Bunny",
    tags: ["1080p", "SDR"],
    url: "https://test-videos.co.uk/vids/bigbuckbunny/mp4/h264/1080/Big_Buck_Bunny_1080_10s_1MB.mp4",
  },
  {
    label: "Sintel Trailer",
    tags: ["1080p", "SDR"],
    url: "https://media.w3.org/2010/05/sintel/trailer.mp4",
  },
  {
    label: "HDR10 Demo",
    tags: ["4K", "HDR", "HLS"],
    url: "https://devstreaming-cdn.apple.com/videos/streaming/examples/adv_dv_atmos/main.m3u8",
  },
  {
    label: "Dolby Vision",
    tags: ["4K", "DV", "HLS"],
    url: "https://devstreaming-cdn.apple.com/videos/streaming/examples/adv_dv_atmos/main.m3u8/../Job2dae5735-d6ca-48ca-91be-0ec0bead535c-107702578-hls_bundle_hdrhls797_dolbyvision/prog_index.m3u8",
  },
  {
    label: "HEVC HDR",
    tags: ["4K", "HDR", "HEVC"],
    url: "https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_16x9/bipbop_16x9_variant.m3u8",
  },
  {
    label: "4K60 HDR",
    tags: ["4K", "60fps", "HDR"],
    url: "https://test-videos.co.uk/vids/bigbuckbunny/mp4/h264/720/Big_Buck_Bunny_720_10s_1MB.mp4",
  },
  {
    label: "Tears HLS",
    tags: ["1080p", "HLS"],
    url: "https://demo.unified-streaming.com/k8s/features/stable/video/tears-of-steel/tears-of-steel.ism/.m3u8",
  },
  {
    label: "DASH Adaptive",
    tags: ["Adaptive", "DASH"],
    url: "https://dash.akamaized.net/akamai/bbb_30fps/bbb_30fps.mpd",
  },
];

type TracksByType = {
  video: TrackInfo[];
  audio: TrackInfo[];
  sub: TrackInfo[];
};

function AppInter() {
  const playerRef = useRef<ExpoMpvViewRef>(null);

  const [isPlaying, setIsPlaying] = useState(false);
  const [isBuffering, setIsBuffering] = useState(false);
  const [position, setPosition] = useState(0);
  const [duration, setDuration] = useState(0);
  const [videoSize, setVideoSize] = useState({ width: 0, height: 0 });
  const [speed, setSpeed] = useState(1.0);
  const [muted, setMuted] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [source, setSource] = useState(TEST_VIDEOS[1].url);
  const [inputUrl, setInputUrl] = useState("");
  const [currentVideoIndex, setCurrentVideoIndex] = useState(1);
  const [isSourceLoading, setIsSourceLoading] = useState(true);
  const [loadingMessage, setLoadingMessage] = useState("Loading stream...");
  const [tracks, setTracks] = useState<TracksByType>({
    video: [],
    audio: [],
    sub: [],
  });
  const [currentTrackIds, setCurrentTrackIds] = useState({
    vid: 0,
    aid: 0,
    sid: 0,
  });
  const [hwdecMode, setHwdecMode] = useState(
    Platform.OS === "ios" ? "videotoolbox" : "mediacodec"
  );
  const [mediaInfo, setMediaInfo] = useState<MediaInfo | null>(null);

  const refreshMediaInfo = useCallback(async () => {
    try {
      const info = await playerRef.current?.getMediaInfo();
      if (info) setMediaInfo(info);
    } catch (e) {
      console.log("refreshMediaInfo error:", e);
    }
  }, []);

  const refreshTracks = useCallback(async () => {
    try {
      const list = await playerRef.current?.getTrackList();
      const ids = await playerRef.current?.getCurrentTrackIds();
      if (list) {
        const grouped: TracksByType = { video: [], audio: [], sub: [] };
        for (const t of list) {
          if (t.type === "video") grouped.video.push(t);
          else if (t.type === "audio") grouped.audio.push(t);
          else if (t.type === "sub") grouped.sub.push(t);
        }
        setTracks(grouped);
      }
      if (ids) setCurrentTrackIds(ids);
    } catch (e) {
      console.log("refreshTracks error:", e);
    }
    refreshMediaInfo();
  }, [refreshMediaInfo]);

  const onPlaybackStateChange = useCallback(
    ({ nativeEvent }: { nativeEvent: PlaybackStateChangeEvent }) => {
      setIsPlaying(nativeEvent.isPlaying);
    },
    []
  );

  const onProgress = useCallback(
    ({ nativeEvent }: { nativeEvent: ProgressEvent }) => {
      setPosition(nativeEvent.position);
      setDuration(nativeEvent.duration);
    },
    []
  );

  const onLoad = useCallback(
    ({ nativeEvent }: { nativeEvent: LoadEvent }) => {
      setDuration(nativeEvent.duration);
      setVideoSize({ width: nativeEvent.width, height: nativeEvent.height });
      setError(null);
      setIsSourceLoading(false);
      setLoadingMessage("Loading stream...");
      setTimeout(() => refreshTracks(), 500);
    },
    [refreshTracks]
  );

  const onError = useCallback(
    ({ nativeEvent }: { nativeEvent: ErrorEvent }) => {
      setError(nativeEvent.error);
      setIsSourceLoading(false);
    },
    []
  );

  const onEnd = useCallback(({ nativeEvent }: { nativeEvent: EndEvent }) => {
    console.log("Playback ended:", nativeEvent.reason);
  }, []);

  const onBuffer = useCallback(
    ({ nativeEvent }: { nativeEvent: BufferEvent }) => {
      setIsBuffering(nativeEvent.isBuffering);
    },
    []
  );

  const beginSourceLoad = useCallback((message: string) => {
    setIsSourceLoading(true);
    setLoadingMessage(message);
    setIsBuffering(false);
    setPosition(0);
    setDuration(0);
    setVideoSize({ width: 0, height: 0 });
    setCurrentTrackIds({ vid: 0, aid: 0, sid: 0 });
    setTracks({ video: [], audio: [], sub: [] });
    setMediaInfo(null);
  }, []);

  const formatTime = (seconds: number): string => {
    if (!isFinite(seconds) || seconds < 0) return "00:00";
    const h = Math.floor(seconds / 3600);
    const m = Math.floor((seconds % 3600) / 60);
    const s = Math.floor(seconds % 60);
    if (h > 0)
      return `${h}:${m.toString().padStart(2, "0")}:${s.toString().padStart(2, "0")}`;
    return `${m.toString().padStart(2, "0")}:${s.toString().padStart(2, "0")}`;
  };

  const progressPercent = duration > 0 ? (position / duration) * 100 : 0;

  const cycleSpeed = () => {
    const speeds = [0.5, 1.0, 1.5, 2.0];
    const nextIndex = (speeds.indexOf(speed) + 1) % speeds.length;
    const newSpeed = speeds[nextIndex];
    setSpeed(newSpeed);
    playerRef.current?.setSpeed(newSpeed);
  };

  const toggleMute = () => {
    const newMuted = !muted;
    setMuted(newMuted);
    playerRef.current?.setMuted(newMuted);
  };

  const hwdecOptions =
    Platform.OS === "ios"
      ? ["videotoolbox", "videotoolbox-copy", "no"]
      : ["mediacodec", "mediacodec-copy", "no"];

  const cycleHwdec = () => {
    const nextIndex = (hwdecOptions.indexOf(hwdecMode) + 1) % hwdecOptions.length;
    const newMode = hwdecOptions[nextIndex];
    setHwdecMode(newMode);
    playerRef.current?.setPropertyString("hwdec", newMode);
    setTimeout(() => refreshMediaInfo(), 500);
  };

  const formatBitrate = (bps: number): string => {
    if (bps <= 0) return "N/A";
    if (bps >= 1_000_000) return `${(bps / 1_000_000).toFixed(1)} Mbps`;
    if (bps >= 1_000) return `${(bps / 1_000).toFixed(0)} Kbps`;
    return `${bps.toFixed(0)} bps`;
  };

  const selectVideo = (index: number) => {
    const video = TEST_VIDEOS[index];
    beginSourceLoad(`Switching to ${video.label}...`);
    setCurrentVideoIndex(index);
    setSource(video.url);
    setError(null);
    setInputUrl("");
  };

  const handleLoadUrl = () => {
    const url = inputUrl.trim();
    if (!url) return;
    beginSourceLoad("Loading custom URL...");
    setCurrentVideoIndex(-1);
    setSource(url);
    setError(null);
  };

  const selectTrack = (type: "audio" | "sub" | "video", id: number) => {
    if (type === "audio") {
      playerRef.current?.setAudioTrack(id);
    } else if (type === "sub") {
      playerRef.current?.setSubtitleTrack(id);
    }
    setTimeout(() => refreshTracks(), 300);
  };

  const toggleSubtitles = () => {
    if (currentTrackIds.sid > 0) {
      playerRef.current?.setSubtitleTrack(0);
    } else if (tracks.sub.length > 0) {
      playerRef.current?.setSubtitleTrack(tracks.sub[0].id);
    }
    setTimeout(() => refreshTracks(), 300);
  };

  const trackLabel = (t: TrackInfo) => {
    const parts: string[] = [];
    if (t.title) parts.push(t.title);
    if (t.lang) parts.push(`[${t.lang}]`);
    if (t.codec) parts.push(t.codec);
    if (t.type === "audio" && t.channelCount) {
      parts.push(`${t.channelCount}ch`);
      if (t.sampleRate) parts.push(`${t.sampleRate}Hz`);
    }
    if (t.type === "video" && t.width && t.height) {
      parts.push(`${t.width}x${t.height}`);
      if (t.fps) parts.push(`${t.fps.toFixed(1)}fps`);
    }
    if (t.isDefault) parts.push("(default)");
    if (t.isExternal) parts.push("(ext)");
    return parts.length > 0 ? parts.join(" ") : `Track ${t.id}`;
  };

  const hasAnyTracks =
    tracks.video.length > 0 ||
    tracks.audio.length > 0 ||
    tracks.sub.length > 0;

  return (
    <SafeAreaView style={styles.container}>
      <StatusBar barStyle="light-content" />
      <ScrollView style={styles.scrollContainer}>
        {/* Header */}
        <View style={styles.header}>
          <Text style={styles.title}>MPV Player</Text>
          <Text style={styles.subtitle}>Expo Module + libmpv</Text>
        </View>

        {/* Video Source Selector */}
        <View style={styles.videoSelector}>
          <Text style={styles.sectionTitle}>Test Videos</Text>
          <ScrollView horizontal showsHorizontalScrollIndicator={false} style={styles.videoList}>
            {TEST_VIDEOS.map((video, index) => (
              <TouchableOpacity
                key={index}
                style={[
                  styles.videoChip,
                  currentVideoIndex === index && styles.videoChipActive,
                ]}
                onPress={() => selectVideo(index)}
              >
                <Text
                  style={[
                    styles.videoChipText,
                    currentVideoIndex === index && styles.videoChipTextActive,
                  ]}
                >
                  {video.label}
                </Text>
                <View style={styles.tagRow}>
                  {video.tags.map((tag) => (
                    <View
                      key={tag}
                      style={[
                        styles.tag,
                        tag.includes("HDR") && styles.tagHDR,
                        tag.includes("DV") && styles.tagDV,
                        tag.includes("4K") && styles.tag4K,
                        tag.includes("HEVC") && styles.tagHEVC,
                        tag.includes("HLS") && styles.tagHLS,
                        tag.includes("DASH") && styles.tagDASH,
                        tag.includes("60") && styles.tag60,
                      ]}
                    >
                      <Text style={styles.tagText}>{tag}</Text>
                    </View>
                  ))}
                </View>
              </TouchableOpacity>
            ))}
          </ScrollView>
        </View>

        {/* Video Player */}
        <View style={styles.playerContainer}>
          <ExpoMpvView
            ref={playerRef}
            source={source}
            hwdec={hwdecMode}
            style={styles.player}
            onPlaybackStateChange={onPlaybackStateChange}
            onProgress={onProgress}
            onLoad={onLoad}
            onError={onError}
            onEnd={onEnd}
            onBuffer={onBuffer}
            onSeek={() => {}}
            onVolumeChange={() => {}}
          />
          {(isSourceLoading || isBuffering) && (
            <View style={styles.loadingOverlay}>
              <View style={styles.loadingCard}>
                <ActivityIndicator size="large" color="#fff" />
                <Text style={styles.loadingTitle}>
                  {isSourceLoading ? loadingMessage : "Buffering stream..."}
                </Text>
                <Text style={styles.loadingSubtitle}>
                  {isSourceLoading
                    ? "Waiting for metadata and first frame"
                    : "Fetching more media data"}
                </Text>
              </View>
            </View>
          )}
        </View>

        {/* Error display */}
        {error && (
          <View style={styles.errorContainer}>
            <Text style={styles.errorText}>{error}</Text>
          </View>
        )}

        {/* Now Playing */}
        {currentVideoIndex >= 0 && (
          <View style={styles.nowPlaying}>
            <Text style={styles.nowPlayingLabel}>Now Playing:</Text>
            <Text style={styles.nowPlayingTitle}>
              {TEST_VIDEOS[currentVideoIndex].label}
            </Text>
            <View style={styles.tagRow}>
              {TEST_VIDEOS[currentVideoIndex].tags.map((tag) => (
                <View
                  key={tag}
                  style={[
                    styles.tag,
                    tag.includes("HDR") && styles.tagHDR,
                    tag.includes("DV") && styles.tagDV,
                    tag.includes("4K") && styles.tag4K,
                  ]}
                >
                  <Text style={styles.tagText}>{tag}</Text>
                </View>
              ))}
            </View>
          </View>
        )}

        {/* Progress Bar */}
        <View style={styles.progressContainer}>
          <Text style={styles.timeText}>{formatTime(position)}</Text>
          <View style={styles.progressBarBg}>
            <View
              style={[
                styles.progressBarFill,
                { width: `${progressPercent}%` },
              ]}
            />
          </View>
          <Text style={styles.timeText}>{formatTime(duration)}</Text>
        </View>

        {/* Video Info */}
        {videoSize.width > 0 && (
          <Text style={styles.infoText}>
            {videoSize.width}x{videoSize.height}
          </Text>
        )}

        {/* Controls */}
        <View style={styles.controls}>
          <TouchableOpacity
            style={styles.controlBtn}
            onPress={() => playerRef.current?.seekBy(-10)}
          >
            <Text style={styles.controlText}>-10s</Text>
          </TouchableOpacity>

          <TouchableOpacity
            style={[styles.controlBtn, styles.playBtn]}
            onPress={() => playerRef.current?.togglePlay()}
          >
            <Text style={styles.playBtnText}>{isPlaying ? "||" : ">"}</Text>
          </TouchableOpacity>

          <TouchableOpacity
            style={styles.controlBtn}
            onPress={() => playerRef.current?.seekBy(10)}
          >
            <Text style={styles.controlText}>+10s</Text>
          </TouchableOpacity>
        </View>

        {/* Secondary Controls */}
        <View style={styles.secondaryControls}>
          <TouchableOpacity style={styles.secondaryBtn} onPress={cycleSpeed}>
            <Text style={styles.secondaryBtnText}>{speed}x</Text>
          </TouchableOpacity>

          <TouchableOpacity style={styles.secondaryBtn} onPress={toggleMute}>
            <Text style={styles.secondaryBtnText}>
              {muted ? "Unmute" : "Mute"}
            </Text>
          </TouchableOpacity>

          <TouchableOpacity
            style={styles.secondaryBtn}
            onPress={toggleSubtitles}
          >
            <Text style={styles.secondaryBtnText}>
              {currentTrackIds.sid > 0 ? "Sub OFF" : "Sub ON"}
            </Text>
          </TouchableOpacity>

          <TouchableOpacity
            style={styles.secondaryBtn}
            onPress={cycleHwdec}
          >
            <Text style={styles.secondaryBtnText}>
              HW: {hwdecMode === "no" ? "off" : hwdecMode}
            </Text>
          </TouchableOpacity>

          <TouchableOpacity
            style={styles.secondaryBtn}
            onPress={refreshTracks}
          >
            <Text style={styles.secondaryBtnText}>Refresh</Text>
          </TouchableOpacity>
        </View>

        {/* URL Input */}
        <View style={styles.urlContainer}>
          <TextInput
            style={styles.urlInput}
            value={inputUrl}
            onChangeText={setInputUrl}
            placeholder="Enter custom URL..."
            placeholderTextColor="#666"
            autoCapitalize="none"
            autoCorrect={false}
          />
          <TouchableOpacity style={styles.loadBtn} onPress={handleLoadUrl}>
            <Text style={styles.loadBtnText}>Load</Text>
          </TouchableOpacity>
        </View>

        {/* Media Info Panel */}
        {mediaInfo && (
          <View style={styles.mediaInfoPanel}>
            <Text style={styles.trackPanelTitle}>Media Info</Text>

            <View style={styles.mediaInfoGrid}>
              <View style={styles.mediaInfoRow}>
                <Text style={styles.mediaInfoLabel}>Hardware Decode</Text>
                <View style={styles.mediaInfoValueRow}>
                  <View
                    style={[
                      styles.hwdecDot,
                      { backgroundColor: mediaInfo.hwdecCurrent ? "#4ade80" : "#f87171" },
                    ]}
                  />
                  <Text style={styles.mediaInfoValue}>
                    {mediaInfo.hwdecCurrent || "Software"}
                  </Text>
                </View>
              </View>

              <View style={styles.mediaInfoRow}>
                <Text style={styles.mediaInfoLabel}>Video Codec</Text>
                <Text style={styles.mediaInfoValue}>
                  {mediaInfo.videoCodec || "N/A"}
                </Text>
              </View>

              <View style={styles.mediaInfoRow}>
                <Text style={styles.mediaInfoLabel}>Resolution</Text>
                <Text style={styles.mediaInfoValue}>
                  {mediaInfo.width > 0
                    ? `${mediaInfo.width}x${mediaInfo.height}`
                    : "N/A"}
                </Text>
              </View>

              <View style={styles.mediaInfoRow}>
                <Text style={styles.mediaInfoLabel}>Frame Rate</Text>
                <Text style={styles.mediaInfoValue}>
                  {mediaInfo.fps > 0 ? `${mediaInfo.fps.toFixed(2)} fps` : "N/A"}
                </Text>
              </View>

              <View style={styles.mediaInfoRow}>
                <Text style={styles.mediaInfoLabel}>Video Bitrate</Text>
                <Text style={styles.mediaInfoValue}>
                  {formatBitrate(mediaInfo.videoBitrate)}
                </Text>
              </View>

              <View style={styles.mediaInfoRow}>
                <Text style={styles.mediaInfoLabel}>Audio Codec</Text>
                <Text style={styles.mediaInfoValue}>
                  {mediaInfo.audioCodec || "N/A"}
                </Text>
              </View>

              <View style={styles.mediaInfoRow}>
                <Text style={styles.mediaInfoLabel}>Audio Bitrate</Text>
                <Text style={styles.mediaInfoValue}>
                  {formatBitrate(mediaInfo.audioBitrate)}
                </Text>
              </View>

              <View style={styles.mediaInfoRow}>
                <Text style={styles.mediaInfoLabel}>Pixel Format</Text>
                <Text style={styles.mediaInfoValue}>
                  {mediaInfo.pixelFormat || "N/A"}
                </Text>
              </View>

              <View style={styles.mediaInfoRow}>
                <Text style={styles.mediaInfoLabel}>Color Space</Text>
                <Text style={styles.mediaInfoValue}>
                  {mediaInfo.colorspace || "N/A"}
                </Text>
              </View>
            </View>
          </View>
        )}

        {/* Track Info Debug Panel */}
        {hasAnyTracks && (
          <View style={styles.trackPanel}>
            <Text style={styles.trackPanelTitle}>Track Information</Text>

            {/* Video Tracks */}
            {tracks.video.length > 0 && (
              <View style={styles.trackSection}>
                <Text style={styles.trackSectionTitle}>
                  Video Tracks ({tracks.video.length})
                </Text>
                {tracks.video.map((t) => (
                  <View
                    key={`v-${t.id}`}
                    style={[
                      styles.trackItem,
                      t.selected && styles.trackItemSelected,
                    ]}
                  >
                    <Text style={styles.trackId}>V{t.id}</Text>
                    <Text
                      style={[
                        styles.trackLabel,
                        t.selected && styles.trackLabelSelected,
                      ]}
                      numberOfLines={2}
                    >
                      {trackLabel(t)}
                    </Text>
                    {t.selected && <Text style={styles.trackBadge}>ACTIVE</Text>}
                  </View>
                ))}
              </View>
            )}

            {/* Audio Tracks */}
            {tracks.audio.length > 0 && (
              <View style={styles.trackSection}>
                <Text style={styles.trackSectionTitle}>
                  Audio Tracks ({tracks.audio.length})
                </Text>
                {tracks.audio.map((t) => (
                  <TouchableOpacity
                    key={`a-${t.id}`}
                    style={[
                      styles.trackItem,
                      t.selected && styles.trackItemSelected,
                    ]}
                    onPress={() => selectTrack("audio", t.id)}
                  >
                    <Text style={styles.trackId}>A{t.id}</Text>
                    <Text
                      style={[
                        styles.trackLabel,
                        t.selected && styles.trackLabelSelected,
                      ]}
                      numberOfLines={2}
                    >
                      {trackLabel(t)}
                    </Text>
                    {t.selected && <Text style={styles.trackBadge}>ACTIVE</Text>}
                  </TouchableOpacity>
                ))}
              </View>
            )}

            {/* Subtitle Tracks */}
            {tracks.sub.length > 0 && (
              <View style={styles.trackSection}>
                <Text style={styles.trackSectionTitle}>
                  Subtitle Tracks ({tracks.sub.length})
                </Text>
                {tracks.sub.map((t) => (
                  <TouchableOpacity
                    key={`s-${t.id}`}
                    style={[
                      styles.trackItem,
                      t.selected && styles.trackItemSelected,
                    ]}
                    onPress={() => selectTrack("sub", t.id)}
                  >
                    <Text style={styles.trackId}>S{t.id}</Text>
                    <Text
                      style={[
                        styles.trackLabel,
                        t.selected && styles.trackLabelSelected,
                      ]}
                      numberOfLines={2}
                    >
                      {trackLabel(t)}
                    </Text>
                    {t.selected && <Text style={styles.trackBadge}>ACTIVE</Text>}
                  </TouchableOpacity>
                ))}
              </View>
            )}

            {/* No subtitles message */}
            {tracks.sub.length === 0 && (
              <View style={styles.trackSection}>
                <Text style={styles.trackSectionTitle}>Subtitle Tracks</Text>
                <Text style={styles.noTracksText}>
                  No subtitle tracks found in this media
                </Text>
              </View>
            )}

            {/* Current Selection Summary */}
            <View style={styles.trackSection}>
              <Text style={styles.trackSectionTitle}>Current Selection</Text>
              <Text style={styles.selectionText}>
                VID: {currentTrackIds.vid || "none"} | AID:{" "}
                {currentTrackIds.aid || "none"} | SID:{" "}
                {currentTrackIds.sid || "none"}
              </Text>
            </View>
          </View>
        )}

        {/* Bottom padding */}
        <View style={{ height: 40 }} />
      </ScrollView>
    </SafeAreaView>
  );
}

export default function App() {
  return (
    <SafeAreaProvider>
      <AppInter />
    </SafeAreaProvider>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: "#111",
  },
  scrollContainer: {
    flex: 1,
  },
  header: {
    paddingHorizontal: 20,
    paddingTop: 10,
    paddingBottom: 8,
  },
  title: {
    color: "#fff",
    fontSize: 24,
    fontWeight: "700",
  },
  subtitle: {
    color: "#888",
    fontSize: 13,
    marginTop: 2,
  },
  // Video selector
  videoSelector: {
    paddingHorizontal: 20,
    paddingBottom: 12,
  },
  sectionTitle: {
    color: "#999",
    fontSize: 12,
    fontWeight: "600",
    textTransform: "uppercase",
    letterSpacing: 0.5,
    marginBottom: 8,
  },
  videoList: {
    flexGrow: 0,
  },
  videoChip: {
    backgroundColor: "#1e1e2e",
    borderRadius: 12,
    paddingHorizontal: 14,
    paddingVertical: 10,
    marginRight: 8,
    minWidth: 120,
    maxWidth: 160,
    borderWidth: 1,
    borderColor: "#333",
  },
  videoChipActive: {
    backgroundColor: "#1a2a4e",
    borderColor: "#4a9eff",
  },
  videoChipText: {
    color: "#ccc",
    fontSize: 12,
    fontWeight: "600",
    marginBottom: 6,
  },
  videoChipTextActive: {
    color: "#fff",
  },
  tagRow: {
    flexDirection: "row",
    flexWrap: "wrap",
    gap: 3,
  },
  tag: {
    backgroundColor: "#333",
    borderRadius: 4,
    paddingHorizontal: 5,
    paddingVertical: 2,
  },
  tagText: {
    color: "#aaa",
    fontSize: 9,
    fontWeight: "600",
  },
  tagHDR: {
    backgroundColor: "#3d2e00",
  },
  tagDV: {
    backgroundColor: "#2e1a3d",
  },
  tag4K: {
    backgroundColor: "#002e1a",
  },
  tagHEVC: {
    backgroundColor: "#2e002e",
  },
  tagHLS: {
    backgroundColor: "#002e3d",
  },
  tagDASH: {
    backgroundColor: "#3d2e00",
  },
  tag60: {
    backgroundColor: "#3d0000",
  },
  // Now playing
  nowPlaying: {
    paddingHorizontal: 20,
    paddingVertical: 8,
    backgroundColor: "#0d0d1a",
    borderBottomWidth: 1,
    borderBottomColor: "#222",
  },
  nowPlayingLabel: {
    color: "#666",
    fontSize: 10,
    textTransform: "uppercase",
    letterSpacing: 0.5,
  },
  nowPlayingTitle: {
    color: "#fff",
    fontSize: 14,
    fontWeight: "600",
    marginTop: 2,
    marginBottom: 4,
  },
  // Player
  playerContainer: {
    width: "100%",
    aspectRatio: 16 / 9,
    backgroundColor: "#000",
    position: "relative",
  },
  player: {
    flex: 1,
  },
  loadingOverlay: {
    ...StyleSheet.absoluteFill,
    justifyContent: "center",
    alignItems: "center",
    backgroundColor: "rgba(0,0,0,0.48)",
    paddingHorizontal: 24,
  },
  loadingCard: {
    minWidth: 220,
    maxWidth: 280,
    paddingHorizontal: 20,
    paddingVertical: 18,
    borderRadius: 16,
    backgroundColor: "rgba(17,24,39,0.88)",
    borderWidth: 1,
    borderColor: "rgba(255,255,255,0.12)",
    alignItems: "center",
  },
  loadingTitle: {
    color: "#fff",
    fontSize: 15,
    fontWeight: "700",
    marginTop: 12,
    textAlign: "center",
  },
  loadingSubtitle: {
    color: "#b6bfd4",
    fontSize: 12,
    marginTop: 6,
    textAlign: "center",
  },
  errorContainer: {
    marginHorizontal: 20,
    marginTop: 8,
    padding: 10,
    backgroundColor: "#3a1a1a",
    borderRadius: 8,
  },
  errorText: {
    color: "#ff6b6b",
    fontSize: 13,
  },
  progressContainer: {
    flexDirection: "row",
    alignItems: "center",
    paddingHorizontal: 20,
    marginTop: 16,
    gap: 10,
  },
  timeText: {
    color: "#aaa",
    fontSize: 12,
    fontVariant: ["tabular-nums"],
    width: 55,
    textAlign: "center",
  },
  progressBarBg: {
    flex: 1,
    height: 4,
    backgroundColor: "#333",
    borderRadius: 2,
    overflow: "hidden",
  },
  progressBarFill: {
    height: "100%",
    backgroundColor: "#4a9eff",
    borderRadius: 2,
  },
  infoText: {
    color: "#666",
    fontSize: 11,
    textAlign: "center",
    marginTop: 6,
  },
  controls: {
    flexDirection: "row",
    justifyContent: "center",
    alignItems: "center",
    marginTop: 20,
    gap: 20,
  },
  controlBtn: {
    width: 56,
    height: 56,
    borderRadius: 28,
    backgroundColor: "#222",
    justifyContent: "center",
    alignItems: "center",
  },
  controlText: {
    color: "#fff",
    fontSize: 14,
    fontWeight: "600",
  },
  playBtn: {
    width: 70,
    height: 70,
    borderRadius: 35,
    backgroundColor: "#4a9eff",
  },
  playBtnText: {
    color: "#fff",
    fontSize: 24,
    fontWeight: "700",
  },
  secondaryControls: {
    flexDirection: "row",
    justifyContent: "center",
    flexWrap: "wrap",
    marginTop: 16,
    gap: 10,
  },
  secondaryBtn: {
    paddingHorizontal: 14,
    paddingVertical: 8,
    backgroundColor: "#222",
    borderRadius: 20,
  },
  secondaryBtnText: {
    color: "#ccc",
    fontSize: 13,
    fontWeight: "500",
  },
  urlContainer: {
    flexDirection: "row",
    marginHorizontal: 20,
    marginTop: 16,
    gap: 10,
  },
  urlInput: {
    flex: 1,
    height: 42,
    backgroundColor: "#222",
    borderRadius: 8,
    paddingHorizontal: 12,
    color: "#fff",
    fontSize: 13,
  },
  loadBtn: {
    height: 42,
    paddingHorizontal: 20,
    backgroundColor: "#4a9eff",
    borderRadius: 8,
    justifyContent: "center",
    alignItems: "center",
  },
  loadBtnText: {
    color: "#fff",
    fontSize: 14,
    fontWeight: "600",
  },
  // Track info panel styles
  trackPanel: {
    marginHorizontal: 20,
    marginTop: 20,
    backgroundColor: "#1a1a2e",
    borderRadius: 12,
    padding: 16,
  },
  // Media info panel styles
  mediaInfoPanel: {
    marginHorizontal: 20,
    marginTop: 20,
    backgroundColor: "#1a1a2e",
    borderRadius: 12,
    padding: 16,
  },
  mediaInfoGrid: {
    gap: 8,
  },
  mediaInfoRow: {
    flexDirection: "row",
    justifyContent: "space-between",
    alignItems: "center",
    paddingVertical: 4,
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: "#333",
  },
  mediaInfoLabel: {
    color: "#888",
    fontSize: 12,
    fontWeight: "500",
  },
  mediaInfoValueRow: {
    flexDirection: "row",
    alignItems: "center",
    gap: 6,
  },
  mediaInfoValue: {
    color: "#ddd",
    fontSize: 12,
    fontWeight: "600",
    fontVariant: ["tabular-nums"],
  },
  hwdecDot: {
    width: 8,
    height: 8,
    borderRadius: 4,
  },
  trackPanelTitle: {
    color: "#fff",
    fontSize: 16,
    fontWeight: "700",
    marginBottom: 12,
  },
  trackSection: {
    marginBottom: 14,
  },
  trackSectionTitle: {
    color: "#8888cc",
    fontSize: 13,
    fontWeight: "600",
    marginBottom: 6,
    textTransform: "uppercase",
    letterSpacing: 0.5,
  },
  trackItem: {
    flexDirection: "row",
    alignItems: "center",
    backgroundColor: "#222244",
    borderRadius: 8,
    paddingHorizontal: 12,
    paddingVertical: 10,
    marginBottom: 4,
    gap: 8,
  },
  trackItemSelected: {
    backgroundColor: "#2a3a5e",
    borderWidth: 1,
    borderColor: "#4a9eff",
  },
  trackId: {
    color: "#666",
    fontSize: 11,
    fontWeight: "700",
    fontVariant: ["tabular-nums"],
    width: 28,
  },
  trackLabel: {
    flex: 1,
    color: "#aaa",
    fontSize: 12,
  },
  trackLabelSelected: {
    color: "#fff",
  },
  trackBadge: {
    color: "#4a9eff",
    fontSize: 10,
    fontWeight: "700",
    backgroundColor: "#1a2a4e",
    paddingHorizontal: 6,
    paddingVertical: 2,
    borderRadius: 4,
    overflow: "hidden",
  },
  noTracksText: {
    color: "#666",
    fontSize: 12,
    fontStyle: "italic",
    paddingVertical: 8,
  },
  selectionText: {
    color: "#aaa",
    fontSize: 12,
    fontVariant: ["tabular-nums"],
    paddingVertical: 4,
  },
});
