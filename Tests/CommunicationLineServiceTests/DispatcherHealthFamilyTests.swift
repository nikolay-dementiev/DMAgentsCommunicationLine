import CommunicationLineWire
import Foundation
import Testing

struct DispatcherHealthFamilyTests {
  private func fields(_ response: WireResponse) throws -> [String: WireValue] {
    guard case .object(let fields)? = response.result else { throw POSIXError(.EIO) }
    return fields
  }

  private struct World {
    let fixture: ServiceFixture
    let owner: String
    let alpha: (id: String, token: String)
    let beta: (id: String, token: String)
  }

  private func makeWorld() throws -> World {
    let fixture = try ServiceFixture()
    let owner = try fixture.bootstrapOwner()
    let alpha = try fixture.enrol(owner: owner, family: "A", name: "alpha")
    let beta = try fixture.enrol(owner: owner, family: "B", name: "beta")
    _ = fixture.call("rule.add", token: owner, ["from": .string("A"), "to": .string("B")])
    return World(fixture: fixture, owner: owner, alpha: alpha, beta: beta)
  }

  private func send(_ world: World, to id: String) {
    _ = world.fixture.call(
      "send", token: world.alpha.token,
      ["to": .array([.string(id)]), "subject": .string("s"), "body": .string("b")])
  }

  @Test func test_health_reportsHowManyRecipientsWithMailAreNotListening() throws {
    let world = try makeWorld()
    send(world, to: world.alpha.id)
    send(world, to: world.beta.id)

    let report = try fields(world.fixture.call("health", token: world.owner))

    #expect(
      report["not_listening_with_pending"] == .integer(2),
      "two principals have mail and no wait is parked")
  }

  @Test func test_health_withAFamily_countsOnlyThatFamily_overdueIncluded() throws {
    let world = try makeWorld()
    send(world, to: world.alpha.id)
    send(world, to: world.beta.id)
    world.fixture.clock.advance(days: 31.0 / 1440)

    let scoped = try fields(
      world.fixture.call("health", token: world.owner, ["family": .string("B")]))
    let everyone = try fields(world.fixture.call("health", token: world.owner))

    #expect(
      scoped["pending"]
        == .array([.object(["principal": .string(world.beta.id), "count": .integer(1)])]),
      "only family B's recipient is pending")
    #expect(scoped["overdue_count"] == .integer(1), "only its overdue delivery is counted")
    #expect(scoped["not_listening_with_pending"] == .integer(1), "and only its principal")
    #expect(everyone["overdue_count"] == .integer(2), "without a family both are counted")
  }

  @Test func test_health_withAFamilyThatHasNoPrincipal_isRefused() throws {
    let world = try makeWorld()

    let response = world.fixture.call(
      "health", token: world.owner, ["family": .string("Nobody")])

    #expect(response.failure?.code == .unknownFamily, "the same refusal as principal.list")
    #expect(response.failure?.message == "no principal in family Nobody", "the message names it")
  }

  @Test func test_health_withAFamily_isStillOwnerOnly() throws {
    let world = try makeWorld()

    let response = world.fixture.call(
      "health", token: world.alpha.token, ["family": .string("A")])

    #expect(response.failure?.code == .ownerRequired, "an agent token is refused")
  }
}
