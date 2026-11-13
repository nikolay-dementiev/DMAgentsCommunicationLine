import CommunicationLineInstall
import CommunicationLineWire
import Darwin
import Foundation
import Testing

/// Records the commands it is asked to run and answers from a script.
private final class ScriptedRunner: CommandRunning, @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [[String]] = []
  private let status: Int32
  private let output: String

  var commands: [[String]] { lock.withLock { recorded } }

  init(status: Int32 = 0, output: String = "") {
    self.status = status
    self.output = output
  }

  func run(_ executable: String, _ arguments: [String]) throws -> CommandResult {
    lock.withLock { recorded.append([executable] + arguments) }
    return CommandResult(status: status, output: output)
  }
}

struct SystemLaunchdTests {
  private let plist = URL(
    fileURLWithPath: "/tmp/cli-x/Library/LaunchAgents/com.commline.service.plist")

  @Test func test_bootstrap_loadsThePlistIntoTheGraphicalDomainOfTheUser() throws {
    let runner = ScriptedRunner()

    try SystemLaunchd(runner: runner).bootstrap(plist: plist, userID: 501)

    #expect(
      runner.commands == [["/bin/launchctl", "bootstrap", "gui/501", plist.path]],
      "launchctl bootstrap into gui/<uid>")
  }

  @Test func test_bootout_unloadsTheServiceByLabel() throws {
    let runner = ScriptedRunner()

    try SystemLaunchd(runner: runner).bootout(label: "com.commline.service", userID: 501)

    #expect(
      runner.commands == [["/bin/launchctl", "bootout", "gui/501/com.commline.service"]],
      "launchctl bootout gui/<uid>/<label>")
  }

  @Test func test_isLoaded_followsTheStatusOfPrint() throws {
    let loaded = ScriptedRunner(status: 0)
    let absent = ScriptedRunner(status: 113)

    #expect(
      try SystemLaunchd(runner: loaded).isLoaded(label: "l", userID: 501), "status 0 is loaded")
    #expect(
      try !SystemLaunchd(runner: absent).isLoaded(label: "l", userID: 501),
      "a failing print means not loaded")
    #expect(loaded.commands == [["/bin/launchctl", "print", "gui/501/l"]], "launchctl print")
  }

  @Test func test_isLoaded_onlyANotFoundAnswerMeansNotLoaded() {
    for status in [Int32(112), 5, 1] {
      let runner = ScriptedRunner(status: status, output: "no domain")

      #expect(
        throws: InstallError.launchd("print failed (\(status)): no domain"),
        "status \(status) is not a not-found answer, so it is an error"
      ) {
        _ = try SystemLaunchd(runner: runner).isLoaded(label: "l", userID: 501)
      }
    }
  }

  @Test func test_aFailingLaunchctl_isAnErrorThatCarriesItsOutput() {
    let runner = ScriptedRunner(status: 5, output: "Bootstrap failed: 5: Input/output error")

    #expect(
      throws: InstallError.launchd("bootstrap failed (5): Bootstrap failed: 5: Input/output error")
    ) {
      try SystemLaunchd(runner: runner).bootstrap(plist: plist, userID: 501)
    }
  }
}

/// A descriptor written by one thread and closed by another, so every access takes the lock.
private final class DescriptorBox: @unchecked Sendable {
  private let lock = NSLock()
  private var descriptor: Int32 = -1

  func store(_ value: Int32) { lock.withLock { descriptor = value } }

  func closeIfOpen() {
    let open = lock.withLock { () -> Int32 in
      defer { descriptor = -1 }
      return descriptor
    }
    if open >= 0 { close(open) }
  }
}

struct SocketReadinessTests {
  private func listen(at path: String) throws -> Int32 {
    let descriptor = try UnixSocket.makeStreamSocket()
    _ = try UnixSocket.withAddress(path: path) { Darwin.bind(descriptor, $0, $1) }
    guard Darwin.listen(descriptor, 4) == 0 else { throw POSIXError(.EIO) }
    return descriptor
  }

  @Test func test_aSocketThatAccepts_isReady() throws {
    let home = try TemporaryHome()
    let socket = home.url.appendingPathComponent("s.sock")
    let listener = try listen(at: socket.path)
    defer { close(listener) }

    try SocketReadiness(interval: 0.01).waitUntilAnswering(socket: socket, within: 2)
  }

  @Test func test_aSocketThatNeverAppears_failsWithinTheTimeLimit() throws {
    let home = try TemporaryHome()
    let started = Date()

    #expect(throws: InstallError.self) {
      try SocketReadiness(interval: 0.01).waitUntilAnswering(
        socket: home.url.appendingPathComponent("none.sock"), within: 0.3)
    }

    #expect(Date().timeIntervalSince(started) < 2, "it gives up instead of hanging")
  }

  @Test func test_aSocketThatAppearsLate_isWaitedFor() throws {
    let home = try TemporaryHome()
    let socket = home.url.appendingPathComponent("late.sock")
    let listener = DescriptorBox()
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
      listener.store((try? self.listen(at: socket.path)) ?? -1)
    }
    defer { listener.closeIfOpen() }

    try SocketReadiness(interval: 0.01).waitUntilAnswering(socket: socket, within: 3)
  }
}
