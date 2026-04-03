import ExpoModulesCore

public class ExpoMpvModule: Module {
  public func definition() -> ModuleDefinition {
    Name("ExpoMpv")

    // MARK: - View

    View(ExpoMpvView.self) {
      // Events emitted by the native view
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

      // MARK: - Props

      Prop("source") { (view: ExpoMpvView, source: String?) in
        if let source = source {
          view.loadFile(source)
        }
      }

      Prop("paused") { (view: ExpoMpvView, paused: Bool) in
        if paused {
          view.pause()
        } else {
          view.play()
        }
      }

      Prop("speed") { (view: ExpoMpvView, speed: Double) in
        view.setSpeed(speed)
      }

      Prop("volume") { (view: ExpoMpvView, volume: Double) in
        view.setVolume(volume)
      }

      Prop("muted") { (view: ExpoMpvView, muted: Bool) in
        view.setMuted(muted)
      }

      Prop("loop") { (view: ExpoMpvView, loop: Bool) in
        view.setLooping(loop)
      }

      // MARK: - Imperative Functions (called via ref)

      AsyncFunction("play") { (view: ExpoMpvView) in
        view.play()
      }.runOnQueue(.main)

      AsyncFunction("pause") { (view: ExpoMpvView) in
        view.pause()
      }.runOnQueue(.main)

      AsyncFunction("togglePlay") { (view: ExpoMpvView) in
        view.togglePlay()
      }.runOnQueue(.main)

      AsyncFunction("stop") { (view: ExpoMpvView) in
        view.stop()
      }.runOnQueue(.main)

      AsyncFunction("seekTo") { (view: ExpoMpvView, position: Double) in
        view.seekTo(position)
      }.runOnQueue(.main)

      AsyncFunction("seekBy") { (view: ExpoMpvView, offset: Double) in
        view.seekBy(offset)
      }.runOnQueue(.main)

      AsyncFunction("setSpeed") { (view: ExpoMpvView, speed: Double) in
        view.setSpeed(speed)
      }.runOnQueue(.main)

      AsyncFunction("setVolume") { (view: ExpoMpvView, volume: Double) in
        view.setVolume(volume)
      }.runOnQueue(.main)

      AsyncFunction("setMuted") { (view: ExpoMpvView, muted: Bool) in
        view.setMuted(muted)
      }.runOnQueue(.main)

      AsyncFunction("setSubtitleTrack") { (view: ExpoMpvView, trackId: Int) in
        view.setSubtitleTrack(trackId)
      }.runOnQueue(.main)

      AsyncFunction("setAudioTrack") { (view: ExpoMpvView, trackId: Int) in
        view.setAudioTrack(trackId)
      }.runOnQueue(.main)

      AsyncFunction("getPlaybackInfo") { (view: ExpoMpvView) -> [String: Any] in
        return view.getPlaybackInfo()
      }.runOnQueue(.main)
    }
  }
}
