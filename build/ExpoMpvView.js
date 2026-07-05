import { jsx as _jsx } from "react/jsx-runtime";
import { requireNativeView } from 'expo';
import * as React from 'react';
import { useImperativeHandle, useRef } from 'react';
const NativeView = requireNativeView('ExpoMpv', 'ExpoMpvView');
function ExpoMpvView(props) {
    const { ref, ...restProps } = props;
    const nativeRef = useRef(null);
    useImperativeHandle(ref, () => ({
        play: () => nativeRef.current?.play(),
        pause: () => nativeRef.current?.pause(),
        togglePlay: () => nativeRef.current?.togglePlay(),
        stop: () => nativeRef.current?.stop(),
        seekTo: (position) => nativeRef.current?.seekTo(position),
        seekBy: (offset) => nativeRef.current?.seekBy(offset),
        setSpeed: (speed) => nativeRef.current?.setSpeed(speed),
        setVolume: (volume) => nativeRef.current?.setVolume(volume),
        setMuted: (muted) => nativeRef.current?.setMuted(muted),
        setSubtitleTrack: (trackId) => nativeRef.current?.setSubtitleTrack(trackId),
        setAudioTrack: (trackId) => nativeRef.current?.setAudioTrack(trackId),
        addSubtitle: (path, flag, title, lang) => nativeRef.current?.addSubtitle(path, flag, title, lang),
        removeSubtitle: (trackId) => nativeRef.current?.removeSubtitle(trackId),
        reloadSubtitles: () => nativeRef.current?.reloadSubtitles(),
        setSubtitleDelay: (seconds) => nativeRef.current?.setSubtitleDelay(seconds),
        setPropertyString: (name, value) => nativeRef.current?.setPropertyString(name, value),
        getPlaybackInfo: () => nativeRef.current?.getPlaybackInfo(),
        getTrackList: () => nativeRef.current?.getTrackList(),
        getCurrentTrackIds: () => nativeRef.current?.getCurrentTrackIds(),
        getMediaInfo: () => nativeRef.current?.getMediaInfo(),
    }), [ref]);
    return _jsx(NativeView, { ref: nativeRef, ...restProps });
}
ExpoMpvView.displayName = 'ExpoMpvView';
export default ExpoMpvView;
//# sourceMappingURL=ExpoMpvView.js.map