import CommunicationLineStore
import Foundation
import Testing

@Suite struct StoreCloseTests {
  private func openStore() throws -> (SQLiteStore, TemporaryDirectory) {
    let scratch = try TemporaryDirectory()
    let store = try SQLiteStore.open(
      at: scratch.storePath, busyTimeoutMilliseconds: 1000, migrations: SchemaMigrations.all)
    return (store, scratch)
  }

  @Test func test_close_checkpointsTheLogAndLeavesOnlyTheDatabaseFile() throws {
    let (store, scratch) = try openStore()
    let log = scratch.storePath.path + "-wal"
    #expect(FileManager.default.fileExists(atPath: log), "migrations left a write-ahead log")

    store.close()

    #expect(!FileManager.default.fileExists(atPath: log), "closing folds the log into the database")
  }

  @Test func test_close_thenAnyUse_failsInsteadOfCrashing() throws {
    let (store, _) = try openStore()

    store.close()

    #expect(throws: (any Error).self, "a closed store reports an error") {
      _ = try store.schemaVersion()
    }
    store.close()
  }
}
