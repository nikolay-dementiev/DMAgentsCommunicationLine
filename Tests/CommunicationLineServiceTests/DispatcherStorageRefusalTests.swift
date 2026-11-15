import CommunicationLineService
import CommunicationLineWire
import Foundation
import Testing

struct DispatcherStorageRefusalTests {
  private struct World {
    let fixture: ServiceFixture
    let owner: String
    let alice: (id: String, token: String)
    let bob: (id: String, token: String)
  }

  private func makeWorld() throws -> World {
    let fixture = try ServiceFixture()
    let owner = try fixture.bootstrapOwner()
    return World(
      fixture: fixture, owner: owner,
      alice: try fixture.enrol(owner: owner, family: "A", name: "alice"),
      bob: try fixture.enrol(owner: owner, family: "A", name: "bob"))
  }

  private func send(_ world: World, subject: String = "s") -> WireResponse {
    world.fixture.call(
      "send", token: world.alice.token,
      [
        "to": .array([.string(world.bob.id)]), "subject": .string(subject),
        "body": .string("b"),
      ])
  }

  /// A budget of one byte puts the store past any refusal level at once.
  private func squeeze(_ world: World) {
    let changed = world.fixture.call(
      "setting.set", token: world.owner, ["key": .string("storage.budget"), "value": .integer(1)])
    #expect(changed.isSuccess, "the owner can still change the budget at the refusal level")
  }

  @Test func test_send_atTheRefusalLevel_isRefusedWithStorageFull() throws {
    let world = try makeWorld()
    #expect(send(world).isSuccess, "a send below the refusal level goes through")
    squeeze(world)

    let refused = send(world, subject: "again")

    #expect(refused.failure?.code == .storageFull, "send is refused with its own error")
  }

  @Test func test_everythingElse_keepsWorkingAtTheRefusalLevel() throws {
    let world = try makeWorld()
    let sent = send(world)
    let messageID = try world.fixture.string(sent, "id")
    squeeze(world)

    let inbox = world.fixture.call("inbox", token: world.bob.token)
    let read = world.fixture.call("read", token: world.bob.token, ["id": .string(messageID)])
    let waited = world.fixture.call("wait", token: world.bob.token, ["timeout": .integer(1)])
    let acknowledged = world.fixture.call(
      "acknowledge", token: world.bob.token, ["id": .string(messageID)])
    let health = world.fixture.call("health", token: world.owner)
    let cleanup = world.fixture.call("health.cleanup", token: world.owner)
    let activity = world.fixture.call("activity.list", token: world.owner)

    #expect(inbox.isSuccess, "the inbox can be read")
    #expect(read.isSuccess, "a message can be read")
    #expect(waited.isSuccess, "a wait answers")
    #expect(acknowledged.isSuccess, "mail can be acknowledged")
    #expect(health.isSuccess, "the owner sees health")
    #expect(cleanup.isSuccess, "the owner can run cleanup")
    #expect(activity.isSuccess, "the owner can read the activity")
  }

  @Test func test_health_showsTheRefusalState_andSendWorksAgainOnceSpaceIsFree() throws {
    let world = try makeWorld()
    squeeze(world)

    let health = world.fixture.call("health", token: world.owner)
    guard case .array(let warnings) = try world.fixture.field(health, "warnings") else {
      throw FixtureError.missing("warnings", health)
    }
    #expect(warnings.contains(.string("storage_full")), "health says that send is refused")

    _ = world.fixture.call(
      "setting.set", token: world.owner,
      ["key": .string("storage.budget"), "value": .integer(5_000_000_000)])
    #expect(send(world).isSuccess, "with room again, send works")
    let healthy = world.fixture.call("health", token: world.owner)
    guard case .array(let after) = try world.fixture.field(healthy, "warnings") else {
      throw FixtureError.missing("warnings", healthy)
    }
    #expect(!after.contains(.string("storage_full")), "and the refusal state clears")
  }
}
