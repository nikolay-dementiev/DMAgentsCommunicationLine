import Foundation

/// Keeps a client that is refused over and over from filling the activity log: refused requests
/// with the same outcome are let through to the log once per window, and the first one after the
/// window says how many were left out. Every peer the service serves runs as the service's own
/// user, so the outcome is the whole key. The state lives in memory only.
public final class RefusalThrottle: @unchecked Sendable {
  private struct Window {
    var opened: Date
    var suppressed: Int
  }

  private let lock = NSLock()
  private var windows: [String: Window] = [:]

  public init() {}

  /// The number of refusals left out since the last record of `outcome`, when this one is to be
  /// recorded; nil when it is to be left out. A window of zero or less records everything.
  public func admit(outcome: String, at instant: Date, window: TimeInterval) -> Int? {
    guard window > 0 else { return 0 }
    return lock.withLock {
      guard var current = windows[outcome], instant.timeIntervalSince(current.opened) < window
      else {
        let carried = windows[outcome]?.suppressed ?? 0
        windows[outcome] = Window(opened: instant, suppressed: 0)
        return carried
      }
      current.suppressed += 1
      windows[outcome] = current
      return nil
    }
  }
}
