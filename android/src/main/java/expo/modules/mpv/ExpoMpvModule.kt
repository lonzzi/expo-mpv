package expo.modules.mpv

import expo.modules.kotlin.modules.Module
import expo.modules.kotlin.modules.ModuleDefinition

class ExpoMpvModule : Module() {
    override fun definition() = ModuleDefinition {
        Name("ExpoMpv")

        View(ExpoMpvView::class) {
            // Events (same as iOS)
            Events(
                "onPlaybackStateChange",
                "onProgress",
                "onLoad",
                "onError",
                "onEnd",
                "onBuffer",
                "onSeek",
                "onVolumeChange"
            )

            // Props (same as iOS)
            Prop("source") { view: ExpoMpvView, source: String? ->
                if (source != null) {
                    view.loadFile(source)
                }
            }

            Prop("paused") { view: ExpoMpvView, paused: Boolean ->
                if (paused) view.pause() else view.play()
            }

            Prop("speed") { view: ExpoMpvView, speed: Double ->
                view.setSpeed(speed)
            }

            Prop("volume") { view: ExpoMpvView, volume: Double ->
                view.setVolume(volume)
            }

            Prop("muted") { view: ExpoMpvView, muted: Boolean ->
                view.setMuted(muted)
            }

            Prop("loop") { view: ExpoMpvView, loop: Boolean ->
                view.setLooping(loop)
            }

            Prop("hwdec") { view: ExpoMpvView, hwdec: String? ->
                if (hwdec != null) {
                    view.setHwdec(hwdec)
                }
            }

            // Async functions (same as iOS)
            AsyncFunction("play") { view: ExpoMpvView ->
                view.play()
            }

            AsyncFunction("pause") { view: ExpoMpvView ->
                view.pause()
            }

            AsyncFunction("togglePlay") { view: ExpoMpvView ->
                view.togglePlay()
            }

            AsyncFunction("stop") { view: ExpoMpvView ->
                view.stop()
            }

            AsyncFunction("seekTo") { view: ExpoMpvView, position: Double ->
                view.seekTo(position)
            }

            AsyncFunction("seekBy") { view: ExpoMpvView, offset: Double ->
                view.seekBy(offset)
            }

            AsyncFunction("setSpeed") { view: ExpoMpvView, speed: Double ->
                view.setSpeed(speed)
            }

            AsyncFunction("setVolume") { view: ExpoMpvView, volume: Double ->
                view.setVolume(volume)
            }

            AsyncFunction("setMuted") { view: ExpoMpvView, muted: Boolean ->
                view.setMuted(muted)
            }

            AsyncFunction("setSubtitleTrack") { view: ExpoMpvView, trackId: Int ->
                view.setSubtitleTrack(trackId)
            }

            AsyncFunction("setAudioTrack") { view: ExpoMpvView, trackId: Int ->
                view.setAudioTrack(trackId)
            }

            AsyncFunction("addSubtitle") { view: ExpoMpvView, path: String, flag: String?, title: String?, lang: String? ->
                view.addSubtitle(path, flag ?: "auto", title, lang)
            }

            AsyncFunction("removeSubtitle") { view: ExpoMpvView, trackId: Int ->
                view.removeSubtitle(trackId)
            }

            AsyncFunction("reloadSubtitles") { view: ExpoMpvView ->
                view.reloadSubtitles()
            }

            AsyncFunction("setSubtitleDelay") { view: ExpoMpvView, seconds: Double ->
                view.setSubtitleDelay(seconds)
            }

            AsyncFunction("setPropertyString") { view: ExpoMpvView, name: String, value: String ->
                view.setPropertyString(name, value)
            }

            AsyncFunction("getPlaybackInfo") { view: ExpoMpvView ->
                view.getPlaybackInfo()
            }

            AsyncFunction("getTrackList") { view: ExpoMpvView ->
                view.getTrackList()
            }

            AsyncFunction("getCurrentTrackIds") { view: ExpoMpvView ->
                view.getCurrentTrackIds()
            }

            AsyncFunction("getMediaInfo") { view: ExpoMpvView ->
                view.getMediaInfo()
            }
        }
    }
}
