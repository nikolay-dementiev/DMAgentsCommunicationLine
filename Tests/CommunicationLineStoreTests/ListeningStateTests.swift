import CommunicationLineApplication
import CommunicationLineDomain
import CommunicationLineStore
import Foundation
import Testing

@Suite struct ListeningStateTests {
  /// Parks `token` in a wait on another thread; returns once the quota counts one more place.
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

  private func waitUntilIdle(_ fixture: MessagingFixture) throws {
    let deadline = Date().addingTimeInterval(5)
    while fixture.waitQuota.activeCount > 0 {
      try #require(Date() < deadline, "the waiter never ended")
      Thread.sleep(forTimeInterval: 0.005)
    }
  }

  @Test func test_aParkedWait_makesItsPrincipalListening_sinceTheTimeItStarted() throws {
    let fixture = try MessagingFixture(arrival: InProcessMailArrival())
    try park(fixture, token: fixture.alphaPeerToken, seconds: 1)

    #expect(
      fixture.waitQuota.listeningSince(fixture.alphaPeer.id) == fixture.clock.now(),
      "the principal that waits is listening, since the instant the wait started")
    #expect(
      fixture.waitQuota.listeningSince(fixture.alpha.id) == nil,
      "a principal that does not wait is not listening")
    #expect(
      fixture.waitQuota.listeningPrincipals() == [fixture.alphaPeer.id],
      "exactly the waiting principal is listed")
  }

  @Test func test_whenTheWaitEnds_thePrincipalIsNoLongerListening() throws {
    let fixture = try MessagingFixture(arrival: InProcessMailArrival())
    try park(fixture, token: fixture.alphaPeerToken, seconds: 0.3)
    try waitUntilIdle(fixture)

    #expect(
      fixture.waitQuota.listeningSince(fixture.alphaPeer.id) == nil,
      "an ended wait does not leave the principal listening")
    #expect(fixture.waitQuota.listeningPrincipals().isEmpty, "nobody is listening")
  }

  @Test func test_withTwoWaits_listeningSinceIsTheOldestOne_andMovesToTheNextWhenItEnds() throws {
    let fixture = try MessagingFixture(arrival: InProcessMailArrival())
    _ = try fixture.settings.change(
      SettingAddress(key: "limits.waits.principal", scope: .global, subject: nil),
      to: .integer(2), ownerToken: fixture.owner)
    let first = fixture.clock.now()
    try park(fixture, token: fixture.alphaPeerToken, seconds: 0.4)
    fixture.clock.instant = first.addingTimeInterval(60)
    try park(fixture, token: fixture.alphaPeerToken, seconds: 5)

    #expect(
      fixture.waitQuota.listeningSince(fixture.alphaPeer.id) == first,
      "the oldest parked wait decides the time")

    let deadline = Date().addingTimeInterval(5)
    while fixture.waitQuota.activeCount > 1 {
      try #require(Date() < deadline, "the first wait never ended")
      Thread.sleep(forTimeInterval: 0.005)
    }
    #expect(
      fixture.waitQuota.listeningSince(fixture.alphaPeer.id) == first.addingTimeInterval(60),
      "when the oldest wait ends, the younger one decides")
  }
}
