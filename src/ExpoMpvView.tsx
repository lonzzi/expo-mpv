import { requireNativeView } from 'expo';
import * as React from 'react';
import { forwardRef, useImperativeHandle, useRef } from 'react';

import { ExpoMpvViewProps, ExpoMpvViewRef } from './ExpoMpv.types';

const NativeView: React.ComponentType<ExpoMpvViewProps & { ref?: React.Ref<any> }> =
  requireNativeView('ExpoMpv');

const ExpoMpvView = forwardRef<ExpoMpvViewRef, ExpoMpvViewProps>((props, ref) => {
  const nativeRef = useRef<any>(null);

  useImperativeHandle(ref, () => ({
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
    getPlaybackInfo: () => nativeRef.current?.getPlaybackInfo(),
  }));

  return <NativeView ref={nativeRef} {...props} />;
});

ExpoMpvView.displayName = 'ExpoMpvView';

export default ExpoMpvView;
