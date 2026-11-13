import CommunicationLineApplication
import CommunicationLineDomain
import CommunicationLineStore
import Dispatch
import Foundation
import Testing

/// Runs `wait` on another thread and keeps its result.
private final class BackgroundWait: @unchecked Sendable {
  private let finished = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private var outcome: Result<WaitResult, Error>?

  init(
    _ messages: MessageService, token: CredentialToken, timeout: TimeInterval,
    cancellation: WaitCancellation? = nil
  ) {
    nonisolated(unsafe) let messages = messages
    Thread.detachNewThread { [self] in
      let result = Result {
        try messages.wait(token: token, timeout: timeout, cancellation: cancellation)
      }
      lock.withLock { outcome = result }
      finished.signal()
    }
  }

  /// The result, or `nil` when the wait is still running after `seconds`.
  func result(within seconds: TimeInterval) throws -> WaitResult? {
    guard finished.wait(timeout: .now() + seconds) == .success else { return nil }
    return try lock.withLock { try #require(outcome) }.get()
  }
}

@Suite struct MessageWaitTests {
  private func waitUntilParked(_ arrival: InProcessMailArrival, count: Int = 1) throws {
    let deadline = Date().addingTimeInterval(5)
    while arrival.parkedWaiterCount < count {
      try #require(Date() < deadline, "the waiter never parked")
      Thread.sleep(forTimeInterval: 0.005)
    }
  }

  @Test func test_wait_withPendingMail_returnsAtOnceWithoutParking() throws {
    let fixture = try MessagingFixture()
    try fixture.mail(from: fixture.alphaToken, to: fixture.alphaPeer)

    let result = try fixture.messages.wait(token: fixture.alphaPeerToken, timeout: 30)

    #expect(result == .mail, "pending mail is returned")
    #expect(fixture.recorder.waitTimeouts.isEmpty, "the caller did not park")
  }

  @Test func test_wait_withoutMail_timesOutWithADistinctResult() throws {
    let arrival = InProcessMailArrival()
    let fixture = try MessagingFixture(arrival: arrival)

    let result = try fixture.messages.wait(token: fixture.alphaPeerToken, timeout: 0.05)

    #expect(result == .timedOut, "nothing arrived")
    #expect(arrival.parkedWaiterCount == 0, "the waiter is gone after the timeout")
  }

  @Test func test_wait_whenCancelled_endsAtOnceAndGivesItsPlaceBack() throws {
    let arrival = InProcessMailArrival()
    let fixture = try MessagingFixture(arrival: arrival)
    let cancellation = WaitCancellation()
    let waiter = BackgroundWait(
      fixture.messages, token: fixture.alphaPeerToken, timeout: 30, cancellation: cancellation)
    try waitUntilParked(arrival)
    #expect(fixture.waitQuota.activeCount == 1, "the parked wait holds a place")

    cancellation.cancel()

    #expect(try waiter.result(within: 5) == .timedOut, "the cancelled wait ended long before 30 s")
    #expect(arrival.parkedWaiterCount == 0, "it is no longer parked")
    #expect(fixture.waitQuota.activeCount == 0, "its place in the quota is free again")
  }

  @Test func test_wait_cancelledBeforeItStarted_doesNotPark() throws {
    let arrival = InProcessMailArrival()
    let fixture = try MessagingFixture(arrival: arrival)
    let cancellation = WaitCancellation()
    cancellation.cancel()

    let result = try fixture.messages.wait(
      token: fixture.alphaPeerToken, timeout: 30, cancellation: cancellation)

    #expect(result == .timedOut, "a cancellation that came first is honoured")
    #expect(fixture.waitQuota.activeCount == 0, "no place was taken")
  }

  @Test func test_wait_wakesWhenMailIsSentToTheWaiter() throws {
    let arrival = InProcessMailArrival()
    let fixture = try MessagingFixture(arrival: arrival)
    let waiter = BackgroundWait(fixture.messages, token: fixture.alphaPeerToken, timeout: 30)
    try waitUntilParked(arrival)

    try fixture.mail(from: fixture.alphaToken, to: fixture.alphaPeer)

    #expect(try waiter.result(within: 10) == .mail, "the waiter woke with mail")
  }

  @Test func test_wait_doesNotWakeForMailSentToSomeoneElse() throws {
    let arrival = InProcessMailArrival()
    let fixture = try MessagingFixture(arrival: arrival)
    let waiter = BackgroundWait(fixture.messages, token: fixture.alphaPeerToken, timeout: 0.4)
    try waitUntilParked(arrival)

    try fixture.mail(from: fixture.alphaToken, to: fixture.alphaHead)

    #expect(try waiter.result(within: 10) == .timedOut, "the waiter slept until its timeout")
  }

