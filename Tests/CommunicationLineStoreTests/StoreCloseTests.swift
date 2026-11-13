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

  @Test func test_close_checkpointsTheWriteAheadLog() throws {
    let (store, scratch) = try openStore()
    let log = scratch.storePath.path + "-wal"
    let before = (try? FileManager.default.attributesOfItem(atPath: log)[.size] as? Int) ?? 0
    #expect(before > 0, "migrations left records in the write-ahead log")

    store.close()

    let size = (try? FileManager.default.attributesOfItem(atPath: log)[.size] as? Int) ?? 0
    #expect(size == 0, "closing folds the log into the database, nothing is left in it")
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
