import { requireNativeView } from 'expo';
import * as React from 'react';
import { useImperativeHandle, useRef } from 'react';

import { ExpoMpvViewProps, ExpoMpvViewRef } from './ExpoMpv.types';

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
      play: () => nativeRef.current?.play(),
      pause: () => nativeRef.current?.pause(),
      togglePlay: () => nativeRef.current?.togglePlay(),
      stop: () => nativeRef.current?.stop(),
      seekTo: (position: number) => nativeRef.current?.seekTo(position),
      seekBy: (offset: number) => nativeRef.current?.seekBy(offset),
      setSpeed: (speed: number) => nativeRef.current?.setSpeed(speed),
      setVolume: (volume: number) => nativeRef.current?.setVolume(volume),
      setMuted: (muted: boolean) => nativeRef.current?.setMuted(muted),
      setSubtitleTrack: (trackId: number) => nativeRef.current?.setSubtitleTrack(trackId),
      setAudioTrack: (trackId: number) => nativeRef.current?.setAudioTrack(trackId),
      addSubtitle: (path: string, flag?: string, title?: string, lang?: string) =>
        nativeRef.current?.addSubtitle(path, flag, title, lang),
      removeSubtitle: (trackId: number) => nativeRef.current?.removeSubtitle(trackId),
      reloadSubtitles: () => nativeRef.current?.reloadSubtitles(),
      setSubtitleDelay: (seconds: number) => nativeRef.current?.setSubtitleDelay(seconds),
      setPropertyString: (name: string, value: string) =>
        nativeRef.current?.setPropertyString(name, value),
      getPlaybackInfo: () => nativeRef.current?.getPlaybackInfo(),
      getTrackList: () => nativeRef.current?.getTrackList(),
      getCurrentTrackIds: () => nativeRef.current?.getCurrentTrackIds(),
      getMediaInfo: () => nativeRef.current?.getMediaInfo(),
    }),
    [ref]
  );

  return <NativeView ref={nativeRef} {...restProps} />;
}

ExpoMpvView.displayName = 'ExpoMpvView';

export default ExpoMpvView;