  @Test func test_wait_defaultsToTheCatalogWaitAndIsCappedByIt() throws {
    let fixture = try MessagingFixture()

    _ = try fixture.messages.wait(token: fixture.alphaPeerToken, timeout: nil)
    _ = try fixture.settings.change(
      SettingAddress(key: "messaging.wait", scope: .global, subject: nil), to: .integer(60),
      ownerToken: fixture.owner)
    _ = try fixture.messages.wait(token: fixture.alphaPeerToken, timeout: 3600)
    _ = try fixture.messages.wait(token: fixture.alphaPeerToken, timeout: 5)

    #expect(fixture.recorder.waitTimeouts == [900, 60, 5], "default, capped, shorter request kept")
  }

  @Test func test_wait_zeroCatalogWait_neverParks() throws {
    let fixture = try MessagingFixture()
    _ = try fixture.settings.change(
      SettingAddress(key: "messaging.wait", scope: .global, subject: nil), to: .integer(0),
      ownerToken: fixture.owner)

    let result = try fixture.messages.wait(token: fixture.alphaPeerToken, timeout: 30)

    #expect(result == .timedOut, "no mail and no parking")
    #expect(fixture.recorder.waitTimeouts.isEmpty, "parked waits are disabled")
  }

  @Test func test_wait_ownerToken_isRefused() throws {
    let fixture = try MessagingFixture()

    #expect(throws: IdentityError.principalCredentialRequired) {
      _ = try fixture.messages.wait(token: fixture.owner, timeout: 1)
    }
  }

  @Test func test_send_signalsOnlyAfterTheMailIsCommitted() throws {
    let fixture = try MessagingFixture()
    nonisolated(unsafe) var committedAtSignal: [Int] = []
    fixture.recorder.onSignal = {
      committedAtSignal.append((try? fixture.count("deliveries")) ?? -1)
    }

    try fixture.mail(from: fixture.alphaToken, to: fixture.alphaPeer)

    #expect(committedAtSignal == [1], "a waiter woken by the signal finds the delivery")
  }

  // MARK: - The in-process arrival on its own

  @Test func test_arrival_signalForSomeoneElse_doesNotWakeAWaiter() {
    let arrival = InProcessMailArrival()
    let waiting = PrincipalID("waiting")
    let ticket = arrival.ticket(for: waiting)
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
      arrival.signal(recipients: [PrincipalID("someone-else")])
    }

    #expect(
      arrival.wait(for: waiting, since: ticket, timeout: 0.4) == .timedOut,
      "only a signal naming the waiter wakes it")
  }

  @Test func test_arrival_signalForTheWaiter_wakesIt() {
    let arrival = InProcessMailArrival()
    let waiting = PrincipalID("waiting")
    let ticket = arrival.ticket(for: waiting)
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
      arrival.signal(recipients: [waiting])
    }

    #expect(arrival.wait(for: waiting, since: ticket, timeout: 10) == .signalled, "woken")
  }

  @Test func test_arrival_signalBetweenTheTicketAndTheWait_isNotLost() {
    let arrival = InProcessMailArrival()
    let waiting = PrincipalID("waiting")
    let ticket = arrival.ticket(for: waiting)

    arrival.signal(recipients: [waiting])
    let started = Date()

    #expect(
      arrival.wait(for: waiting, since: ticket, timeout: 10) == .signalled,
      "a signal after the ticket is reported")
    #expect(
      Date().timeIntervalSince(started) < 1, "and it returns at once instead of parking")
  }

  // MARK: - A wake that finds nothing

  /// Returns the scripted results in order, then `.timedOut`, and records every timeout it was given.
  private final class ScriptedArrival: MailArrival {
    private var script: [ArrivalResult]
    private(set) var timeouts: [TimeInterval] = []

    init(_ script: [ArrivalResult]) { self.script = script }

    func ticket(for recipient: PrincipalID) -> ArrivalTicket { ArrivalTicket(value: 0) }
    func signal(recipients: Set<PrincipalID>) {}

    func wait(for recipient: PrincipalID, since ticket: ArrivalTicket, timeout: TimeInterval)
      -> ArrivalResult
    {
      timeouts.append(timeout)
      return script.isEmpty ? .timedOut : script.removeFirst()
    }
  }

  @Test func test_wait_aSignalThatFindsNothingPending_keepsWaitingForTheRestOfTheTime() throws {
    let arrival = ScriptedArrival([.signalled])
    let fixture = try MessagingFixture(arrival: arrival)

    let result = try fixture.messages.wait(token: fixture.alphaPeerToken, timeout: 30)

    #expect(result == .timedOut, "a wake with an empty inbox is not mail")
    #expect(arrival.timeouts == [30, 30], "it parked again for the time that was left")
  }
}
