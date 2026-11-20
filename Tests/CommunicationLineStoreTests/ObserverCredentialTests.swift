import CommunicationLineApplication
import CommunicationLineDomain
import CommunicationLineStore
import Foundation
import Testing

/// The observer credential reads the health document and nothing else. It is not a principal: it
/// has no family, no inbox and no id that mail could be sent to.
struct ObserverCredentialTests {
  private func agentToken(_ fixture: IdentityFixture) throws -> CredentialToken {
    let principal = try fixture.service.createPrincipal(
      family: "ops", role: .agent, displayName: "helper", ownerToken: fixture.owner)
    return try fixture.service.issueCredential(for: principal.id, ownerToken: fixture.owner)
  }

  @Test func test_anIssuedObserverToken_authenticatesAsAnObserver() throws {
    let fixture = try IdentityFixture()

    let token = try fixture.service.issueObserverCredential(ownerToken: fixture.owner)

    #expect(try fixture.service.authenticate(token) == .observer, "the token is an observer's")
  }

  @Test func test_issuingAgain_replacesTheObserverToken() throws {
    let fixture = try IdentityFixture()
    let first = try fixture.service.issueObserverCredential(ownerToken: fixture.owner)

    let second = try fixture.service.issueObserverCredential(ownerToken: fixture.owner)

    #expect(try fixture.service.authenticate(second) == .observer, "the new token works")
    #expect(throws: IdentityError.tokenRevoked) {
      _ = try fixture.service.authenticate(first)
    }
  }

  @Test func test_revoking_stopsTheObserverToken_andRevokingAgainChangesNothing() throws {
    let fixture = try IdentityFixture()
    let token = try fixture.service.issueObserverCredential(ownerToken: fixture.owner)

    try fixture.service.revokeObserverCredential(ownerToken: fixture.owner)
    try fixture.service.revokeObserverCredential(ownerToken: fixture.owner)

    #expect(throws: IdentityError.tokenRevoked) {
      _ = try fixture.service.authenticate(token)
    }
  }

  @Test func test_revoking_withNothingIssued_isNotAnError() throws {
    let fixture = try IdentityFixture()

    try fixture.service.revokeObserverCredential(ownerToken: fixture.owner)
  }

  @Test func test_onlyTheOwner_issuesOrRevokesTheObserverCredential() throws {
    let fixture = try IdentityFixture()
    let agent = try agentToken(fixture)
    let observer = try fixture.service.issueObserverCredential(ownerToken: fixture.owner)

    for caller in [agent, observer] {
      #expect(throws: IdentityError.ownerCredentialRequired) {
        _ = try fixture.service.issueObserverCredential(ownerToken: caller)
      }
      #expect(throws: IdentityError.ownerCredentialRequired) {
        try fixture.service.revokeObserverCredential(ownerToken: caller)
      }
    }
    #expect(
      try fixture.service.authenticate(observer) == .observer,
      "the refused calls changed nothing: the observer token still works")
  }

  @Test func test_anObserver_isNotTheOwner_butMayReadWhatTheOwnerReads() throws {
    let fixture = try IdentityFixture()
    let observer = try fixture.service.issueObserverCredential(ownerToken: fixture.owner)
    let agent = try agentToken(fixture)

    #expect(throws: IdentityError.ownerCredentialRequired) {
      try fixture.service.authenticateOwner(observer)
    }
    try fixture.service.authenticateOwnerOrObserver(observer)
    try fixture.service.authenticateOwnerOrObserver(fixture.owner)
    #expect(throws: IdentityError.ownerCredentialRequired) {
      try fixture.service.authenticateOwnerOrObserver(agent)
    }
  }

  @Test func test_theObserverToken_isNeverStoredInTheClear() throws {
    let fixture = try IdentityFixture()

    let token = try fixture.service.issueObserverCredential(ownerToken: fixture.owner)

    let disk = String(decoding: try fixture.everythingOnDisk(), as: UTF8.self)
    #expect(!disk.contains(token.encoded), "only a digest of the token is on disk")
  }

  @Test func test_migratingToVersion8_keepsTheCredentialsAndStartsWithoutAnObserver() throws {
    let scratch = try TemporaryDirectory()
    _ = try SQLiteStore.open(
      at: scratch.storePath, busyTimeoutMilliseconds: 1000,
      migrations: Array(SchemaMigrations.all.prefix(7)))
    let raw = try RawDatabase(path: scratch.storePath)
    try raw.execute(
      """
      INSERT INTO principals (id, family, role, display_name, enabled, created_at_ms)
      VALUES ('p1', 'f', 'agent', 'one', 1, 0);
      INSERT INTO credentials (digest, kind, principal_id, issued_at_ms)
      VALUES ('\(String(repeating: "a", count: 64))', 'principal', 'p1', 0),
             ('\(String(repeating: "b", count: 64))', 'owner', NULL, 0);
      """)

    let store = try SQLiteStore.open(
      at: scratch.storePath, busyTimeoutMilliseconds: 1000, migrations: SchemaMigrations.all)

    #expect(try store.schemaVersion() == 8, "the store is at version 8")
    #expect(try raw.integer("SELECT count(*) FROM credentials") == 2, "both credentials are kept")
    #expect(
      try raw.integer("SELECT count(*) FROM observer_credential") == 0, "no observer credential")
  }
}
