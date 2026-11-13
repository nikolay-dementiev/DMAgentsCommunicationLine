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
  private var ownerToken = ""
  private var fileCounter = 0
  private let lock = NSLock()

  init() throws {
    commline = try builtExecutable("commline")
    serviceExecutable = try builtExecutable("commline-service")
    try FileManager.default.createDirectory(
      at: secrets.url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try startService()
    ownerToken = try require(run(["owner", "init"]), "owner init").out
  }

  deinit { _ = stopService() }

  var socketPath: String { store.path + "/commline.sock" }

  // MARK: - Service

  func startService() throws {
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
    let issued = try require(asOwner(["credential", "issue", id]), "credential issue")
    return (id, issued.out)
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
