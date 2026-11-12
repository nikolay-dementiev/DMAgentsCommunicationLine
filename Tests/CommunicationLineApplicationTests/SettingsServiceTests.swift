import CommunicationLineApplication
import CommunicationLineDomain
import Foundation
import Testing

@Suite struct SettingsServiceTests {
  private let instant = Date(timeIntervalSince1970: 1_700_000_000)
  private let limit = SettingAddress(key: "demo.limit", scope: .global, subject: nil)

  private func makeSUT() throws -> (
    service: SettingsService, store: SpySettingsStore, authenticator: StubAuthenticator
  ) {
    let store = SpySettingsStore()
    let authenticator = StubAuthenticator()
    let service = SettingsService(
      catalog: try SettingsCatalog.decode(from: demoCatalogJSON), store: store,
      clock: FixedClock(instant: instant), authenticator: authenticator)
    return (service, store, authenticator)
  }

  // MARK: - Reading

  @Test func test_effectiveValue_asAnAgent_usesTheFamilyAndIdOfTheAuthenticatedPrincipal() throws {
    let (service, store, authenticator) = try makeSUT()
    authenticator.result = .success(.principal(agentPrincipal))
    store.stored = StoredSettingValues(
      principal: .integer(1), family: .integer(2), global: .integer(3))

    let value = try service.effectiveValue(of: "demo.limit", token: sampleToken)

    #expect(value == .integer(1), "the principal value wins")
    #expect(store.lookups.count == 1, "the store is asked once")
    #expect(store.lookups.first?.family == "f", "the family comes from the authenticated principal")
    #expect(store.lookups.first?.principal == "p", "the id comes from the authenticated principal")
  }

  @Test func test_effectiveValue_asTheOwner_readsOnlyGlobalAndDefault() throws {
    let (service, store, _) = try makeSUT()

    #expect(
      try service.effectiveValue(of: "demo.limit", token: sampleToken) == .integer(5),
      "nothing stored: the default applies")
    #expect(store.lookups.first?.family == nil, "the owner has no family")
    #expect(store.lookups.first?.principal == nil, "the owner has no principal scope")
  }

  @Test func test_effectiveValue_rejectedToken_readsNothing() throws {
    let (service, store, authenticator) = try makeSUT()
    authenticator.result = .failure(.unknownToken)

    #expect(throws: IdentityError.unknownToken) {
      _ = try service.effectiveValue(of: "demo.limit", token: sampleToken)
    }
    #expect(store.lookups.isEmpty, "an unauthenticated caller reaches no stored value")
  }

  @Test func test_effectiveValue_unknownKey_isRejected() throws {
    let (service, _, _) = try makeSUT()

    #expect(throws: SettingsServiceError.unknownKey("demo.missing")) {
      _ = try service.effectiveValue(of: "demo.missing", token: sampleToken)
    }
  }

  @Test func test_effectiveValue_badTokenAndUnknownKey_doesNotRevealWhichKeysExist() throws {
    let (service, _, authenticator) = try makeSUT()
    authenticator.result = .failure(.unknownToken)

    #expect(throws: IdentityError.unknownToken) {
      _ = try service.effectiveValue(of: "demo.missing", token: sampleToken)
    }
  }

  // MARK: - Changing

  @Test func test_change_asTheOwner_isAppliedWithTheOwnerAsActorAndInjectedTime() throws {
    let (service, store, authenticator) = try makeSUT()
    let address = SettingAddress(key: "demo.limit", scope: .family, subject: "ops")

    let record = try service.change(address, to: .integer(7), ownerToken: sampleToken)

    #expect(authenticator.presented == [sampleToken.encoded], "the presented token is checked")
    #expect(store.applied.count == 1, "one change reaches the store")
    #expect(store.applied.first?.actor == SettingsService.ownerActor, "the owner is the actor")
    #expect(store.applied.first?.at == instant, "the time comes from the injected clock")
    #expect(record.newValue == .integer(7), "the audit record is returned")
  }

  @Test func test_change_withAnAgentToken_isRefusedAndNotApplied() throws {
    let (service, store, authenticator) = try makeSUT()
    authenticator.result = .success(.principal(agentPrincipal))

    #expect(throws: IdentityError.ownerCredentialRequired) {
      _ = try service.change(limit, to: .integer(7), ownerToken: sampleToken)
    }
    #expect(store.applied.isEmpty, "an agent cannot change settings")
  }

  @Test func test_change_rejectedToken_isRefusedAndNotApplied() throws {
    let (service, store, authenticator) = try makeSUT()
    authenticator.result = .failure(.tokenRevoked)

    #expect(throws: IdentityError.tokenRevoked) {
      _ = try service.change(limit, to: .integer(7), ownerToken: sampleToken)
    }
    #expect(store.applied.isEmpty, "nothing reaches the store")
  }

  @Test func test_change_valueOutsideTheRange_isRejectedAndNotApplied() throws {
    let (service, store, _) = try makeSUT()

    #expect(
      throws: SettingsServiceError.invalidValue(key: "demo.limit", reason: .aboveMaximum(10))
    ) {
      _ = try service.change(limit, to: .integer(11), ownerToken: sampleToken)
    }
    #expect(store.applied.isEmpty, "nothing reaches the store")
  }

  @Test func test_change_scopeTheKeyDoesNotAllow_isRejected() throws {
    let (service, store, _) = try makeSUT()
    let address = SettingAddress(key: "demo.budget", scope: .principal, subject: "p")

    #expect(throws: SettingsServiceError.scopeNotAllowed(key: "demo.budget", scope: .principal)) {
      _ = try service.change(address, to: .integer(5), ownerToken: sampleToken)
    }
    #expect(store.applied.isEmpty, "nothing reaches the store")
  }

  @Test func test_change_subjectDoesNotMatchTheScope_isRejected() throws {
    let (service, _, _) = try makeSUT()

    #expect(throws: SettingsServiceError.subjectRequired(.family)) {
      _ = try service.change(
        SettingAddress(key: "demo.limit", scope: .family, subject: ""), to: .integer(5),
        ownerToken: sampleToken)
    }
    #expect(throws: SettingsServiceError.subjectNotAllowed(.global)) {
      _ = try service.change(
        SettingAddress(key: "demo.limit", scope: .global, subject: "f"), to: .integer(5),
        ownerToken: sampleToken)
    }
  }

  @Test func test_change_unknownKey_isRejected() throws {
    let (service, _, _) = try makeSUT()

    #expect(throws: SettingsServiceError.unknownKey("demo.missing")) {
      _ = try service.change(
        SettingAddress(key: "demo.missing", scope: .global, subject: nil), to: .integer(5),
        ownerToken: sampleToken)
    }
  }

  // MARK: - Audit trail

  @Test func test_auditTrail_asTheOwner_isReadFromTheStore() throws {
    let (service, _, _) = try makeSUT()

    #expect(
      try service.auditTrail(of: "demo.limit", ownerToken: sampleToken).isEmpty,
      "the store's records are returned")
  }

  @Test func test_auditTrail_withAnAgentToken_isRefused() throws {
    let (service, _, authenticator) = try makeSUT()
    authenticator.result = .success(.principal(agentPrincipal))

    #expect(throws: IdentityError.ownerCredentialRequired) {
      _ = try service.auditTrail(of: "demo.limit", ownerToken: sampleToken)
    }
  }

  @Test func test_auditTrail_unknownKey_isRejected() throws {
    let (service, _, _) = try makeSUT()

    #expect(throws: SettingsServiceError.unknownKey("demo.missing")) {
      _ = try service.auditTrail(of: "demo.missing", ownerToken: sampleToken)
    }
  }
}
