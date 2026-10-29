import ExpoModulesCore
import Libmpv
import CoreText
import AVFoundation
import MediaPlayer
import ImageIO

class ExpoMpvView: ExpoView {
  // MARK: - Metal Layer

  private let metalLayer = MetalLayer()

  // MARK: - MPV

  private let mpvLock = NSLock()
  private var mpvHandle: OpaquePointer?
  private var mpv: OpaquePointer? {
    get {
      mpvLock.lock()
      defer { mpvLock.unlock() }
      return mpvHandle
    }
    set {
      mpvLock.lock()
      mpvHandle = newValue
      mpvLock.unlock()
    }
  }
  private lazy var queue = DispatchQueue(label: "com.expo.mpv.event", qos: .userInitiated)
  private final class WakeupContext {
    private let handler: () -> Void

    init(handler: @escaping () -> Void) { self.handler = handler }

    func notify() {
      // Never access the UIKit view from mpv's foreign callback threads.
      DispatchQueue.main.async(execute: handler)
    }
  }
  private var wakeupContext: WakeupContext?
  // Accessed on the main queue; replies from the mpv event queue are marshalled there.
  private struct PendingCommand {
    let name: String
    let completion: (() -> Void)?
    let reportErrors: Bool
  }
  private var pendingCommands: [UInt64: PendingCommand] = [:]
  private var nextCommandID: UInt64 = 1
  private var isUpdatingProperties: Bool {
    pendingCommands.values.contains { $0.name == "set" }
  }

  // MARK: - State

  private var isInitialized = false
  private var pendingSource: (url: String, startPosition: Double)?
  // Apply source and startPosition together after all React props have arrived.
  var sourceToLoad: String?
  var startPosition: Double = 0
  var showNotificationControls = false
  var metadata: [String: String] = [:]
  private var nowPlaying: ExpoMpvNowPlayingController?
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

  override func didMoveToWindow() {
    super.didMoveToWindow()
    if window != nil { setNeedsLayout() }
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    metalLayer.frame = bounds
    let scale = window?.screen.nativeScale ?? UIScreen.main.nativeScale
    metalLayer.contentsScale = scale
    let w = bounds.width * scale
    let h = bounds.height * scale
    let drawableSize = CGSize(width: w, height: h)
    let surfaceChanged = w > 1 && h > 1 && metalLayer.drawableSize != drawableSize
    if surfaceChanged {
      metalLayer.drawableSize = drawableSize
    }
    CATransaction.commit()
    if surfaceChanged {
      // Wake the VO thread even while paused; it owns swapchain/viewport resize.
      NotificationCenter.default.post(
        name: Notification.Name("ExpoMpvMetalDrawableSizeDidChange"), object: metalLayer
      )
    }

    // Do not open the source against the zero-sized surface created by init.
    if window != nil, w > 1, h > 1, let source = pendingSource {
      pendingSource = nil
      loadFile(source.url, startPosition: source.startPosition)
    }
  }

  // MARK: - Metal Layer Setup

