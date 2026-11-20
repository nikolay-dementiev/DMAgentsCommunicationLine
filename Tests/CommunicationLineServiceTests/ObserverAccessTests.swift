import CommunicationLineWire
import Foundation
import Testing

/// The observer credential may call `health` and `principal.list`, and nothing else.
struct ObserverAccessTests {
  private struct World {
    let fixture: ServiceFixture
    let owner: String
    let observer: String
    let alpha: (id: String, token: String)
    let beta: (id: String, token: String)
  }

  private func makeWorld() throws -> World {
    let fixture = try ServiceFixture()
    let owner = try fixture.bootstrapOwner()
    let alpha = try fixture.enrol(owner: owner, family: "A", name: "alpha")
    let beta = try fixture.enrol(owner: owner, family: "A", name: "beta")
    let issued = fixture.call("observer.issue", token: owner)
    let observer = try fixture.string(issued, "token")
    return World(fixture: fixture, owner: owner, observer: observer, alpha: alpha, beta: beta)
  }

  /// Every operation of the protocol with arguments that would succeed for the right caller, so
  /// that a refusal can only come from who is asking.
  private func everyOperation(_ world: World) -> [(String, [String: WireValue])] {
    let target = WireValue.string(world.alpha.id)
    return [
      ("send", ["to": .array([target]), "subject": .string("s"), "body": .string("b")]),
      ("inbox", [:]), ("read", ["id": .string("m1")]), ("acknowledge", ["id": .string("m1")]),
      ("wait", ["timeout": .integer(1)]), ("owner.credential", [:]),
      (
        "principal.create",
        ["family": .string("A"), "role": .string("agent"), "name": .string("gamma")]
      ),
      ("principal.disable", ["principal": target]), ("principal.enable", ["principal": target]),
      ("credential.issue", ["principal": target]),
      (
        "grant.add",
        ["reader_kind": .string("principal"), "reader": target, "target_kind": .string("global")]
      ),
      ("grant.revoke", ["id": .integer(1)]), ("grant.list", [:]),
      ("rule.add", ["from": .string("A"), "to": .string("B")]),
      ("rule.remove", ["from": .string("A"), "to": .string("B")]), ("rule.list", [:]),
      ("setting.get", ["key": .string("health.threshold")]),
      ("setting.set", ["key": .string("health.threshold"), "value": .integer(5)]),
      ("activity.list", [:]), ("health.cleanup", [:]), ("observer.issue", [:]),
      ("observer.revoke", [:]),
    ]
  }

  @Test func test_anObserver_readsHealthAndThePrincipalList() throws {
    let world = try makeWorld()

    let health = world.fixture.call("health", token: world.observer)
    let family = world.fixture.call("health", token: world.observer, ["family": .string("A")])
    let listed = world.fixture.call("principal.list", token: world.observer)
    let byOwner = world.fixture.call("principal.list", token: world.owner)

    #expect(health.isSuccess, "health is readable")
    #expect(family.isSuccess, "health with a family is readable")
    #expect(listed.isSuccess, "the principal list is readable")
    #expect(listed.result == byOwner.result, "and it is the list the owner sees")
  }

  @Test func test_anObserver_isRefusedEveryOtherOperation_withThePermissionOutcome() throws {
    let world = try makeWorld()

    for (operation, arguments) in everyOperation(world) {
      let response = world.fixture.call(operation, token: world.observer, arguments)

      #expect(!response.isSuccess, "\(operation) is refused to an observer")
      #expect(
        response.failure?.code.errorClass == .permission,
        "\(operation) is refused with the permission outcome: \(String(describing: response.failure))"
      )
    }
  }

  @Test func test_whatAnObserverIsRefused_changesNothing() throws {
    let world = try makeWorld()
    let before = world.fixture.call("principal.list", token: world.owner).result
    let threshold: [String: WireValue] = ["key": .string("health.threshold")]
    let setting = world.fixture.call("setting.get", token: world.owner, threshold).result

    for (operation, arguments) in everyOperation(world) {
      _ = world.fixture.call(operation, token: world.observer, arguments)
    }

    #expect(
      world.fixture.call("principal.list", token: world.owner).result == before,
      "no principal was created, disabled or enabled")
    #expect(
      world.fixture.call("setting.get", token: world.owner, threshold).result == setting,
      "no setting changed")
    #expect(
      world.fixture.call("health", token: world.observer).isSuccess,
      "the observer token is still the one that works: nothing replaced or revoked it")
  }

  @Test func test_aRefusalOfAnObserver_isRecordedInTheActivityLogAsTheObservers() throws {
    let world = try makeWorld()
    _ = world.fixture.call(
      "send", token: world.observer,
      ["to": .array([.string(world.alpha.id)]), "subject": .string("s"), "body": .string("b")])

    let log = world.fixture.call("activity.list", token: world.owner)

    guard case .object(let fields)? = log.result, case .array(let entries)? = fields["records"]
    else {
      Issue.record("the activity log has entries: \(String(describing: log.result))")
      return
    }
    let refusals = entries.filter { entry in
      guard case .object(let record) = entry else { return false }
      return record["actor"] == .string("observer") && record["operation"] == .string("send")
    }
    #expect(refusals.count == 1, "the refused send is recorded once, as the observer's")
  }

  @Test func test_anObserver_hasNoInbox_andIsNotAPrincipalAnyoneCanWriteTo() throws {
    let world = try makeWorld()

    let listed = world.fixture.call("principal.list", token: world.owner)

    guard case .object(let fields)? = listed.result,
      case .array(let principals)? = fields["principals"]
    else {
      Issue.record("the list has principals")
      return
    }
    #expect(principals.count == 2, "only the two agents are listed: the observer is no principal")
    #expect(
      world.fixture.call("inbox", token: world.observer).failure?.code == .agentRequired,
      "there is no inbox to read")
  }

  @Test func test_aRevokedObserverToken_isRefusedEvenForHealth() throws {
    let world = try makeWorld()

    let revoked = world.fixture.call("observer.revoke", token: world.owner)
    let afterwards = world.fixture.call("health", token: world.observer)

    #expect(revoked.isSuccess, "the owner revokes it")
    #expect(afterwards.failure?.code.errorClass == .authentication, "the token no longer works")
  }

  @Test func test_issuingANewObserverToken_stopsTheOldOne() throws {
    let world = try makeWorld()

    let second = try world.fixture.string(
      world.fixture.call("observer.issue", token: world.owner), "token")

    #expect(
      world.fixture.call("health", token: world.observer).failure?.code.errorClass
        == .authentication, "the old token is revoked")
    #expect(world.fixture.call("health", token: second).isSuccess, "the new token works")
  }
}
