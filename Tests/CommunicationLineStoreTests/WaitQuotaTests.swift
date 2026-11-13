import CommunicationLineApplication
import CommunicationLineDomain
import CommunicationLineStore
import Dispatch
import Foundation
import Testing

@Suite struct WaitQuotaTests {
  private func set(_ fixture: MessagingFixture, _ key: String, to value: Int64) throws {
    _ = try fixture.settings.change(
      SettingAddress(key: key, scope: .global, subject: nil), to: .integer(value),
      ownerToken: fixture.owner)
  }

  /// Parks `token` in a wait on another thread; returns once the quota counts it.
  private func park(_ fixture: MessagingFixture, token: CredentialToken, seconds: TimeInterval)
    throws
  {
    nonisolated(unsafe) let messages = fixture.messages
    let before = fixture.waitQuota.activeCount
    Thread.detachNewThread { _ = try? messages.wait(token: token, timeout: seconds) }
    let deadline = Date().addingTimeInterval(5)
    while fixture.waitQuota.activeCount == before {
      try #require(Date() < deadline, "the waiter never parked")
      Thread.sleep(forTimeInterval: 0.005)
    }
  }

  @Test func test_aSecondWaitOfOnePrincipal_isRefusedAtOnce() throws {
    let arrival = InProcessMailArrival()
    let fixture = try MessagingFixture(arrival: arrival)
    try set(fixture, "limits.waits.principal", to: 1)
    try park(fixture, token: fixture.alphaPeerToken, seconds: 1)

    #expect(throws: MessagingError.tooManyWaiters) {
      _ = try fixture.messages.wait(token: fixture.alphaPeerToken, timeout: 1)
    }
    #expect(arrival.parkedWaiterCount == 1, "the refused wait did not park")
  }

  @Test func test_anotherPrincipal_stillWaits_whileTheGlobalLimitHolds() throws {
    let arrival = InProcessMailArrival()
    let fixture = try MessagingFixture(arrival: arrival)
    try set(fixture, "limits.waits.principal", to: 1)
    try park(fixture, token: fixture.alphaPeerToken, seconds: 1)

    let result = try fixture.messages.wait(token: fixture.alphaHeadToken, timeout: 0.05)

    #expect(result == .timedOut, "the per-principal limit is not shared between principals")
  }

  @Test func test_theGlobalLimit_refusesEveryPrincipalOnceItIsReached() throws {
    let arrival = InProcessMailArrival()
    let fixture = try MessagingFixture(arrival: arrival)
    try set(fixture, "limits.waits.global", to: 1)
    try park(fixture, token: fixture.alphaPeerToken, seconds: 1)

    #expect(throws: MessagingError.tooManyWaiters) {
      _ = try fixture.messages.wait(token: fixture.alphaHeadToken, timeout: 1)
    }
  }

  @Test func test_aFinishedWait_givesItsPlaceBack() throws {
    let fixture = try MessagingFixture(arrival: InProcessMailArrival())
    try set(fixture, "limits.waits.principal", to: 1)

    let first = try fixture.messages.wait(token: fixture.alphaPeerToken, timeout: 0.05)
    let second = try fixture.messages.wait(token: fixture.alphaPeerToken, timeout: 0.05)

    #expect(first == .timedOut && second == .timedOut, "waits one after another all fit")
    #expect(fixture.waitQuota.activeCount == 0, "no place is left taken")
  }

  @Test func test_withNoPlaceAtAll_pendingMailIsStillReturned() throws {
    let fixture = try MessagingFixture(arrival: InProcessMailArrival())
    try set(fixture, "limits.waits.global", to: 0)
    try fixture.mail(from: fixture.alphaToken, to: fixture.alphaPeer)

    let result = try fixture.messages.wait(token: fixture.alphaPeerToken, timeout: 1)

    #expect(result == .mail, "only parking needs a place, not an answer that is already there")
    #expect(throws: MessagingError.tooManyWaiters) {
      _ = try fixture.messages.wait(token: fixture.alphaHeadToken, timeout: 1)
    }
  }
}
