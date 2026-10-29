import ExpoModulesCore
import AVFoundation
import MediaPlayer

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
  func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                   options: UIScene.ConnectionOptions) -> UISceneConfiguration {
    let config = UISceneConfiguration(name: "Media Session", sessionRole: session.role)
    config.delegateClass = MediaSceneDelegate.self
    return config
  }
}

class MediaSceneDelegate: UIResponder, UIWindowSceneDelegate {
  var window: UIWindow?
  func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
    guard let scene = scene as? UIWindowScene else { return }
    window = UIWindow(windowScene: scene)
    window?.rootViewController = MediaProbeController()
    window?.makeKeyAndVisible()
  }
}

class MediaProbeController: UIViewController {
  private let player = ExpoMpvView(appContext: nil)
  private var samples: [[String: Any]] = []
  private var errors: [String] = []
  private var loads = 0
  private var timer: Timer?
  private var interruptionChecked = false
  private var artworkChecked = false

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .black
    player.showNotificationControls = true
    player.metadata = ["title": "Background episode", "artist": "NekoFin regression",
                       "artwork": artworkURL("artwork")]
    player.onLoad.handler = { [weak self] _ in
      guard let self else { return }
      self.loads += 1
      self.player.setLooping(true)
      DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.checkInterruption() }
      DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.checkArtwork() }
    }
    player.onError.handler = { [weak self] error in self?.errors.append(String(describing: error)) }
    view.addSubview(player)
    player.sourceToLoad = Bundle.main.url(forResource: "fixture", withExtension: "mp4")!.path
    player.loadSourceIfNeeded()
    timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.sample() }
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    player.frame = view.bounds
  }

  private func checkInterruption() {
    NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: nil,
      userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
      if self.player.getPlaybackInfo()["isPlaying"] as? Bool != false {
        self.errors.append("Interruption did not pause native playback")
      }
      NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: nil,
        userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
                   AVAudioSessionInterruptionOptionKey: AVAudioSession.InterruptionOptions.shouldResume.rawValue])
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
        if self.player.getPlaybackInfo()["isPlaying"] as? Bool != true {
          self.errors.append("Eligible interruption did not resume native playback")
        }
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: nil,
          userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
        self.player.pause() // An explicit user pause must cancel automatic resume.
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: nil,
          userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
                     AVAudioSessionInterruptionOptionKey: AVAudioSession.InterruptionOptions.shouldResume.rawValue])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
          if self.player.getPlaybackInfo()["isPlaying"] as? Bool != false {
            self.errors.append("Interruption resumed after an explicit user pause")
          }
          self.player.play()
          self.interruptionChecked = true
        }
      }
    }
  }

  private func sample() {
    let info = player.getPlaybackInfo()
    let now = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
    samples.append([
      "time": Date().timeIntervalSince1970,
      "state": UIApplication.shared.applicationState.rawValue,
      "position": info["position"] ?? 0,
      "playing": info["isPlaying"] ?? false,
      "title": now[MPMediaItemPropertyTitle] ?? "",
      "rate": now[MPNowPlayingInfoPropertyPlaybackRate] ?? -1,
      "audioCategory": AVAudioSession.sharedInstance().category.rawValue,
      "audioOptions": AVAudioSession.sharedInstance().categoryOptions.rawValue,
      "artworkWidth": (now[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork)?.bounds.width ?? 0,
      "artworkHeight": (now[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork)?.bounds.height ?? 0,
    ])
    if samples.count > 1200 { samples.removeFirst() }
    let result: [String: Any] = ["loads": loads, "errors": errors, "samples": samples,
                               "interruptionChecked": interruptionChecked, "artworkChecked": artworkChecked]
    let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("media-session.json")
    try? JSONSerialization.data(withJSONObject: result).write(to: url, options: .atomic)
  }

  private func checkArtwork() {
    let artwork = MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork
    if artwork?.bounds.width != 512 || artwork?.bounds.height != 256 {
      errors.append("Artwork was not loaded and resized in Now Playing")
    }
    player.metadata.removeValue(forKey: "artwork")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
      if MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork] != nil {
        self.errors.append("Removing artwork left the previous cover in Now Playing")
      }
      self.player.metadata["artwork"] = self.artworkURL("artwork-next")
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
        let next = MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork
        if next?.bounds.width != 256 || next?.bounds.height != 512 {
          self.errors.append("Now Playing retained the old artwork after a metadata change")
        }
        self.artworkChecked = true
      }
    }
  }

  private func artworkURL(_ name: String) -> String {
    if let base = ProcessInfo.processInfo.environment["EXPO_MPV_ARTWORK_BASE_URL"],
       let url = URL(string: base) {
      return url.appendingPathComponent(name + ".webp").absoluteString
    }
    return Bundle.main.url(forResource: name, withExtension: "webp")!.absoluteString
  }
}
