import CommunicationLineWire
import Foundation
import Testing

/// The health document lists every principal with its presence, read from the same place as
/// `principal.list`, so the two cannot disagree.
struct HealthPresenceTests {
  private struct World {
    let fixture: ServiceFixture
    let owner: String
    let alpha: (id: String, token: String)
    let alphaHead: (id: String, token: String)
    let beta: (id: String, token: String)
  }

  private func makeWorld() throws -> World {
    let fixture = try ServiceFixture()
    let owner = try fixture.bootstrapOwner()
    let beta = try fixture.enrol(owner: owner, family: "B", name: "beta")
    let alpha = try fixture.enrol(owner: owner, family: "A", name: "alpha")
    let alphaHead = try fixture.enrol(owner: owner, family: "A", name: "alpha head", role: "head")
    return World(fixture: fixture, owner: owner, alpha: alpha, alphaHead: alphaHead, beta: beta)
  }

  private func principals(_ response: WireResponse) throws -> [WireValue] {
    guard case .object(let fields)? = response.result,
      case .array(let items)? = fields["principals"]
    else { throw POSIXError(.EIO) }
    return items
  }

  private func listeningSince(of id: String, in items: [WireValue]) -> WireValue? {
    for item in items {
      if case .object(let entry) = item, entry["id"] == .string(id) {
        return entry["listening_since_ms"]
      }
    }
    return nil
  }

  /// Parks a wait of `token` on a thread of its own; the semaphore is signalled when it ends.
  private func park(_ world: World, token: String) -> DispatchSemaphore {
    let finished = DispatchSemaphore(value: 0)
    let fixture = world.fixture
    Thread.detachNewThread {
      _ = fixture.call("wait", token: token, ["timeout": .integer(30)])
      finished.signal()
    }
    return finished
  }

  private func waitUntilListening(_ world: World, _ id: String) throws {
    let deadline = Date().addingTimeInterval(10)
    while listeningSince(
      of: id, in: try principals(world.fixture.call("health", token: world.owner))) == .null
    {
      try #require(Date() < deadline, "the wait never showed as listening")
      Thread.sleep(forTimeInterval: 0.01)
    }
  }

  @Test func test_health_listsThePrincipalsExactlyAsPrincipalList() throws {
    let world = try makeWorld()
    _ = world.fixture.call(
      "send", token: world.alphaHead.token,
      ["to": .array([.string(world.alpha.id)]), "subject": .string("s"), "body": .string("b")])
    _ = world.fixture.call(
      "principal.disable", token: world.owner, ["principal": .string(world.beta.id)])

    let health = try principals(world.fixture.call("health", token: world.owner))
    let listing = try principals(world.fixture.call("principal.list", token: world.owner))

    #expect(health == listing, "the same principals, in the same order, with the same fields")
    #expect(health.count == 3, "all three principals are listed")
  }

  @Test func test_health_withAFamily_listsOnlyThatFamily() throws {
    let world = try makeWorld()

    let health = try principals(
      world.fixture.call("health", token: world.owner, ["family": .string("A")]))
    let listing = try principals(
      world.fixture.call("principal.list", token: world.owner, ["family": .string("A")]))

    #expect(health == listing, "the family filter of principal.list")
    #expect(health.count == 2, "the two principals of family A")
  }

  @Test func test_health_showsAParkedWaitAsListening_andEndingItClearsIt() throws {
    let world = try makeWorld()
    let finished = park(world, token: world.alpha.token)
    try waitUntilListening(world, world.alpha.id)

    let items = try principals(world.fixture.call("health", token: world.owner))
    #expect(
      listeningSince(of: world.alpha.id, in: items) == .integer(1_800_000_000_000),
      "the waiting principal is listening since its wait started")
    #expect(
      listeningSince(of: world.beta.id, in: items) == .null, "a principal with no wait is not")

    _ = world.fixture.call(
      "send", token: world.alphaHead.token,
      ["to": .array([.string(world.alpha.id)]), "subject": .string("s"), "body": .string("b")])
    #expect(finished.wait(timeout: .now() + 10) == .success, "mail ended the wait")
    let after = try principals(world.fixture.call("health", token: world.owner))
    #expect(
      listeningSince(of: world.alpha.id, in: after) == .null, "an ended wait is not listening")
  }

  @Test func test_health_reportsTheOldestOfTwoWaitsOfOnePrincipal() throws {
    let world = try makeWorld()
    let first = park(world, token: world.alpha.token)
    try waitUntilListening(world, world.alpha.id)
    world.fixture.clock.advance(seconds: 10)
    let second = park(world, token: world.alpha.token)
    // A wait that is still running 0.3 s after it started has parked: it would have ended at once
    // with too_many_waiters, or with mail, otherwise. Nothing else shows a second wait of the
    // same principal, and probing with a third wait would take the place that second one needs.
    Thread.sleep(forTimeInterval: 0.3)
    try #require(second.wait(timeout: .now()) == .timedOut, "the second wait is still parked")

    let items = try principals(world.fixture.call("health", token: world.owner))

    #expect(
      listeningSince(of: world.alpha.id, in: items) == .integer(1_800_000_000_000),
      "listening since the oldest wait, not the newest")
    world.fixture.runtime.cancelWaits()
    #expect(first.wait(timeout: .now() + 10) == .success, "the first wait ended")
    #expect(second.wait(timeout: .now() + 10) == .success, "the second wait ended")
  }
}
