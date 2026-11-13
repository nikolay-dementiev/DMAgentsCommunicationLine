import CommunicationLineDomain
import Foundation

/// A cleanup that ran but whose commit the caller has not seen yet.
public struct CleanupAttempt: Sendable {
  public let result: CleanupResult
  fileprivate let report: CleanupReport
}

/// Runs cleanup for the service and remembers the last run, whether it came from the schedule or
/// from the owner. The memory lasts as long as the process.
public final class CleanupRunner: @unchecked Sendable {
  private let service: CleanupService
  private let clock: any WallClock
  private let lock = NSLock()
  private var report: CleanupReport?

  public init(service: CleanupService, clock: any WallClock) {
    self.service = service
    self.clock = clock
  }

  /// The last run, or nil when none has happened since the service started.
  public var latest: CleanupReport? {
    lock.lock()
    defer { lock.unlock() }
    return report
  }

  /// Runs cleanup once, in its own transaction. A failure is remembered and thrown again.
  @discardableResult
  public func run() throws -> CleanupResult {
    let finished = try attempt()
    remember(finished)
    return finished.result
  }

  /// Runs cleanup without remembering that it succeeded, for a caller whose own transaction is
  /// still open: the deletions are only real once that transaction commits, and the caller then
  /// passes the attempt to ``remember(_:)``. A failure is remembered at once and thrown again.
  public func attempt() throws -> CleanupAttempt {
    let started = clock.now()
    do {
      let result = try service.run()
      return CleanupAttempt(
        result: result, report: CleanupReport(at: started, outcome: .success(result)))
    } catch {
      store(
        CleanupReport(at: started, outcome: .failure(CleanupFailure(description: "\(error)"))))
      throw error
    }
  }

  public func remember(_ attempt: CleanupAttempt) {
    store(attempt.report)
  }

  private func store(_ new: CleanupReport) {
    lock.lock()
    report = new
    lock.unlock()
  }
}
