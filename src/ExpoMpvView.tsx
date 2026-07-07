import { requireNativeView } from 'expo';
import * as React from 'react';
import { useImperativeHandle, useRef } from 'react';

import type { ExpoMpvViewProps, ExpoMpvViewRef } from './ExpoMpv.types';

const NativeView: React.ComponentType<ExpoMpvViewProps & { ref?: React.Ref<any> }> =
  requireNativeView('ExpoMpv', 'ExpoMpvView');

type ExpoMpvViewComponentProps = ExpoMpvViewProps & {
  ref?: React.Ref<ExpoMpvViewRef>;
};

function ExpoMpvView(props: ExpoMpvViewComponentProps) {
  const { ref, ...restProps } = props;
  const nativeRef = useRef<any>(null);

  useImperativeHandle(
    ref,
    (): ExpoMpvViewRef => ({
      // Every method resolves to a Promise even when the native view isn't
      // mounted yet. Without the `?? Promise.resolve()` fallbacks, optional
      // chaining returns `undefined` and callers doing `.then()` / `await`
      // crash with "cannot read 'then' of undefined".
      play: () => nativeRef.current?.play() ?? Promise.resolve(),
      pause: () => nativeRef.current?.pause() ?? Promise.resolve(),
      togglePlay: () => nativeRef.current?.togglePlay() ?? Promise.resolve(),
      stop: () => nativeRef.current?.stop() ?? Promise.resolve(),
      seekTo: (position: number) => {
        // Guard against NaN/undefined reaching the native Double parameter,
        // which otherwise throws a native type error.
        if (!Number.isFinite(position)) return Promise.resolve();
        return nativeRef.current?.seekTo(position) ?? Promise.resolve();
      },
      seekBy: (offset: number) => {
        if (!Number.isFinite(offset)) return Promise.resolve();
        return nativeRef.current?.seekBy(offset) ?? Promise.resolve();
      },
      setSpeed: (speed: number) => nativeRef.current?.setSpeed(speed) ?? Promise.resolve(),
      setVolume: (volume: number) => nativeRef.current?.setVolume(volume) ?? Promise.resolve(),
      setMuted: (muted: boolean) => nativeRef.current?.setMuted(muted) ?? Promise.resolve(),
      setSubtitleTrack: (trackId: number) =>
        nativeRef.current?.setSubtitleTrack(trackId) ?? Promise.resolve(),
      setAudioTrack: (trackId: number) =>
        nativeRef.current?.setAudioTrack(trackId) ?? Promise.resolve(),
      addSubtitle: (path: string, flag?: string, title?: string, lang?: string) =>
        nativeRef.current?.addSubtitle(path, flag, title, lang) ?? Promise.resolve(),
      removeSubtitle: (trackId: number) =>
        nativeRef.current?.removeSubtitle(trackId) ?? Promise.resolve(),
      addAudio: (path: string, flag?: string, title?: string, lang?: string) =>
        nativeRef.current?.addAudio(path, flag, title, lang) ?? Promise.resolve(),
      removeAudio: (trackId: number) =>
        nativeRef.current?.removeAudio(trackId) ?? Promise.resolve(),
      reloadSubtitles: () => nativeRef.current?.reloadSubtitles() ?? Promise.resolve(),
      setSubtitleDelay: (seconds: number) =>
        nativeRef.current?.setSubtitleDelay(seconds) ?? Promise.resolve(),
      setPropertyString: (name: string, value: string) =>
        nativeRef.current?.setPropertyString(name, value) ?? Promise.resolve(),
      getPlaybackInfo: () =>
        nativeRef.current?.getPlaybackInfo() ??
        Promise.resolve({
          position: 0,
          duration: 0,
          isPlaying: false,
          speed: 1,
          volume: 100,
          muted: false,
        }),
      getTrackList: () => nativeRef.current?.getTrackList() ?? Promise.resolve([]),
      getCurrentTrackIds: () =>
        nativeRef.current?.getCurrentTrackIds() ?? Promise.resolve({ vid: 0, aid: 0, sid: 0 }),
      getMediaInfo: () =>
        nativeRef.current?.getMediaInfo() ??
        Promise.resolve({
          hwdec: '',
          hwdecCurrent: '',
          videoCodec: '',
          audioCodec: '',
          width: 0,
          height: 0,
          fps: 0,
          videoBitrate: 0,
          audioBitrate: 0,
          pixelFormat: '',
          colorspace: '',
        }),
    }),
    [ref]
  );

  return <NativeView ref={nativeRef} {...restProps} />;
}

ExpoMpvView.displayName = 'ExpoMpvView';

export default ExpoMpvView;
