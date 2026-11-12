import CommunicationLineStore
import Foundation
import Testing

@Suite struct StoreMigrationTests {
  private let widgetMigrations = [
    Migration(version: 1, statements: ["CREATE TABLE widgets (id INTEGER PRIMARY KEY)"]),
    Migration(version: 2, statements: ["ALTER TABLE widgets ADD COLUMN name TEXT"]),
  ]

  @Test func test_open_freshFile_reachesLatestVersion() throws {
    let scratch = try TemporaryDirectory()
    let store = try SQLiteStore.open(
      at: scratch.storePath, busyTimeoutMilliseconds: 1000, migrations: widgetMigrations)
    let raw = try RawDatabase(path: scratch.storePath)

    #expect(try store.schemaVersion() == 2, "the store reports the latest version")
    #expect(try raw.integer("PRAGMA user_version") == 2, "the file carries the latest version")
    #expect(try raw.tableExists("widgets"), "the first migration ran")
    #expect(
      try raw.integer("SELECT count(*) FROM pragma_table_info('widgets') WHERE name = 'name'") == 1,
      "the second migration ran")
  }

  @Test func test_open_currentDatabase_appliesNothingAgain() throws {
    let scratch = try TemporaryDirectory()
    _ = try SQLiteStore.open(
      at: scratch.storePath, busyTimeoutMilliseconds: 1000, migrations: widgetMigrations)
    let raw = try RawDatabase(path: scratch.storePath)
    try raw.execute("INSERT INTO widgets (id, name) VALUES (1, 'kept')")

    let reopened = try SQLiteStore.open(
      at: scratch.storePath, busyTimeoutMilliseconds: 1000, migrations: widgetMigrations)

    #expect(try reopened.schemaVersion() == 2, "the version is unchanged")
    #expect(try raw.integer("SELECT count(*) FROM widgets") == 1, "existing rows are untouched")
  }

  @Test func test_open_newerDatabase_failsWithoutChangingIt() throws {
    let scratch = try TemporaryDirectory()
    _ = try SQLiteStore.open(
      at: scratch.storePath, busyTimeoutMilliseconds: 1000, migrations: widgetMigrations)
    let raw = try RawDatabase(path: scratch.storePath)
    try raw.execute("PRAGMA user_version = 5")

    #expect(throws: StoreError.newerSchema(found: 5, supported: 2)) {
      _ = try SQLiteStore.open(
        at: scratch.storePath, busyTimeoutMilliseconds: 1000, migrations: widgetMigrations)
    }
    #expect(try raw.integer("PRAGMA user_version") == 5, "the newer version is left as it was")
  }

  @Test func test_open_migrationFailsMidway_leavesVersionAndSchemaUnchanged() throws {
    let scratch = try TemporaryDirectory()
    let broken = [
      widgetMigrations[0],
      Migration(
        version: 2,
        statements: [
          "CREATE TABLE gadgets (id INTEGER PRIMARY KEY)",
          "CREATE TABLE gadgets (id INTEGER PRIMARY KEY)",
        ]),
    ]

    #expect(throws: StoreError.self) {
      _ = try SQLiteStore.open(
        at: scratch.storePath, busyTimeoutMilliseconds: 1000, migrations: broken)
    }
    let raw = try RawDatabase(path: scratch.storePath)

    #expect(try raw.integer("PRAGMA user_version") == 1, "the version stays at the last good one")
    #expect(try raw.tableExists("widgets"), "the committed migration is kept")
    #expect(try !raw.tableExists("gadgets"), "the half-applied migration left no table")
  }

  @Test func test_open_gapInMigrationNumbers_isRejected() throws {
    let scratch = try TemporaryDirectory()
    let gapped = [widgetMigrations[0], Migration(version: 3, statements: [])]

    #expect(throws: StoreError.invalidMigrations) {
      _ = try SQLiteStore.open(
        at: scratch.storePath, busyTimeoutMilliseconds: 1000, migrations: gapped)
    }
  }

  @Test func test_open_setsWalForeignKeysAndBusyTimeout() throws {
    let scratch = try TemporaryDirectory()
    let store = try SQLiteStore.open(
      at: scratch.storePath, busyTimeoutMilliseconds: 1234, migrations: widgetMigrations)

    #expect(try store.pragmaValue(.journalMode) == "wal", "write-ahead logging is on")
    #expect(try store.pragmaValue(.foreignKeys) == "1", "foreign keys are enforced")
    #expect(try store.pragmaValue(.busyTimeout) == "1234", "the busy timeout is the given one")
  }
}
