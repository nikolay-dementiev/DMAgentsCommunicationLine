import CommunicationLineApplication
import CommunicationLineDomain
import CommunicationLineStore
import Dispatch
import Foundation
import Testing

/// Findings of the review of the foundation branch: races between openers, silent input loss and
/// values that did not survive a round trip.
@Suite struct StoreRobustnessTests {
  private let instant = Date(timeIntervalSince1970: 1_700_000_000.1254)
  private let limit = SettingAddress(key: "demo.limit", scope: .global, subject: nil)

  private func makeSettings() throws -> (SQLiteSettingsStore, TemporaryDirectory) {
    let scratch = try TemporaryDirectory()
    let store = try SQLiteStore.open(
      at: scratch.storePath, busyTimeoutMilliseconds: 5000, migrations: SchemaMigrations.all)
    return (SQLiteSettingsStore(store: store), scratch)
  }

  @Test func test_open_manyProcessesStartingAtOnce_allSucceedOnAFreshFile() throws {
    for _ in 0..<20 {
      let scratch = try TemporaryDirectory()
      let path = scratch.storePath
      let lock = NSLock()
      nonisolated(unsafe) var failures: [String] = []
      DispatchQueue.concurrentPerform(iterations: 8) { _ in
        do {
          _ = try SQLiteStore.open(
            at: path, busyTimeoutMilliseconds: 10_000, migrations: SchemaMigrations.all)
        } catch {
          lock.withLock { failures.append("\(error)") }
        }
      }
      #expect(failures.isEmpty, "every opener reaches the current version: \(failures)")
    }
  }

  @Test func test_open_migrationWithTwoStatementsInOneString_isRejectedNotHalfApplied() throws {
    let scratch = try TemporaryDirectory()
    let migrations = [
      Migration(
        version: 1,
        statements: ["CREATE TABLE a (id INTEGER); CREATE TABLE b (id INTEGER)"])
    ]

    #expect(throws: StoreError.self) {
      _ = try SQLiteStore.open(
        at: scratch.storePath, busyTimeoutMilliseconds: 1000, migrations: migrations)
    }
    let raw = try RawDatabase(path: scratch.storePath)
    #expect(try raw.integer("PRAGMA user_version") == 0, "the version did not move")
    #expect(try !raw.tableExists("a"), "the first statement was rolled back too")
  }

  @Test func test_apply_returnedRecord_equalsTheRecordReadBack() throws {
    let (settings, scratch) = try makeSettings()
    defer { withExtendedLifetime(scratch) {} }

    let returned = try settings.apply(.integer(7), to: limit, actor: "owner", at: instant)

    #expect(
      try settings.auditRecords(key: "demo.limit") == [returned],
      "the time is rounded to milliseconds in the returned record as well")
  }

  @Test(arguments: [
    Date(timeIntervalSince1970: .infinity), Date(timeIntervalSince1970: .nan),
    Date(timeIntervalSince1970: 1e300),
  ])
  func test_apply_unrepresentableTime_isRejected(time: Date) throws {
    let (settings, scratch) = try makeSettings()
    defer { withExtendedLifetime(scratch) {} }

    #expect(throws: StoreError.invalidTimestamp) {
      _ = try settings.apply(.integer(7), to: limit, actor: "owner", at: time)
    }
  }

  @Test func test_apply_subjectsDifferingAfterANulCharacter_stayDistinct() throws {
    let (settings, scratch) = try makeSettings()
    defer { withExtendedLifetime(scratch) {} }
    let first = SettingAddress(key: "demo.limit", scope: .family, subject: "ops\u{0}one")
    let second = SettingAddress(key: "demo.limit", scope: .family, subject: "ops\u{0}two")
    _ = try settings.apply(.integer(1), to: first, actor: "owner", at: instant)
    _ = try settings.apply(.integer(2), to: second, actor: "owner", at: instant)

    #expect(
      try settings.storedValues(key: "demo.limit", family: "ops\u{0}one", principal: nil).family
        == .integer(1), "the first subject keeps its own value")
    #expect(
      try settings.storedValues(key: "demo.limit", family: "ops\u{0}two", principal: nil).family
        == .integer(2), "the second subject keeps its own value")
  }
}
