import Foundation
import SQLite3

/// SQLite's "copy this text now" destructor; the C macro is not imported into Swift.
private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// A value bound to or read from a statement.
enum SQLiteValue: Equatable {
  case integer(Int64)
  case text(String)
  case null
}

/// A thin wrapper over one SQLite connection. Statements are always parameterised.
final class SQLiteDatabase {
  private var handle: OpaquePointer?

  init(path: String) throws {
    let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
    let code = sqlite3_open_v2(path, &handle, flags, nil)
    guard code == SQLITE_OK else {
      let error = failure("open", code)
      sqlite3_close(handle)
      handle = nil
      throw error
    }
  }

  deinit { sqlite3_close(handle) }

  func setBusyTimeout(milliseconds: Int) throws {
    let code = sqlite3_busy_timeout(handle, Int32(clamping: milliseconds))
    guard code == SQLITE_OK else { throw failure("busy timeout", code) }
  }

  func execute(_ sql: String, _ bindings: [SQLiteValue] = []) throws {
    _ = try rows(sql, bindings)
  }

  func rows(_ sql: String, _ bindings: [SQLiteValue] = []) throws -> [[SQLiteValue]] {
    var statement: OpaquePointer?
    defer { sqlite3_finalize(statement) }
    let hasMore = try sql.withCString { text -> Bool in
      var tail: UnsafePointer<CChar>?
      let prepared = sqlite3_prepare_v2(handle, text, -1, &statement, &tail)
      guard prepared == SQLITE_OK else { throw failure("prepare", prepared) }
      return tail.map { String(cString: $0).contains { !$0.isWhitespace && $0 != ";" } } ?? false
    }
    // SQLite runs only the first statement of a string; refuse the rest instead of dropping it.
    guard !hasMore else { throw StoreError.multipleStatements(sql) }
    for (offset, value) in bindings.enumerated() {
      try bind(value, at: Int32(offset + 1), to: statement)
    }
    var result: [[SQLiteValue]] = []
    while true {
      let code = sqlite3_step(statement)
      if code == SQLITE_DONE { return result }
      guard code == SQLITE_ROW else { throw failure("step", code) }
      result.append(try readRow(statement))
    }
  }

  /// Runs `body` inside one write transaction: committed when it returns, rolled back when it throws.
  func transaction<Result>(_ body: () throws -> Result) throws -> Result {
    try execute("BEGIN IMMEDIATE")
    let result: Result
    do {
      result = try body()
    } catch {
      do {
        try execute("ROLLBACK")
      } catch let rollbackError {
        throw StoreError.sqlite(
          operation: "rollback after \(error)", code: SQLITE_ERROR,
          message: "\(rollbackError)")
      }
      throw error
    }
    do {
      try execute("COMMIT")
    } catch {
      // A failed COMMIT (busy, disk full) can leave the transaction open; end it so the connection stays usable.
      if sqlite3_get_autocommit(handle) == 0 {
        do {
          try execute("ROLLBACK")
        } catch let rollbackError {
          throw StoreError.sqlite(
            operation: "rollback after \(error)", code: SQLITE_ERROR, message: "\(rollbackError)")
        }
      }
      throw error
    }
    return result
  }

  private func bind(_ value: SQLiteValue, at index: Int32, to statement: OpaquePointer?) throws {
    let code: Int32
    switch value {
    case .integer(let number): code = sqlite3_bind_int64(statement, index, number)
    case .text(let text):
      // Bind the exact byte count: a length of -1 would stop at an embedded NUL character.
      guard let length = Int32(exactly: text.utf8.count) else {
        throw StoreError.sqlite(operation: "bind", code: SQLITE_TOOBIG, message: "text too long")
      }
      code = sqlite3_bind_text(statement, index, text, length, sqliteTransient)
    case .null: code = sqlite3_bind_null(statement, index)
    }
    guard code == SQLITE_OK else { throw failure("bind", code) }
  }

  private func readRow(_ statement: OpaquePointer?) throws -> [SQLiteValue] {
    try (0..<sqlite3_column_count(statement)).map { column in
      switch sqlite3_column_type(statement, column) {
      case SQLITE_INTEGER: return .integer(sqlite3_column_int64(statement, column))
      case SQLITE_TEXT:
        guard let bytes = sqlite3_column_text(statement, column) else {
          throw failure("read text", SQLITE_NOMEM)
        }
        let count = Int(sqlite3_column_bytes(statement, column))
        return .text(
          String(decoding: UnsafeBufferPointer(start: bytes, count: count), as: UTF8.self))
      case SQLITE_NULL: return .null
      case let other: throw StoreError.unsupportedColumnType(other)
      }
    }
  }

  private func failure(_ operation: String, _ code: Int32) -> StoreError {
    .sqlite(operation: operation, code: code, message: String(cString: sqlite3_errmsg(handle)))
  }
}
