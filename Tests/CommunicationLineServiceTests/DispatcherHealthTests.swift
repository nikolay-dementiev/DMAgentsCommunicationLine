import CommunicationLineWire
import Foundation
import Testing

struct DispatcherHealthTests {
  private func object(_ value: WireValue?) throws -> [String: WireValue] {
    guard case .object(let fields)? = value else { throw POSIXError(.EIO) }
    return fields
  }

  private func list(_ value: WireValue?) throws -> [WireValue] {
    guard case .array(let items)? = value else { throw POSIXError(.EIO) }
    return items
  }

  @Test func test_health_worksOnAFreshStoreWithoutAnyAgent() throws {
    let fixture = try ServiceFixture()
    let owner = try fixture.bootstrapOwner()

    let response = fixture.call("health", token: owner)
    let fields = try object(response.result)

    #expect(response.isSuccess, "the owner needs no agent session to ask")
    #expect(fields["pending"] == .array([]), "nobody has mail")
    #expect(fields["overdue_count"] == .integer(0), "nothing is overdue")
    #expect(fields["overdue"] == .array([]), "no overdue entries")
    #expect(fields["warnings"] == .array([]), "no warning")
    #expect(fields["last_cleanup"] == .null, "no cleanup has run")
    #expect(fields["started_at_ms"] == .integer(1_800_000_000_000), "the start of the service")
    let storage = try object(fields["storage"])
    #expect(storage["budget_bytes"] == .integer(5_000_000_000), "the default budget")
    #expect(storage["warning_percent"] == .integer(80), "the default warning percent")
    guard case .integer(let used)? = storage["used_bytes"] else {
      Issue.record("used_bytes is a number")
      return
    }
    #expect(used > 0, "the schema itself takes space")
  }

  @Test func test_health_listsAnOverdueDeliveryWithItsAge_andCountsPendingPerPrincipal() throws {
    let fixture = try ServiceFixture()
    let owner = try fixture.bootstrapOwner()
    let alice = try fixture.enrol(owner: owner, family: "A", name: "alice")
    let bob = try fixture.enrol(owner: owner, family: "A", name: "bob")
    let sent = fixture.call(
      "send", token: alice.token,
      ["to": .array([.string(bob.id)]), "subject": .string("s"), "body": .string("b")])
    let messageID = try fixture.string(sent, "id")
    fixture.clock.advance(days: 31.0 / 1440)

    let fields = try object(fixture.call("health", token: owner).result)

    #expect(
      fields["pending"] == .array([.object(["principal": .string(bob.id), "count": .integer(1)])]),
      "bob has one pending delivery")
    #expect(fields["overdue_count"] == .integer(1), "31 minutes is past the 30 minute threshold")
    #expect(
      fields["overdue"]
        == .array([
          .object([
            "message": .string(messageID), "recipient": .string(bob.id),
            "age_seconds": .integer(1860),
          ])
        ]), "the message, its recipient and its age")
  }

  @Test func test_health_isRefusedToAnAgent() throws {
    let fixture = try ServiceFixture()
    let owner = try fixture.bootstrapOwner()
    let alice = try fixture.enrol(owner: owner, family: "A", name: "alice")

    #expect(
      fixture.call("health", token: alice.token).failure?.code == .ownerRequired,
      "only the owner reads the report")
    #expect(fixture.call("health").failure?.code == .tokenRequired, "a token is required")
  }

  @Test func test_health_showsTheLastCleanup() throws {
    let fixture = try ServiceFixture()
    let owner = try fixture.bootstrapOwner()
    _ = fixture.call("health.cleanup", token: owner)

    let fields = try object(fixture.call("health", token: owner).result)

    #expect(
      fields["last_cleanup"]
        == .object([
          "at_ms": .integer(1_800_000_000_000), "ok": .bool(true), "deliveries": .integer(0),
          "messages": .integer(0), "activity": .integer(0),
        ]), "when the cleanup ran and what it deleted")
  }
}
