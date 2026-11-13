import CommunicationLineWire
import Foundation
import Testing

struct DispatcherOwnerTests {
  @Test func test_ownerCredential_firstCallBootstraps_laterCallsNeedTheCurrentToken() throws {
    let fixture = try ServiceFixture()
    let first = try fixture.bootstrapOwner()

    let again = fixture.call("owner.credential")
    #expect(
      again.failure?.code == .ownerRequired, "a second bootstrap without the token is refused")

    let rotated = fixture.call("owner.credential", token: first)
    let second = try fixture.string(rotated, "token")
    #expect(second != first, "rotation issues a new token")
    let stale = fixture.call("rule.list", token: first)
    #expect(!stale.isSuccess, "the old owner token stops working")
    #expect(fixture.call("rule.list", token: second).isSuccess, "the new owner token works")
  }

  @Test func test_principalCreate_returnsTheStoredPrincipal() throws {
    let fixture = try ServiceFixture()
    let owner = try fixture.bootstrapOwner()

    let response = fixture.call(
      "principal.create", token: owner,
      ["family": .string("ops"), "role": .string("head"), "name": .string("lead")])

    #expect(response.isSuccess, "the owner may create principals")
    #expect(try fixture.string(response, "family") == "ops", "the family is echoed")
    #expect(try fixture.string(response, "role") == "head", "the role is echoed")
    #expect(try fixture.string(response, "name") == "lead", "the name is echoed")
    #expect(try fixture.field(response, "enabled") == .bool(true), "a new principal is enabled")
  }

  @Test func test_ownerOperations_withAnAgentToken_areRefused() throws {
    let fixture = try ServiceFixture()
    let owner = try fixture.bootstrapOwner()
    let agent = try fixture.enrol(owner: owner, family: "ops", name: "a")
    let target = ["principal": WireValue.string(agent.id)]

    for (operation, arguments) in [
      (
        "principal.create",
        ["family": WireValue.string("x"), "role": .string("agent"), "name": .string("n")]
      ),
      ("principal.disable", target), ("principal.enable", target), ("credential.issue", target),
      ("rule.add", ["from": .string("a"), "to": .string("b")]),
      ("setting.set", ["key": .string("messaging.page_size"), "value": .integer(5)]),
    ] {
      let response = fixture.call(operation, token: agent.token, arguments)
      #expect(response.failure?.code == .ownerRequired, "\(operation) needs the owner token")
    }
  }

  @Test func test_disablePrincipal_stopsItsTokenAndEnableDoesNotRevive() throws {
    let fixture = try ServiceFixture()
    let owner = try fixture.bootstrapOwner()
    let agent = try fixture.enrol(owner: owner, family: "ops", name: "a")
    let id = ["principal": WireValue.string(agent.id)]

    #expect(fixture.call("principal.disable", token: owner, id).isSuccess, "disable succeeds")
    #expect(
      fixture.call("inbox", token: agent.token).failure?.code == .principalDisabled,
      "a disabled principal is refused")
    #expect(fixture.call("principal.enable", token: owner, id).isSuccess, "enable succeeds")
    #expect(
      fixture.call("inbox", token: agent.token).failure?.code == .tokenRevoked,
      "the old token stays revoked after enabling")
    let fresh = try fixture.string(fixture.call("credential.issue", token: owner, id), "token")
    #expect(fixture.call("inbox", token: fresh).isSuccess, "a new credential works")
  }

  @Test func test_unknownPrincipal_isNotFound() throws {
    let fixture = try ServiceFixture()
    let owner = try fixture.bootstrapOwner()

    let response = fixture.call(
      "credential.issue", token: owner, ["principal": .string("nobody")])

    #expect(response.failure?.code == .unknownPrincipal, "no such principal")
  }

  @Test func test_rules_addListRemove() throws {
    let fixture = try ServiceFixture()
    let owner = try fixture.bootstrapOwner()
    let rule: [String: WireValue] = ["from": .string("A"), "to": .string("B")]

    #expect(fixture.call("rule.add", token: owner, rule).isSuccess, "add")
    let listed = try fixture.field(fixture.call("rule.list", token: owner), "rules")
    #expect(listed == .array([.object(rule)]), "the rule is listed")
    #expect(fixture.call("rule.remove", token: owner, rule).isSuccess, "remove")
    #expect(
      try fixture.field(fixture.call("rule.list", token: owner), "rules") == .array([]),
      "no rule is left")
  }

  @Test func test_grants_addListRevoke() throws {
    let fixture = try ServiceFixture()
    let owner = try fixture.bootstrapOwner()
    let added = fixture.call(
      "grant.add", token: owner,
      [
        "reader_kind": .string("family"), "reader": .string("audit"),
        "target_kind": .string("global"),
      ])
    guard case .integer(let id) = try fixture.field(added, "id") else {
      Issue.record("the grant id is an integer")
      return
    }

    let listed = try fixture.field(fixture.call("grant.list", token: owner), "grants")
    guard case .array(let grants) = listed, case .object(let grant)? = grants.first else {
      Issue.record("one grant is listed")
      return
    }
    #expect(grant["reader_kind"] == .string("family"), "reader kind")
    #expect(grant["reader"] == .string("audit"), "reader")
    #expect(grant["target_kind"] == .string("global"), "target kind")
    #expect(grant["revoked"] == .bool(false), "not revoked yet")

    #expect(
      fixture.call("grant.revoke", token: owner, ["id": .integer(id)]).isSuccess, "revoke")
    #expect(
      fixture.call("grant.revoke", token: owner, ["id": .integer(id + 99)]).failure?.code
        == .unknownGrant, "an unknown grant is not found")
  }

  @Test func test_settings_getAndSet() throws {
    let fixture = try ServiceFixture()
    let owner = try fixture.bootstrapOwner()
    let key = WireValue.string("messaging.page_size")

    let before = try fixture.field(
      fixture.call("setting.get", token: owner, ["key": key]), "value")
    #expect(before == .integer(100), "the default applies first")

    let set = fixture.call("setting.set", token: owner, ["key": key, "value": .integer(5)])
    #expect(set.isSuccess, "the owner changes a setting")
    #expect(
      try fixture.field(fixture.call("setting.get", token: owner, ["key": key]), "value")
        == .integer(5), "the new value applies")
    #expect(
      fixture.call("setting.set", token: owner, ["key": key, "value": .integer(500)]).failure?.code
        == .invalidValue, "a value above the range is refused")
    #expect(
      fixture.call("setting.get", token: owner, ["key": .string("no.such")]).failure?.code
        == .unknownKey, "an unknown key is not found")
  }
}
