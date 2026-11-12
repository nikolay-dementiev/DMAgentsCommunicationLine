import Foundation

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
    try StoreFilesystem.prepareFolder(path.deletingLastPathComponent())
    try StoreFilesystem.prepareDatabaseFile(path)
    try StoreFilesystem.verifySidecars(of: path)
    let database = try SQLiteDatabase(path: path.path)
    try database.setBusyTimeout(milliseconds: busyTimeoutMilliseconds)
    try database.execute("PRAGMA foreign_keys = ON")
    let found = try Self.userVersion(of: database)
    guard found <= migrations.count else {
      throw StoreError.newerSchema(found: found, supported: migrations.count)
    }
    let journal = try database.rows("PRAGMA journal_mode = WAL")
    guard journal == [[.text("wal")]] else {
      throw StoreError.walUnavailable(actual: "\(journal)")
    }
    for migration in migrations where migration.version > found {
      try database.transaction {
        for statement in migration.statements { try database.execute(statement) }
        try database.execute("PRAGMA user_version = \(migration.version)")
      }
    }
    try StoreFilesystem.verifySidecars(of: path)
    return SQLiteStore(database: database)
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
