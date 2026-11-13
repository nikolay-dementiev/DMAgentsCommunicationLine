import CommunicationLineDomain
import Foundation

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

  /// Runs cleanup once. A failure is remembered and thrown again.
  @discardableResult
  public func run() throws -> CleanupResult {
    let started = clock.now()
    do {
      let result = try service.run()
      remember(CleanupReport(at: started, outcome: .success(result)))
      return result
    } catch {
      remember(
        CleanupReport(at: started, outcome: .failure(CleanupFailure(description: "\(error)"))))
      throw error
    }
  }

  private func remember(_ new: CleanupReport) {
    lock.lock()
    report = new
    lock.unlock()
  }
}
