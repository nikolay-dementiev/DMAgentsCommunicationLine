import Foundation

/// Runs actions at given moments on a thread of its own. The service cuts connections at their
/// deadlines with it instead of with the shared dispatch pool, whose workers can all be busy or
/// blocked: a deadline that waits for a free worker is not a deadline.
final class DeadlineTimer: @unchecked Sendable {
  private struct Entry {
    let order: UInt64
    let moment: Date
    let action: @Sendable () -> Void
  }

  private let condition = NSCondition()
  private var entries: [Entry] = []
  private var nextOrder: UInt64 = 0
  private var isStopped = false
  private var hasEnded = false

  init() {
    let thread = Thread { [self] in run() }
    thread.name = "commline-deadlines"
    thread.start()
  }

  /// Runs `action` on the timer thread once `delay` seconds have passed. Actions must be short:
  /// they run one after another.
  func schedule(after delay: TimeInterval, _ action: @escaping @Sendable () -> Void) {
    condition.lock()
    defer { condition.unlock() }
    guard !isStopped else { return }
    nextOrder += 1
    entries.append(
      Entry(order: nextOrder, moment: Date().addingTimeInterval(delay), action: action))
    condition.broadcast()
  }

  /// Stops the thread and drops what is still waiting. Returns when the thread has ended.
  func stop() {
    condition.lock()
    isStopped = true
    entries.removeAll()
    condition.broadcast()
    while !hasEnded { condition.wait() }
    condition.unlock()
  }

  private func run() {
    condition.lock()
    while !isStopped {
      guard let soonest = entries.min(by: { ($0.moment, $0.order) < ($1.moment, $1.order) })
      else {
        condition.wait()
        continue
      }
      if soonest.moment <= Date() {
        entries.removeAll { $0.order == soonest.order }
        condition.unlock()
        soonest.action()
        condition.lock()
      } else {
        _ = condition.wait(until: soonest.moment)
      }
    }
    hasEnded = true
    condition.broadcast()
    condition.unlock()
  }
}
