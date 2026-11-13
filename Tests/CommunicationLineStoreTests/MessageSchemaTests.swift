import CommunicationLineApplication
import CommunicationLineDomain
import CommunicationLineStore
import Foundation
import Testing

@Suite struct MessageSchemaTests {
  private struct Fixture {
    let identity: IdentityFixture
    let sender: Principal
    let raw: RawDatabase

    init() throws {
      identity = try IdentityFixture()
      sender = try identity.service.createPrincipal(
        family: "A", role: .agent, displayName: "sender", ownerToken: identity.owner)
      raw = try identity.raw()
      try raw.execute("PRAGMA foreign_keys = ON")
    }

    func insertMessage(id: String = "m1", sender: String? = nil) throws {
      try raw.execute(
        """
        INSERT INTO messages (id, sender, subject, body, created_at_ms)
        VALUES ('\(id)', '\(sender ?? self.sender.id.rawValue)', 's', 'b', 1)
        """)
    }
  }

  @Test func test_schema_versionThreeCreatesTheMessageTables() throws {
    let fixture = try Fixture()

    #expect(SchemaMigrations.all.map(\.version).starts(with: [1, 2, 3]), "version three is kept")
    #expect(try fixture.raw.tableExists("messages"), "messages exist")
    #expect(try fixture.raw.tableExists("deliveries"), "deliveries exist")
  }

  @Test func test_messages_refuseAnUnknownSender() throws {
    let fixture = try Fixture()

    #expect(throws: RawDatabaseError.self) { try fixture.insertMessage(sender: "nobody") }
  }

  @Test func test_deliveries_refuseAMessageThatDoesNotExist() throws {
    let fixture = try Fixture()

    #expect(throws: RawDatabaseError.self) {
      try fixture.raw.execute(
        """
        INSERT INTO deliveries (message_seq, recipient, state)
        VALUES (999, '\(fixture.sender.id.rawValue)', 'pending')
        """)
    }
  }

  @Test func test_deliveries_refuseAStateOtherThanPendingOrAcknowledged() throws {
    let fixture = try Fixture()
    try fixture.insertMessage()

    #expect(throws: RawDatabaseError.self) {
      try fixture.raw.execute(
        """
        INSERT INTO deliveries (message_seq, recipient, state)
        VALUES (1, '\(fixture.sender.id.rawValue)', 'read')
        """)
    }
  }

  @Test func test_deliveries_acknowledgedNeedsATime_pendingForbidsOne() throws {
    let fixture = try Fixture()
    try fixture.insertMessage()
    let recipient = fixture.sender.id.rawValue

    #expect(throws: RawDatabaseError.self, "acknowledged without a time") {
      try fixture.raw.execute(
        """
        INSERT INTO deliveries (message_seq, recipient, state)
        VALUES (1, '\(recipient)', 'acknowledged')
        """)
    }
    #expect(throws: RawDatabaseError.self, "pending with a time") {
      try fixture.raw.execute(
        """
        INSERT INTO deliveries (message_seq, recipient, state, acknowledged_at_ms)
        VALUES (1, '\(recipient)', 'pending', 5)
        """)
    }
  }

  @Test func test_deliveries_oneRowPerRecipientOfAMessage() throws {
    let fixture = try Fixture()
    try fixture.insertMessage()
    let insert = """
      INSERT INTO deliveries (message_seq, recipient, state)
      VALUES (1, '\(fixture.sender.id.rawValue)', 'pending')
      """
    try fixture.raw.execute(insert)

    #expect(throws: RawDatabaseError.self) { try fixture.raw.execute(insert) }
  }
}
