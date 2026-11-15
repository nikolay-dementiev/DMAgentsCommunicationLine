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

/// A listener that behaves as a script says for each request: it answers, stays silent or sends
/// bytes that are not a response.
private final class ScriptedResponder: @unchecked Sendable {
  enum Behavior {
    case answer, silent, garbage
    /// Silent, and keeps its stream until the semaphore is signalled after the connection ends.
    case silentUntil(DispatchSemaphore)
  }

  private let lock = NSLock()
  private var listener: Int32
  private var held: [Int32] = []
  private let serving = DispatchGroup()
  private let behavior: @Sendable (String) -> Behavior

  init(path: String, behavior: @escaping @Sendable (String) -> Behavior) throws {
    self.behavior = behavior
    listener = try UnixSocket.makeStreamSocket()
    _ = try UnixSocket.withAddress(path: path) { Darwin.bind(listener, $0, $1) }
    guard Darwin.listen(listener, 8) == 0 else { throw POSIXError(.EIO) }
    let descriptor = listener
    Thread.detachNewThread { [self] in
      // The accept loop owns the listener and closes it once, when `stop()` has shut it down.
      defer { close(descriptor) }
      while true {
        let connection = accept(descriptor, nil, nil)
        if connection < 0 { return }
        lock.withLock { held.append(connection) }
        serving.enter()
        Thread.detachNewThread { [self] in
          serve(connection)
          serving.leave()
        }
      }
    }
  }

  /// Returns once every connection that was accepted has been served and its descriptor closed.
  func waitUntilIdle() { serving.wait() }

  func stop() {
    // Under the lock, so that a connection is never shut down after the stream that serves it has
    // given its number back.
    lock.withLock {
      for descriptor in held + [listener] { shutdown(descriptor, SHUT_RDWR) }
      held = []
    }
    // Only shut down: every connection is closed by the stream that serves it, and the listener by
    // its accept loop. Closing a number here as well would close it twice, and the second close
    // could hit an unrelated descriptor that reused the number in another test.
  }

  private func serve(_ connection: Int32) {
    let stream = FileDescriptorStream(descriptor: connection)
    defer { lock.withLock { held.removeAll { $0 == connection } } }
    let codec = FrameCodec(maximumSize: 65_536)
    guard let payload = try? codec.readFrame(from: stream),
      let request = try? WireCoding.decodeRequest(payload)
    else { return }
    switch behavior(request.operation) {
    case .answer:
      let response = WireResponse.failure(code: .tokenRequired, message: "a token is required")
      if let data = try? WireCoding.encode(response) { try? codec.writeFrame(data, to: stream) }
    case .garbage:
      try? codec.writeFrame(Data("not a response".utf8), to: stream)
    case .silent:
      // Say nothing until the connection is shut down, by the client or by `stop()`.
      _ = try? codec.readFrame(from: stream)
    case .silentUntil(let release):
      _ = try? codec.readFrame(from: stream)
      release.wait()
    }
  }
}

struct ScriptedResponderTests {
  @Test func test_stopping_closesEachDescriptorOnce_soNoOtherDescriptorIsClosedWithIt() throws {
    let home = try TemporaryHome()
    let path = home.url.appendingPathComponent("once.sock").path
    let release = DispatchSemaphore(value: 0)
    let responder = try ScriptedResponder(path: path) { _ in .silentUntil(release) }
    // The request is read and the responder goes quiet; the client gives up after its deadline.
    _ = try? SocketServiceConnection(socketPath: path).exchange(
      WireRequest(token: nil, operation: "health"), deadline: Date().addingTimeInterval(0.3))
    responder.stop()
    // Descriptors opened now take the lowest free numbers, which are the ones just given back.
    let others = (0..<8).map { _ in open("/dev/null", O_RDONLY) }
    defer { others.filter { $0 >= 0 }.forEach { close($0) } }

    // Only now may the serving stream let go of its descriptor.
    release.signal()
    responder.waitUntilIdle()

    for descriptor in others {
      #expect(
        descriptor >= 0 && fcntl(descriptor, F_GETFD) != -1,
        "descriptor \(descriptor) is still open: the responder closed only its own")
    }
  }
}

struct SocketReadinessTests {
  private func respond(at path: String, _ behavior: ScriptedResponder.Behavior) throws
    -> ScriptedResponder
  {
    try ScriptedResponder(path: path) { _ in behavior }
  }

  @Test func test_aSocketThatAnswersARequest_isReady() throws {
    let home = try TemporaryHome()
    let socket = home.url.appendingPathComponent("s.sock")
    let responder = try respond(at: socket.path, .answer)
    defer { responder.stop() }

    try SocketReadiness(interval: 0.01).waitUntilAnswering(socket: socket, within: 60)
  }

