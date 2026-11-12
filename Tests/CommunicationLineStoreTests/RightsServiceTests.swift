import CommunicationLineApplication
import CommunicationLineDomain
import CommunicationLineStore
import Foundation
import Testing

final class MutableClock: WallClock {
  var instant: Date
  init(_ instant: Date) { self.instant = instant }
  func now() -> Date { instant }
}

/// A real store with an owner, two families and a rights service on top of it.
private struct RightsFixture {
  let identity: IdentityFixture
  let rights: RightsService
  let clock = MutableClock(Date(timeIntervalSince1970: 1_800_000_000))
  let alpha: Principal
  let alphaToken: CredentialToken
  let beta: Principal
  let betaToken: CredentialToken
  let betaHead: Principal
  let betaHeadToken: CredentialToken
  let stranger: Principal
  let strangerToken: CredentialToken

  var owner: CredentialToken { identity.owner }

  init() throws {
    identity = try IdentityFixture()
    let service = identity.service
    let owner = identity.owner
    func enrol(_ family: String, _ role: RoleKind, _ name: String) throws -> (
      Principal, CredentialToken
    ) {
      let principal = try service.createPrincipal(
        family: family, role: role, displayName: name, ownerToken: owner)
      return (principal, try service.issueCredential(for: principal.id, ownerToken: owner))
    }
    (alpha, alphaToken) = try enrol("A", .agent, "alpha")
    (beta, betaToken) = try enrol("B", .agent, "beta")
    (betaHead, betaHeadToken) = try enrol("B", .head, "beta head")
    (stranger, strangerToken) = try enrol("C", .agent, "stranger")
    rights = RightsService(
      rights: SQLiteRightsStore(store: identity.store),
      principals: SQLiteIdentityStore(store: identity.store), authenticator: service,
      clock: clock)
  }

  var meta: MessageMeta {
    MessageMeta(sender: alpha.id, recipients: [beta.id], family: "A")
  }

  func count(_ table: String) throws -> Int {
    try identity.raw().integer("SELECT count(*) FROM \(table)")
  }
}

@Suite struct RightsServiceTests {
  // MARK: - Owner-only data

