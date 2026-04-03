import { ExpoMpvView } from "expo-mpv";
import type {
  ExpoMpvViewRef,
  ProgressEvent,
  LoadEvent,
  PlaybackStateChangeEvent,
  ErrorEvent,
  EndEvent,
  BufferEvent,
} from "expo-mpv";
import { useCallback, useRef, useState } from "react";
import {
  ActivityIndicator,
  StatusBar,
  StyleSheet,
  Text,
  TextInput,
  TouchableOpacity,
  View,
} from "react-native";
import { SafeAreaView } from "react-native-safe-area-context";

// test stream
const DEFAULT_VIDEO =
  "https://download.blender.org/peach/bigbuckbunny_movies/big_buck_bunny_720p_h264.mov";

export default function App() {
  const playerRef = useRef<ExpoMpvViewRef>(null);

  const [isPlaying, setIsPlaying] = useState(false);
  const [isBuffering, setIsBuffering] = useState(false);
  const [position, setPosition] = useState(0);
  const [duration, setDuration] = useState(0);
  const [videoSize, setVideoSize] = useState({ width: 0, height: 0 });
  const [speed, setSpeed] = useState(1.0);
  const [volume, setVolume] = useState(100);
  const [muted, setMuted] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [source, setSource] = useState(DEFAULT_VIDEO);
  const [inputUrl, setInputUrl] = useState(DEFAULT_VIDEO);

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

  const onLoad = useCallback(({ nativeEvent }: { nativeEvent: LoadEvent }) => {
    setDuration(nativeEvent.duration);
    setVideoSize({ width: nativeEvent.width, height: nativeEvent.height });
    setError(null);
  }, []);

  const onError = useCallback(
    ({ nativeEvent }: { nativeEvent: ErrorEvent }) => {
      setError(nativeEvent.error);
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

  const formatTime = (seconds: number): string => {
    if (!isFinite(seconds) || seconds < 0) return "00:00";
    const m = Math.floor(seconds / 60);
    const s = Math.floor(seconds % 60);
    return `${m.toString().padStart(2, "0")}:${s.toString().padStart(2, "0")}`;
  };

  const progressPercent = duration > 0 ? (position / duration) * 100 : 0;

  const handleSeek = (direction: "forward" | "backward") => {
    playerRef.current?.seekBy(direction === "forward" ? 10 : -10);
  };

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

  const handleLoadUrl = () => {
    setSource(inputUrl);
    setError(null);
  };

  return (
    <SafeAreaView style={styles.container} edges={["top"]} >
      <StatusBar barStyle="light-content" />

      {/* Header */}
      <View style={styles.header}>
        <Text style={styles.title}>MPV Player</Text>
        <Text style={styles.subtitle}>Expo Module + libmpv</Text>
      </View>

      {/* Video Player */}
      <View style={styles.playerContainer}>
        <ExpoMpvView
          ref={playerRef}
          source={source}
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

        {/* Buffering indicator */}
        {isBuffering && (
          <View style={styles.bufferingOverlay}>
            <ActivityIndicator size="large" color="#fff" />
          </View>
        )}
      </View>

      {/* Error display */}
      {error && (
        <View style={styles.errorContainer}>
          <Text style={styles.errorText}>{error}</Text>
        </View>
      )}

      {/* Progress Bar */}
      <View style={styles.progressContainer}>
        <Text style={styles.timeText}>{formatTime(position)}</Text>
        <View style={styles.progressBarBg}>
          <View
            style={[styles.progressBarFill, { width: `${progressPercent}%` }]}
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
          onPress={() => handleSeek("backward")}
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
          onPress={() => handleSeek("forward")}
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
          onPress={() => playerRef.current?.stop()}
        >
          <Text style={styles.secondaryBtnText}>Stop</Text>
        </TouchableOpacity>
      </View>

      {/* URL Input */}
      <View style={styles.urlContainer}>
        <TextInput
          style={styles.urlInput}
          value={inputUrl}
          onChangeText={setInputUrl}
          placeholder="Enter video URL..."
          placeholderTextColor="#666"
          autoCapitalize="none"
          autoCorrect={false}
        />
        <TouchableOpacity style={styles.loadBtn} onPress={handleLoadUrl}>
          <Text style={styles.loadBtnText}>Load</Text>
        </TouchableOpacity>
      </View>
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: "#111",
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
  playerContainer: {
    width: "100%",
    aspectRatio: 16 / 9,
    backgroundColor: "#000",
    position: "relative",
  },
  player: {
    flex: 1,
  },
  bufferingOverlay: {
    ...StyleSheet.absoluteFillObject,
    justifyContent: "center",
    alignItems: "center",
    backgroundColor: "rgba(0,0,0,0.4)",
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
    width: 45,
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
    marginTop: 16,
    gap: 12,
  },
  secondaryBtn: {
    paddingHorizontal: 16,
    paddingVertical: 10,
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
    marginTop: 20,
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
});
