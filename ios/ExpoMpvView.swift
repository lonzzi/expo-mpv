import ExpoModulesCore
import Libmpv
import CoreText

class ExpoMpvView: ExpoView {
  // MARK: - Metal Layer

  private let metalLayer = MetalLayer()

  // MARK: - MPV

  private var mpv: OpaquePointer?
  private lazy var queue = DispatchQueue(label: "com.expo.mpv.event", qos: .userInitiated)

  // MARK: - State

  private var isInitialized = false
  private var pendingSource: String?
  private var pendingHwdec: String = "videotoolbox"
  private var progressTimer: Timer?

  /// Whether a source has been requested (loadfile issued and not stopped).
  /// Distinguishes "idle" (no media) from "loading" (media coming up).
  private var hasSource = false
  /// Last emitted high-level playback state, to avoid duplicate events.
  private var currentState = "idle"

  // MARK: - Event Dispatchers

  let onPlaybackStateChange = EventDispatcher()
  let onProgress = EventDispatcher()
  let onLoad = EventDispatcher()
  let onError = EventDispatcher()
  let onEnd = EventDispatcher()
  let onBuffer = EventDispatcher()
  let onSeek = EventDispatcher()
  let onVolumeChange = EventDispatcher()
  let onHdrStateChange = EventDispatcher()

  // MARK: - Init

  required init(appContext: AppContext? = nil) {
    super.init(appContext: appContext)
    clipsToBounds = true
    backgroundColor = .black
    setupMetalLayer()
    setupMpv()
    setupNotifications()
  }

  deinit {
    stopProgressTimer()
    NotificationCenter.default.removeObserver(self)
    destroy()
  }

  // MARK: - Layout

  override func layoutSubviews() {
    super.layoutSubviews()
    metalLayer.frame = bounds
    let scale = window?.screen.nativeScale ?? UIScreen.main.nativeScale
    let w = bounds.width * scale
    let h = bounds.height * scale
    if w > 1 && h > 1 {
      metalLayer.drawableSize = CGSize(width: w, height: h)
    }
  }

  // MARK: - Metal Layer Setup

  private func setupMetalLayer() {
    metalLayer.contentsScale = UIScreen.main.nativeScale
    metalLayer.framebufferOnly = true
    metalLayer.backgroundColor = UIColor.black.cgColor
    metalLayer.pixelFormat = .bgra8Unorm
    metalLayer.device = MTLCreateSystemDefaultDevice()
    if metalLayer.device == nil {
      log("WARNING: MTLCreateSystemDefaultDevice() returned nil — Metal not available")
    }
    layer.addSublayer(metalLayer)
  }

  // MARK: - MPV Setup

