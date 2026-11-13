import CommunicationLineDomain
import Foundation

/// Counts the waits that are parked, overall and per principal, so that a few callers cannot hold
/// every thread of the service.
public final class WaitQuota: @unchecked Sendable {
  private let lock = NSLock()
  private var perPrincipal: [PrincipalID: Int] = [:]
  private var total = 0

  public init() {}

  /// The waits parked right now.
  public var activeCount: Int {
    lock.withLock { total }
  }

  /// Takes a place for `principal`, or throws when either limit is already reached. A limit of zero
  /// admits nobody.
  func acquire(principal: PrincipalID, global: Int, perPrincipalLimit: Int) throws {
    try lock.withLock {
      guard total < global, perPrincipal[principal, default: 0] < perPrincipalLimit else {
        throw MessagingError.tooManyWaiters
      }
      total += 1
      perPrincipal[principal, default: 0] += 1
    }
  }

  func release(principal: PrincipalID) {
    lock.withLock {
      total -= 1
      let remaining = perPrincipal[principal, default: 1] - 1
      perPrincipal[principal] = remaining > 0 ? remaining : nil
    }
  }
}
