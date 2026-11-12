import CommunicationLineApplication
import CommunicationLineDomain
import CommunicationLineStore
import Foundation
import Testing

@Suite struct IdentityServiceTests {
  // MARK: - Schema

  @Test func test_schema_identityAndRightsTablesExist() throws {
    let fixture = try IdentityFixture()
    let raw = try fixture.raw()

    #expect(
      try raw.integer("PRAGMA user_version") == SchemaMigrations.all.count, "latest schema version")
    for table in ["principals", "credentials", "read_grants", "send_rules"] {
      #expect(try raw.tableExists(table), "\(table) exists")
    }
  }

  // MARK: - Owner credential

  @Test func test_issueOwnerCredential_firstTime_authenticatesAsTheOwner() throws {
    let fixture = try IdentityFixture()

    #expect(
      try fixture.service.authenticate(fixture.owner) == .owner,
      "the issued token is the owner")
  }

  @Test func test_issueOwnerCredential_whenOneExists_needsTheCurrentOwnerToken() throws {
    let fixture = try IdentityFixture()
    let agent = try makeAgentToken(fixture)

    #expect(throws: IdentityError.ownerCredentialRequired) {
      _ = try fixture.service.issueOwnerCredential(replacing: nil)
    }
    #expect(throws: IdentityError.ownerCredentialRequired) {
      _ = try fixture.service.issueOwnerCredential(replacing: agent)
    }
  }

  @Test func test_issueOwnerCredential_replacing_revokesTheOldOwnerToken() throws {
    let fixture = try IdentityFixture()

    let replacement = try fixture.service.issueOwnerCredential(replacing: fixture.owner)

    #expect(try fixture.service.authenticate(replacement) == .owner, "the new token works")
    #expect(throws: IdentityError.tokenRevoked) {
      _ = try fixture.service.authenticate(fixture.owner)
    }
  }

  // MARK: - Principals

  @Test func test_createPrincipal_asTheOwner_returnsAnEnabledPrincipalWithTheGivenIdentity() throws
  {
    let fixture = try IdentityFixture()

    let principal = try fixture.service.createPrincipal(
      family: " ops ", role: .head, displayName: "Ops head", ownerToken: fixture.owner)

    #expect(principal.family == "ops", "the family is trimmed and kept")
    #expect(principal.role == .head, "the role is kept")
    #expect(principal.displayName == "Ops head", "the name is kept")
    #expect(principal.isEnabled, "a new principal is enabled")
  }

  @Test func test_createPrincipal_withAnAgentToken_isRefused() throws {
    let fixture = try IdentityFixture()
    let agent = try makeAgentToken(fixture)

    #expect(throws: IdentityError.ownerCredentialRequired) {
      _ = try fixture.service.createPrincipal(
        family: "ops", role: .agent, displayName: "x", ownerToken: agent)
    }
    #expect(
      try fixture.raw().integer("SELECT count(*) FROM principals") == 1,
      "only the agent made by the owner exists")
  }

  @Test func test_createPrincipal_unknownToken_isRefused() throws {
    let fixture = try IdentityFixture()
    let stranger = try #require(CredentialToken(bytes: [UInt8](repeating: 200, count: 32)))

    #expect(throws: IdentityError.unknownToken) {
      _ = try fixture.service.createPrincipal(
        family: "ops", role: .agent, displayName: "x", ownerToken: stranger)
    }
  }

  @Test(arguments: [("", "name", "family"), ("ops", "  ", "displayName")])
  func test_createPrincipal_blankField_isRefused(family: String, name: String, field: String)
    throws
  {
    let fixture = try IdentityFixture()

    #expect(throws: IdentityError.invalidName(field: field)) {
      _ = try fixture.service.createPrincipal(
        family: family, role: .agent, displayName: name, ownerToken: fixture.owner)
    }
  }

  @Test func test_principalIdentity_cannotBeChangedAfterCreation() throws {
    let fixture = try IdentityFixture()
    let principal = try fixture.service.createPrincipal(
      family: "ops", role: .agent, displayName: "x", ownerToken: fixture.owner)
    let raw = try fixture.raw()

    for column in ["family", "role", "id"] {
      let value = column == "role" ? "'head'" : "'changed'"
      #expect(throws: RawDatabaseError.self, "\(column) of \(principal.id.rawValue) is immutable") {
        try raw.execute("UPDATE principals SET \(column) = \(value)")
      }
    }
  }

  // MARK: - Credentials

  @Test func test_issueCredential_returnsATokenThatAuthenticatesAsThePrincipal() throws {
    let fixture = try IdentityFixture()
    let principal = try fixture.service.createPrincipal(
      family: "ops", role: .agent, displayName: "x", ownerToken: fixture.owner)

    let token = try fixture.service.issueCredential(for: principal.id, ownerToken: fixture.owner)

    #expect(try fixture.service.authenticate(token) == .principal(principal), "the principal")
  }

  @Test func test_issueCredential_storesOnlyTheDigestNeverTheToken() throws {
    let fixture = try IdentityFixture()
    let principal = try fixture.service.createPrincipal(
      family: "ops", role: .agent, displayName: "x", ownerToken: fixture.owner)

    let token = try fixture.service.issueCredential(for: principal.id, ownerToken: fixture.owner)

    let disk = try fixture.everythingOnDisk()
    #expect(
      disk.range(of: Data(token.encoded.utf8)) == nil, "the plaintext token is nowhere on disk")
    #expect(disk.range(of: Data(fixture.owner.encoded.utf8)) == nil, "nor is the owner's")
    #expect(
      try fixture.raw().integer(
        "SELECT count(*) FROM credentials WHERE digest = '\(token.digest.hex)'") == 1,
      "the SHA-256 digest is what is kept")
  }

  @Test func test_issueCredential_forADisabledOrUnknownPrincipal_isRefused() throws {
    let fixture = try IdentityFixture()
    let principal = try fixture.service.createPrincipal(
      family: "ops", role: .agent, displayName: "x", ownerToken: fixture.owner)
    try fixture.service.disablePrincipal(principal.id, ownerToken: fixture.owner)

    #expect(throws: IdentityError.principalDisabled) {
      _ = try fixture.service.issueCredential(for: principal.id, ownerToken: fixture.owner)
    }
    #expect(throws: IdentityError.unknownPrincipal(PrincipalID("nobody"))) {
      _ = try fixture.service.issueCredential(
        for: PrincipalID("nobody"), ownerToken: fixture.owner)
    }
  }

  @Test func test_issueCredential_randomSourceFails_storesNothing() throws {
    let working = try IdentityFixture()
    let principal = try working.service.createPrincipal(
      family: "ops", role: .agent, displayName: "x", ownerToken: working.owner)
    let failing = IdentityService(
      store: SQLiteIdentityStore(store: working.store), random: FailingRandom(),
      identifiers: SequentialIdentifiers(), clock: StoreFixedClock(instant: .now))

    #expect(throws: FailingRandom.Failure()) {
      _ = try failing.issueCredential(for: principal.id, ownerToken: working.owner)
    }
    #expect(
      try working.raw().integer("SELECT count(*) FROM credentials") == 1,
      "only the owner credential exists")
  }

  @Test func test_issueCredential_sameDigestTwice_isRefusedNotOverwritten() throws {
    let fixture = try IdentityFixture(random: SequenceRandom(repeating: true))
    let principal = try fixture.service.createPrincipal(
      family: "ops", role: .agent, displayName: "x", ownerToken: fixture.owner)

    #expect(throws: StoreError.self) {
      _ = try fixture.service.issueCredential(for: principal.id, ownerToken: fixture.owner)
    }
  }

  // MARK: - Authentication failures

  @Test func test_authenticate_unknownToken_failsWithUnknownToken() throws {
    let fixture = try IdentityFixture()
    let stranger = try #require(CredentialToken(bytes: [UInt8](repeating: 200, count: 32)))

    #expect(throws: IdentityError.unknownToken) {
      _ = try fixture.service.authenticate(stranger)
    }
  }

  @Test func test_disable_takesEffectAtOnceAndFailsWithPrincipalDisabled() throws {
    let fixture = try IdentityFixture()
    let principal = try fixture.service.createPrincipal(
      family: "ops", role: .agent, displayName: "x", ownerToken: fixture.owner)
    let first = try fixture.service.issueCredential(for: principal.id, ownerToken: fixture.owner)
    let second = try fixture.service.issueCredential(for: principal.id, ownerToken: fixture.owner)

    try fixture.service.disablePrincipal(principal.id, ownerToken: fixture.owner)

    for token in [first, second] {
      #expect(throws: IdentityError.principalDisabled) {
        _ = try fixture.service.authenticate(token)
      }
    }
  }

  @Test func test_enable_neverRevivesAnOldToken_aNewCredentialIsRequired() throws {
    let fixture = try IdentityFixture()
    let principal = try fixture.service.createPrincipal(
      family: "ops", role: .agent, displayName: "x", ownerToken: fixture.owner)
    let old = try fixture.service.issueCredential(for: principal.id, ownerToken: fixture.owner)
    try fixture.service.disablePrincipal(principal.id, ownerToken: fixture.owner)

    try fixture.service.enablePrincipal(principal.id, ownerToken: fixture.owner)

    #expect(throws: IdentityError.tokenRevoked) {
      _ = try fixture.service.authenticate(old)
    }
    let fresh = try fixture.service.issueCredential(for: principal.id, ownerToken: fixture.owner)
    #expect(try fixture.service.authenticate(fresh) == .principal(principal), "the new one works")
  }

  @Test func test_ownerToken_neverAuthenticatesAsAPrincipalAndAnAgentTokenNeverAsTheOwner() throws {
    let fixture = try IdentityFixture()
    let agent = try makeAgentToken(fixture)

    #expect(try fixture.service.authenticate(fixture.owner) == .owner, "owner stays owner")
    #expect(throws: IdentityError.ownerCredentialRequired) {
      try fixture.service.authenticateOwner(agent)
    }
  }

  @Test func test_secureRandomSource_returnsTheRequestedCountAndDiffersBetweenCalls() throws {
    let source = SecureRandomSource()

    let first = try source.randomBytes(count: 32)
    let second = try source.randomBytes(count: 32)

    #expect(first.count == 32, "the requested number of bytes")
    #expect(first != second, "two calls give different bytes")
  }

  @Test func test_uuidIdentifiers_areUnique() {
    let source = UUIDIdentifierSource()

    #expect(source.newPrincipalID() != source.newPrincipalID(), "each id is new")
  }

  // MARK: - Helpers

  private func makeAgentToken(_ fixture: IdentityFixture) throws -> CredentialToken {
    let principal = try fixture.service.createPrincipal(
      family: "ops", role: .agent, displayName: "helper", ownerToken: fixture.owner)
    return try fixture.service.issueCredential(for: principal.id, ownerToken: fixture.owner)
  }
}
