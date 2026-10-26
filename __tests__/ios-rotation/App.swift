import ExpoModulesCore
import UIKit
import QuartzCore

@main class AppDelegate: UIResponder, UIApplicationDelegate {
  func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                   options: UIScene.ConnectionOptions) -> UISceneConfiguration {
    let config = UISceneConfiguration(name: "Rotation", sessionRole: session.role)
    config.delegateClass = SceneDelegate.self
    return config
  }
}
class SceneDelegate: UIResponder, UIWindowSceneDelegate {
  var window: UIWindow?
  func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
    guard let scene = scene as? UIWindowScene else { return }
    window = UIWindow(windowScene: scene)
    window?.rootViewController = RotationProbeController()
    window?.makeKeyAndVisible()
  }
}
class RotationProbeController: UIViewController {
  private let player = ExpoMpvView(appContext: nil)
  private var mask: UIInterfaceOrientationMask = .portrait
  private var samples: [[String: Any]] = []
  private var events: [[String: Any]] = []
  private var displayLink: CADisplayLink?
  private var started = false
  private var origin = CACurrentMediaTime()
  private var loadCount = 0
  private var scheduled = false
  private var errors: [[String: Any]] = []
  override var supportedInterfaceOrientations: UIInterfaceOrientationMask { mask }
  override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation { .portrait }
  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .black
    view.addSubview(player)
    player.onLoad.handler = { [weak self] _ in self?.loadCount += 1 }
    player.onError.handler = { [weak self] error in self?.errors.append(error) }
    player.onProgress.handler = { [weak self] data in
      guard let self, !self.scheduled, let position = data["position"] as? Double, position > 0 else { return }
      self.scheduled = true
      self.events.append(["kind": "firstProgress", "ms": self.elapsed()])
      self.scheduleRotations()
    }
  }
  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    player.frame = view.bounds
  }
  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    guard !started else { return }
    started = true
    origin = CACurrentMediaTime()
    player.loadFile(Bundle.main.url(forResource: "fixture", withExtension: "mp4")!.path)
    displayLink = CADisplayLink(target: self, selector: #selector(sample))
    displayLink?.preferredFramesPerSecond = 60
    displayLink?.add(to: .main, forMode: .common)
  }
  private func scheduleRotations() {
    for index in 0..<4 {
      DispatchQueue.main.asyncAfter(deadline: .now() + 1 + Double(index) * 2) {
        if index == 2 { self.player.pause() }
        self.mask = index.isMultiple(of: 2) ? .landscapeRight : .portrait
        self.events.append(["kind": "request", "index": index, "ms": self.elapsed(), "paused": index >= 2])
        self.setNeedsUpdateOfSupportedInterfaceOrientations()
        self.view.window?.windowScene?.requestGeometryUpdate(.iOS(interfaceOrientations: self.mask)) { error in
          self.errors.append(["rotation": error.localizedDescription])
        }
      }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 9) { self.finish() }
  }
  override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
    super.viewWillTransition(to: size, with: coordinator)
    events.append(["kind": "begin", "ms": elapsed(), "width": size.width, "height": size.height])
    coordinator.animate(alongsideTransition: nil) { _ in
      self.events.append(["kind": "end", "ms": self.elapsed()])
    }
  }
  private func elapsed() -> Double { (CACurrentMediaTime() - origin) * 1000 }
  @objc private func sample() {
    guard let surface = player.layer.sublayers?.first(where: { $0 is CAMetalLayer }) as? CAMetalLayer else { return }
    let pb = player.layer.presentation()?.bounds ?? player.bounds
    let mb = surface.presentation()?.bounds ?? surface.bounds
    samples.append(["ms": elapsed(), "bounds": [player.bounds.width, player.bounds.height],
                    "presentation": [pb.width, pb.height], "metal": [surface.bounds.width, surface.bounds.height],
                    "metalPresentation": [mb.width, mb.height],
                    "drawable": [surface.drawableSize.width, surface.drawableSize.height],
                    "gravity": surface.contentsGravity.rawValue])
  }
  private func finish() {
    displayLink?.invalidate()
    player.pause()
    let result: [String: Any] = ["finished": true, "loads": loadCount, "errors": errors,
                               "events": events, "samples": samples]
    let data = try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    try! data.write(to: directory.appendingPathComponent("rotation.json"))
  }
}
