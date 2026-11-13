import CommunicationLineApplication
import CommunicationLineDomain
import CommunicationLineStore
import Dispatch
import Foundation
import Testing

/// The owner credential and the enabled flag are decided inside one transaction, not by a check
/// followed by a write, so concurrent callers cannot both win.
@Suite struct IdentityRaceTests {
  private enum Outcome {
    case token(CredentialToken)
    case failure(String)
  }

  private func service(on path: URL) throws -> IdentityService {
    let store = try SQLiteStore.open(
      at: path, busyTimeoutMilliseconds: 10_000, migrations: SchemaMigrations.all)
    return IdentityService(
      store: SQLiteIdentityStore(store: store), random: SecureRandomSource(),
      identifiers: UUIDIdentifierSource(), clock: StoreFixedClock(instant: Date()))
  }

  private func race(
    on path: URL, callers: Int = 8, _ action: @escaping (IdentityService) throws -> CredentialToken
  ) throws -> [Outcome] {
    nonisolated(unsafe) let services = try (0..<callers).map { _ in try service(on: path) }
    nonisolated(unsafe) let run = action
    let lock = NSLock()
    nonisolated(unsafe) var outcomes: [Outcome] = []
    DispatchQueue.concurrentPerform(iterations: callers) { index in
      let outcome: Outcome
      do {
        outcome = .token(try run(services[index]))
      } catch {
        outcome = .failure("\(error)")
      }
      lock.withLock { outcomes.append(outcome) }
    }
    return outcomes
  }

  @Test func test_issueOwnerCredential_manyCallersBootstrapAtOnce_exactlyOneWins() throws {
    for _ in 0..<10 {
      let scratch = try TemporaryDirectory()
      let first = try service(on: scratch.storePath)

      let outcomes = try race(on: scratch.storePath) { try $0.issueOwnerCredential(replacing: nil) }

      let winners = outcomes.compactMap { outcome -> CredentialToken? in
        if case .token(let token) = outcome { return token }
        return nil
      }
      #expect(winners.count == 1, "exactly one bootstrap succeeds, got \(winners.count)")
      for token in winners {
        #expect(try first.authenticate(token) == .owner, "the winner's token is the live owner")
      }
      let raw = try RawDatabase(path: scratch.storePath)
      #expect(
        try raw.integer(
          "SELECT count(*) FROM credentials WHERE kind = 'owner' AND revoked_at_ms IS NULL") == 1,
        "one active owner credential")
    }
  }

  @Test func test_issueOwnerCredential_manyCallersRotateWithTheSameToken_exactlyOneWins() throws {
    for _ in 0..<10 {
      let fixture = try IdentityFixture()
      let current = fixture.owner

      let outcomes = try race(on: fixture.scratch.storePath) {
        try $0.issueOwnerCredential(replacing: current)
      }

      let winners = outcomes.compactMap { outcome -> CredentialToken? in
        if case .token(let token) = outcome { return token }
        return nil
      }
      #expect(winners.count == 1, "exactly one rotation succeeds, got \(winners.count)")
      for token in winners {
        #expect(try fixture.service.authenticate(token) == .owner, "the winner is the owner")
      }
      #expect(throws: IdentityError.tokenRevoked) {
        _ = try fixture.service.authenticate(current)
      }
    }
  }

  @Test func test_database_refusesASecondActiveOwnerCredential() throws {
    let fixture = try IdentityFixture()
    let raw = try fixture.raw()
    let digest = String(repeating: "ab", count: 32)

    #expect(throws: RawDatabaseError.self) {
      try raw.execute(
        """
        INSERT INTO credentials (digest, kind, principal_id, issued_at_ms)
        VALUES ('\(digest)', 'owner', NULL, 1)
        """)
    }
  }

  @Test func test_insertCredential_forADisabledPrincipal_isRefusedInTheSameTransaction() throws {
    let fixture = try IdentityFixture()
    let principal = try fixture.service.createPrincipal(
      family: "ops", role: .agent, displayName: "x", ownerToken: fixture.owner)
    try fixture.service.disablePrincipal(principal.id, ownerToken: fixture.owner)
    let store = SQLiteIdentityStore(store: fixture.store)
    let token = try #require(CredentialToken(bytes: [UInt8](repeating: 77, count: 32)))

    #expect(throws: IdentityError.principalDisabled) {
      try store.insertPrincipalCredential(digest: token.digest, for: principal.id, at: Date())
    }
    #expect(
      try fixture.raw().integer("SELECT count(*) FROM credentials WHERE principal_id IS NOT NULL")
        == 0, "no credential was stored for a disabled principal")
  }

  @Test func test_enable_revokesAnyCredentialThatSurvivedTheDisable() throws {
    let fixture = try IdentityFixture()
    let principal = try fixture.service.createPrincipal(
      family: "ops", role: .agent, displayName: "x", ownerToken: fixture.owner)
    try fixture.service.disablePrincipal(principal.id, ownerToken: fixture.owner)
    let stray = try #require(CredentialToken(bytes: [UInt8](repeating: 78, count: 32)))
    try fixture.raw().execute(
      """
      INSERT INTO credentials (digest, kind, principal_id, issued_at_ms)
      VALUES ('\(stray.digest.hex)', 'principal', '\(principal.id.rawValue)', 1)
      """)

    try fixture.service.enablePrincipal(principal.id, ownerToken: fixture.owner)

    #expect(throws: IdentityError.tokenRevoked) {
      _ = try fixture.service.authenticate(stray)
    }
  }
}