  private func setupMpv() {
    log("Creating mpv instance...")

    mpv = mpv_create()
    guard let mpv = mpv else {
      let msg = "Failed to create mpv instance"
      log("ERROR: \(msg)")
      DispatchQueue.main.async { self.onError(["error": msg]) }
      return
    }

    // Enable mpv log messages so we can see what's happening
    checkError(mpv_request_log_messages(mpv, "v"), label: "request_log_messages")

    // Pass the CAMetalLayer as the wid (window ID)
    // mpv expects the raw pointer value as an Int64
    var wid = unsafeBitCast(metalLayer, to: Int64.self)
    checkError(mpv_set_option(mpv, "wid", MPV_FORMAT_INT64, &wid), label: "set wid")

    // Rendering configuration
    // On simulator: use vo=gpu (old pipeline, avoids libplacebo's pl_tex_upload_pbo
    // which crashes on simulator due to MTLSimDriver XPC shared memory size limits)
    // On device: use vo=gpu-next (libplacebo pipeline, better quality)
    #if targetEnvironment(simulator)
    log("Running on SIMULATOR — using vo=gpu to avoid MTLSimDriver crash")
    setOptionString("vo", "gpu")
    setOptionString("gpu-api", "vulkan")
    setOptionString("gpu-context", "moltenvk")
    setOptionString("hwdec", "videotoolbox-copy")
    #else
    setOptionString("vo", "gpu-next")
    setOptionString("gpu-api", "vulkan")
    setOptionString("gpu-context", "moltenvk")
    setOptionString("hwdec", pendingHwdec)
    // HDR / Dolby Vision passthrough. Must be set before mpv_initialize and
    // requires vo=gpu-next (device only). With this enabled, mpv + libplacebo +
    // libdovi automatically pass through / tone-map HDR & DV per content, and
    // the moltenvk backend drives the CAMetalLayer's EDR mode. `auto` is not
    // supported on moltenvk, so we use `yes`.
    setOptionString("target-colorspace-hint", "yes")
    #endif

    // General options
    setOptionString("keep-open", "yes")
    setOptionString("idle", "yes")
    setOptionString("input-default-bindings", "no")
    setOptionString("input-vo-keyboard", "no")

    // Subtitle font configuration
    // iOS has no fontconfig, so libass can't discover system fonts.
    // We use CoreText to find a CJK font file and point libass to it.
    configureFonts(mpv)

    // Initialize mpv
    log("Initializing mpv...")
    let initResult = mpv_initialize(mpv)
    guard initResult == 0 else {
      let errStr = String(cString: mpv_error_string(initResult))
      let msg = "mpv_initialize failed: \(errStr) (\(initResult))"
      log("ERROR: \(msg)")
      DispatchQueue.main.async { self.onError(["error": msg]) }
      mpv_destroy(mpv)
      self.mpv = nil
      return
    }

    isInitialized = true
    log("mpv initialized successfully")

    // Observe properties
    mpv_observe_property(mpv, 0, "pause", MPV_FORMAT_FLAG)
    mpv_observe_property(mpv, 1, "duration", MPV_FORMAT_DOUBLE)
    mpv_observe_property(mpv, 2, "time-pos", MPV_FORMAT_DOUBLE)
    mpv_observe_property(mpv, 3, "paused-for-cache", MPV_FORMAT_FLAG)
    mpv_observe_property(mpv, 4, "eof-reached", MPV_FORMAT_FLAG)
    mpv_observe_property(mpv, 5, "volume", MPV_FORMAT_DOUBLE)
    mpv_observe_property(mpv, 6, "mute", MPV_FORMAT_FLAG)
    mpv_observe_property(mpv, 7, "speed", MPV_FORMAT_DOUBLE)
    mpv_observe_property(mpv, 8, "demuxer-cache-duration", MPV_FORMAT_DOUBLE)
    mpv_observe_property(mpv, 9, "video-params/w", MPV_FORMAT_INT64)
    mpv_observe_property(mpv, 10, "video-params/h", MPV_FORMAT_INT64)
    mpv_observe_property(mpv, 11, "core-idle", MPV_FORMAT_FLAG)
    mpv_observe_property(mpv, 12, "video-params/sig-peak", MPV_FORMAT_DOUBLE)

    // Set wakeup callback for the event loop
    let rawSelf = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
    mpv_set_wakeup_callback(mpv, { ctx in
      guard let ctx = ctx else { return }
      let view = Unmanaged<ExpoMpvView>.fromOpaque(ctx).takeUnretainedValue()
      view.readEvents()
    }, rawSelf)

    // Load pending source if any
    if let source = pendingSource {
      pendingSource = nil
      loadFile(source)
    }
  }

  // MARK: - App Lifecycle

