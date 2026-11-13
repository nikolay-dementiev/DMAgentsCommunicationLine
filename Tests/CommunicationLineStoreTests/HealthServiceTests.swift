import CommunicationLineApplication
import CommunicationLineDomain
import CommunicationLineStore
import Foundation
import Testing

@Suite struct HealthServiceTests {
  private struct Fixture {
    let world: MessagingFixture
    let health: HealthService
    let cleanup: CleanupRunner
    let startedAt = Date(timeIntervalSince1970: 1_800_000_000)

    init() throws {
      world = try MessagingFixture()
      let store = world.identity.store
      cleanup = CleanupRunner(
        service: CleanupService(
          store: SQLiteRetentionStore(store: store), settings: world.settings,
          transactions: SQLiteTransactionRunner(store: store), clock: world.clock),
        clock: world.clock)
      health = HealthService(
        store: SQLiteHealthStore(store: store), settings: world.settings,
        storage: StorageService(store: SQLiteStorageStore(store: store), settings: world.settings),
        cleanup: cleanup, identity: world.identity.service, clock: world.clock,
        startedAt: startedAt)
    }

    func report() throws -> HealthReport { try health.report(ownerToken: world.owner) }

    func advance(seconds: TimeInterval) {
      world.clock.instant = world.clock.instant.addingTimeInterval(seconds)
    }

    func set(_ key: String, to value: Int64, scope: SettingScope = .global, subject: String? = nil)
      throws
    {
      _ = try world.settings.change(
        SettingAddress(key: key, scope: scope, subject: subject), to: .integer(value),
        ownerToken: world.owner)
    }
  }

  @Test func test_pending_isCountedPerPrincipal_andAcknowledgedMailIsNot() throws {
    let fixture = try Fixture()
    let world = fixture.world
    try world.mail(from: world.alphaToken, to: world.alphaPeer, "one")
    try world.mail(from: world.alphaToken, to: world.alphaPeer, "two")
    try world.mail(from: world.alphaToken, to: world.alphaHead, "three")
    let done = try world.mail(from: world.alphaToken, to: world.alphaHead, "four")
    try world.messages.acknowledge(token: world.alphaHeadToken, messageID: done)

    let counts = Dictionary(
      uniqueKeysWithValues: try fixture.report().pending.map { ($0.principal, $0.count) })

    #expect(
      counts == [world.alphaPeer.id: 2, world.alphaHead.id: 1],
      "two and one pending; the acknowledged delivery is not pending")
  }

  @Test func test_aDeliveryPendingPastTheThreshold_isOverdue_withItsAge() throws {
    let fixture = try Fixture()
    let world = fixture.world
    let id = try world.mail(from: world.alphaToken, to: world.alphaPeer)
    fixture.advance(seconds: 1799)

    let early = try fixture.report()
    fixture.advance(seconds: 2)
    let late = try fixture.report()

    #expect(early.overdueCount == 0 && early.overdue.isEmpty, "inside the 1800 s threshold")
    #expect(late.overdueCount == 1, "past the threshold")
    #expect(
      late.overdue == [OverdueDelivery(message: id, recipient: world.alphaPeer.id, age: 1801)],
      "the message, who has it, and how long it has waited")
  }

  @Test func test_anAcknowledgedDelivery_isNeverOverdue() throws {
    let fixture = try Fixture()
    let world = fixture.world
    let id = try world.mail(from: world.alphaToken, to: world.alphaPeer)
    try world.messages.acknowledge(token: world.alphaPeerToken, messageID: id)
    fixture.advance(seconds: 86_400)

    let report = try fixture.report()

    #expect(report.overdue.isEmpty && report.overdueCount == 0, "nothing is waiting")
  }

  @Test func test_theThreshold_canBeSetForOnePrincipal() throws {
    let fixture = try Fixture()
    let world = fixture.world
    try fixture.set(
      "health.threshold", to: 60, scope: .principal, subject: world.alphaPeer.id.rawValue)
    try world.mail(from: world.alphaToken, to: world.alphaPeer)
    try world.mail(from: world.alphaToken, to: world.alphaHead)
    fixture.advance(seconds: 120)

    let report = try fixture.report()

    #expect(
      report.overdue.map(\.recipient) == [world.alphaPeer.id],
      "only the principal with the short threshold is overdue after two minutes")
  }

  @Test func test_overdueEntries_areBoundedByThePageSize_butAllAreCounted() throws {
    let fixture = try Fixture()
    let world = fixture.world
    try fixture.set("messaging.page_size", to: 2)
    for index in 0..<3 { try world.mail(from: world.alphaToken, to: world.alphaPeer, "m\(index)") }
    fixture.advance(seconds: 3600)

    let report = try fixture.report()

    #expect(report.overdueCount == 3, "every overdue delivery is counted")
    #expect(report.overdue.count == 2, "only one page of them is listed")
  }

  @Test func test_aBudgetBelowTheUse_raisesTheStorageWarning() throws {
    let fixture = try Fixture()

    #expect(try fixture.report().warnings.isEmpty, "no warning under the default budget")
    try fixture.set("storage.budget", to: 1)
    let report = try fixture.report()

    #expect(report.warnings == [.storageBudget], "the warning is named")
    #expect(report.storage.budgetBytes == 1, "the budget the use is measured against")
    #expect(report.storage.usedBytes > 0, "the use")
  }

  @Test func test_lastCleanup_isEmptyUntilOneRuns_thenHoldsItsResult() throws {
    let fixture = try Fixture()
    #expect(try fixture.report().lastCleanup == nil, "no cleanup yet")

    fixture.advance(seconds: 5)
    try fixture.cleanup.run()
    let last = try #require(try fixture.report().lastCleanup, "a cleanup ran")

    #expect(last.at == fixture.world.clock.instant, "when it ran")
    #expect(
      last.outcome == .success(CleanupResult(deliveries: 0, messages: 0, activity: 0)),
      "what it deleted")
  }

  @Test func test_theReport_carriesTheServiceStartTime() throws {
    let fixture = try Fixture()

    #expect(try fixture.report().startedAt == fixture.startedAt, "the start time as given")
  }

  @Test func test_anAgentCannotReadTheReport() throws {
    let fixture = try Fixture()

    #expect(throws: IdentityError.ownerCredentialRequired) {
      _ = try fixture.health.report(ownerToken: fixture.world.alphaToken)
    }
  }
}
