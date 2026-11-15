import CommunicationLineApplication
import CommunicationLineDomain
import CommunicationLineStore
import Foundation
import Testing

@Suite struct StorageRefusalLevelTests {
  private struct Fixture {
    let world: MessagingFixture
    let storage: StorageService

    init() throws {
      world = try MessagingFixture()
      storage = StorageService(
        store: SQLiteStorageStore(store: world.identity.store), settings: world.settings)
    }

    func setBudget(_ bytes: Int64) throws {
      _ = try world.settings.change(
        SettingAddress(key: "storage.budget", scope: .global, subject: nil), to: .integer(bytes),
        ownerToken: world.owner)
    }
  }

  @Test func test_underTheDefaultBudget_theStoreDoesNotRefuse() throws {
    let fixture = try Fixture()

    let status = try fixture.storage.status()

    #expect(status.refusalPercent == 95, "the default refusal level")
    #expect(!status.isRefusing, "a small store is far below it")
    #expect(try !fixture.storage.refusesNewMail(), "so mail is accepted")
  }

  @Test func test_theRefusalLevel_isReachedExactlyAtItsPercent() throws {
    let fixture = try Fixture()
    let used = try fixture.storage.status().usedBytes
    // The largest budget whose 95 percent mark is still at or below the use.
    let atTheLevel = used * 100 / 95

    try fixture.setBudget(atTheLevel)
    #expect(try fixture.storage.status().isRefusing, "use at 95 percent of the budget refuses")

    try fixture.setBudget(atTheLevel + 1)
    #expect(try !fixture.storage.status().isRefusing, "one byte more budget is below the level")
  }

  @Test func test_theWarning_comesBeforeTheRefusal() throws {
    let fixture = try Fixture()
    let used = try fixture.storage.status().usedBytes

    // 90 percent of this budget is used: past the 80 percent warning, short of the 95 percent level.
    try fixture.setBudget(used * 100 / 90)
    let status = try fixture.storage.status()

    #expect(status.isWarning, "the warning is on")
    #expect(!status.isRefusing, "but mail is still accepted")
  }
}
