import CommunicationLineApplication
import CommunicationLineDomain
import CommunicationLineStore
import Foundation
import Testing

@Suite struct MessageProtectionTests {
  /// Runs `sql` and returns the database's refusal text; fails the test when it is not refused.
  private func refusal(of sql: String, on raw: RawDatabase) throws -> String {
    do {
      try raw.execute(sql)
    } catch RawDatabaseError.statement(let reason) {
      return reason
    }
    Issue.record("the statement was accepted: \(sql)")
    return ""
  }

  private func pendingFixture() throws -> (fixture: MessagingFixture, id: MessageID) {
    let fixture = try MessagingFixture()
    let id = try fixture.mail(from: fixture.alphaToken, to: fixture.alphaPeer)
    return (fixture, id)
  }

  // MARK: - Triggers

  @Test func test_pendingDelivery_cannotBeDeleted() throws {
    let (fixture, _) = try pendingFixture()

    let reason = try refusal(of: "DELETE FROM deliveries", on: try fixture.identity.raw())

    #expect(reason.contains("pending"), "the trigger names the reason: \(reason)")
    #expect(try fixture.count("deliveries") == 1, "the delivery is still there")
  }

  @Test func test_acknowledgedDelivery_cannotGoBackToPending() throws {
    let (fixture, id) = try pendingFixture()
    try fixture.messages.acknowledge(token: fixture.alphaPeerToken, messageID: id)

    let reason = try refusal(
      of: "UPDATE deliveries SET state = 'pending', acknowledged_at_ms = NULL",
      on: try fixture.identity.raw())

    #expect(reason.contains("acknowledged"), "the trigger names the reason: \(reason)")
    #expect(try fixture.isAcknowledged(id, by: fixture.alphaPeer), "still acknowledged")
  }

  @Test func test_pendingDelivery_cannotBeRewrittenToAnotherRecipientOrMessage() throws {
    let (fixture, _) = try pendingFixture()
    let raw = try fixture.identity.raw()

    #expect(
      try refusal(of: "UPDATE deliveries SET recipient = '\(fixture.beta.id.rawValue)'", on: raw)
        .contains("pending"),
      "the recipient cannot be changed")
    #expect(
      try refusal(of: "UPDATE deliveries SET message_seq = message_seq + 1", on: raw)
        .contains("pending"),
      "the message cannot be changed")
  }

  @Test func test_messageWithAPendingDelivery_cannotBeDeleted_evenWithoutForeignKeys() throws {
    let (fixture, _) = try pendingFixture()

    let reason = try refusal(of: "DELETE FROM messages", on: try fixture.identity.raw())

    #expect(reason.contains("pending"), "the trigger names the reason: \(reason)")
    #expect(try fixture.count("messages") == 1, "the message is still there")
  }

  @Test func test_message_cannotBeRewritten() throws {
    let (fixture, _) = try pendingFixture()

    let reason = try refusal(
      of: "UPDATE messages SET body = 'changed'", on: try fixture.identity.raw())

    #expect(reason.contains("message"), "the trigger names the reason: \(reason)")
  }

  @Test func test_insertOrReplace_cannotOverwriteADeliveryOrAMessage() throws {
    let (fixture, id) = try pendingFixture()
    let raw = try fixture.identity.raw()
    let recipient = fixture.alphaPeer.id.rawValue
    let sender = fixture.alpha.id.rawValue

    #expect(
      try !refusal(
        of:
          "INSERT OR REPLACE INTO deliveries VALUES (1, '\(recipient)', 'acknowledged', 5)",
        on: raw
      ).isEmpty, "a pending delivery cannot be replaced")
    #expect(
      try !refusal(
        of:
          """
          INSERT OR REPLACE INTO messages (seq, id, sender, subject, body, created_at_ms)
          VALUES (1, '\(id.rawValue)', '\(sender)', 'forged', 'forged', 1)
          """, on: raw
      ).isEmpty, "a stored message cannot be replaced")
    #expect(!(try fixture.isAcknowledged(id, by: fixture.alphaPeer)), "the delivery is pending")
    #expect(
      try fixture.messages.read(token: fixture.alphaToken, messageID: id).subject == "s",
      "the message is unchanged")
  }

  @Test func test_acknowledgedDelivery_mayBeDeleted_soThatRetentionCanReclaimIt() throws {
    let (fixture, id) = try pendingFixture()
    try fixture.messages.acknowledge(token: fixture.alphaPeerToken, messageID: id)

    try fixture.identity.raw().execute("DELETE FROM deliveries WHERE state = 'acknowledged'")

    #expect(try fixture.count("deliveries") == 0, "only acknowledged mail can be reclaimed")
  }

  // MARK: - Restart

  private struct Stack {
    let identity: IdentityService
    let messages: MessageService

    init(path: URL) throws {
      let store = try SQLiteStore.open(
        at: path, busyTimeoutMilliseconds: 1000, migrations: SchemaMigrations.all)
      let clock = StoreFixedClock(instant: Date(timeIntervalSince1970: 1_800_000_000))
      identity = IdentityService(
        store: SQLiteIdentityStore(store: store), random: SequenceRandom(),
        identifiers: SequentialIdentifiers(), clock: clock)
      let settings = SettingsService(
        catalog: try BundledSettingsCatalogSource.shipped.load(),
        store: SQLiteSettingsStore(store: store), clock: clock, authenticator: identity)
      messages = MessageService(
        store: SQLiteMessageStore(store: store), rights: SQLiteRightsStore(store: store),
        authenticator: identity, settings: settings, identifiers: SequentialIdentifiers(),
        clock: clock, arrival: RecordingArrival())
    }
  }

  @Test func test_pendingMail_survivesClosingAndReopeningTheStore() throws {
    let scratch = try TemporaryDirectory()
    var recipientToken: CredentialToken?
    var sent: MessageID?
    do {
      let first = try Stack(path: scratch.storePath)
      let owner = try first.identity.issueOwnerCredential(replacing: nil)
      let sender = try first.identity.createPrincipal(
        family: "A", role: .agent, displayName: "sender", ownerToken: owner)
      let recipient = try first.identity.createPrincipal(
        family: "A", role: .agent, displayName: "recipient", ownerToken: owner)
      let senderToken = try first.identity.issueCredential(for: sender.id, ownerToken: owner)
      recipientToken = try first.identity.issueCredential(for: recipient.id, ownerToken: owner)
      sent = try first.messages.send(
        token: senderToken, to: [recipient.id], subject: "kept", body: "across a restart")
    }

    let second = try Stack(path: scratch.storePath)
    let page = try second.messages.inbox(token: try #require(recipientToken), after: nil)

    #expect(page.entries.map(\.messageID) == [try #require(sent)], "the mail is still pending")
    #expect(page.entries.first?.subject == "kept", "with its content")
  }
}
