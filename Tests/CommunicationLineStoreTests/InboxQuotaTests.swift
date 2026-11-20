import CommunicationLineApplication
import CommunicationLineDomain
import CommunicationLineStore
import Dispatch
import Foundation
import Testing

/// The pending count of a recipient and the inserts of one send happen under one write lock, and
/// the count is a kept counter, not a scan of the recipient's pending deliveries.
@Suite struct InboxQuotaTests {
  /// Message ids of the second sender; they must not collide with those of the fixture.
  private final class OtherIdentifiers: IdentifierSource {
    private var next = 0
    func newPrincipalID() -> PrincipalID { PrincipalID("other-principal") }
    func newMessageID() -> MessageID {
      next += 1
      return MessageID("other-\(next)")
    }
  }

  private final class Outcome: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<MessageID, Error>?
    let finished = DispatchSemaphore(value: 0)

    var result: Result<MessageID, Error>? { lock.withLock { stored } }

    func deliver(_ result: Result<MessageID, Error>) {
      lock.withLock { stored = result }
      finished.signal()
    }
  }

  private func setQuota(_ fixture: MessagingFixture, to value: Int64) throws {
    _ = try fixture.settings.change(
      SettingAddress(key: "quota.messages.assigned_per_principal", scope: .global, subject: nil),
      to: .integer(value), ownerToken: fixture.owner)
  }

  /// A message service on a second connection to the same file, which is what a second process
  /// holds.
  private func secondSender(_ fixture: MessagingFixture) throws -> MessageService {
    let store = try SQLiteStore.open(
      at: fixture.identity.scratch.storePath, busyTimeoutMilliseconds: 5000,
      migrations: SchemaMigrations.all)
    let identity = IdentityService(
      store: SQLiteIdentityStore(store: store), random: SequenceRandom(),
      identifiers: SequentialIdentifiers(), clock: fixture.clock)
    let settings = SettingsService(
      catalog: try BundledSettingsCatalogSource.shipped.load(),
      store: SQLiteSettingsStore(store: store), clock: fixture.clock, authenticator: identity)
    return MessageService(
      store: SQLiteMessageStore(store: store), rights: SQLiteRightsStore(store: store),
      authenticator: identity, settings: settings, identifiers: OtherIdentifiers(),
      clock: fixture.clock, arrival: RecordingArrival(), waitLimiter: WaitQuota(),
      storage: StorageService(store: SQLiteStorageStore(store: store), settings: settings))
  }

  private func counter(_ fixture: MessagingFixture, of recipient: Principal) throws -> Int {
    try fixture.identity.raw().integer(
      "SELECT count FROM pending_counts WHERE recipient = '\(recipient.id.rawValue)'")
  }

  // MARK: - The write lock

  @Test func test_theLastSlotOfAnInbox_goesToExactlyOneOfTwoConcurrentSenders() throws {
    // The two threads below touch the fixture one after the other: the first one is paused inside
    // its transaction and the second one waits for the write lock.
    nonisolated(unsafe) let fixture = try MessagingFixture()
    try setQuota(fixture, to: 2)
    try fixture.mail(from: fixture.alphaToken, to: fixture.alphaPeer, "one")
    nonisolated(unsafe) let other = try secondSender(fixture)

    let counted = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var paused = false
    fixture.store.afterAuthorize = {
      guard !paused else { return }
      paused = true
      counted.signal()
      release.wait()
    }
    let first = Outcome()
    Thread.detachNewThread {
      first.deliver(
        Result {
          try fixture.messages.send(
            token: fixture.alphaToken, to: [fixture.alphaPeer.id], subject: "a", body: "b")
        })
    }
    counted.wait()

    let second = Outcome()
    Thread.detachNewThread {
      second.deliver(
        Result {
          try other.send(
            token: fixture.alphaHeadToken, to: [fixture.alphaPeer.id], subject: "b", body: "b")
        })
    }
    let finishedEarly = second.finished.wait(timeout: .now() + 0.4) == .success
    release.signal()
    first.finished.wait()
    if !finishedEarly { second.finished.wait() }

    #expect(!finishedEarly, "the second sender waited for the write lock of the first one")
    #expect((try? first.result?.get()) != nil, "the first sender took the last slot")
    #expect(
      second.result.map { result in
        if case .failure(let error) = result {
          return (error as? MessagingError) == .recipientInboxFull(fixture.alphaPeer.id, limit: 2)
        }
        return false
      } == true, "the second sender found the inbox full once the first one committed")
    #expect(try fixture.count("deliveries") == 2, "the quota was not exceeded")
  }

  // MARK: - The kept counter

  @Test func test_thePendingCounter_followsSendsAndAcknowledgements() throws {
    let fixture = try MessagingFixture()
    let first = try fixture.mail(from: fixture.alphaToken, to: fixture.alphaPeer, "one")
    try fixture.mail(from: fixture.alphaToken, to: fixture.alphaPeer, "two")

    #expect(try counter(fixture, of: fixture.alphaPeer) == 2, "two pending deliveries")
    try fixture.messages.acknowledge(token: fixture.alphaPeerToken, messageID: first)
    #expect(
      try counter(fixture, of: fixture.alphaPeer) == 1, "an acknowledged one no longer counts")
    try fixture.messages.acknowledge(token: fixture.alphaPeerToken, messageID: first)
    #expect(try counter(fixture, of: fixture.alphaPeer) == 1, "acknowledging twice counts once")
  }

  @Test func test_aRefusedSend_leavesTheCounterAlone() throws {
    let fixture = try MessagingFixture()
    try setQuota(fixture, to: 1)
    try fixture.mail(from: fixture.alphaToken, to: fixture.alphaPeer, "one")

    #expect(throws: MessagingError.self) {
      _ = try fixture.messages.send(
        token: fixture.alphaToken, to: [fixture.alphaHead.id, fixture.alphaPeer.id], subject: "s",
        body: "b")
    }

    #expect(try counter(fixture, of: fixture.alphaPeer) == 1, "the refused send counted nothing")
    #expect(
      try fixture.identity.raw().integer(
        "SELECT count(*) FROM pending_counts WHERE recipient = '\(fixture.alphaHead.id.rawValue)'")
        == 0, "and the other recipient of the refused send has no count either")
  }

  @Test func test_migratingToVersion7_countsTheDeliveriesThatAreAlreadyPending() throws {
    let scratch = try TemporaryDirectory()
    _ = try SQLiteStore.open(
      at: scratch.storePath, busyTimeoutMilliseconds: 1000,
      migrations: Array(SchemaMigrations.all.prefix(6)))
    let raw = try RawDatabase(path: scratch.storePath)
    try raw.execute(
      """
      INSERT INTO principals (id, family, role, display_name, enabled, created_at_ms)
      VALUES ('p1', 'f', 'agent', 'one', 1, 0), ('p2', 'f', 'agent', 'two', 1, 0);
      INSERT INTO messages (id, sender, subject, body, created_at_ms)
      VALUES ('m1', 'p2', 's', 'b', 0), ('m2', 'p2', 's', 'b', 0), ('m3', 'p2', 's', 'b', 0),
             ('m4', 'p1', 's', 'b', 0);
      INSERT INTO deliveries (message_seq, recipient, state, acknowledged_at_ms)
      VALUES (1, 'p1', 'pending', NULL), (2, 'p1', 'pending', NULL),
             (3, 'p1', 'acknowledged', 5), (4, 'p2', 'pending', NULL);
      """)

    _ = try SQLiteStore.open(
      at: scratch.storePath, busyTimeoutMilliseconds: 1000, migrations: SchemaMigrations.all)

    #expect(
      try raw.integer("SELECT count FROM pending_counts WHERE recipient = 'p1'") == 2,
      "two pending for p1; the acknowledged one is left out")
    #expect(
      try raw.integer("SELECT count FROM pending_counts WHERE recipient = 'p2'") == 1,
      "one pending for p2")
  }
}
