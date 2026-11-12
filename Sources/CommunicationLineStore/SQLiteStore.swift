import Foundation
import SQLite3

/// The SQLite pragmas a caller may observe.
public enum StorePragma: String {
  case journalMode = "journal_mode"
  case foreignKeys = "foreign_keys"
  case busyTimeout = "busy_timeout"
  case userVersion = "user_version"
}

/// The database of the product: write-ahead logging, enforced foreign keys and numbered migrations.
public final class SQLiteStore {
  let database: SQLiteDatabase

  private init(database: SQLiteDatabase) {
    self.database = database
  }

  /// Opens or creates the database at `path` and brings its schema to the latest migration.
  ///
  /// - Throws: ``StoreError/newerSchema(found:supported:)`` when the file was written by newer code;
  ///   the file is not changed in that case.
  public static func open(
    at path: URL,
    busyTimeoutMilliseconds: Int,
    migrations: [Migration]
  ) throws -> SQLiteStore {
    guard migrations.map(\.version) == (0..<migrations.count).map({ $0 + 1 }) else {
      throw StoreError.invalidMigrations
    }
    guard busyTimeoutMilliseconds >= 0 else {
      throw StoreError.invalidBusyTimeout(busyTimeoutMilliseconds)
    }
    try StoreFilesystem.prepareFolder(
      path.deletingLastPathComponent(), waitingUpTo: busyTimeoutMilliseconds)
    try StoreFilesystem.prepareDatabaseFile(path, waitingUpTo: busyTimeoutMilliseconds)
    return try StoreFilesystem.withSetupLock(
      on: path.deletingLastPathComponent(), waitingUpTo: busyTimeoutMilliseconds
    ) {
      try StoreFilesystem.verifySidecars(of: path)
      let database = try SQLiteDatabase(path: path.path)
      try database.setBusyTimeout(milliseconds: busyTimeoutMilliseconds)
      try database.execute("PRAGMA foreign_keys = ON")
      let found = try Self.userVersion(of: database)
      guard found <= migrations.count else {
        throw StoreError.newerSchema(found: found, supported: migrations.count)
      }
      try enableWriteAheadLogging(database, waitingUpTo: busyTimeoutMilliseconds)
      try StoreFilesystem.verifySidecars(of: path)
      for migration in migrations where migration.version > found {
        try database.transaction {
          // Another process may have migrated while this one waited for the write lock.
          let current = try Self.userVersion(of: database)
          guard current <= migrations.count else {
            throw StoreError.newerSchema(found: current, supported: migrations.count)
          }
          if current >= migration.version { return }
          for statement in migration.statements { try database.execute(statement) }
          try database.execute("PRAGMA user_version = \(migration.version)")
        }
      }
      try StoreFilesystem.verifySidecars(of: path)
      return SQLiteStore(database: database)
    }
  }

  /// Switches the file to write-ahead logging. SQLite does not apply the busy timeout to this switch when
  /// another connection is opening the same file, so a busy answer is retried until the timeout is spent.
  private static func enableWriteAheadLogging(
    _ database: SQLiteDatabase, waitingUpTo timeoutMilliseconds: Int
  ) throws {
    let deadline = Date().addingTimeInterval(Double(timeoutMilliseconds) / 1000)
    while try database.rows("PRAGMA journal_mode") != [[.text("wal")]] {
      do {
        let journal = try database.rows("PRAGMA journal_mode = WAL")
        guard journal == [[.text("wal")]] else {
          throw StoreError.walUnavailable(actual: "\(journal)")
        }
      } catch StoreError.sqlite(_, let code, _) where code == SQLITE_BUSY && Date() < deadline {
        Thread.sleep(forTimeInterval: 0.005)
      }
    }
  }

  public func schemaVersion() throws -> Int {
    try Self.userVersion(of: database)
  }

  public func pragmaValue(_ pragma: StorePragma) throws -> String {
    switch try database.rows("PRAGMA \(pragma.rawValue)").first?.first {
    case .integer(let number): return String(number)
    case .text(let text): return text
    case .null, .none: return ""
    }
  }

  private static func userVersion(of database: SQLiteDatabase) throws -> Int {
    guard case .integer(let version) = try database.rows("PRAGMA user_version").first?.first else {
      throw StoreError.sqlite(operation: "read user_version", code: 0, message: "no value")
    }
    return Int(version)
  }
}
