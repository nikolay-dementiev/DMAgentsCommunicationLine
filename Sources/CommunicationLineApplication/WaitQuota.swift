import CommunicationLineDomain
import Foundation

/// Who has a `wait` parked in the service right now. The state lives in memory only: it is not
/// stored and does not survive a restart, and a waiter that reconnects is listening again.
public protocol ListeningRegistry: Sendable {
  /// When the oldest parked wait of `principal` started, or nil when it has none parked.
  func listeningSince(_ principal: PrincipalID) -> Date?
  /// Every principal with at least one wait parked.
  func listeningPrincipals() -> Set<PrincipalID>
}

/// A place taken by one parked wait; it is given back when that wait ends.
struct WaitPlace {
  fileprivate let number: UInt64
}

/// Counts the waits that are parked, overall and per principal, so that a few callers cannot hold
/// every thread of the service. It also knows since when each principal is listening.
public final class WaitQuota: ListeningRegistry, @unchecked Sendable {
  private let lock = NSLock()
  private var started: [PrincipalID: [UInt64: Date]] = [:]
  private var nextNumber: UInt64 = 0
  private var total = 0

  public init() {}

  /// The waits parked right now.
  public var activeCount: Int {
    lock.withLock { total }
  }

  public func listeningSince(_ principal: PrincipalID) -> Date? {
    lock.withLock { started[principal]?.values.min() }
  }

  public func listeningPrincipals() -> Set<PrincipalID> {
    lock.withLock { Set(started.keys) }
  }

  /// Takes a place for `principal`, or throws when either limit is already reached. A limit of zero
  /// admits nobody.
  func acquire(principal: PrincipalID, at instant: Date, global: Int, perPrincipalLimit: Int) throws
    -> WaitPlace
  {
    try lock.withLock {
      guard total < global, started[principal, default: [:]].count < perPrincipalLimit else {
        throw MessagingError.tooManyWaiters
      }
      total += 1
      nextNumber += 1
      started[principal, default: [:]][nextNumber] = instant
      return WaitPlace(number: nextNumber)
    }
  }

  func release(principal: PrincipalID, place: WaitPlace) {
    lock.withLock {
      guard started[principal]?.removeValue(forKey: place.number) != nil else { return }
      total -= 1
      if started[principal]?.isEmpty == true { started[principal] = nil }
    }
  }
}
