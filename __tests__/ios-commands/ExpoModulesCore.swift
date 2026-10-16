@_exported import UIKit

public class AppContext {}
open class ExpoView: UIView {
  public required init(appContext: AppContext? = nil) { super.init(frame: .zero) }
  @available(*, unavailable)
  public required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}
public final class EventDispatcher {
  public var handler: (([String: Any]) -> Void)?
  public init() {}
  public func callAsFunction(_ event: [String: Any]) { handler?(event) }
}
