import CommunicationLineApplication
import CommunicationLineDomain
import CommunicationLineStore
import Foundation
import Testing

@Suite struct StorageWarningTests {
  private struct Fixture {
    let world: MessagingFixture
    let storage: StorageService
    let cleanup: CleanupService

    init() throws {
      world = try MessagingFixture()
      let store = world.identity.store
      storage = StorageService(store: SQLiteStorageStore(store: store), settings: world.settings)
      cleanup = CleanupService(
        store: SQLiteRetentionStore(store: store), settings: world.settings,
        transactions: SQLiteTransactionRunner(store: store), clock: world.clock)
    }

    func setBudget(_ bytes: Int64) throws {
      _ = try world.settings.change(
        SettingAddress(key: "storage.budget", scope: .global, subject: nil), to: .integer(bytes),
        ownerToken: world.owner)
    }

    /// Fills the store with acknowledged mail of about 200 KiB each.
    func fill(messages count: Int) throws {
      let body = String(repeating: "x", count: 200_000)
      for _ in 0..<count {
        let id = try world.messages.send(
          token: world.alphaToken, to: [world.alphaPeer.id], subject: "s", body: body)
        try world.messages.acknowledge(token: world.alphaPeerToken, messageID: id)
      }
    }
  }

  @Test func test_anUnusableWarningPercent_isReportedUnderItsOwnKey() throws {
    let fixture = try Fixture()
    try fixture.world.identity.raw().execute(
      "INSERT INTO settings_values (key, scope, subject, value) VALUES ('storage.warning_percent', 'global', '', '0')"
    )

    #expect(throws: CleanupError.invalidSetting("storage.warning_percent")) {
      _ = try fixture.storage.status()
    }
  }

  @Test func test_aSmallStore_underTheDefaultBudget_hasNoWarning() throws {
    let fixture = try Fixture()

    let status = try fixture.storage.status()

    #expect(status.usedBytes > 0, "the schema itself takes space")
    #expect(status.budgetBytes == 5_000_000_000, "the default budget")
    #expect(!status.isWarning, "far below the threshold")
  }

  @Test func test_theWarning_appearsPastTheThreshold_andClearsWhenSpaceIsFreed() throws {
    let fixture = try Fixture()
    try fixture.fill(messages: 15)
    let full = try fixture.storage.status().usedBytes
    // A budget whose 80 percent mark is just below the current use.
    try fixture.setBudget(full * 100 / 80 - 1_000)

    #expect(try fixture.storage.status().isWarning, "past 80 percent of the budget")

    fixture.world.clock.instant = fixture.world.clock.instant.addingTimeInterval(91 * 86_400)
    _ = try fixture.cleanup.run()

    let after = try fixture.storage.status()
    #expect(after.usedBytes < full / 2, "cleanup freed most of the space")
    #expect(!after.isWarning, "the warning clears once the use is under the threshold")
  }

  @Test func test_theThreshold_isTheWarningPercentOfTheBudget() throws {
    let fixture = try Fixture()
    let used = try fixture.storage.status().usedBytes
    try fixture.setBudget(used * 100 / 80)
    #expect(try fixture.storage.status().isWarning, "exactly at the threshold warns")

    try fixture.setBudget(used * 100 / 80 + 100)

    #expect(try !fixture.storage.status().isWarning, "just under the threshold does not")
  }
}
