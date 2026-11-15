import CommunicationLineWire
import Foundation
import Testing

struct DispatcherCleanupTests {
  /// A store with one message from alice to bob, acknowledged by bob.
  private func acknowledgedMail() throws -> (
    fixture: ServiceFixture, owner: String, alice: String
  ) {
    let fixture = try ServiceFixture()
    let owner = try fixture.bootstrapOwner()
    let alice = try fixture.enrol(owner: owner, family: "A", name: "alice")
    let bob = try fixture.enrol(owner: owner, family: "A", name: "bob")
    let sent = fixture.call(
      "send", token: alice.token,
      ["to": .array([.string(bob.id)]), "subject": .string("s"), "body": .string("b")])
    _ = fixture.call(
      "acknowledge", token: bob.token, ["id": .string(try fixture.string(sent, "id"))])
    return (fixture, owner, alice.token)
  }

  @Test func test_healthCleanup_deletesMailPastItsRetention_andAnswersWhatItDeleted() throws {
    let world = try acknowledgedMail()
    world.fixture.clock.advance(days: 91)

    let response = world.fixture.call("health.cleanup", token: world.owner)

    #expect(response.isSuccess, "the owner runs cleanup")
    #expect(try world.fixture.field(response, "deliveries") == .integer(1), "one delivery")
    #expect(try world.fixture.field(response, "messages") == .integer(1), "one message")
    let raw = try RawFile(folder: world.fixture.folder)
    #expect(try raw.count("messages") == 0, "the message is gone from the store")
  }

  @Test func test_healthCleanup_keepsMailInsideItsRetention() throws {
    let world = try acknowledgedMail()
    world.fixture.clock.advance(days: 89)

    let response = world.fixture.call("health.cleanup", token: world.owner)

    #expect(try world.fixture.field(response, "messages") == .integer(0), "nothing is due")
    #expect(try RawFile(folder: world.fixture.folder).count("messages") == 1, "mail stays")
  }

  @Test func test_healthCleanup_isRefusedToAnAgent_andToAnonymousCallers() throws {
    let world = try acknowledgedMail()
    world.fixture.clock.advance(days: 91)

    let agent = world.fixture.call("health.cleanup", token: world.alice)
    let anonymous = world.fixture.call("health.cleanup")

    #expect(agent.failure?.code == .ownerRequired, "an agent may not run cleanup")
    #expect(anonymous.failure?.code == .tokenRequired, "a token is required")
    #expect(try RawFile(folder: world.fixture.folder).count("messages") == 1, "nothing was deleted")
  }

  @Test func test_healthCleanup_leavesItsOwnRecordInTheActivityLog() throws {
    let world = try acknowledgedMail()

    _ = world.fixture.call("health.cleanup", token: world.owner)
    let page = world.fixture.call("activity.list", token: world.owner, ["limit": .integer(50)])

    guard case .array(let records) = try world.fixture.field(page, "records") else {
      Issue.record("the log answers with a list")
      return
    }
    let operations = records.compactMap { record -> String? in
      guard case .object(let fields) = record, case .string(let name)? = fields["operation"]
      else { return nil }
      return name
    }
    #expect(operations.contains("health.cleanup"), "the owner's cleanup request is on record")
  }
}

struct HealthAfterCleanupTests {
  @Test func test_health_reportsWhatTheOwnerCleanupDeleted() throws {
    let fixture = try ServiceFixture()
    let owner = try fixture.bootstrapOwner()
    let alice = try fixture.enrol(owner: owner, family: "A", name: "alice")
    let bob = try fixture.enrol(owner: owner, family: "A", name: "bob")
    let sent = fixture.call(
      "send", token: alice.token,
      ["to": .array([.string(bob.id)]), "subject": .string("s"), "body": .string("b")])
    _ = fixture.call(
      "acknowledge", token: bob.token, ["id": .string(try fixture.string(sent, "id"))])
    fixture.clock.advance(days: 91)

    _ = fixture.call("health.cleanup", token: owner)
    let health = fixture.call("health", token: owner)

    guard case .object(let last) = try fixture.field(health, "last_cleanup") else {
      Issue.record("a cleanup ran")
      return
    }
    #expect(last["deliveries"] == .integer(1), "the report holds what that run deleted")
    #expect(last["messages"] == .integer(1), "and the message")
  }
}