  private func setupMetalLayer() {
    metalLayer.contentsScale = UIScreen.main.nativeScale
    metalLayer.framebufferOnly = true
    metalLayer.backgroundColor = UIColor.black.cgColor
    // UIKit can resize the layer before the VO presents a matching drawable.
    // Keep that previous frame proportional during the intervening rotation frames.
    metalLayer.contentsGravity = .resizeAspect
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
    // NOTE: We intentionally do NOT set `target-colorspace-hint=yes` here.
    // On iOS + vo=gpu-next it can break hardware decode / rendering (neither the
    // MPVKit demo nor streamyfin enable it on iOS — streamyfin only sets it on
    // tvOS with vo=avfoundation). HDR/Dolby Vision content is still decoded and
    // tone-mapped by libplacebo; we report HDR via onHdrStateChange (sig-peak).
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

    // libass reads cache limits when its subtitle renderer is created.
    setOptionString("sub-glyph-limit", "100000")
    setOptionString("sub-bitmap-max-size", "256")

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
    mpv_observe_property(mpv, 13, "sid", MPV_FORMAT_INT64)

    // The callback can overlap deinit, so its userdata must outlive the view.
    // Create the weak reference while the view is alive, then resolve it only
    // on the main queue, where the UIKit view is owned and released.
    let context = WakeupContext { [weak self] in self?.readEvents() }
    wakeupContext = context
    mpv_set_wakeup_callback(mpv, { ctx in
      guard let ctx = ctx else { return }
      Unmanaged<WakeupContext>.fromOpaque(ctx).takeUnretainedValue().notify()
    }, Unmanaged.passUnretained(context).toOpaque())

    // Load pending source if any
    if let source = pendingSource {
      pendingSource = nil
      loadFile(source.url, startPosition: source.startPosition)
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
    setPropertyString("vid", "no")
  }

  @objc private func appWillEnterForeground() {
    guard mpv != nil else { return }
    setPropertyString("vid", "auto")
    setNeedsLayout()
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
    // Synchronous property reads would wait on the same core lock while an
    // async subtitle/font update initializes libass. Refresh after its reply.
    guard mpv != nil, !isUpdatingProperties else { return }
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

    updateMediaSession()

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
    guard !isUpdatingProperties else { return }
    let state = computeState()
    updateMediaSession()

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
      guard let self = self, let handle = self.mpv else { return }
      // If this reader held the last reference during an unmount, release the
      // UIKit view on its owning queue rather than on the mpv event queue.
      defer { DispatchQueue.main.async { withExtendedLifetime(self) {} } }

      // Destruction is enqueued on this same serial queue, so handle remains
      // valid until this reader has finished, even if the view is detached.
      while self.mpv == handle {
        let event = mpv_wait_event(handle, 0)
        guard let event = event else { break }

        if event.pointee.event_id == MPV_EVENT_NONE {
          break
        }

        switch event.pointee.event_id {
        case MPV_EVENT_PROPERTY_CHANGE:
          self.handlePropertyChange(event, handle: handle)

        case MPV_EVENT_COMMAND_REPLY:
          let commandID = event.pointee.reply_userdata
          let error = event.pointee.error
          self.dispatchEvent(for: handle) {
            guard let command = self.pendingCommands.removeValue(forKey: commandID) else { return }
            self.reportCommandResult(command.name, result: error, reportErrors: command.reportErrors)
            command.completion?()
            if command.name == "set", !self.isUpdatingProperties {
              self.emitStateChange()
              self.emitProgressEvent()
            }
          }

        case MPV_EVENT_LOG_MESSAGE:
          if let data = event.pointee.data {
            let msg = data.assumingMemoryBound(to: mpv_event_log_message.self).pointee
            if let text = msg.text {
              let logText = String(cString: text).trimmingCharacters(in: .whitespacesAndNewlines)
              let prefix = msg.prefix.map { String(cString: $0) } ?? "?"
              let level = msg.level.map { String(cString: $0) } ?? "?"
              self.log("[\(prefix)] [\(level)] \(logText)")
              if logText.contains("OSD bitmaps do not fit") {
                let codec = self.getString("current-tracks/sub/codec")?.lowercased()
                if codec == "ass" || codec == "ssa" {
                  self.setPropertyString("force-rgba-osd-rendering", "yes")
                }
              }
            }
          }

        case MPV_EVENT_FILE_LOADED:
          self.log("EVENT: file-loaded")
          self.dispatchEvent(for: handle) {
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
            self.dispatchEvent(for: handle) {
              // NOTE: do NOT clear hasSource here. END_FILE also fires for the
              // previous file when switching via `loadfile replace` (reason=stop),
              // which would otherwise flip the state to "idle" right after the new
              // load. Only the explicit stop() method clears hasSource.
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
              if reason == "ended" {
                // EOF with keep-open=yes: emit "ended" directly to avoid relying
                // on eof-reached property timing.
                self.currentState = "ended"
                self.onPlaybackStateChange(["state": "ended", "isPlaying": false])
                self.stopProgressTimer()
              } else {
                self.emitStateChange()
              }
            }
          }

        case MPV_EVENT_SHUTDOWN:
          self.log("EVENT: shutdown")
          self.dispatchEvent(for: handle) { self.destroy() }
          return

        case MPV_EVENT_SEEK:
          self.dispatchEvent(for: handle) {
            self.onSeek([:])
          }

        case MPV_EVENT_PLAYBACK_RESTART:
          self.dispatchEvent(for: handle) {
            // libmpv's AudioUnit driver initializes the shared session with
            // mixWithOthers. A system media owner must reapply its nonmixing
            // playback category after the audio output has actually started.
            self.nowPlaying?.activateAudioSession()
            // A paused load has no progress timer. Publish the decoded frame's
            // actual position, including any HLS/keyframe adjustment.
            self.emitProgressEvent()
            self.emitStateChange()
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

  private func dispatchEvent(for handle: OpaquePointer, _ action: @escaping () -> Void) {
    DispatchQueue.main.async { [weak self] in
      guard self?.mpv == handle else { return }
      action()
    }
  }

  private func handlePropertyChange(_ event: UnsafePointer<mpv_event>, handle: OpaquePointer) {
    guard let data = event.pointee.data else { return }
    let prop = data.assumingMemoryBound(to: mpv_event_property.self).pointee

    guard let cName = prop.name else { return }
    let name = String(cString: cName)

    switch name {
    case "sid":
      // Compact ASS masks normally fit the GPU atlas. Retry on track changes;
      // an actual atlas overflow can still fall back to RGBA composition.
      setPropertyString("force-rgba-osd-rendering", "no")

    // These flags all feed the unified state machine; let computeState() decide.
    case "pause", "core-idle", "eof-reached":
      dispatchEvent(for: handle) {
        self.emitStateChange()
      }

    case "paused-for-cache":
      let buffering: Bool = {
        guard prop.format == MPV_FORMAT_FLAG, let flagPtr = prop.data else { return false }
        return flagPtr.assumingMemoryBound(to: Int32.self).pointee != 0
      }()
      dispatchEvent(for: handle) {
        // Keep the dedicated buffering event for backwards compatibility, and
        // recompute the high-level state (buffering vs playing).
        self.onBuffer(["isBuffering": buffering])
        self.emitStateChange()
      }

    case "volume":
      if prop.format == MPV_FORMAT_DOUBLE, let dataPtr = prop.data {
        let volume = dataPtr.assumingMemoryBound(to: Double.self).pointee
        dispatchEvent(for: handle) {
          self.onVolumeChange(["volume": volume, "muted": self.getFlag("mute")])
        }
      }

    case "mute":
      if prop.format == MPV_FORMAT_FLAG, let flagPtr = prop.data {
        let muted = flagPtr.assumingMemoryBound(to: Int32.self).pointee != 0
        dispatchEvent(for: handle) {
          self.onVolumeChange(["volume": self.getDouble("volume"), "muted": muted])
        }
      }

    case "video-params/sig-peak":
      let sigPeak: Double = {
        guard prop.format == MPV_FORMAT_DOUBLE, let dataPtr = prop.data else { return 0 }
        return dataPtr.assumingMemoryBound(to: Double.self).pointee
      }()
      dispatchEvent(for: handle) {
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

  func updateMediaSession() {
    guard showNotificationControls, hasSource, mpv != nil else {
      nowPlaying?.invalidate()
      nowPlaying = nil
      return
    }
    guard !isUpdatingProperties else { return }
    if nowPlaying == nil { nowPlaying = ExpoMpvNowPlayingController(player: self) }
    nowPlaying?.update(metadata: metadata, playback: getPlaybackInfo(), ended: getFlag("eof-reached"))
  }

  func loadSourceIfNeeded() {
    guard let source = sourceToLoad else { return }
    sourceToLoad = nil
    loadFile(source, startPosition: startPosition)
  }

  func loadFile(_ url: String, startPosition: Double = 0) {
    cancelPendingCommands()
    guard isInitialized, mpv != nil, window != nil,
          bounds.width > 1, bounds.height > 1,
          metalLayer.drawableSize.width > 1, metalLayer.drawableSize.height > 1 else {
      log("loadFile deferred until the player surface is ready: \(url)")
      pendingSource = (url, startPosition)
      return
    }
    log("loadFile: \(url)")
    hasSource = true
    updateMediaSession()
    setPropertyString("force-rgba-osd-rendering", "no")
    let position = startPosition.isFinite ? max(0, startPosition) : 0
    // Per-file options seek before the first frame and cannot leak to the next file.
    command("loadfile", args: [url, "replace", "-1", "start=\(position)"])
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
    nowPlaying?.activateAudioSession()
    setFlag("pause", false)
  }

  func pause() {
    nowPlaying?.cancelInterruptionResume()
    setFlag("pause", true)
  }

  func togglePlay() {
    let isPaused = getFlag("pause")
    if isPaused { nowPlaying?.activateAudioSession() }
    setFlag("pause", !isPaused)
  }

  func stop() {
    sourceToLoad = nil
    pendingSource = nil
    cancelPendingCommands()
    command("stop")
    hasSource = false
    updateMediaSession()
    DispatchQueue.main.async { [weak self] in
      self?.emitStateChange() // -> idle
    }
  }

  func seekTo(_ position: Double) {
    command("seek", args: [String(position), "absolute"])
  }

  func seekBy(_ offset: Double) {
    command("seek", args: [String(offset), "relative"])
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

  func setSubtitleTrackAsync(_ trackId: Int, completion: @escaping () -> Void) {
    // Selecting a subtitle initializes libass and can read/parse fonts. The
    // synchronous property API performs that work on the caller's UI thread.
    commandAsync("set", args: ["sid", String(trackId)], reportErrors: false, completion: completion)
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
  func addSubtitle(_ path: String, flag: String = "select", title: String? = nil, lang: String? = nil, completion: (() -> Void)? = nil) {
    log("addSubtitle: \(path) flags=\(flag)")
    commandAsync("sub-add", args: trackAddArgs(path, flag: flag, title: title, lang: lang), completion: completion)
  }

  /// Remove a subtitle track by id.
  func removeSubtitle(_ trackId: Int) {
    command("sub-remove", args: [String(trackId)])
  }

  /// Reload current subtitles (useful after font changes).
  func reloadSubtitles(completion: (() -> Void)? = nil) {
    commandAsync("sub-reload", completion: completion)
  }

  /// Load an external audio file (local path or URL). `flag` defaults to
  /// "select" so it becomes the active audio track. Pass "auto" to add without
  /// selecting (then use setAudioTrack).
  func addAudio(_ path: String, flag: String = "select", title: String? = nil, lang: String? = nil, completion: (() -> Void)? = nil) {
    log("addAudio: \(path) flags=\(flag)")
    commandAsync("audio-add", args: trackAddArgs(path, flag: flag, title: title, lang: lang), completion: completion)
  }

  /// Remove an audio track by id.
  func removeAudio(_ trackId: Int) {
    command("audio-remove", args: [String(trackId)])
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

  func setPropertyStringAsync(_ name: String, _ value: String, completion: @escaping () -> Void) {
    commandAsync("set", args: [name, value], reportErrors: false, completion: completion)
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
    nowPlaying?.invalidate()
    nowPlaying = nil
    stopProgressTimer()
    cancelPendingCommands()
    if let mpv = mpv {
      log("Destroying mpv...")
      mpv_set_wakeup_callback(mpv, nil, nil)
      self.mpv = nil
      // Shutdown may wait for network workers; serialize it after event readers.
      // mpv's wid is an unretained layer pointer, so retain it through shutdown.
      let surface = metalLayer
      let context = wakeupContext
      wakeupContext = nil
      queue.async {
        withExtendedLifetime((surface, context)) { mpv_terminate_destroy(mpv) }
      }
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
    func bundledFont(in bundle: Bundle) -> String? {
      if let url = bundle.url(forResource: "ExpoMpvFonts", withExtension: "bundle"),
         let fonts = Bundle(url: url),
         let path = fonts.path(forResource: fontFileName, ofType: fontFileExt) {
        return path
      }
      // Support applications built before the dedicated font resource bundle.
      return bundle.path(forResource: fontFileName, ofType: fontFileExt)
    }
    for bundle in Bundle.allBundles {
      if let path = bundledFont(in: bundle) {
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
             let path = bundledFont(in: bundle) {
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

  private func withCommandArguments(
    _ command: String, args: [String],
    _ perform: (UnsafeMutablePointer<UnsafePointer<CChar>?>?) -> Int32
  ) -> Int32 {
    let strings = ([command] + args).map { strdup($0) }
    defer { strings.forEach { free($0) } }
    var pointers = strings.map { UnsafePointer($0) } + [nil]
    return pointers.withUnsafeMutableBufferPointer { perform($0.baseAddress) }
  }

  // These commands only schedule playback changes. Keep their ordering with
  // subsequent property writes (pause, track selection, etc.) synchronous.
  private func command(_ command: String, args: [String] = []) {
    guard let mpv = mpv else { return }
    let result = withCommandArguments(command, args: args) { mpv_command(mpv, $0) }
    reportCommandResult(command, result: result)
  }

  // External track commands can wait on HTTP/TLS for seconds. Queue the command
  // in libmpv and report its actual result via MPV_EVENT_COMMAND_REPLY instead.
  private func commandAsync(_ command: String, args: [String] = [], reportErrors: Bool = true, completion: (() -> Void)? = nil) {
    guard let mpv = mpv else {
      completion?()
      return
    }
    let commandID = nextCommandID
    nextCommandID += 1
    pendingCommands[commandID] = PendingCommand(name: command, completion: completion, reportErrors: reportErrors)
    let result = withCommandArguments(command, args: args) { mpv_command_async(mpv, commandID, $0) }
    if result < 0 {
      pendingCommands.removeValue(forKey: commandID)
      reportCommandResult(command, result: result, reportErrors: reportErrors)
      completion?()
    }
  }

  private func cancelPendingCommands() {
    let commands = pendingCommands
    pendingCommands.removeAll()
    if let mpv = mpv {
      for commandID in commands.keys { mpv_abort_async_command(mpv, commandID) }
    }
    // Settle callers on cancellation too; an obsolete reply must not resolve
    // twice or leave an awaiting JS caller pending after the view goes away.
    for command in commands.values { command.completion?() }
  }

  private func reportCommandResult(_ command: String, result: Int32, reportErrors: Bool = true) {
    if result < 0 {
      let errStr = String(cString: mpv_error_string(result))
      log("ERROR: command '\(command)' failed: \(errStr) (\(result))")
      if reportErrors { onError(["error": "Command '\(command)' failed: \(errStr)"]) }
    } else {
      log("Command OK: \(command)")
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

/// One system media owner per process. A retiring view cannot clear its successor.
private final class ExpoMpvNowPlayingController {
  private static weak var owner: ExpoMpvNowPlayingController?
  private weak var player: ExpoMpvView?
  private var commands: [(MPRemoteCommand, Any)] = []
  private var observers: [NSObjectProtocol] = []
  private var resumeAfterInterruption = false
  private var artworkURL: String?
  private var artworkTask: URLSessionDownloadTask?
  private var artwork: MPMediaItemArtwork?
  private var latestInfo: [String: Any] = [:]

  init(player: ExpoMpvView) {
    self.player = player
    Self.owner?.invalidate()
    Self.owner = self
    UIApplication.shared.beginReceivingRemoteControlEvents()
    activateAudioSession()
    let center = MPRemoteCommandCenter.shared()
    bind(center.playCommand) { player in player.play() }
    bind(center.pauseCommand) { player in player.pause() }
    bind(center.togglePlayPauseCommand) { player in player.togglePlay() }
    bind(center.stopCommand) { player in player.stop() }
    center.changePlaybackPositionCommand.isEnabled = true
    let token = center.changePlaybackPositionCommand.addTarget { [weak self] event in
      guard let self, Self.owner === self, self.player != nil,
            let position = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
      DispatchQueue.main.async { [weak self] in
        guard let self, Self.owner === self else { return }
        self.player?.seekTo(position.positionTime)
      }
      return .success
    }
    commands.append((center.changePlaybackPositionCommand, token))
    let notifications = NotificationCenter.default
    observers.append(notifications.addObserver(forName: AVAudioSession.interruptionNotification,
      object: nil, queue: .main) { [weak self] notification in self?.interrupted(notification) })
    observers.append(notifications.addObserver(forName: AVAudioSession.routeChangeNotification,
      object: nil, queue: .main) { [weak self] notification in
        guard let self, Self.owner === self,
              let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
        self.resumeAfterInterruption = false
        self.player?.pause()
      })
  }

  private func bind(_ command: MPRemoteCommand, action: @escaping (ExpoMpvView) -> Void) {
    command.isEnabled = true
    let token = command.addTarget { [weak self] _ in
      guard let self, Self.owner === self, self.player != nil else { return .commandFailed }
      DispatchQueue.main.async { [weak self] in
        guard let self, Self.owner === self, let player = self.player else { return }
        action(player)
      }
      return .success
    }
    commands.append((command, token))
  }

  func activateAudioSession() {
    guard Self.owner === self else { return }
    do {
      let audio = AVAudioSession.sharedInstance()
      try audio.setCategory(.playback, mode: .moviePlayback)
      try audio.setActive(true)
    } catch { NSLog("[ExpoMpv] Unable to activate playback audio session: %@", String(describing: error)) }
  }

  func update(metadata: [String: String], playback: [String: Any], ended: Bool) {
    guard Self.owner === self else { return }
    updateArtwork(metadata["artwork"])
    let playing = playback["isPlaying"] as? Bool == true && !ended
    let position = playback["position"] as? Double ?? 0
    let duration = playback["duration"] as? Double ?? 0
    let speed = playback["speed"] as? Double ?? 1
    latestInfo = [
      MPMediaItemPropertyTitle: metadata["title"] ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Media",
      MPMediaItemPropertyArtist: metadata["artist"] ?? "",
      MPMediaItemPropertyAlbumTitle: metadata["albumTitle"] ?? "",
      MPMediaItemPropertyPlaybackDuration: duration.isFinite ? max(0, duration) : 0,
      MPNowPlayingInfoPropertyElapsedPlaybackTime: position.isFinite ? max(0, position) : 0,
      MPNowPlayingInfoPropertyPlaybackRate: playing ? speed : 0,
      MPNowPlayingInfoPropertyDefaultPlaybackRate: speed,
      MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
    ]
    latestInfo[MPMediaItemPropertyArtwork] = artwork
    MPNowPlayingInfoCenter.default().nowPlayingInfo = latestInfo
    // Also publish explicit state for Simulator/Mac Catalyst, where the system
    // cannot infer native AudioUnit playback from a physical audio session.
    MPNowPlayingInfoCenter.default().playbackState = playing ? .playing : .paused
  }

  private func updateArtwork(_ value: String?) {
    let value = value?.isEmpty == false ? value : nil
    guard artworkURL != value else { return }
    artworkURL = value
    artwork = nil
    artworkTask?.cancel()
    guard let value, let url = URL(string: value),
          ["http", "https", "file"].contains(url.scheme?.lowercased() ?? "") else { return }
    if url.isFileURL {
      DispatchQueue.global(qos: .utility).async { [weak self] in
        if let image = Self.loadArtwork(url) { self?.publishArtwork(image, url: value) }
      }
      return
    }
    var request = URLRequest(url: url)
    request.timeoutInterval = 10
    artworkTask = URLSession.shared.downloadTask(with: request) { [weak self] file, response, error in
      guard error == nil, let file,
            (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
            let image = Self.loadArtwork(file) else { return }
      self?.publishArtwork(image, url: value)
    }
    artworkTask?.resume()
  }

  private static func loadArtwork(_ file: URL) -> UIImage? {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
          let size = attributes[.size] as? NSNumber, size.intValue <= 8 * 1024 * 1024,
          let source = CGImageSourceCreateWithURL(file as CFURL, nil),
          let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 512,
          ] as CFDictionary) else { return nil }
    return UIImage(cgImage: image)
  }

  private func publishArtwork(_ image: UIImage, url: String) {
    DispatchQueue.main.async { [weak self] in
      guard let self, Self.owner === self, self.artworkURL == url else { return }
      let artwork = MPMediaItemArtwork(boundsSize: image.size) { requested in
        guard requested.width > 0, requested.height > 0 else { return image }
        let ratio = min(1, requested.width / image.size.width, requested.height / image.size.height)
        let size = CGSize(width: image.size.width * ratio, height: image.size.height * ratio)
        return UIGraphicsImageRenderer(size: size).image { _ in
          image.draw(in: CGRect(origin: .zero, size: size))
        }
      }
      self.artwork = artwork
      self.latestInfo[MPMediaItemPropertyArtwork] = artwork
      MPNowPlayingInfoCenter.default().nowPlayingInfo = self.latestInfo
    }
  }

  private func interrupted(_ notification: Notification) {
    guard Self.owner === self, let player,
          let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
          let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
    if type == .began {
      let wasPlaying = player.getPlaybackInfo()["isPlaying"] as? Bool == true
      player.pause()
      resumeAfterInterruption = wasPlaying
    } else {
      let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
      let resume = resumeAfterInterruption && AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume)
      resumeAfterInterruption = false
      if resume { player.play() }
    }
  }

  func cancelInterruptionResume() { resumeAfterInterruption = false }

  func invalidate() {
    artworkTask?.cancel()
    artworkTask = nil
    artworkURL = nil
    artwork = nil
    latestInfo = [:]
    commands.forEach { $0.0.removeTarget($0.1) }
    commands.removeAll()
    observers.forEach { NotificationCenter.default.removeObserver($0) }
    observers.removeAll()
    if Self.owner === self {
      Self.owner = nil
      MPNowPlayingInfoCenter.default().playbackState = .stopped
      MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
      UIApplication.shared.endReceivingRemoteControlEvents()
    }
    // libmpv also uses the shared audio session. Its asynchronous teardown can
    // overlap a new player, so never deactivate the process-wide session here.
  }
}

// MARK: - MetalLayer

private class MetalLayer: CAMetalLayer {
  // MoltenVK resets this when it creates a swapchain. The old drawable can
  // remain visible during UIKit rotation; stretching it would deform the video.
  override var contentsGravity: CALayerContentsGravity {
    get { super.contentsGravity }
    set { super.contentsGravity = .resizeAspect }
  }

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