  private func setupNotifications() {
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(appDidEnterBackground),
      name: UIApplication.didEnterBackgroundNotification,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(appWillEnterForeground),
      name: UIApplication.willEnterForegroundNotification,
      object: nil
    )
  }

  @objc private func appDidEnterBackground() {
    guard mpv != nil else { return }
    mpv_set_property_string(mpv, "vid", "no")
  }

  @objc private func appWillEnterForeground() {
    guard mpv != nil else { return }
    mpv_set_property_string(mpv, "vid", "auto")
  }

  // MARK: - Progress Timer

  /// Start the progress timer if it isn't already running. Idempotent so it can
  /// be driven repeatedly from the state machine without tearing down/recreating.
  private func startProgressTimer() {
    DispatchQueue.main.async { [weak self] in
      guard let self = self, self.progressTimer == nil else { return }
      self.progressTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
        self?.emitProgressEvent()
      }
    }
  }

  private func stopProgressTimer() {
    progressTimer?.invalidate()
    progressTimer = nil
  }

  private func emitProgressEvent() {
    guard mpv != nil else { return }
    let position = getDouble("time-pos")
    let duration = getDouble("duration")
    let cachedDuration = getDouble("demuxer-cache-duration")
    // Absolute timeline position up to which media is buffered (for a seek bar).
    let cacheTime = getDouble("demuxer-cache-time")
    // Network read rate in bytes/sec, from the demuxer-cache-state NODE map.
    let bufferRate = getCacheRawInputRate()
    // Cache fill percentage while stalled (0-100); 100 when not buffering.
    let bufferingPercent = getFlag("paused-for-cache") ? getDouble("cache-buffering-state") : 100

    guard position.isFinite && duration.isFinite else { return }

    onProgress([
      "position": position,
      "duration": duration,
      "bufferedDuration": cachedDuration.isFinite ? cachedDuration : 0,
      "bufferedPosition": cacheTime.isFinite ? cacheTime : 0,
      "bufferRate": bufferRate,
      "bufferingPercent": bufferingPercent.isFinite ? bufferingPercent : 0,
    ])
  }

  // MARK: - Playback State Machine

  /// Derive the high-level playback state from mpv's orthogonal status flags.
  /// Order matters: cache stalls and EOF take precedence over the pause flag.
  private func computeState() -> String {
    guard mpv != nil, hasSource else { return "idle" }
    if getFlag("eof-reached") { return "ended" }
    if getFlag("paused-for-cache") { return "buffering" }
    if getFlag("pause") { return "paused" }
    // Not paused and not stalled, but the core isn't rendering yet -> still
    // loading the first frame (or re-buffering after a seek).
    if getFlag("core-idle") { return "loading" }
    return "playing"
  }

  /// Recompute state, drive the progress timer accordingly, and emit an event
  /// only when the state actually changes. Must run on the main thread.
  private func emitStateChange() {
    let state = computeState()

    switch state {
    case "playing", "loading", "buffering":
      startProgressTimer()
    default:
      stopProgressTimer()
    }

    guard state != currentState else { return }
    currentState = state
    onPlaybackStateChange([
      "state": state,
      "isPlaying": !getFlag("pause"),
    ])
  }

  // MARK: - Event Loop

  private func readEvents() {
    queue.async { [weak self] in
      guard let self = self, self.mpv != nil else { return }

      while true {
        let event = mpv_wait_event(self.mpv, 0)
        guard let event = event else { break }

        if event.pointee.event_id == MPV_EVENT_NONE {
          break
        }

        switch event.pointee.event_id {
        case MPV_EVENT_PROPERTY_CHANGE:
          self.handlePropertyChange(event)

        case MPV_EVENT_LOG_MESSAGE:
          if let data = event.pointee.data {
            let msg = data.assumingMemoryBound(to: mpv_event_log_message.self).pointee
            if let text = msg.text {
              let logText = String(cString: text).trimmingCharacters(in: .whitespacesAndNewlines)
              let prefix = msg.prefix.map { String(cString: $0) } ?? "?"
              let level = msg.level.map { String(cString: $0) } ?? "?"
              self.log("[\(prefix)] [\(level)] \(logText)")
            }
          }

        case MPV_EVENT_FILE_LOADED:
          self.log("EVENT: file-loaded")
          DispatchQueue.main.async {
            let duration = self.getDouble("duration")
            let width = self.getInt("video-params/w")
            let height = self.getInt("video-params/h")
            self.log("Media loaded: duration=\(duration) size=\(width)x\(height)")
            self.onLoad([
              "duration": duration.isFinite ? duration : 0,
              "width": width,
              "height": height,
            ])
            // File is demuxed and tracks are known, but the first frame may not
            // be rendered yet — let the state machine decide loading vs playing.
            self.emitStateChange()
          }

        case MPV_EVENT_START_FILE:
          self.log("EVENT: start-file")

        case MPV_EVENT_END_FILE:
          if let data = event.pointee.data {
            let endFile = data.assumingMemoryBound(to: mpv_event_end_file.self).pointee
            self.log("EVENT: end-file reason=\(endFile.reason) error=\(endFile.error)")
            DispatchQueue.main.async {
              let reason: String
              switch endFile.reason {
              case MPV_END_FILE_REASON_EOF:
                reason = "ended"
              case MPV_END_FILE_REASON_ERROR:
                reason = "error"
                let errStr = String(cString: mpv_error_string(endFile.error))
                let msg = "Playback error: \(errStr) (code \(endFile.error))"
                self.log("ERROR: \(msg)")
                self.onError(["error": msg])
                self.hasSource = false
              case MPV_END_FILE_REASON_STOP:
                reason = "stopped"
                self.hasSource = false
              default:
                reason = "unknown"
                self.hasSource = false
              }
              self.onEnd(["reason": reason])
              if reason == "ended" {
                // EOF with keep-open=yes: emit "ended" directly to avoid relying
                // on eof-reached property timing.
                self.currentState = "ended"
                self.onPlaybackStateChange(["state": "ended", "isPlaying": false])
                self.stopProgressTimer()
              } else {
                self.emitStateChange() // -> idle
              }
            }
          }

        case MPV_EVENT_SHUTDOWN:
          self.log("EVENT: shutdown")
          self.mpv = nil
          return

        case MPV_EVENT_SEEK:
          DispatchQueue.main.async {
            self.onSeek([:])
          }

        default:
          let eventName = mpv_event_name(event.pointee.event_id)
          if let eventName = eventName {
            self.log("EVENT: \(String(cString: eventName))")
          }
        }
      }
    }
  }

  private func handlePropertyChange(_ event: UnsafePointer<mpv_event>) {
    guard let data = event.pointee.data else { return }
    let prop = data.assumingMemoryBound(to: mpv_event_property.self).pointee

    guard let cName = prop.name else { return }
    let name = String(cString: cName)

    switch name {
    // These flags all feed the unified state machine; let computeState() decide.
    case "pause", "core-idle", "eof-reached":
      DispatchQueue.main.async {
        self.emitStateChange()
      }

    case "paused-for-cache":
      let buffering: Bool = {
        guard prop.format == MPV_FORMAT_FLAG, let flagPtr = prop.data else { return false }
        return flagPtr.assumingMemoryBound(to: Int32.self).pointee != 0
      }()
      DispatchQueue.main.async {
        // Keep the dedicated buffering event for backwards compatibility, and
        // recompute the high-level state (buffering vs playing).
        self.onBuffer(["isBuffering": buffering])
        self.emitStateChange()
      }

    case "volume":
      if prop.format == MPV_FORMAT_DOUBLE, let dataPtr = prop.data {
        let volume = dataPtr.assumingMemoryBound(to: Double.self).pointee
        DispatchQueue.main.async {
          self.onVolumeChange(["volume": volume, "muted": self.getFlag("mute")])
        }
      }

    case "mute":
      if prop.format == MPV_FORMAT_FLAG, let flagPtr = prop.data {
        let muted = flagPtr.assumingMemoryBound(to: Int32.self).pointee != 0
        DispatchQueue.main.async {
          self.onVolumeChange(["volume": self.getDouble("volume"), "muted": muted])
        }
      }

    case "video-params/sig-peak":
      let sigPeak: Double = {
        guard prop.format == MPV_FORMAT_DOUBLE, let dataPtr = prop.data else { return 0 }
        return dataPtr.assumingMemoryBound(to: Double.self).pointee
      }()
      DispatchQueue.main.async {
        self.emitHdrStateChange(sigPeak: sigPeak)
      }

    default:
      break
    }
  }

  /// Report HDR state to JS. `sigPeak` > 1 means the media is HDR; combined with
  /// the screen's EDR headroom it tells whether HDR is actually being displayed.
  /// Must run on the main thread (reads UIScreen).
  private func emitHdrStateChange(sigPeak: Double) {
    let peak = sigPeak.isFinite ? sigPeak : 0
    let isHdr = peak > 1.0
    let headroom = window?.screen.potentialEDRHeadroom ?? 1.0
    let hdrActive = isHdr && headroom > 1.0
    let gamma = getString("video-params/gamma") ?? ""
    onHdrStateChange([
      "isHdr": isHdr,
      "hdrActive": hdrActive,
      "sigPeak": peak,
      "hdrFormat": isHdr ? gamma : "",
    ])
  }

  // MARK: - Public API

  func loadFile(_ url: String) {
    guard isInitialized, mpv != nil else {
      log("loadFile deferred (not initialized yet): \(url)")
      pendingSource = url
      return
    }
    log("loadFile: \(url)")
    hasSource = true
    commandAsync("loadfile", args: [url, "replace"])
    // Enter "loading" immediately. We force it here (rather than via
    // computeState) because right after loadfile mpv may still report the
    // previous file's flags (e.g. eof-reached), which would misfire "ended".
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      self.currentState = "loading"
      self.onPlaybackStateChange(["state": "loading", "isPlaying": !self.getFlag("pause")])
      self.startProgressTimer()
    }
  }

  func play() {
    setFlag("pause", false)
  }

  func pause() {
    setFlag("pause", true)
  }

  func togglePlay() {
    let isPaused = getFlag("pause")
    setFlag("pause", !isPaused)
  }

  func stop() {
    commandAsync("stop")
    hasSource = false
    DispatchQueue.main.async { [weak self] in
      self?.emitStateChange() // -> idle
    }
  }

  func seekTo(_ position: Double) {
    commandAsync("seek", args: [String(position), "absolute"])
  }

  func seekBy(_ offset: Double) {
    commandAsync("seek", args: [String(offset), "relative"])
  }

  func setSpeed(_ speed: Double) {
    setDouble("speed", speed)
  }

  func setVolume(_ volume: Double) {
    setDouble("volume", volume)
  }

  func setMuted(_ muted: Bool) {
    setFlag("mute", muted)
  }

  func setLooping(_ loop: Bool) {
    guard mpv != nil else { return }
    mpv_set_property_string(mpv, "loop-file", loop ? "inf" : "no")
  }

  func setHwdec(_ mode: String) {
    pendingHwdec = mode
    if isInitialized, mpv != nil {
      setPropertyString("hwdec", mode)
    }
  }

  func setSubtitleTrack(_ trackId: Int) {
    setInt("sid", Int64(trackId))
  }

  func setAudioTrack(_ trackId: Int) {
    setInt("aid", Int64(trackId))
  }

  /// Build args for sub-add / audio-add: <url> [<flags> [<title> [<lang>]]].
  private func trackAddArgs(_ path: String, flag: String, title: String?, lang: String?) -> [String] {
    var args = [path, flag]
    if let title = title { args.append(title) }
    if let lang = lang {
      if args.count == 2 { args.append("") } // placeholder for title
      args.append(lang)
    }
    return args
  }

  /// Load an external subtitle file (local path or URL).
  /// `flag` defaults to "select" (mpv's own default) so the subtitle is shown
  /// immediately. Pass "auto" to add without selecting (then use setSubtitleTrack).
  func addSubtitle(_ path: String, flag: String = "select", title: String? = nil, lang: String? = nil) {
    guard mpv != nil else { return }
    log("addSubtitle: \(path) flags=\(flag)")
    commandAsync("sub-add", args: trackAddArgs(path, flag: flag, title: title, lang: lang))
  }

  /// Remove a subtitle track by id.
  func removeSubtitle(_ trackId: Int) {
    commandAsync("sub-remove", args: [String(trackId)])
  }

  /// Reload current subtitles (useful after font changes).
  func reloadSubtitles() {
    commandAsync("sub-reload")
  }

  /// Load an external audio file (local path or URL). `flag` defaults to
  /// "select" so it becomes the active audio track. Pass "auto" to add without
  /// selecting (then use setAudioTrack).
  func addAudio(_ path: String, flag: String = "select", title: String? = nil, lang: String? = nil) {
    guard mpv != nil else { return }
    log("addAudio: \(path) flags=\(flag)")
    commandAsync("audio-add", args: trackAddArgs(path, flag: flag, title: title, lang: lang))
  }

  /// Remove an audio track by id.
  func removeAudio(_ trackId: Int) {
    commandAsync("audio-remove", args: [String(trackId)])
  }

  func setSubtitleDelay(_ seconds: Double) {
    setDouble("sub-delay", seconds)
  }

  func setPropertyString(_ name: String, _ value: String) {
    guard mpv != nil else { return }
    let result = mpv_set_property_string(mpv, name, value)
    if result < 0 {
      let errStr = String(cString: mpv_error_string(result))
      log("ERROR: set property string '\(name)'='\(value)' failed: \(errStr)")
    }
  }

  func getPlaybackInfo() -> [String: Any] {
    let position = getDouble("time-pos")
    let duration = getDouble("duration")
    let isPaused = getFlag("pause")
    let speed = getDouble("speed")
    let volume = getDouble("volume")
    let muted = getFlag("mute")

    return [
      "position": position.isFinite ? position : 0,
      "duration": duration.isFinite ? duration : 0,
      "isPlaying": !isPaused,
      "speed": speed,
      "volume": volume,
      "muted": muted,
    ]
  }

  func getTrackList() -> [[String: Any]] {
    guard mpv != nil else { return [] }

    let count = getInt("track-list/count")
    var tracks: [[String: Any]] = []

    for i in 0..<count {
      let prefix = "track-list/\(i)"
      var track: [String: Any] = [:]

      track["id"] = Int(getInt("\(prefix)/id"))
      track["type"] = getString("\(prefix)/type") ?? "unknown"
      track["title"] = getString("\(prefix)/title") ?? ""
      track["lang"] = getString("\(prefix)/lang") ?? ""
      track["codec"] = getString("\(prefix)/codec") ?? ""
      track["selected"] = getFlag("\(prefix)/selected")
      track["isDefault"] = getFlag("\(prefix)/default")
      track["isExternal"] = getFlag("\(prefix)/external")

      // Extra info based on track type
      let trackType = track["type"] as? String ?? ""
      if trackType == "audio" {
        track["channelCount"] = Int(getInt("\(prefix)/demux-channel-count"))
        track["sampleRate"] = Int(getInt("\(prefix)/demux-samplerate"))
      } else if trackType == "video" {
        track["width"] = Int(getInt("\(prefix)/demux-w"))
        track["height"] = Int(getInt("\(prefix)/demux-h"))
        track["fps"] = getDouble("\(prefix)/demux-fps")
      }

      tracks.append(track)
    }

    log("getTrackList: \(tracks.count) tracks found")
    return tracks
  }

  func getCurrentTrackIds() -> [String: Int] {
    guard mpv != nil else { return [:] }
    return [
      "vid": Int(getInt("vid")),
      "aid": Int(getInt("aid")),
      "sid": Int(getInt("sid")),
    ]
  }

  func getMediaInfo() -> [String: Any] {
    guard mpv != nil else { return [:] }

    let hwdec = getString("hwdec") ?? ""
    let hwdecCurrent = getString("hwdec-current") ?? ""
    let videoCodec = getString("video-codec") ?? ""
    let audioCodec = getString("audio-codec-name") ?? ""
    let width = getInt("video-params/w")
    let height = getInt("video-params/h")
    let fps = getDouble("container-fps")
    let videoBitrate = getDouble("video-bitrate")
    let audioBitrate = getDouble("audio-bitrate")
    let pixelFormat = getString("video-params/pixelformat") ?? ""
    let colorspace = getString("video-params/colormatrix") ?? ""
    // Transfer function: "pq" = HDR10/Dolby Vision, "hlg" = HLG, else SDR.
    let gamma = getString("video-params/gamma") ?? ""
    let isHdr = gamma == "pq" || gamma == "hlg" || getDouble("video-params/sig-peak") > 1.0

    return [
      "hwdec": hwdec,
      "hwdecCurrent": hwdecCurrent,
      "videoCodec": videoCodec,
      "audioCodec": audioCodec,
      "width": Int(width),
      "height": Int(height),
      "fps": fps.isFinite ? fps : 0,
      "videoBitrate": videoBitrate.isFinite ? videoBitrate : 0,
      "audioBitrate": audioBitrate.isFinite ? audioBitrate : 0,
      "pixelFormat": pixelFormat,
      "colorspace": colorspace,
      "isHdr": isHdr,
      "hdrFormat": gamma,
    ]
  }

  func destroy() {
    stopProgressTimer()
    if let mpv = mpv {
      log("Destroying mpv...")
      mpv_set_wakeup_callback(mpv, nil, nil)
      mpv_terminate_destroy(mpv)
      self.mpv = nil
    }
  }

  // MARK: - Font Configuration

  /// Configure fonts for subtitle rendering.
  ///
  /// iOS 18+ changed system fonts (PingFang etc.) to Apple's HVGL variable font format,
  /// which FreeType (used by libass) cannot parse. This means system CJK fonts are
  /// unusable by libass even if CoreText can find them.
  ///
  /// Solution: bundle a standard OTF/TTF CJK font (Noto Sans CJK SC) that FreeType
  /// can read, and point libass to it via sub-fonts-dir.
  /// See: https://github.com/libass/libass/issues/912
  ///      https://github.com/mpv-player/mpv/issues/14878
  private func configureFonts(_ mpv: OpaquePointer) {
    // Locate the bundled Noto Sans CJK SC font in the module's bundle
    let fontFileName = "NotoSansCJKsc-Regular"
    let fontFileExt = "otf"

    // Search in all bundles (the font is in the ExpoMpv pod bundle)
    var fontPath: String?
    for bundle in Bundle.allBundles {
      if let path = bundle.path(forResource: fontFileName, ofType: fontFileExt) {
        fontPath = path
        break
      }
    }

    // Also check the main bundle's Frameworks
    if fontPath == nil {
      let frameworksPath = Bundle.main.bundlePath + "/Frameworks"
      if let contents = try? FileManager.default.contentsOfDirectory(atPath: frameworksPath) {
        for item in contents where item.hasSuffix(".framework") {
          let bundlePath = frameworksPath + "/" + item
          if let bundle = Bundle(path: bundlePath),
             let path = bundle.path(forResource: fontFileName, ofType: fontFileExt) {
            fontPath = path
            break
          }
        }
      }
    }

    guard let resolvedFontPath = fontPath else {
      log("WARNING: Bundled font \(fontFileName).\(fontFileExt) not found in any bundle")
      // Fallback: try auto font provider without bundled font
      setOptionString("sub-font-provider", "auto")
      setOptionString("sub-font", "sans-serif")
      return
    }

    let fontsDir = (resolvedFontPath as NSString).deletingLastPathComponent
    log("Font: \(resolvedFontPath)")

    // Point libass to the directory containing our bundled font
    setOptionString("sub-fonts-dir", fontsDir)

    // auto = CoreText on Apple platforms (handles font name matching + fallback)
    setOptionString("sub-font-provider", "auto")

    // Default font for SRT / plain text subtitles
    setOptionString("sub-font", "Noto Sans CJK SC")
    setOptionString("sub-font-size", "40")
    setOptionString("sub-codepage", "auto")

    // ASS subtitles: don't force-override styles.
    // When ASS references fonts like "Microsoft YaHei" that don't exist on iOS,
    // CoreText + our bundled font provide fallback.
    setOptionString("sub-ass-override", "no")
    setOptionString("sub-ass-shaper", "simple")

    // Auto-load external subtitles from same directory as video
    setOptionString("sub-auto", "fuzzy")
  }

  // MARK: - MPV Helpers

  private func commandAsync(_ command: String, args: [String] = []) {
    guard mpv != nil else {
      log("commandAsync ignored (mpv is nil): \(command)")
      return
    }

    // Build null-terminated args string for mpv_command_string is simplest,
    // but mpv_command_string doesn't exist. Use mpv_command with proper memory management.
    let allArgs = [command] + args
    // Create C strings that live long enough
    var cStrings = allArgs.map { strdup($0) }
    cStrings.append(nil) // null-terminate

    // Create array of const pointers
    let result = cStrings.withUnsafeMutableBufferPointer { buffer -> Int32 in
      // Build an array of UnsafePointer<CChar>? from UnsafeMutablePointer<CChar>?
      var constPtrs = buffer.map { UnsafePointer($0) }
      return constPtrs.withUnsafeMutableBufferPointer { constBuffer in
        mpv_command(mpv, constBuffer.baseAddress)
      }
    }

    // Free strdup'd strings
    for ptr in cStrings {
      if let ptr = ptr { free(ptr) }
    }

    if result < 0 {
      let errStr = String(cString: mpv_error_string(result))
      log("ERROR: command '\(command) \(args.joined(separator: " "))' failed: \(errStr) (\(result))")
      DispatchQueue.main.async {
        self.onError(["error": "Command '\(command)' failed: \(errStr)"])
      }
    } else {
      log("Command OK: \(command) \(args.joined(separator: " "))")
    }
  }

  private func setOptionString(_ name: String, _ value: String) {
    guard let mpv = mpv else { return }
    let result = mpv_set_option_string(mpv, name, value)
    if result < 0 {
      let errStr = String(cString: mpv_error_string(result))
      log("ERROR: set option '\(name)'='\(value)' failed: \(errStr)")
    } else {
      log("Option: \(name) = \(value)")
    }
  }

  private func getDouble(_ name: String) -> Double {
    guard mpv != nil else { return 0 }
    var data: Double = 0
    mpv_get_property(mpv, name, MPV_FORMAT_DOUBLE, &data)
    return data
  }

  private func getString(_ name: String) -> String? {
    guard mpv != nil else { return nil }
    let cstr = mpv_get_property_string(mpv, name)
    defer { mpv_free(cstr) }
    guard let cstr = cstr else { return nil }
    return String(cString: cstr)
  }

  private func getInt(_ name: String) -> Int64 {
    guard mpv != nil else { return 0 }
    var data: Int64 = 0
    mpv_get_property(mpv, name, MPV_FORMAT_INT64, &data)
    return data
  }

  private func getFlag(_ name: String) -> Bool {
    guard mpv != nil else { return false }
    var data: Int32 = 0
    mpv_get_property(mpv, name, MPV_FORMAT_FLAG, &data)
    return data != 0
  }

  /// Read the current network read rate (bytes/sec) from the
  /// `demuxer-cache-state` NODE map's `raw-input-rate` field.
  /// Returns 0 when unknown (e.g. local playback or before caching starts).
  private func getCacheRawInputRate() -> Double {
    guard mpv != nil else { return 0 }
    var node = mpv_node()
    guard mpv_get_property(mpv, "demuxer-cache-state", MPV_FORMAT_NODE, &node) >= 0 else {
      return 0
    }
    defer { mpv_free_node_contents(&node) }
    guard let dict = nodeToAny(node) as? [String: Any] else { return 0 }
    if let rate = dict["raw-input-rate"] as? Int64 { return Double(rate) }
    if let rate = dict["raw-input-rate"] as? Double { return rate }
    return 0
  }

  /// Recursively convert an mpv_node into a native Swift value
  /// (String / Bool / Int64 / Double / [Any] / [String: Any]).
  private func nodeToAny(_ node: mpv_node) -> Any? {
    switch node.format {
    case MPV_FORMAT_STRING:
      return node.u.string.map { String(cString: $0) }
    case MPV_FORMAT_FLAG:
      return node.u.flag != 0
    case MPV_FORMAT_INT64:
      return node.u.int64
    case MPV_FORMAT_DOUBLE:
      return node.u.double_
    case MPV_FORMAT_NODE_ARRAY:
      guard let list = node.u.list?.pointee, let values = list.values else { return [Any]() }
      var arr: [Any] = []
      for i in 0..<Int(list.num) {
        if let v = nodeToAny(values[i]) { arr.append(v) }
      }
      return arr
    case MPV_FORMAT_NODE_MAP:
      guard let list = node.u.list?.pointee, let values = list.values, let keys = list.keys else {
        return [String: Any]()
      }
      var map: [String: Any] = [:]
      for i in 0..<Int(list.num) {
        guard let keyPtr = keys[i] else { continue }
        if let v = nodeToAny(values[i]) { map[String(cString: keyPtr)] = v }
      }
      return map
    default:
      return nil
    }
  }

  private func setDouble(_ name: String, _ value: Double) {
    guard mpv != nil else { return }
    var data = value
    let result = mpv_set_property(mpv, name, MPV_FORMAT_DOUBLE, &data)
    if result < 0 {
      let errStr = String(cString: mpv_error_string(result))
      log("ERROR: set property '\(name)'=\(value) failed: \(errStr)")
    }
  }

  private func setInt(_ name: String, _ value: Int64) {
    guard mpv != nil else { return }
    var data = value
    let result = mpv_set_property(mpv, name, MPV_FORMAT_INT64, &data)
    if result < 0 {
      let errStr = String(cString: mpv_error_string(result))
      log("ERROR: set property '\(name)'=\(value) failed: \(errStr)")
    }
  }

  private func setFlag(_ name: String, _ flag: Bool) {
    guard mpv != nil else { return }
    var data: Int32 = flag ? 1 : 0
    let result = mpv_set_property(mpv, name, MPV_FORMAT_FLAG, &data)
    if result < 0 {
      let errStr = String(cString: mpv_error_string(result))
      log("ERROR: set flag '\(name)'=\(flag) failed: \(errStr)")
    }
  }

  @discardableResult
  private func checkError(_ status: Int32, label: String = "") -> Bool {
    if status < 0 {
      let errStr = String(cString: mpv_error_string(status))
      log("ERROR [\(label)]: \(errStr) (\(status))")
      return false
    }
    return true
  }

  private func log(_ message: String) {
    NSLog("[ExpoMpv] %@", message)
  }
}

// MARK: - MetalLayer

private class MetalLayer: CAMetalLayer {
  // Guard against MoltenVK 1×1 drawableSize bug
  override var drawableSize: CGSize {
    get { super.drawableSize }
    set {
      if Int(newValue.width) > 1 && Int(newValue.height) > 1 {
        super.drawableSize = newValue
      }
    }
  }

  // EDR/HDR content must be set on main thread
  override var wantsExtendedDynamicRangeContent: Bool {
    get { super.wantsExtendedDynamicRangeContent }
    set {
      if Thread.isMainThread {
        super.wantsExtendedDynamicRangeContent = newValue
      } else {
        DispatchQueue.main.sync {
          super.wantsExtendedDynamicRangeContent = newValue
        }
      }
    }
  }
}
