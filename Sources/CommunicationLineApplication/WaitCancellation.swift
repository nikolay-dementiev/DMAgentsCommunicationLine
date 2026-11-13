import Foundation

/// Lets the caller of a parked `wait` end it early, for instance because the client went away.
///
/// The wait that holds the token registers a wake-up; `cancel()` runs it, so the wait notices at
/// once instead of sitting out its time. A cancellation that comes before the wait has registered
/// is remembered and the wait ends as soon as it looks.
public final class WaitCancellation: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false
  private var wake: (() -> Void)?

  public init() {}

  public var isCancelled: Bool { lock.withLock { cancelled } }

  /// Ends the wait that holds this token. Safe to call more than once and from any thread.
  public func cancel() {
    let action: (() -> Void)? = lock.withLock {
      cancelled = true
      return wake
    }
    action?()
  }

  /// Registers what wakes the parked wait. Runs it at once when `cancel()` came first.
  func onCancel(_ wake: @escaping () -> Void) {
    let runNow: Bool = lock.withLock {
      self.wake = wake
      return cancelled
    }
    if runNow { wake() }
  }
}
