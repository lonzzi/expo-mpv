import ExpoModulesCore
import UIKit

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
  func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                   options: UIScene.ConnectionOptions) -> UISceneConfiguration {
    let configuration = UISceneConfiguration(name: "Lifecycle", sessionRole: session.role)
    configuration.delegateClass = ProbeSceneDelegate.self
    return configuration
  }
}

class ProbeSceneDelegate: UIResponder, UIWindowSceneDelegate {
  var window: UIWindow?

  func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
             options: UIScene.ConnectionOptions) {
    guard let scene = scene as? UIWindowScene else { return }
    window = UIWindow(windowScene: scene)
    window?.rootViewController = ProbeController()
    window?.makeKeyAndVisible()
  }
}

// Widen the real deallocation window so a foreign-thread wakeup reliably overlaps
// teardown. No callbacks or mpv state are mocked or injected by this subclass.
class RetiringMpvView: ExpoMpvView {
  deinit { Thread.sleep(forTimeInterval: 0.25) }
}

private final class WeakView {
  weak var value: ExpoMpvView?
  init(_ value: ExpoMpvView) { self.value = value }
}

class ProbeController: UIViewController {
  private var player: RetiringMpvView?
  private var retired: [WeakView] = []
  private var created = 0
  private var loaded = 0
  private var firstPositions: [Double] = []
  private var expectedPositions: [Double] = []
  private var errors: [[String: Any]] = []
  private let status = UILabel()
  private let cycleCount: Int = {
    let args = ProcessInfo.processInfo.arguments
    guard let index = args.firstIndex(of: "--cycles"), args.indices.contains(index + 1)
    else { return 40 }
    return Int(args[index + 1]) ?? 40
  }()

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .black
    status.textColor = .white
    status.frame = CGRect(x: 24, y: 40, width: 800, height: 50)
    view.addSubview(status)
    nextCycle()
  }

  private func nextCycle() {
    guard created < cycleCount else {
      DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.writeResult(finished: true) }
      return
    }
    let current = RetiringMpvView(appContext: nil)
    player = current
    created += 1
    let cycle = created
    status.text = "Player lifecycle \(cycle) / \(cycleCount)"
    current.frame = CGRect(x: 0, y: 100, width: view.bounds.width, height: 400)
    let start = cycle.isMultiple(of: 3) ? 0.0 : 2.375
    expectedPositions.append(start)
    let startsPaused = cycle.isMultiple(of: 2)
    if startsPaused { current.pause() }
    var receivedProgress = false
    current.onProgress.handler = { [weak self, weak current] data in
      guard let self, let current, self.player === current, !receivedProgress,
            let position = data["position"] as? Double else { return }
      receivedProgress = true
      if startsPaused { return }
      self.firstPositions.append(position)
      current.pause()
      current.play()
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.retire(cycle: cycle) }
    }
    current.onLoad.handler = { [weak self, weak current] _ in
      guard let self, let current, self.player === current else { return }
      self.loaded += 1
      current.setLooping(true)
      current.setPropertyString("sub-use-margins", "no")
      if startsPaused {
        // Paused players intentionally stop progress events; inspect their decoded frame.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self, weak current] in
          guard let self, let current, self.player === current else { return }
          let info = current.getPlaybackInfo()
          if !receivedProgress {
            self.errors.append(["error": "Paused load did not publish its initial position"])
          }
          self.firstPositions.append(info["position"] as? Double ?? -1)
          if info["isPlaying"] as? Bool != false {
            self.errors.append(["error": "Paused load started playing"])
          }
          current.play()
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.retire(cycle: cycle) }
        }
      }
    }
    current.onError.handler = { [weak self] data in self?.errors.append(data) }
    // Alternate prop order and load before attaching to exercise deferred surfaces.
    let path = Bundle.main.url(forResource: "fixture", withExtension: "mp4")!.path
    if startsPaused {
      current.startPosition = start
      current.sourceToLoad = path
    } else {
      current.sourceToLoad = path
      current.startPosition = start
    }
    current.loadSourceIfNeeded()
    // A later startPosition-only update must neither reload nor change a deferred load.
    current.startPosition = 1
    current.loadSourceIfNeeded()
    view.addSubview(current)
    writeResult(finished: false)
  }

  private func retire(cycle: Int) {
    guard let current = player else { return }
    retired.append(WeakView(current))
    current.removeFromSuperview()
    // Exercise both implicit deinit (navigation/unmount) and explicit, repeated
    // destroy. The implicit path must remain safe while mpv is still playing.
    if cycle.isMultiple(of: 2) {
      current.destroy()
      current.destroy()
    }
    player = nil
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.nextCycle() }
  }

  private func writeResult(finished: Bool) {
    let result: [String: Any] = [
      "finished": finished, "requested": cycleCount, "created": created,
      "loaded": loaded, "retired": retired.count,
      "retainedViews": retired.filter { $0.value != nil }.count, "errors": errors,
      "firstPositions": firstPositions, "expectedPositions": expectedPositions,
    ]
    let data = try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    try! data.write(to: documents.appendingPathComponent("lifecycle.json"), options: .atomic)
    if finished { status.text = "Lifecycle complete: \(loaded) players" }
  }
}