  @Test func test_everyRightsChange_withAnAgentToken_isRefusedAndStoresNothing() throws {
    let fixture = try RightsFixture()
    let agent = fixture.alphaToken
    let rights = fixture.rights
    let grant = try rights.addReadGrant(
      reader: .family("C"), target: .global, expiresAt: nil, ownerToken: fixture.owner)

    let attempts: [(String, () throws -> Void)] = [
      ("allowSending", { try rights.allowSending(from: "A", to: "B", ownerToken: agent) }),
      ("removeSendRule", { try rights.removeSendRule(from: "A", to: "B", ownerToken: agent) }),
      (
        "addReadGrant",
        {
          _ = try rights.addReadGrant(
            reader: .family("A"), target: .global, expiresAt: nil, ownerToken: agent)
        }
      ),
      ("revokeReadGrant", { try rights.revokeReadGrant(id: grant, ownerToken: agent) }),
      ("listSendRules", { _ = try rights.sendRules(ownerToken: agent) }),
      ("listReadGrants", { _ = try rights.readGrants(ownerToken: agent) }),
    ]
    for (name, attempt) in attempts {
      #expect(throws: IdentityError.ownerCredentialRequired, "\(name) is owner-only") {
        try attempt()
      }
    }
    #expect(try fixture.count("send_rules") == 0, "no send rule was stored")
    #expect(try fixture.count("read_grants") == 1, "only the owner's grant exists")
    #expect(
      try fixture.identity.raw().integer(
        "SELECT count(*) FROM read_grants WHERE revoked_at_ms IS NULL")
        == 1, "the owner's grant was not revoked")
  }

  @Test func test_rightsChange_invalidInput_isRefused() throws {
    let fixture = try RightsFixture()
    let past = fixture.clock.instant.addingTimeInterval(-1)

    #expect(throws: RightsError.invalidRule) {
      try fixture.rights.allowSending(from: "A", to: "A", ownerToken: fixture.owner)
    }
    #expect(throws: RightsError.invalidRule) {
      try fixture.rights.allowSending(from: "", to: "B", ownerToken: fixture.owner)
    }
    #expect(throws: RightsError.invalidRule) {
      _ = try fixture.rights.addReadGrant(
        reader: .family(" "), target: .global, expiresAt: nil, ownerToken: fixture.owner)
    }
    #expect(throws: RightsError.invalidRule) {
      _ = try fixture.rights.addReadGrant(
        reader: .family("C"), target: .family(" "), expiresAt: nil, ownerToken: fixture.owner)
    }
    #expect(throws: RightsError.invalidRule) {
      _ = try fixture.rights.addReadGrant(
        reader: .family("C"), target: .principal(PrincipalID("")), expiresAt: nil,
        ownerToken: fixture.owner)
    }
    #expect(throws: RightsError.expiryInThePast) {
      _ = try fixture.rights.addReadGrant(
        reader: .family("C"), target: .global, expiresAt: past, ownerToken: fixture.owner)
    }
    #expect(throws: RightsError.unknownGrant(999)) {
      try fixture.rights.revokeReadGrant(id: 999, ownerToken: fixture.owner)
    }
  }

  // MARK: - Sending

  @Test func test_canSend_withinAFamily_needsNoRule() throws {
    let fixture = try RightsFixture()

    #expect(
      try fixture.rights.canSend(token: fixture.betaToken, to: fixture.betaHead.id),
      "same family")
  }

  @Test func test_canSend_acrossFamilies_followsTheOwnersRuleInThatDirectionOnly() throws {
    let fixture = try RightsFixture()
    #expect(
      !(try fixture.rights.canSend(token: fixture.alphaToken, to: fixture.beta.id)),
      "no rule yet")

    try fixture.rights.allowSending(from: "A", to: "B", ownerToken: fixture.owner)

    #expect(try fixture.rights.canSend(token: fixture.alphaToken, to: fixture.beta.id), "A to B")
    #expect(
      !(try fixture.rights.canSend(token: fixture.betaToken, to: fixture.alpha.id)),
      "B to A has no rule")

    try fixture.rights.removeSendRule(from: "A", to: "B", ownerToken: fixture.owner)

    #expect(
      !(try fixture.rights.canSend(token: fixture.alphaToken, to: fixture.beta.id)),
      "removed rule")
  }

  @Test func test_canSend_toADisabledOrUnknownPrincipal_failsVisibly() throws {
    let fixture = try RightsFixture()
    try fixture.rights.allowSending(from: "A", to: "B", ownerToken: fixture.owner)
    try fixture.identity.service.disablePrincipal(fixture.beta.id, ownerToken: fixture.owner)

    #expect(
      !(try fixture.rights.canSend(token: fixture.alphaToken, to: fixture.beta.id)),
      "a disabled recipient receives nothing")
    #expect(throws: IdentityError.unknownPrincipal(PrincipalID("nobody"))) {
      _ = try fixture.rights.canSend(token: fixture.alphaToken, to: PrincipalID("nobody"))
    }
  }

  @Test func test_canSend_ownerToken_isRefusedBecauseTheOwnerIsNotAPrincipal() throws {
    let fixture = try RightsFixture()

    #expect(throws: IdentityError.principalCredentialRequired) {
      _ = try fixture.rights.canSend(token: fixture.owner, to: fixture.beta.id)
    }
  }

  // MARK: - Reading

  @Test func test_canRead_sendersRecipientsAndTheFamilyHead() throws {
    let fixture = try RightsFixture()

    #expect(try fixture.rights.canRead(token: fixture.alphaToken, meta: fixture.meta), "sender")
    #expect(try fixture.rights.canRead(token: fixture.betaToken, meta: fixture.meta), "recipient")
    #expect(
      !(try fixture.rights.canRead(token: fixture.betaHeadToken, meta: fixture.meta)),
      "the head of another family")
    #expect(
      !(try fixture.rights.canRead(token: fixture.strangerToken, meta: fixture.meta)),
      "an unrelated principal")
  }

  @Test func test_readGrant_widensReadingUntilItExpiresOrIsRevoked() throws {
    let fixture = try RightsFixture()
    let expiry = fixture.clock.instant.addingTimeInterval(600)
    let id = try fixture.rights.addReadGrant(
      reader: .principal(fixture.stranger.id), target: .global, expiresAt: expiry,
      ownerToken: fixture.owner)

    #expect(try fixture.rights.canRead(token: fixture.strangerToken, meta: fixture.meta), "granted")
    #expect(
      try fixture.rights.canRead(token: fixture.alphaToken, meta: fixture.meta),
      "the sender still reads")

    fixture.clock.instant = expiry
    #expect(
      !(try fixture.rights.canRead(token: fixture.strangerToken, meta: fixture.meta)),
      "expired at the expiry instant")

    fixture.clock.instant = expiry.addingTimeInterval(-300)
    #expect(try fixture.rights.canRead(token: fixture.strangerToken, meta: fixture.meta), "valid")
    try fixture.rights.revokeReadGrant(id: id, ownerToken: fixture.owner)
    #expect(
      !(try fixture.rights.canRead(token: fixture.strangerToken, meta: fixture.meta)),
      "revoked")
  }

  @Test func test_familyGrant_reachesEveryPrincipalOfThatFamilyAndNeverAllowsSending() throws {
    let fixture = try RightsFixture()
    _ = try fixture.rights.addReadGrant(
      reader: .family("C"), target: .global, expiresAt: nil, ownerToken: fixture.owner)

    #expect(try fixture.rights.canRead(token: fixture.strangerToken, meta: fixture.meta), "reads")
    #expect(
      !(try fixture.rights.canSend(token: fixture.strangerToken, to: fixture.alpha.id)),
      "a read grant never authorizes sending")
  }

  // MARK: - Effective rights

  @Test func test_effectiveRights_showsOnlyTheCallersOwnRights() throws {
    let fixture = try RightsFixture()
    try fixture.rights.allowSending(from: "A", to: "B", ownerToken: fixture.owner)
    try fixture.rights.allowSending(from: "B", to: "C", ownerToken: fixture.owner)
    _ = try fixture.rights.addReadGrant(
      reader: .principal(fixture.alpha.id), target: .global, expiresAt: nil,
      ownerToken: fixture.owner)
    _ = try fixture.rights.addReadGrant(
      reader: .family("C"), target: .global, expiresAt: nil, ownerToken: fixture.owner)

    let rights = try fixture.rights.effectiveRights(token: fixture.alphaToken)

    #expect(rights.family == "A", "its family")
    #expect(rights.canSendToFamilies == ["A", "B"], "its own family and the rule targets from it")
    #expect(
      rights.readGrants == [
        ReadGrant(
          reader: .principal(fixture.alpha.id), target: .global, expiresAt: nil, isRevoked: false)
      ],
      "only grants that name it or its family; none of the others")
  }

  @Test func test_effectiveRights_ownerToken_isRefused() throws {
    let fixture = try RightsFixture()

    #expect(throws: IdentityError.principalCredentialRequired) {
      _ = try fixture.rights.effectiveRights(token: fixture.owner)
    }
  }

  @Test func test_everyRightsQuery_withADisabledPrincipalsToken_isRefused() throws {
    let fixture = try RightsFixture()
    try fixture.identity.service.disablePrincipal(fixture.alpha.id, ownerToken: fixture.owner)

    #expect(throws: IdentityError.principalDisabled) {
      _ = try fixture.rights.effectiveRights(token: fixture.alphaToken)
    }
    #expect(throws: IdentityError.principalDisabled) {
      _ = try fixture.rights.canRead(token: fixture.alphaToken, meta: fixture.meta)
    }
  }

  // MARK: - Owner listings

  @Test func test_readGrant_targetLimitsWhichMessagesItOpens() throws {
    let fixture = try RightsFixture()
    let familyCMessage = MessageMeta(
      sender: fixture.stranger.id, recipients: [fixture.stranger.id], family: "C")
    _ = try fixture.rights.addReadGrant(
      reader: .principal(fixture.alpha.id), target: .family("B"), expiresAt: nil,
      ownerToken: fixture.owner)

    #expect(
      !(try fixture.rights.canRead(token: fixture.alphaToken, meta: familyCMessage)),
      "the grant names family B, so a message of family C stays closed")

    _ = try fixture.rights.addReadGrant(
      reader: .principal(fixture.alpha.id), target: .principal(fixture.stranger.id),
      expiresAt: nil, ownerToken: fixture.owner)

    #expect(
      try fixture.rights.canRead(token: fixture.alphaToken, meta: familyCMessage),
      "a grant naming the stranger opens the stranger's mail")
    let listed = try fixture.rights.readGrants(ownerToken: fixture.owner).map(\.grant.target)
    #expect(
      listed == [.family("B"), .principal(fixture.stranger.id)],
      "the owner sees the stored targets")
  }

  @Test func test_ownerListings_showRulesAndGrants() throws {
    let fixture = try RightsFixture()
    try fixture.rights.allowSending(from: "A", to: "B", ownerToken: fixture.owner)
    try fixture.rights.allowSending(from: "A", to: "B", ownerToken: fixture.owner)
    let id = try fixture.rights.addReadGrant(
      reader: .family("C"), target: .global, expiresAt: nil, ownerToken: fixture.owner)
    try fixture.rights.revokeReadGrant(id: id, ownerToken: fixture.owner)

    #expect(
      try fixture.rights.sendRules(ownerToken: fixture.owner)
        == [SendRule(fromFamily: "A", toFamily: "B")], "a repeated rule is stored once")
    let grants = try fixture.rights.readGrants(ownerToken: fixture.owner)
    #expect(grants.map(\.id) == [id], "the grant is listed")
    #expect(grants.first?.grant.isRevoked == true, "with its revoked state")
  }
}