  @Test func test_aSocketThatAcceptsButNeverAnswers_isNotReady() throws {
    let home = try TemporaryHome()
    let socket = home.url.appendingPathComponent("silent.sock")
    let responder = try respond(at: socket.path, .silent)
    defer { responder.stop() }
    let started = Date()

    #expect(throws: InstallError.self, "a listener that says nothing is not a service") {
      try SocketReadiness(interval: 0.01).waitUntilAnswering(socket: socket, within: 0.5)
    }

    #expect(Date().timeIntervalSince(started) < 60, "it gives up at the deadline")
  }

  @Test func test_aSocketThatAnswersWithSomethingElse_isNotReady() throws {
    let home = try TemporaryHome()
    let socket = home.url.appendingPathComponent("garbage.sock")
    let responder = try respond(at: socket.path, .garbage)
    defer { responder.stop() }

    #expect(throws: InstallError.self, "bytes that are not a response are not a service") {
      try SocketReadiness(interval: 0.01).waitUntilAnswering(socket: socket, within: 0.5)
    }
  }

  @Test func test_aSocketThatNeverAppears_failsWithinTheTimeLimit() throws {
    let home = try TemporaryHome()
    let started = Date()

    #expect(throws: InstallError.self) {
      try SocketReadiness(interval: 0.01).waitUntilAnswering(
        socket: home.url.appendingPathComponent("none.sock"), within: 0.3)
    }

    #expect(Date().timeIntervalSince(started) < 60, "it gives up instead of hanging")
  }

  @Test func test_aSocketThatAppearsLate_isWaitedFor() throws {
    let home = try TemporaryHome()
    let socket = home.url.appendingPathComponent("late.sock")
    let responder = ResponderBox()
    let attempts = AttemptCounter()
    defer { responder.stop() }
    // The listener appears only once the third attempt has found nothing there: the test depends
    // on what the readiness check has seen, not on how fast a timer or a thread runs. The long
    // limit only keeps a broken check from hanging the test.
    let readiness = SocketReadiness(interval: 0.01) { path in
      if attempts.next() == 3 {
        responder.store(try? ScriptedResponder(path: socket.path) { _ in .answer })
      }
      return SocketServiceConnection(socketPath: path)
    }

    try readiness.waitUntilAnswering(socket: socket, within: 120)

    #expect(attempts.count >= 3, "the check kept trying while the socket was missing")
  }

  @Test func test_anOwnerRequestThatNeverGetsAnAnswer_failsAtTheSharedDeadline() throws {
    let home = try TemporaryHome()
    let executables = try TemporaryHome()
    let layout = HostLayout(home: home.url)
    for name in ["commline", "commline-service"] {
      FileManager.default.createFile(
        atPath: executables.url.appendingPathComponent(name).path, contents: Data(name.utf8))
    }
    try FileManager.default.createDirectory(
      at: layout.storeFolder, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    // The service answers the probe and then goes quiet on the credential request.
    let responder = try ScriptedResponder(path: layout.socketURL.path) {
      $0 == "owner.credential" ? .silent : .answer
    }
    defer { responder.stop() }
    nonisolated(unsafe) let installer = Installer(
      layout: layout, executableFolder: executables.url, userID: 501, launchd: RecordingLaunchd(),
      readiness: SocketReadiness(interval: 0.01),
      connect: { SocketServiceConnection(socketPath: $0) }, readinessSeconds: 1)
    let outcome = ResultBox()
    let done = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
      outcome.store(Result { _ = try installer.install() })
      done.signal()
    }

    let finished = done.wait(timeout: .now() + 5) == .success

    #expect(finished, "the install did not hang on a service that stopped answering")
    if finished {
      #expect(throws: InstallError.self, "it reports that the service is not ready") {
        try outcome.value?.get()
      }
    }
  }
}

private final class ResponderBox: @unchecked Sendable {
  private let lock = NSLock()
  private var responder: ScriptedResponder?

  func store(_ value: ScriptedResponder?) { lock.withLock { responder = value } }

  func stop() { lock.withLock { responder }?.stop() }
}

private final class AttemptCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var attempts = 0

  var count: Int { lock.withLock { attempts } }

  func next() -> Int { lock.withLock { attempts += 1; return attempts } }
}

private final class ResultBox: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: Result<Void, any Error>?

  var value: Result<Void, any Error>? { lock.withLock { stored } }

  func store(_ result: Result<Void, any Error>) { lock.withLock { stored = result } }
}
