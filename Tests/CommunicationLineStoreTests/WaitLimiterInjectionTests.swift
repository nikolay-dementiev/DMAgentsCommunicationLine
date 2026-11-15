import CommunicationLineApplication
import CommunicationLineDomain
import CommunicationLineStore
import Foundation
import Testing

/// A limiter that records the places it hands out, so a test sees what the service asks of it.
private final class SpyWaitLimiter: WaitLimiting, @unchecked Sendable {
  private let lock = NSLock()
  private var acquiredIDs: [PrincipalID] = []
  private var releasedIDs: [PrincipalID] = []
  var refuses = false

  var acquired: [PrincipalID] { lock.withLock { acquiredIDs } }
  var released: [PrincipalID] { lock.withLock { releasedIDs } }

  func acquire(principal: PrincipalID, at instant: Date, global: Int, perPrincipalLimit: Int) throws
    -> WaitPlace
  {
    if refuses { throw MessagingError.tooManyWaiters }
    lock.withLock { acquiredIDs.append(principal) }
    return WaitPlace(number: 1)
  }

  func release(principal: PrincipalID, place: WaitPlace) {
    lock.withLock { releasedIDs.append(principal) }
  }
}

@Suite struct WaitLimiterInjectionTests {
  private func makeSUT(limiter: SpyWaitLimiter) throws -> (MessagingFixture, MessageService) {
    let fixture = try MessagingFixture()
    let service = MessageService(
      store: fixture.store, rights: SQLiteRightsStore(store: fixture.identity.store),
      authenticator: fixture.identity.service, settings: fixture.settings,
      identifiers: SequentialIdentifiers(), clock: fixture.clock, arrival: fixture.recorder,
      waitLimiter: limiter)
    return (fixture, service)
  }

  @Test func test_wait_takesItsPlaceFromTheInjectedLimiter_andGivesItBack() throws {
    let limiter = SpyWaitLimiter()
    let (fixture, service) = try makeSUT(limiter: limiter)

    let result = try service.wait(token: fixture.alphaToken, timeout: 5)

    #expect(result == .timedOut, "nothing is pending, so the wait times out")
    #expect(limiter.acquired == [fixture.alpha.id], "the wait asked the limiter for a place")
    #expect(limiter.released == [fixture.alpha.id], "and gave that place back when it ended")
  }

  @Test func test_wait_whenTheLimiterRefuses_failsWithTooManyWaiters_andReleasesNothing() throws {
    let limiter = SpyWaitLimiter()
    limiter.refuses = true
    let (fixture, service) = try makeSUT(limiter: limiter)

    #expect(throws: MessagingError.tooManyWaiters, "a refused place is the caller's error") {
      _ = try service.wait(token: fixture.alphaToken, timeout: 5)
    }
    #expect(limiter.released.isEmpty, "a place that was never taken is not given back")
  }
}
