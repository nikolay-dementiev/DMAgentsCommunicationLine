import CommunicationLineApplication
import CommunicationLineDomain
import CommunicationLineStore
import Foundation
import Testing

@Suite struct StoreSettingsTests {
  private let instant = Date(timeIntervalSince1970: 1_700_000_000.125)

  private func makeSUT() throws -> (settings: SQLiteSettingsStore, scratch: TemporaryDirectory) {
    let scratch = try TemporaryDirectory()
    let store = try SQLiteStore.open(
      at: scratch.storePath, busyTimeoutMilliseconds: 1000, migrations: SchemaMigrations.all)
    return (SQLiteSettingsStore(store: store), scratch)
  }

  private let limit = SettingAddress(key: "demo.limit", scope: .global, subject: nil)

  @Test func test_schema_createsTheSettingsTables() throws {
    let (_, scratch) = try makeSUT()
    let raw = try RawDatabase(path: scratch.storePath)

    #expect(try raw.integer("PRAGMA user_version") == SchemaMigrations.all.count, "latest schema")
    #expect(try raw.tableExists("settings_values"), "stored values table")
    #expect(try raw.tableExists("settings_audit"), "audit table")
  }

  @Test func test_apply_firstChange_storesTheValueAndAnAuditRecordWithNoOldValue() throws {
    let (settings, scratch) = try makeSUT()
    defer { withExtendedLifetime(scratch) {} }

    let record = try settings.apply(.integer(7), to: limit, actor: "owner", at: instant)

    #expect(
      record
        == SettingAuditRecord(
          at: instant, actor: "owner", address: limit, oldValue: nil, newValue: .integer(7)),
      "the returned record names actor, time, address, old and new value")
    #expect(try settings.auditRecords(key: "demo.limit") == [record], "the record is persisted")
    #expect(
      try settings.storedValues(key: "demo.limit", family: nil, principal: nil).global
        == .integer(7), "the value is stored")
  }

  @Test func test_apply_secondChange_recordsThePreviousValueAndKeepsOldestFirst() throws {
    let (settings, scratch) = try makeSUT()
    defer { withExtendedLifetime(scratch) {} }
    _ = try settings.apply(.integer(7), to: limit, actor: "owner", at: instant)

    let second = try settings.apply(.integer(9), to: limit, actor: "owner", at: instant + 1)

    #expect(second.oldValue == .integer(7), "the old value is the one stored before")
    #expect(
      try settings.auditRecords(key: "demo.limit").map(\.newValue) == [.integer(7), .integer(9)],
      "both changes are kept, oldest first")
    #expect(
      try settings.storedValues(key: "demo.limit", family: nil, principal: nil).global
        == .integer(9), "the stored value is the latest")
  }

  @Test func test_storedValues_returnsOnlyTheScopesAndSubjectsAskedFor() throws {
    let (settings, scratch) = try makeSUT()
    defer { withExtendedLifetime(scratch) {} }
    let family = SettingAddress(key: "demo.limit", scope: .family, subject: "ops")
    let otherFamily = SettingAddress(key: "demo.limit", scope: .family, subject: "dev")
    let principal = SettingAddress(key: "demo.limit", scope: .principal, subject: "agent-1")
    _ = try settings.apply(.integer(1), to: limit, actor: "owner", at: instant)
    _ = try settings.apply(.integer(2), to: family, actor: "owner", at: instant)
    _ = try settings.apply(.integer(3), to: otherFamily, actor: "owner", at: instant)
    _ = try settings.apply(.integer(4), to: principal, actor: "owner", at: instant)

    let stored = try settings.storedValues(key: "demo.limit", family: "ops", principal: "agent-1")
    let other = try settings.storedValues(key: "demo.limit", family: "ops", principal: "agent-2")

    #expect(
      stored
        == StoredSettingValues(principal: .integer(4), family: .integer(2), global: .integer(1)),
      "each scope returns its own value for the matching subject")
    #expect(other.principal == nil, "another principal has no value")
  }

  @Test func test_apply_auditInsertFails_rollsTheValueBack() throws {
    let (settings, scratch) = try makeSUT()
    let raw = try RawDatabase(path: scratch.storePath)
    try raw.execute(
      "CREATE TRIGGER fail_audit BEFORE INSERT ON settings_audit BEGIN SELECT RAISE(ABORT, 'audit failed'); END"
    )

    #expect(throws: StoreError.self) {
      _ = try settings.apply(.integer(7), to: limit, actor: "owner", at: instant)
    }
    #expect(try raw.integer("SELECT count(*) FROM settings_values") == 0, "no value without audit")
  }

  @Test func test_audit_isAppendOnly() throws {
    let (settings, scratch) = try makeSUT()
    _ = try settings.apply(.integer(7), to: limit, actor: "owner", at: instant)
    let raw = try RawDatabase(path: scratch.storePath)

    #expect(throws: RawDatabaseError.self) {
      try raw.execute("UPDATE settings_audit SET actor = 'x'")
    }
    #expect(throws: RawDatabaseError.self) { try raw.execute("DELETE FROM settings_audit") }
    #expect(
      try raw.integer("SELECT count(*) FROM settings_audit") == 1, "the record is still there")
  }

  @Test func test_audit_cannotBeReplacedByAnInsert() throws {
    let (settings, scratch) = try makeSUT()
    _ = try settings.apply(.integer(7), to: limit, actor: "owner", at: instant)
    let raw = try RawDatabase(path: scratch.storePath)

    #expect(throws: RawDatabaseError.self, "a replacing insert is refused") {
      try raw.execute(
        """
        INSERT OR REPLACE INTO settings_audit (id, at_ms, actor, key, scope, subject, new_value)
        VALUES (1, 99, 'forged', 'demo.limit', 'global', '', '1')
        """)
    }
    #expect(
      try raw.integer("SELECT count(*) FROM settings_audit WHERE actor = 'forged'") == 0,
      "the stored audit record was not rewritten")
  }

  @Test func test_storedValues_unreadableStoredValue_isReportedNotIgnored() throws {
    let (settings, scratch) = try makeSUT()
    let raw = try RawDatabase(path: scratch.storePath)
    try raw.execute(
      "INSERT INTO settings_values (key, scope, subject, value) VALUES ('demo.limit', 'global', '', '{broken')"
    )

    #expect(throws: StoreError.invalidStoredValue(key: "demo.limit")) {
      _ = try settings.storedValues(key: "demo.limit", family: nil, principal: nil)
    }
  }

  @Test func test_auditRecords_familyAddressWithPreviousValue_roundTripsSubjectAndOldValue() throws
  {
    let (settings, scratch) = try makeSUT()
    defer { withExtendedLifetime(scratch) {} }
    let family = SettingAddress(key: "demo.limit", scope: .family, subject: "ops")
    _ = try settings.apply(.text("a"), to: family, actor: "owner", at: instant)
    _ = try settings.apply(.boolean(true), to: family, actor: "owner", at: instant)

    let records = try settings.auditRecords(key: "demo.limit")

    #expect(records.map(\.address) == [family, family], "the subject survives the round trip")
    #expect(records.map(\.oldValue) == [nil, .text("a")], "the old value survives the round trip")
    #expect(records.map(\.newValue) == [.text("a"), .boolean(true)], "the new values are kept")
  }
}
