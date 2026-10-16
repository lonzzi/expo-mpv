import UIKit
import Foundation
import ExpoModulesCore

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
  func application(_ application: UIApplication, configurationForConnecting session: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
    let configuration = UISceneConfiguration(name: "Probe", sessionRole: session.role)
    configuration.delegateClass = ProbeSceneDelegate.self
    return configuration
  }
}

class ProbeSceneDelegate: UIResponder, UIWindowSceneDelegate {
  var window: UIWindow?
  func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
    guard let scene = scene as? UIWindowScene else { return }
    window = UIWindow(windowScene: scene)
    window?.rootViewController = ProbeController()
    window?.makeKeyAndVisible()
  }
}

class ProbeController: UIViewController {
  var player: ExpoMpvView!
  weak var retiredPlayer: ExpoMpvView?
  let status = UILabel()
  let heartbeat = UILabel()
  let slow = UIButton(type: .system)
  let pause = UIButton(type: .system)
  let back = UIButton(type: .system)
  var timer: Timer?
  var lastTick = 0.0
  var maxGap = 0.0
  var started = 0.0
  var events: [[String: Any]] = []
  var didRun = false
  var metrics: [String: Any] = [:]
  func argument(_ key: String, default fallback: String) -> String {
    let args = ProcessInfo.processInfo.arguments
    guard let i = args.firstIndex(of: key), args.indices.contains(i + 1) else { return fallback }
    return args[i + 1]
  }
  func url(_ path: String) -> String {
    "http://127.0.0.1:\(argument("--port", default: "18848"))/\(path)?run=\(argument("--run", default: "manual"))"
  }
  let mode: String = {
    let args = ProcessInfo.processInfo.arguments
    guard let i = args.firstIndex(of: "--scenario"), args.indices.contains(i + 1) else { return "subtitle" }
    return args[i + 1]
  }()

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    player = ExpoMpvView(appContext: nil)
    player.frame = CGRect(x: 0, y: 70, width: view.bounds.width, height: 240)
    player.autoresizingMask = [.flexibleWidth]
    view.addSubview(player)
    status.text = "Waiting for local playback"
    status.numberOfLines = 3
    heartbeat.text = "Main-thread heartbeat"
    for (button, title, action) in [(slow, "Load slow external track", #selector(loadSlow)), (pause, "Pause / resume", #selector(togglePause)), (back, "Back", #selector(goBack))] {
      button.setTitle(title, for: .normal)
      button.addTarget(self, action: action, for: .touchUpInside)
    }
    let stack = UIStackView(arrangedSubviews: [status, heartbeat, slow, pause, back])
    stack.axis = .vertical
    stack.spacing = 16
    stack.frame = CGRect(x: 24, y: 330, width: view.bounds.width - 48, height: 310)
    stack.autoresizingMask = [.flexibleWidth]
    view.addSubview(stack)
    player.onLoad.handler = { [weak self] _ in
      guard let self else { return }
      self.record("loaded")
      guard !self.didRun else { return }
      self.didRun = true
      self.player.setLooping(true)
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        if self.mode == "reload" {
          self.player.addSubtitle(self.url("reload.srt"), title: "Reload subtitle")
          self.waitForSubtitle(attempt: 0)
        } else {
          self.runScenario()
        }
      }
    }
    player.onError.handler = { [weak self] data in self?.record("error", data) }
    player.onEnd.handler = { [weak self] data in self?.record("end", data) }
    player.loadFile(Bundle.main.url(forResource: "fixture", withExtension: "mp4")!.path)
  }

  func record(_ event: String, _ data: [String: Any] = [:]) {
    events.append(["event": event, "elapsed": started > 0 ? CACurrentMediaTime() - started : -1, "data": data])
  }

  func waitForSubtitle(attempt: Int) {
    if player.getTrackList().contains(where: { $0["type"] as? String == "sub" }) {
      runScenario()
    } else if attempt < 40 {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.waitForSubtitle(attempt: attempt + 1) }
    } else {
      metrics["preparationFailed"] = true
      finish()
    }
  }

  @objc func loadSlow() {
    record("load-call")
    let completion: () -> Void = {
      self.record("load-completion")
      self.metrics["completionCount"] = (self.metrics["completionCount"] as? Int ?? 0) + 1
    }
    if mode == "audio" {
      player.addAudio(url("slow.wav"), flag: "auto", title: "Slow audio", completion: completion)
    } else if mode == "reload" {
      player.reloadSubtitles(completion: completion)
    } else if mode == "error" {
      player.addSubtitle(url("missing.srt"), title: "Missing subtitle", completion: completion)
    } else {
      player.addSubtitle(url("slow.srt"), flag: "auto", title: "Slow subtitle", completion: completion)
    }
    metrics["commandReturnSeconds"] = CACurrentMediaTime() - started
    record("load-return")
  }

  @objc func togglePause() {
    record("pause-handler")
    player.pause()
    metrics["paused"] = !(player.getPlaybackInfo()["isPlaying"] as? Bool ?? true)
    record("pause-return")
  }

  @objc func goBack() {
    record("back-handler")
    if mode != "destroy" { player.stop() }
    player.removeFromSuperview()
    player.destroy()
    retiredPlayer = player
    player = nil
    record("back-return")
    status.text = "Back completed"
  }

  func runScenario() {
    started = CACurrentMediaTime()
    lastTick = started
    status.text = "Testing \(mode): delayed HTTP response = 4 seconds"
    timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
      guard let self else { return }
      let now = CACurrentMediaTime()
      self.maxGap = max(self.maxGap, now - self.lastTick)
      self.lastTick = now
      self.heartbeat.text = "Heartbeat \(String(format: "%.2f", now - self.started))s"
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.pause.sendActions(for: .touchUpInside) }
    if mode == "back" || mode == "destroy" {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { self.back.sendActions(for: .touchUpInside) }
    }
    if mode == "replace" {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
        self.record("replace-handler")
        self.player.loadFile(Bundle.main.url(forResource: "fixture", withExtension: "mp4")!.path)
        self.record("replace-return")
      }
    }
    if ["subtitle", "audio", "reload", "error"].contains(mode) {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        self.record("resume-handler")
        self.player.play()
        self.metrics["resumed"] = self.player.getPlaybackInfo()["isPlaying"]
        self.record("resume-return")
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
        self.record("seek-handler")
        self.player.seekTo(8)
        self.record("seek-return")
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
        self.metrics["seekPosition"] = self.player.getPlaybackInfo()["position"]
      }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + (mode == "error" ? 1.5 : 6)) { self.finish() }
    slow.sendActions(for: .touchUpInside)
  }

  func finish() {
    timer?.invalidate()
    metrics["scenario"] = mode
    metrics["maxMainThreadGapSeconds"] = maxGap
    if mode == "back" || mode == "destroy" {
      metrics["viewReleased"] = retiredPlayer == nil
    }
    if mode != "back" && mode != "destroy" {
      metrics["tracks"] = player.getTrackList()
      player.setSpeed(1.25)
      player.setVolume(55)
      player.setMuted(true)
      metrics["muted"] = player.getPlaybackInfo()["muted"]
      player.setMuted(false)
      metrics["playback"] = player.getPlaybackInfo()
      if let track = player.getTrackList().first(where: { $0["isExternal"] as? Bool == true }),
         let id = track["id"] as? Int {
        if mode == "audio" {
          player.setAudioTrack(id)
          metrics["selectedExternalID"] = player.getCurrentTrackIds()["aid"]
          player.removeAudio(id)
        } else {
          player.setSubtitleTrack(0)
          metrics["subtitleOffID"] = player.getCurrentTrackIds()["sid"]
          player.setSubtitleTrack(id)
          metrics["selectedExternalID"] = player.getCurrentTrackIds()["sid"]
          player.removeSubtitle(id)
        }
        metrics["tracksAfterRemoval"] = player.getTrackList()
      }
    }
    status.text = "Finished: max UI gap \(String(format: "%.3f", maxGap))s"
    metrics["events"] = events
    let data = try! JSONSerialization.data(withJSONObject: metrics, options: [.prettyPrinted, .sortedKeys])
    try! data.write(to: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("\(mode).json"))
    print("COMMAND_PROBE_DONE \(mode) gap=\(maxGap)")
  }
}
