import Darwin

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
  /// A folder or file is readable or writable by someone other than its owner. Nothing was changed.
  case insecurePermissions(path: String, mode: Int, maximumMode: Int)
  /// A path that must be a plain folder or file is something else, such as a symbolic link.
  case unexpectedFileType(path: String)
  /// A file system call failed.
  case posix(operation: String, path: String, code: Int32)
  /// A stored setting value is not valid JSON for a setting value.
  case invalidStoredValue(key: String)
  /// One SQL string held more than one statement; the rest would have been ignored.
  case multipleStatements(String)
  /// A time is not finite or does not fit the stored millisecond count.
  case invalidTimestamp
  /// A bundled resource is missing.
  case missingResource(String)
  /// A SQLite call failed.
  case sqlite(operation: String, code: Int32, message: String)
  /// A SQLite result had a type the store does not read.
  case unsupportedColumnType(Int32)
  /// A stored identity or rights row is not in a form the store reads.
  case invalidStoredIdentity(String)
  /// The system could not supply random bytes.
  case randomUnavailable(status: Int32)

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
    case .insecurePermissions(let path, let mode, let maximumMode):
      return
        "\(path) has mode \(String(mode, radix: 8)) but must not allow more than \(String(maximumMode, radix: 8)); it was not changed, fix it with: chmod \(String(maximumMode, radix: 8)) '\(path)'"
    case .unexpectedFileType(let path):
      return "\(path) must be a plain folder or file, not a link or another kind of entry"
    case .posix(let operation, let path, let code):
      return "\(operation) failed for \(path): \(String(cString: strerror(code))) (errno \(code))"
    case .invalidStoredValue(let key):
      return "the stored value of setting \(key) cannot be read; the database may be damaged"
    case .multipleStatements(let sql):
      return "one SQL string must hold exactly one statement, got: \(sql)"
    case .invalidTimestamp:
      return "the time of the change cannot be stored as milliseconds since 1970"
    case .missingResource(let name):
      return "the bundled resource \(name) is missing from the package"
    case .sqlite(let operation, let code, let message):
      return "SQLite failed during \(operation) (code \(code)): \(message)"
    case .unsupportedColumnType(let type):
      return "SQLite returned a column of unsupported type \(type)"
    case .invalidStoredIdentity(let detail):
      return
        "a stored identity or rights row cannot be read (\(detail)); the database may be damaged"
    case .randomUnavailable(let status):
      return "the system could not supply random bytes (status \(status))"
    }
  }
}
