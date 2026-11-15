import CommunicationLineDomain
import Foundation

/// Runs cleanup for the service and remembers the last run, whether it came from the schedule or
/// from the owner. The memory lasts as long as the process.
public final class CleanupRunner: @unchecked Sendable {
  private let service: CleanupService
  private let clock: any WallClock
  private let lock = NSLock()
  private var report: CleanupReport?
  private var generation = 0

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

  /// One run, as the runner remembers it: what it did and which memory slot it holds.
  public struct Run: Sendable {
    public let result: CleanupResult
    fileprivate let generation: Int
  }

  /// Runs cleanup once, in its own transaction, and remembers the run only after that transaction
  /// has committed. A failure is remembered and thrown again.
  @discardableResult
  public func run() throws -> CleanupResult { try perform().result }

  /// Like `run()`, and also names the run, so that its missing activity record can be noted on it
  /// and on no other run.
  public func perform() throws -> Run {
    let started = clock.now()
    do {
      let result = try service.run()
      return Run(
        result: result, generation: store(CleanupReport(at: started, outcome: .success(result))))
    } catch {
      store(
        CleanupReport(at: started, outcome: .failure(CleanupFailure(description: "\(error)"))))
      throw error
    }
  }

  /// Marks a run as one whose activity record is missing. The run itself stays as it was: its
  /// deletions are committed. A newer run has replaced it in the memory when the memory no longer
  /// holds it, and then there is nothing to mark.
  public func noteRecordFailure(of run: Run) {
    lock.lock()
    defer { lock.unlock() }
    guard run.generation == generation, let last = report else { return }
    report = CleanupReport(at: last.at, outcome: last.outcome, isRecorded: false)
  }

  @discardableResult
  private func store(_ new: CleanupReport) -> Int {
    lock.lock()
    defer { lock.unlock() }
    report = new
    generation += 1
    return generation
  }
}
