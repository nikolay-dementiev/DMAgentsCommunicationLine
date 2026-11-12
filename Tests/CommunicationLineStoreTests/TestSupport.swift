import Foundation
import SQLite3
import Testing

/// The umask belongs to the whole process, while suites run in parallel. A test that changes it
/// and a test that creates a scratch folder at the same time would otherwise race: the folder
/// gets a mode the test did not expect and the next write into it is refused.
enum ProcessUmask {
  private static let lock = NSLock()

  static func withMask<T>(_ mask: mode_t, _ body: () throws -> T) rethrows -> T {
    lock.lock()
    defer { lock.unlock() }
    let previous = umask(mask)
    defer { umask(previous) }
    return try body()
  }

  static func whileUnchanged<T>(_ body: () throws -> T) rethrows -> T {
    lock.lock()
    defer { lock.unlock() }
    return try body()
  }
}

/// A scratch folder that is removed when the value goes out of scope.
final class TemporaryDirectory {
  let url: URL

  init() throws {
    let location = FileManager.default.temporaryDirectory
      .appending(path: "communicationline-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try ProcessUmask.whileUnchanged {
      try FileManager.default.createDirectory(at: location, withIntermediateDirectories: true)
    }
    url = location
  }

  deinit {
    do {
      try FileManager.default.removeItem(at: url)
    } catch {
      Issue.record("could not remove scratch folder \(url.path): \(error)")
    }
  }

  /// A path inside the scratch folder whose parent folder does not exist yet.
  var storePath: URL {
    url.appending(path: "store", directoryHint: .isDirectory)
      .appending(path: "communicationline.sqlite", directoryHint: .notDirectory)
  }
}

/// A second, independent connection used to observe a database file from outside the store.
final class RawDatabase {
  private var handle: OpaquePointer?

  init(path: URL) throws {
    guard sqlite3_open_v2(path.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
      throw RawDatabaseError.open(String(cString: sqlite3_errmsg(handle)))
    }
  }

  deinit { sqlite3_close(handle) }

  func execute(_ sql: String) throws {
    guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
      throw RawDatabaseError.statement(String(cString: sqlite3_errmsg(handle)))
    }
  }

  func integer(_ sql: String) throws -> Int {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
      throw RawDatabaseError.statement(String(cString: sqlite3_errmsg(handle)))
    }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else { throw RawDatabaseError.noRow }
    return Int(sqlite3_column_int64(statement, 0))
  }

  func tableExists(_ name: String) throws -> Bool {
    try integer("SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = '\(name)'") == 1
  }
}

enum RawDatabaseError: Error {
  case open(String)
  case statement(String)
  case noRow
}
