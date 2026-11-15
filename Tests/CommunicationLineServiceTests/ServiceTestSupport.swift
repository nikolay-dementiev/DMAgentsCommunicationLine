import CommunicationLineDomain
import CommunicationLineService
import CommunicationLineWire
import Foundation
import SQLite3

/// A service runtime on a real store in a short folder under /tmp: a socket path is limited to about
/// a hundred bytes, which the usual per-test temporary folders exceed.
final class ServiceFixture: @unchecked Sendable {
  let folder: URL
  let runtime: ServiceRuntime

  let clock: TestClock

  init(clock: TestClock = TestClock(), reporter: any FailureReporter = StandardErrorReporter())
    throws
  {
    let name = "cl-" + UUID().uuidString.prefix(8).lowercased()
    folder = URL(fileURLWithPath: "/tmp/\(name)", isDirectory: true)
    self.clock = clock
    runtime = try ServiceRuntime.open(storeFolder: folder, clock: clock, reporter: reporter)
  }

  deinit {
    try? FileManager.default.removeItem(at: folder)
  }

  func call(_ operation: String, token: String? = nil, _ arguments: [String: WireValue] = [:])
    -> WireResponse
  {
    runtime.dispatcher.handle(
      WireRequest(token: token, operation: operation, arguments: arguments))
  }

  /// The owner token of a fresh store.
  func bootstrapOwner() throws -> String {
    try string(call("owner.credential"), "token")
  }

  /// Creates a principal and issues its credential; returns its id and token.
  func enrol(owner: String, family: String, name: String, role: String = "agent") throws
    -> (id: String, token: String)
  {
    let created = call(
      "principal.create", token: owner,
      ["family": .string(family), "role": .string(role), "name": .string(name)])
    let id = try string(created, "id")
    let issued = call("credential.issue", token: owner, ["principal": .string(id)])
    return (id, try string(issued, "token"))
  }

  func string(_ response: WireResponse, _ key: String) throws -> String {
    guard case .object(let fields)? = response.result, case .string(let value)? = fields[key]
    else { throw FixtureError.missing(key, response) }
    return value
  }

  func field(_ response: WireResponse, _ key: String) throws -> WireValue {
    guard case .object(let fields)? = response.result, let value = fields[key] else {
      throw FixtureError.missing(key, response)
    }
    return value
  }
}

enum FixtureError: Error {
  case missing(String, WireResponse)
}

/// A clock the test moves by hand.
final class TestClock: WallClock, @unchecked Sendable {
  private let lock = NSLock()
  private var instant: Date

  init(start: Date = Date(timeIntervalSince1970: 1_800_000_000)) { instant = start }

  func now() -> Date {
    lock.lock()
    defer { lock.unlock() }
    return instant
  }

  func advance(seconds: Double) {
    lock.lock()
    instant = instant.addingTimeInterval(seconds)
    lock.unlock()
  }

  func advance(days: Double) {
    lock.lock()
    instant = instant.addingTimeInterval(days * 86_400)
    lock.unlock()
  }
}

/// A second connection to the service's database file, to look at it from outside.
final class RawFile {
  private var handle: OpaquePointer?

  init(folder: URL) throws {
    let path = folder.appendingPathComponent(ServiceRuntime.databaseName).path
    guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
      throw POSIXError(.EIO)
    }
  }

  deinit { sqlite3_close(handle) }

  func execute(_ sql: String) throws {
    guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw POSIXError(.EIO) }
  }

  /// Every column of every activity record, joined into one text.
  func activityDump() throws -> String {
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        handle,
        "SELECT actor || '|' || operation || '|' || outcome || '|' || targets FROM activity",
        -1, &statement, nil) == SQLITE_OK
    else { throw POSIXError(.EIO) }
    defer { sqlite3_finalize(statement) }
    var lines: [String] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      lines.append(String(cString: sqlite3_column_text(statement, 0)))
    }
    return lines.joined(separator: "\n")
  }

  /// The number of rows in `table`.
  func count(_ table: String) throws -> Int {
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(handle, "SELECT COUNT(*) FROM \(table)", -1, &statement, nil) == SQLITE_OK
    else { throw POSIXError(.EIO) }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else { throw POSIXError(.EIO) }
    return Int(sqlite3_column_int64(statement, 0))
  }
}

extension ServiceHost {
  /// Waits until `count` principals have a wait parked, as `principal.list` shows it. The service
  /// itself says when a wait has parked, so a test does not have to guess how long that takes. The
  /// long limit only keeps a broken service from hanging the test.
  func waitUntilParked(ownerToken: String, count: Int) -> Bool {
    let deadline = Date().addingTimeInterval(60)
    repeat {
      let response = try? SocketExchange.call(
        socketPath: socketPath,
        request: WireRequest(token: ownerToken, operation: "principal.list"),
        maximumFrame: frameMaximum)
      if case .object(let fields)? = response?.result,
        case .array(let principals)? = fields["principals"]
      {
        let parked = principals.filter { principal in
          guard case .object(let entry) = principal, case .integer? = entry["listening_since_ms"]
          else { return false }
          return true
        }
        if parked.count >= count { return true }
      }
      Thread.sleep(forTimeInterval: 0.01)
    } while Date() < deadline
    return false
  }
}
