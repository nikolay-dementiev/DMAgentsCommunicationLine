import CommunicationLineApplication
import CommunicationLineDomain
import CommunicationLineStore
import Foundation
import Testing

@Suite struct ActivityRowCapTests {
  private struct Fixture {
    let world: MessagingFixture
    let cleanup: CleanupService
    let activity: SQLiteActivityStore

    init(maxRows: Int64? = nil) throws {
      world = try MessagingFixture()
      let store = world.identity.store
      cleanup = CleanupService(
        store: SQLiteRetentionStore(store: store), settings: world.settings,
        transactions: SQLiteTransactionRunner(store: store), clock: world.clock)
      activity = SQLiteActivityStore(store: store)
      if let maxRows {
        _ = try world.settings.change(
          SettingAddress(key: "retention.activity.max_rows", scope: .global, subject: nil),
          to: .integer(maxRows), ownerToken: world.owner)
      }
    }

    /// Appends `count` young records named `op0`, `op1`, and so on.
    func append(_ count: Int) throws {
      for index in 0..<count {
        try activity.append(
          NewActivity(
            at: world.clock.instant, actor: .owner, operation: "op\(index)", outcome: "ok",
            targets: []))
      }
    }
  }

  @Test func test_overTheRowCap_cleanupDeletesTheOldestRecordsFirst() throws {
    let fixture = try Fixture(maxRows: 1000)
    try fixture.append(1005)

    let result = try fixture.cleanup.run()

    #expect(result.activity == 5, "exactly the rows beyond the cap are deleted")
    #expect(try fixture.world.count("activity") == 1000, "the table is back at the cap")
    let oldest = try fixture.activity.page(after: nil, limit: 1).records.first
    #expect(oldest?.operation == "op5", "the five oldest records went, in order")
  }

  @Test func test_underTheRowCap_youngRecordsAreKept() throws {
    let fixture = try Fixture(maxRows: 1000)
    try fixture.append(10)

    let result = try fixture.cleanup.run()

    #expect(result.activity == 0, "nothing is deleted while the cap and the age allow it")
    #expect(try fixture.world.count("activity") == 10, "all ten records remain")
  }

  @Test func test_aRecordPastTheRetentionAge_isStillDeletedUnderTheCap() throws {
    let fixture = try Fixture(maxRows: 1000)
    try fixture.append(3)
    fixture.world.clock.instant = fixture.world.clock.instant.addingTimeInterval(91 * 86_400)

    let result = try fixture.cleanup.run()

    #expect(result.activity == 3, "the age rule still applies when the cap is not exceeded")
  }
}
