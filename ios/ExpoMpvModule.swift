import ExpoModulesCore

public class ExpoMpvModule: Module {
  public func definition() -> ModuleDefinition {
    Name("ExpoMpv")

    AsyncFunction("fontFamilies") { (input: URL) in
      guard input.isFileURL else {
        throw NSError(domain: "ExpoMpvFonts", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "Font paths must be local files"])
      }
      return try ExpoMpvFontDecoder.fontFamilies(input.path)
    }.runOnQueue(.global(qos: .utility))

    AsyncFunction("decodeWoff2") { (input: URL, output: URL) in
      guard input.isFileURL, output.isFileURL else {
        throw NSError(domain: "ExpoMpvFonts", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "Font paths must be local files"])
      }
      try ExpoMpvFontDecoder.decodeInput(input.path, output: output.path)
    }.runOnQueue(.global(qos: .utility))

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
        "onVolumeChange",
        "onHdrStateChange"
      )

      // MARK: - Props

      Prop("source") { (view: ExpoMpvView, source: String?) in
        view.sourceToLoad = source
      }

      Prop("startPosition") { (view: ExpoMpvView, position: Double?) in
        view.startPosition = position ?? 0
      }

      Prop("showNotificationControls") { (view: ExpoMpvView, enabled: Bool) in
        view.showNotificationControls = enabled
      }

      Prop("metadata") { (view: ExpoMpvView, metadata: [String: String]?) in
        view.metadata = metadata ?? [:]
      }

      OnViewDidUpdateProps { (view: ExpoMpvView) in
        view.loadSourceIfNeeded()
        view.updateMediaSession()
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

      Prop("hwdec") { (view: ExpoMpvView, hwdec: String?) in
        if let hwdec = hwdec {
          view.setHwdec(hwdec)
        }
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

      AsyncFunction("setSubtitleTrack") { (view: ExpoMpvView, trackId: Int, promise: Promise) in
        view.setSubtitleTrackAsync(trackId) { promise.resolve() }
      }.runOnQueue(.main)

      AsyncFunction("setAudioTrack") { (view: ExpoMpvView, trackId: Int) in
        view.setAudioTrack(trackId)
      }.runOnQueue(.main)

      AsyncFunction("addSubtitle") { (view: ExpoMpvView, path: String, flag: String?, title: String?, lang: String?, promise: Promise) in
        view.addSubtitle(path, flag: flag ?? "select", title: title, lang: lang) { promise.resolve() }
      }.runOnQueue(.main)

      AsyncFunction("removeSubtitle") { (view: ExpoMpvView, trackId: Int) in
        view.removeSubtitle(trackId)
      }.runOnQueue(.main)

      AsyncFunction("reloadSubtitles") { (view: ExpoMpvView, promise: Promise) in
        view.reloadSubtitles { promise.resolve() }
      }.runOnQueue(.main)

      AsyncFunction("addAudio") { (view: ExpoMpvView, path: String, flag: String?, title: String?, lang: String?, promise: Promise) in
        view.addAudio(path, flag: flag ?? "select", title: title, lang: lang) { promise.resolve() }
      }.runOnQueue(.main)

      AsyncFunction("removeAudio") { (view: ExpoMpvView, trackId: Int) in
        view.removeAudio(trackId)
      }.runOnQueue(.main)

      AsyncFunction("setSubtitleDelay") { (view: ExpoMpvView, seconds: Double) in
        view.setSubtitleDelay(seconds)
      }.runOnQueue(.main)

      AsyncFunction("setPropertyString") { (view: ExpoMpvView, name: String, value: String, promise: Promise) in
        view.setPropertyStringAsync(name, value) { promise.resolve() }
      }.runOnQueue(.main)

      AsyncFunction("getPlaybackInfo") { (view: ExpoMpvView) -> [String: Any] in
        return view.getPlaybackInfo()
      }.runOnQueue(.main)

      AsyncFunction("getTrackList") { (view: ExpoMpvView) -> [[String: Any]] in
        return view.getTrackList()
      }.runOnQueue(.main)

      AsyncFunction("getCurrentTrackIds") { (view: ExpoMpvView) -> [String: Int] in
        return view.getCurrentTrackIds()
      }.runOnQueue(.main)

      AsyncFunction("getMediaInfo") { (view: ExpoMpvView) -> [String: Any] in
        return view.getMediaInfo()
      }.runOnQueue(.main)
    }
  }
}
