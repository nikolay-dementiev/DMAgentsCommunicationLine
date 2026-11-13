import CommunicationLineApplication
import CommunicationLineDomain
import CommunicationLineStore
import Dispatch
import Foundation
import Testing

/// One store may be used from several threads: a whole transaction runs as one unit, so another
/// thread never sees its uncommitted rows and never starts a transaction inside it.
@Suite struct MessageConcurrencyTests {
  private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool?

    func set(_ newValue: Bool) { lock.withLock { value = newValue } }
    var current: Bool? { lock.withLock { value } }
  }

  @Test func test_readOnAnotherThread_waitsForAnOpenSendTransactionToCommit() throws {
    let fixture = try MessagingFixture()
    nonisolated(unsafe) let store = SQLiteMessageStore(store: fixture.identity.store)
    let inTransaction = DispatchSemaphore(value: 0)
    let proceed = DispatchSemaphore(value: 0)
    let sender = fixture.alpha.id
    let recipient = fixture.alphaPeer.id
    let message = OutgoingMessage(
      id: MessageID("held"), sender: sender, recipients: [recipient], subject: "s", body: "b",
      createdAt: Date(timeIntervalSince1970: 1_800_000_000))
    let sending = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var sendError: Error?
    Thread.detachNewThread {
      do {
        try store.send(message) { _ in
          inTransaction.signal()
          proceed.wait()
        }
      } catch {
        sendError = error
      }
      sending.signal()
    }
    inTransaction.wait()

    let seen = Flag()
    let reading = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
      // Within the sender's open transaction this must wait, then see the committed delivery.
      seen.set((try? store.hasPending(for: recipient)) ?? false)
      reading.signal()
    }
    let finishedEarly = reading.wait(timeout: .now() + 0.3) == .success
    proceed.signal()
    sending.wait()
    // The reader's semaphore was consumed above when it finished early.
    if !finishedEarly { reading.wait() }

    #expect(!finishedEarly, "the reader waited instead of running inside the open transaction")
    #expect(sendError == nil, "the send committed: \(String(describing: sendError))")
    #expect(seen.current == true, "after the commit the reader sees the delivery")
  }
}
