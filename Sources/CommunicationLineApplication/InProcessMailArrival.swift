import CommunicationLineDomain
import Foundation

/// Wakes waiters that live in the same process as the sender. A signal bumps a counter per
/// recipient; a waiter holding an older ticket returns at once, so a send that lands between a
/// waiter's inbox check and its parking is never missed.
///
/// All state is guarded by one condition, which makes the type safe to share between threads.
public final class InProcessMailArrival: MailArrival, @unchecked Sendable {
  private let condition = NSCondition()
  private var generations: [PrincipalID: Int] = [:]
  private var parked = 0

  public init() {}

  /// How many callers are parked right now.
  public var parkedWaiterCount: Int {
    condition.withLock { parked }
  }

  public func ticket(for recipient: PrincipalID) -> ArrivalTicket {
    condition.withLock { ArrivalTicket(value: generations[recipient, default: 0]) }
  }

  public func signal(recipients: Set<PrincipalID>) {
    condition.withLock {
      for recipient in recipients { generations[recipient, default: 0] += 1 }
      condition.broadcast()
    }
  }

  public func wait(for recipient: PrincipalID, since ticket: ArrivalTicket, timeout: TimeInterval)
    -> ArrivalResult
  {
    let deadline = Date().addingTimeInterval(timeout)
    return condition.withLock {
      parked += 1
      defer { parked -= 1 }
      while generations[recipient, default: 0] == ticket.value {
        // `wait(until:)` returns false once the deadline has passed.
        guard condition.wait(until: deadline) else {
          return generations[recipient, default: 0] == ticket.value ? .timedOut : .signalled
        }
      }
      return .signalled
    }
  }
}
