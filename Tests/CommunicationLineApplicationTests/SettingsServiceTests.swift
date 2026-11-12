import CommunicationLineApplication
import CommunicationLineDomain
import Foundation
import Testing

@Suite struct SettingsServiceTests {
  private let instant = Date(timeIntervalSince1970: 1_700_000_000)

  private func makeSUT() throws -> (service: SettingsService, store: SpySettingsStore) {
    let store = SpySettingsStore()
    let service = SettingsService(
      catalog: try SettingsCatalog.decode(from: demoCatalogJSON), store: store,
      clock: FixedClock(instant: instant))
    return (service, store)
  }

  @Test func test_effectiveValue_usesTheStoredValueOfTheNarrowestScope() throws {
    let (service, store) = try makeSUT()
    store.stored = StoredSettingValues(
      principal: .integer(1), family: .integer(2), global: .integer(3))

    let value = try service.effectiveValue(of: "demo.limit", family: "f", principal: "p")

    #expect(value == .integer(1), "the principal value wins")
    #expect(store.lookups.count == 1, "the store is asked once")
    #expect(store.lookups.first?.family == "f", "the family subject is passed on")
    #expect(store.lookups.first?.principal == "p", "the principal subject is passed on")
  }

  @Test func test_effectiveValue_nothingStored_isTheCatalogDefault() throws {
    let (service, _) = try makeSUT()

    #expect(
      try service.effectiveValue(of: "demo.limit", family: nil, principal: nil) == .integer(5),
      "the default applies")
  }

  @Test func test_effectiveValue_unknownKey_isRejected() throws {
    let (service, _) = try makeSUT()

    #expect(throws: SettingsServiceError.unknownKey("demo.missing")) {
      _ = try service.effectiveValue(of: "demo.missing", family: nil, principal: nil)
    }
  }

  @Test func test_change_validValue_isAppliedWithActorAndInjectedTime() throws {
    let (service, store) = try makeSUT()
    let address = SettingAddress(key: "demo.limit", scope: .family, subject: "ops")

    let record = try service.change(address, to: .integer(7), actor: "owner")

    #expect(store.applied.count == 1, "one change reaches the store")
    #expect(store.applied.first?.actor == "owner", "the caller's actor is recorded")
    #expect(store.applied.first?.at == instant, "the time comes from the injected clock")
    #expect(record.newValue == .integer(7), "the audit record is returned")
  }

  @Test func test_change_valueOutsideTheRange_isRejectedAndNotApplied() throws {
    let (service, store) = try makeSUT()
    let address = SettingAddress(key: "demo.limit", scope: .global, subject: nil)

    #expect(
      throws: SettingsServiceError.invalidValue(key: "demo.limit", reason: .aboveMaximum(10))
    ) {
      _ = try service.change(address, to: .integer(11), actor: "owner")
    }
    #expect(store.applied.isEmpty, "nothing reaches the store")
  }

  @Test func test_change_scopeTheKeyDoesNotAllow_isRejected() throws {
    let (service, store) = try makeSUT()
    let address = SettingAddress(key: "demo.budget", scope: .principal, subject: "p")

    #expect(throws: SettingsServiceError.scopeNotAllowed(key: "demo.budget", scope: .principal)) {
      _ = try service.change(address, to: .integer(5), actor: "owner")
    }
    #expect(store.applied.isEmpty, "nothing reaches the store")
  }

  @Test func test_change_subjectDoesNotMatchTheScope_isRejected() throws {
    let (service, _) = try makeSUT()

    #expect(throws: SettingsServiceError.subjectRequired(.family)) {
      _ = try service.change(
        SettingAddress(key: "demo.limit", scope: .family, subject: ""), to: .integer(5),
        actor: "owner")
    }
    #expect(throws: SettingsServiceError.subjectNotAllowed(.global)) {
      _ = try service.change(
        SettingAddress(key: "demo.limit", scope: .global, subject: "f"), to: .integer(5),
        actor: "owner")
    }
  }

  @Test func test_change_blankActor_isRejected() throws {
    let (service, store) = try makeSUT()

    #expect(throws: SettingsServiceError.actorRequired) {
      _ = try service.change(
        SettingAddress(key: "demo.limit", scope: .global, subject: nil), to: .integer(5),
        actor: "  ")
    }
    #expect(store.applied.isEmpty, "an unattributed change is never stored")
  }

  @Test func test_change_unknownKey_isRejected() throws {
    let (service, _) = try makeSUT()

    #expect(throws: SettingsServiceError.unknownKey("demo.missing")) {
      _ = try service.change(
        SettingAddress(key: "demo.missing", scope: .global, subject: nil), to: .integer(5),
        actor: "owner")
    }
  }
}
