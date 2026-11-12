/// Every failure of the store is one of these cases, so callers can react and messages stay actionable.
public enum StoreError: Error, Equatable, CustomStringConvertible {
  /// The database was written by a newer version of the code and is left untouched.
  case newerSchema(found: Int, supported: Int)
  /// The migration list is not numbered 1, 2, 3, ... without gaps.
  case invalidMigrations
  /// The busy timeout must be zero or more milliseconds.
  case invalidBusyTimeout(Int)
  /// The file system did not accept write-ahead logging.
  case walUnavailable(actual: String)
  /// A SQLite call failed.
  case sqlite(operation: String, code: Int32, message: String)
  /// A SQLite result had a type the store does not read.
  case unsupportedColumnType(Int32)

  public var description: String {
    switch self {
    case .newerSchema(let found, let supported):
      return
        "database schema version \(found) is newer than the version \(supported) this code supports; upgrade the software, the database was not changed"
    case .invalidMigrations:
      return "the migration list must be numbered 1, 2, 3, ... without gaps"
    case .invalidBusyTimeout(let value):
      return "the busy timeout must be zero or more milliseconds, got \(value)"
    case .walUnavailable(let actual):
      return "write-ahead logging is not available on this file system (journal mode is \(actual))"
    case .sqlite(let operation, let code, let message):
      return "SQLite failed during \(operation) (code \(code)): \(message)"
    case .unsupportedColumnType(let type):
      return "SQLite returned a column of unsupported type \(type)"
    }
  }
}
