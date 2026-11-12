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

  init(_ messages: MessageService, token: CredentialToken, timeout: TimeInterval) {
    nonisolated(unsafe) let messages = messages
    Thread.detachNewThread { [self] in
      let result = Result { try messages.wait(token: token, timeout: timeout) }
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
}
