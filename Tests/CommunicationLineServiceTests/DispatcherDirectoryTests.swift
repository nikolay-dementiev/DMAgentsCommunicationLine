import CommunicationLineWire
import Foundation
import Testing

struct DispatcherDirectoryTests {
  private struct World {
    let fixture: ServiceFixture
    let owner: String
    let alphaHead: (id: String, token: String)
    let alphaAgent: (id: String, token: String)
    let betaAgent: (id: String, token: String)
  }

  private func makeWorld() throws -> World {
    let fixture = try ServiceFixture()
    let owner = try fixture.bootstrapOwner()
    // Created out of order on purpose: the listing must sort them itself.
    let betaAgent = try fixture.enrol(owner: owner, family: "B", name: "beta agent")
    let alphaAgent = try fixture.enrol(owner: owner, family: "A", name: "alpha agent")
    let alphaHead = try fixture.enrol(owner: owner, family: "A", name: "alpha head", role: "head")
    return World(
      fixture: fixture, owner: owner, alphaHead: alphaHead, alphaAgent: alphaAgent,
      betaAgent: betaAgent)
  }

  private func entries(_ response: WireResponse) throws -> [[String: WireValue]] {
    guard case .object(let fields)? = response.result,
      case .array(let items)? = fields["principals"]
    else { throw POSIXError(.EIO) }
    return items.compactMap { item in
      if case .object(let entry) = item { return entry }
      return nil
    }
  }

  private func send(_ world: World, from token: String, to ids: [String]) {
    _ = world.fixture.call(
      "send", token: token,
      ["to": .array(ids.map { .string($0) }), "subject": .string("s"), "body": .string("b")])
  }

  @Test func test_list_showsEveryPrincipalSortedByFamilyThenRoleThenName() throws {
    let world = try makeWorld()

    let list = try entries(world.fixture.call("principal.list", token: world.owner))

    #expect(
      list.map { $0["name"] } == [
        .string("alpha agent"), .string("alpha head"), .string("beta agent"),
      ], "family first, then role (agent before head), then name")
    #expect(
      list[0] == [
        "id": .string(world.alphaAgent.id), "family": .string("A"), "role": .string("agent"),
        "name": .string("alpha agent"), "enabled": .bool(true), "pending": .integer(0),
        "listening_since_ms": .null,
      ], "every field of an idle principal, and no token")
  }

  @Test func test_list_countsUnacknowledgedDeliveries_andShowsADisabledPrincipal() throws {
    let world = try makeWorld()
    send(world, from: world.alphaHead.token, to: [world.alphaAgent.id])
    send(world, from: world.alphaHead.token, to: [world.alphaAgent.id])
    _ = world.fixture.call(
      "principal.disable", token: world.owner, ["principal": .string(world.betaAgent.id)])

    let list = try entries(world.fixture.call("principal.list", token: world.owner))

    #expect(list[0]["pending"] == .integer(2), "two deliveries wait for the alpha agent")
    #expect(list[1]["pending"] == .integer(0), "the head has no mail")
    #expect(list[2]["enabled"] == .bool(false), "the disabled principal is listed as disabled")
  }

  @Test func test_list_showsAParkedWaitAsListening_andReleasesItWhenTheWaitEnds() throws {
    let world = try makeWorld()
    let fixture = world.fixture
    let waiterToken = world.alphaAgent.token
    let finished = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
      _ = fixture.call("wait", token: waiterToken, ["timeout": .integer(30)])
      finished.signal()
    }
    let deadline = Date().addingTimeInterval(5)
    var list = try entries(fixture.call("principal.list", token: world.owner))
    while list[0]["listening_since_ms"] == .null {
      try #require(Date() < deadline, "the wait never showed as listening")
      Thread.sleep(forTimeInterval: 0.01)
      list = try entries(fixture.call("principal.list", token: world.owner))
    }

    #expect(
      list[0]["listening_since_ms"] == .integer(1_800_000_000_000),
      "the waiting agent is listening since the start of its wait")
    #expect(list[1]["listening_since_ms"] == .null, "the head does not wait")
    #expect(list[2]["listening_since_ms"] == .null, "the other family does not wait")

    send(world, from: world.alphaHead.token, to: [world.alphaAgent.id])
    #expect(finished.wait(timeout: .now() + 10) == .success, "mail ended the wait")
    let after = try entries(fixture.call("principal.list", token: world.owner))
    #expect(after[0]["listening_since_ms"] == .null, "an ended wait is not listening")
    #expect(after[0]["pending"] == .integer(1), "the mail that ended it is still pending")
  }

  @Test func test_list_keepsOnlyTheRequestedFamily() throws {
    let world = try makeWorld()

    let alpha = try entries(
      world.fixture.call("principal.list", token: world.owner, ["family": .string("A")]))
    let beta = try entries(
      world.fixture.call("principal.list", token: world.owner, ["family": .string("B")]))

    #expect(alpha.count == 2 && alpha.allSatisfy { $0["family"] == .string("A") }, "only family A")
    #expect(beta.count == 1 && beta[0]["family"] == .string("B"), "only family B")
  }

  @Test func test_list_refusesAFamilyWithNoPrincipal() throws {
    let world = try makeWorld()

    let response = world.fixture.call(
      "principal.list", token: world.owner, ["family": .string("Nobody")])

    #expect(response.failure?.code == .unknownFamily, "a family that does not exist")
    #expect(response.failure?.message == "no principal in family Nobody", "the message names it")
    #expect(response.failure?.code.errorClass == .notFound, "a client maps it to exit status 6")
  }

  @Test func test_list_isRefusedToAnAgent_andToACallerWithNoToken() throws {
    let world = try makeWorld()

    #expect(
      world.fixture.call("principal.list", token: world.alphaHead.token).failure?.code
        == .ownerRequired, "a head is not the owner")
    #expect(
      world.fixture.call("principal.list", token: world.alphaAgent.token).failure?.code
        == .ownerRequired, "an agent is not the owner")
    #expect(
      world.fixture.call("principal.list").failure?.code == .tokenRequired, "a token is required")
  }
}
