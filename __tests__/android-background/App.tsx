import { registerRootComponent } from 'expo';
import { ExpoMpvView, type ExpoMpvViewRef } from 'expo-mpv';
import * as ScreenOrientation from 'expo-screen-orientation';
import * as SplashScreen from 'expo-splash-screen';
import { useEffect, useRef, useState } from 'react';
import { AppState, StyleSheet, Text, View } from 'react-native';

const config: { endpoint: string; source: string; hwdec: string } = JSON.parse('__CONFIG_JSON__');

function report(event: string, data: unknown) {
  void fetch(`${config.endpoint}/event`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ event, data, time: Date.now() }),
  }).catch(() => {});
}

function App() {
  const player = useRef<ExpoMpvViewRef>(null);
  const lastOrientation = useRef('');
  const [paused, setPaused] = useState(false);
  const [position, setPosition] = useState(0);

  useEffect(() => {
    void SplashScreen.hideAsync();
    const subscription = AppState.addEventListener('change', (state) => report('appState', state));
    let stopped = false;
    let busy = false;
    const poll = async () => {
      if (busy || stopped) return;
      busy = true;
      try {
        const command = await fetch(`${config.endpoint}/control`).then((response) =>
          response.json(),
        );
        if (stopped) return;
        setPaused(command.paused);
        if (command.orientation && command.orientation !== lastOrientation.current) {
          lastOrientation.current = command.orientation;
          await ScreenOrientation.lockAsync(
            command.orientation === 'landscape'
              ? ScreenOrientation.OrientationLock.LANDSCAPE_RIGHT
              : ScreenOrientation.OrientationLock.PORTRAIT_UP,
          );
        }
        const [playback, tracks, media] = await Promise.all([
          player.current?.getPlaybackInfo(),
          player.current?.getCurrentTrackIds(),
          player.current?.getMediaInfo(),
        ]);
        report('telemetry', { playback, tracks, media, appState: AppState.currentState });
      } catch {
        // The app can be suspended while a local request is in flight.
      } finally {
        busy = false;
      }
    };
    const timer = setInterval(() => void poll(), 500);
    void poll();
    return () => {
      stopped = true;
      subscription.remove();
      clearInterval(timer);
    };
  }, []);

  return (
    <View
      style={styles.root}
      onLayout={({ nativeEvent }) => {
        void SplashScreen.hideAsync();
        report('layout', nativeEvent.layout);
      }}
    >
      <ExpoMpvView
        ref={player}
        source={config.source}
        startPosition={4}
        paused={paused}
        loop
        hwdec={config.hwdec}
        style={StyleSheet.absoluteFill}
        onLoad={({ nativeEvent }) => report('load', nativeEvent)}
        onProgress={({ nativeEvent }) => setPosition(nativeEvent.position)}
        onPlaybackStateChange={({ nativeEvent }) => report('state', nativeEvent)}
        onError={({ nativeEvent }) => report('error', nativeEvent)}
      />
      <Text style={styles.status}>
        Background regression · {paused ? 'paused' : 'playing'} · {position.toFixed(2)}
      </Text>
    </View>
  );
}

const styles = StyleSheet.create({
  root: { flex: 1, backgroundColor: '#000' },
  status: { color: '#fff', fontSize: 16, position: 'absolute', top: 50, left: 20 },
});

registerRootComponent(App);
