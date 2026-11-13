import CommunicationLineDomain
import CommunicationLineService
import Darwin
import Foundation
import Testing

typealias Principal = (id: String, token: String)

/// A real `commline-service` on a temporary store, driven through real `commline` processes.
final class EndToEndWorld: @unchecked Sendable {
  let store = ShortFolder()
  private let secrets = ShortFolder()
  private let commline: URL
  private let serviceExecutable: URL
  private var service: Child?
  private var inProcessService: ServiceHost?
  private let clock: EndToEndClock?
  private var ownerToken = ""
  private var fileCounter = 0
  private let lock = NSLock()

  /// With a `clock` the service runs inside the test process on that clock, which the test moves;
  /// the commands are still separate processes talking to it over the socket.
  init(clock: EndToEndClock? = nil) throws {
    self.clock = clock
    commline = try builtExecutable("commline")
    serviceExecutable = try builtExecutable("commline-service")
    try FileManager.default.createDirectory(
      at: secrets.url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try startService()
    ownerToken = try issuedToken(["owner", "init"])
  }

  deinit { _ = stopService() }

  var socketPath: String { store.path + "/commline.sock" }

  // MARK: - Service

  func startService() throws {
    if let clock {
      inProcessService = try ServiceHost.start(
        storeFolder: URL(fileURLWithPath: store.path, isDirectory: true), clock: clock)
      return
    }
    let child = try Child(serviceExecutable, [store.path])
    service = child
    let deadline = Date().addingTimeInterval(10)
    while !FileManager.default.fileExists(atPath: socketPath) {
      if !child.isRunning { throw ProcessError.didNotStart(child.standardError) }
      guard Date() < deadline else { throw ProcessError.didNotStart("no socket after 10 s") }
      Thread.sleep(forTimeInterval: 0.02)
    }
  }

  /// SIGTERM, then the exit status of the service (nil when it did not stop).
  func stopService() -> Int32? {
    if let inProcessService {
      self.inProcessService = nil
      inProcessService.stop()
      return 0
    }
    guard let service else { return nil }
    self.service = nil
    service.terminate()
    return service.waitForExit(seconds: 10)
  }

  /// A second `commline-service` on the same store, not waited for.
  func startSecondInstance() throws -> Child { try Child(serviceExecutable, [store.path]) }

  // MARK: - Commands

  /// Starts `commline` and returns at once. `token` goes through a private token file.
  func spawn(_ arguments: [String], token: String? = nil) throws -> Child {
    var full = ["--store", store.path]
    if let token { full += ["--token-file", tokenFile(holding: token)] }
    return try Child(commline, full + arguments)
  }

  func run(_ arguments: [String], token: String? = nil) throws
    -> (status: Int32, out: String, err: String)
  {
    let child = try spawn(arguments, token: token)
    guard let status = child.waitForExit(seconds: 30) else {
      child.terminate()
      throw ProcessError.didNotStart("commline \(arguments) did not finish in 30 s")
    }
    return (status, child.standardOutput.trimmingCharacters(in: .newlines), child.standardError)
  }

  /// Runs a command that issues a credential and reads the token from the file it was told to
  /// write: the command prints only the path.
  func issuedToken(_ arguments: [String], token: String? = nil) throws -> String {
    lock.lock()
    fileCounter += 1
    let path = secrets.path + "/issued-\(fileCounter)"
    lock.unlock()
    let result = try require(run(arguments + ["--token-out", path], token: token), "\(arguments)")
    #expect(
      result.out == "token file: \(path)", "only the path is printed: \(result.out)")
    return try String(contentsOfFile: path, encoding: .utf8).trimmingCharacters(in: .newlines)
  }

  func asOwner(_ arguments: [String]) throws -> (status: Int32, out: String, err: String) {
    try run(arguments, token: ownerToken)
  }

  func tokenFile(holding token: String) -> String {
    lock.lock()
    fileCounter += 1
    let path = secrets.path + "/token-\(fileCounter)"
    lock.unlock()
    FileManager.default.createFile(
      atPath: path, contents: Data((token + "\n").utf8), attributes: [.posixPermissions: 0o600])
    return path
  }

  func enrol(family: String, name: String, role: String = "agent") throws -> Principal {
    let created = try require(
      asOwner(["principal", "create", "--family", family, "--role", role, "--name", name]),
      "principal create")
    let id = String(created.out.split(separator: "\t").first ?? "")
    return (id, try issuedToken(["credential", "issue", id], token: ownerToken))
  }

  func send(from sender: Principal, to recipient: Principal, subject: String) throws -> String {
    try require(
      run(
        ["send", "--to", recipient.id, "--subject", subject, "--body", "body of \(subject)"],
        token: sender.token), "send \(subject)"
    ).out
  }

  func inboxIDs(of principal: Principal) throws -> [String] {
    let result = try require(run(["inbox"], token: principal.token), "inbox")
    return result.out.split(separator: "\n").filter { !$0.hasPrefix("next:") }
      .map { String($0.split(separator: "\t").first ?? "") }
  }

  @discardableResult
  func require(_ result: (status: Int32, out: String, err: String), _ what: String) throws
    -> (status: Int32, out: String, err: String)
  {
    guard result.status == 0 else {
      throw ProcessError.didNotStart("\(what) exited \(result.status): \(result.err)")
    }
    return result
  }
}

/// A clock the test moves by hand, for a service that runs inside the test process.
final class EndToEndClock: WallClock, @unchecked Sendable {
  private let lock = NSLock()
  private var instant = Date(timeIntervalSince1970: 1_800_000_000)

  func now() -> Date { lock.withLock { instant } }

  func advance(seconds: TimeInterval) {
    lock.withLock { instant = instant.addingTimeInterval(seconds) }
  }
}
