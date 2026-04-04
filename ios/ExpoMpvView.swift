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
  private var progressTimer: Timer?

  // MARK: - Event Dispatchers

  let onPlaybackStateChange = EventDispatcher()
  let onProgress = EventDispatcher()
  let onLoad = EventDispatcher()
  let onError = EventDispatcher()
  let onEnd = EventDispatcher()
  let onBuffer = EventDispatcher()
  let onSeek = EventDispatcher()
  let onVolumeChange = EventDispatcher()

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
    setOptionString("hwdec", "videotoolbox")
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

  private func startProgressTimer() {
    stopProgressTimer()
    DispatchQueue.main.async { [weak self] in
      self?.progressTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
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

    guard position.isFinite && duration.isFinite else { return }

    onProgress([
      "position": position,
      "duration": duration,
      "bufferedDuration": cachedDuration.isFinite ? cachedDuration : 0,
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
            self.startProgressTimer()
          }

        case MPV_EVENT_START_FILE:
          self.log("EVENT: start-file")

        case MPV_EVENT_END_FILE:
          if let data = event.pointee.data {
            let endFile = data.assumingMemoryBound(to: mpv_event_end_file.self).pointee
            self.log("EVENT: end-file reason=\(endFile.reason) error=\(endFile.error)")
            DispatchQueue.main.async {
              self.stopProgressTimer()
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
              case MPV_END_FILE_REASON_STOP:
                reason = "stopped"
              default:
                reason = "unknown"
              }
              self.onEnd(["reason": reason])
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
    case "pause":
      if prop.format == MPV_FORMAT_FLAG, let flagPtr = prop.data {
        let paused = flagPtr.assumingMemoryBound(to: Int32.self).pointee != 0
        DispatchQueue.main.async {
          self.onPlaybackStateChange([
            "state": paused ? "paused" : "playing",
            "isPlaying": !paused,
          ])
          if paused {
            self.stopProgressTimer()
          } else {
            self.startProgressTimer()
          }
        }
      }

    case "paused-for-cache":
      if prop.format == MPV_FORMAT_FLAG, let flagPtr = prop.data {
        let buffering = flagPtr.assumingMemoryBound(to: Int32.self).pointee != 0
        DispatchQueue.main.async {
          self.onBuffer(["isBuffering": buffering])
        }
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

    default:
      break
    }
  }

  // MARK: - Public API

  func loadFile(_ url: String) {
    guard isInitialized, mpv != nil else {
      log("loadFile deferred (not initialized yet): \(url)")
      pendingSource = url
      return
    }
    log("loadFile: \(url)")
    commandAsync("loadfile", args: [url, "replace"])
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
    stopProgressTimer()
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

  func setSubtitleTrack(_ trackId: Int) {
    setInt("sid", Int64(trackId))
  }

  func setAudioTrack(_ trackId: Int) {
    setInt("aid", Int64(trackId))
  }

  /// Load an external subtitle file (local path or URL).
  func addSubtitle(_ path: String, flag: String = "auto", title: String? = nil, lang: String? = nil) {
    guard mpv != nil else { return }
    // sub-add <url> [<flags> [<title> [<lang>]]]
    var args = [path, flag]
    if let title = title { args.append(title) }
    if let lang = lang {
      if args.count == 2 { args.append("") } // placeholder for title
      args.append(lang)
    }
    log("addSubtitle: \(path) flags=\(flag)")
    commandAsync("sub-add", args: args)
  }

  /// Remove a subtitle track by id.
  func removeSubtitle(_ trackId: Int) {
    commandAsync("sub-remove", args: [String(trackId)])
  }

  /// Reload current subtitles (useful after font changes).
  func reloadSubtitles() {
    commandAsync("sub-reload")
  }

  func setSubtitleDelay(_ seconds: Double) {
    setDouble("sub-delay", seconds)
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
