import CommunicationLineService
import CommunicationLineWire
import Darwin
import Foundation
import Testing

private struct FixedPeerReader: PeerCredentialReader {
  let userID: UInt32

  func effectiveUserID(ofSocket descriptor: Int32) throws -> UInt32 { userID }
}

private func shortFolder() -> URL {
  URL(fileURLWithPath: "/tmp/cl-" + UUID().uuidString.prefix(8).lowercased(), isDirectory: true)
}

private func mode(of path: String) throws -> Int {
  var info = stat()
  guard lstat(path, &info) == 0 else { throw POSIXError(.ENOENT) }
  return Int(info.st_mode & 0o7777)
}

/// Leaves a socket file behind with nobody listening, like a service that was killed.
private func leaveStaleSocket(at path: String) throws {
  let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
  var address = sockaddr_un()
  address.sun_family = sa_family_t(AF_UNIX)
  withUnsafeMutableBytes(of: &address.sun_path) { buffer in
    for (index, byte) in path.utf8.enumerated() { buffer[index] = byte }
  }
  let bound = withUnsafePointer(to: &address) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
      bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
  }
  close(descriptor)
  guard bound == 0 else { throw POSIXError(.EADDRINUSE) }
}

struct ServiceHostTests {
  private func ask(_ host: ServiceHost, _ request: WireRequest) throws -> WireResponse {
    try SocketExchange.call(
      socketPath: host.socketPath, request: request, maximumFrame: host.frameMaximum)
  }

  @Test func test_start_createsAPrivateFolderAndAPrivateSocket() throws {
    let folder = shortFolder()
    defer { try? FileManager.default.removeItem(at: folder) }

    let host = try ServiceHost.start(storeFolder: folder)
    defer { host.stop() }

    #expect(try mode(of: folder.path) == 0o700, "the store folder is private to the owner")
    #expect(try mode(of: host.socketPath) == 0o600, "the socket file is private to the owner")
    #expect(
      host.socketPath.hasPrefix(folder.path + "/"), "the socket lives inside the store folder")
  }

  @Test func test_aRequestOverTheSocket_isAnsweredByTheDispatcher() throws {
    let folder = shortFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let host = try ServiceHost.start(storeFolder: folder)
    defer { host.stop() }

    let bootstrap = try ask(host, WireRequest(token: nil, operation: "owner.credential"))
    #expect(bootstrap.isSuccess, "the owner credential is issued over the socket")
    let bad = try ask(host, WireRequest(token: nil, operation: "no.such.op"))
    #expect(bad.failure?.code == .badRequest, "a failure comes back as a typed failure")
  }

  @Test func test_aSecondInstanceOnTheSameStore_isRefused() throws {
    let folder = shortFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let first = try ServiceHost.start(storeFolder: folder)

    #expect(throws: ServiceHostError.alreadyRunning) {
      _ = try ServiceHost.start(storeFolder: folder)
    }
    #expect(
      try ask(first, WireRequest(token: nil, operation: "no.such.op")).failure?.code == .badRequest,
      "the first instance is not disturbed")

    first.stop()
    let again = try ServiceHost.start(storeFolder: folder)
    again.stop()
  }

  @Test func test_aStaleSocketOfADeadInstance_isReplaced() throws {
    let folder = shortFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    try FileManager.default.createDirectory(
      at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let stalePath = folder.appendingPathComponent(ServiceHost.socketName).path
    try leaveStaleSocket(at: stalePath)

    let host = try ServiceHost.start(storeFolder: folder)
    defer { host.stop() }

    let response = try ask(host, WireRequest(token: nil, operation: "no.such.op"))
    #expect(response.failure?.code == .badRequest, "the new instance serves on the old path")
  }

  @Test func test_aSocketOfAnotherUser_isNotReplaced() throws {
    let folder = shortFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let first = try ServiceHost.start(storeFolder: folder)
    let path = first.socketPath
    first.stop()
    try leaveStaleSocket(at: path)
    let someoneElse = UInt32(geteuid()) + 1

    #expect(
      throws: ServiceHostError.unexpectedFileAtSocketPath(path),
      "a socket the service's user does not own is left alone"
    ) {
      _ = try ServiceHost.start(storeFolder: folder, userID: someoneElse)
    }
    #expect(FileManager.default.fileExists(atPath: path), "the foreign socket file is still there")
  }

  @Test func test_aPeerWithAnotherUserID_isNotServed() throws {
    let folder = shortFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let host = try ServiceHost.start(
      storeFolder: folder, peerReader: FixedPeerReader(userID: geteuid() &+ 1))
    defer { host.stop() }

    #expect(throws: (any Error).self, "the connection is closed without an answer") {
      _ = try ask(host, WireRequest(token: nil, operation: "owner.credential"))
    }
    let owner = try ServiceHost.start(
      storeFolder: shortFolder(), peerReader: FixedPeerReader(userID: geteuid()))
    defer { owner.stop() }
    #expect(
      try ask(owner, WireRequest(token: nil, operation: "no.such.op")).failure?.code == .badRequest,
      "a peer with the service's own user ID is served")
  }

  @Test func test_oneRequestPerConnection_thenTheConnectionIsClosed() throws {
    let folder = shortFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let host = try ServiceHost.start(storeFolder: folder)
    defer { host.stop() }
    let stream = try UnixSocketClient.connect(path: host.socketPath)
    let codec = FrameCodec(maximumSize: host.frameMaximum)
    let request = try WireCoding.encode(WireRequest(token: nil, operation: "no.such.op"))

    try codec.writeFrame(request, to: stream)
    _ = try codec.readFrame(from: stream)

    #expect(try codec.readFrame(from: stream) == nil, "the service closes after its answer")
  }

  @Test func test_anOversizedFrame_isAnsweredWithATypedFailure() throws {
    let folder = shortFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let host = try ServiceHost.start(storeFolder: folder)
    defer { host.stop() }
    let stream = try UnixSocketClient.connect(path: host.socketPath)

    try stream.write(Data([0x7F, 0xFF, 0xFF, 0xFF]))
    let answer = try FrameCodec(maximumSize: host.frameMaximum).readFrame(from: stream)

    let response = try WireCoding.decodeResponse(try #require(answer))
    #expect(response.failure?.code == .frameTooLarge, "the oversized frame is refused by name")
  }

  @Test func test_aFrameThatIsNotARequest_isABadRequest() throws {
    let folder = shortFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let host = try ServiceHost.start(storeFolder: folder)
    defer { host.stop() }
    let stream = try UnixSocketClient.connect(path: host.socketPath)
    let codec = FrameCodec(maximumSize: host.frameMaximum)

    try codec.writeFrame(Data("not json".utf8), to: stream)
    let answer = try codec.readFrame(from: stream)

    let response = try WireCoding.decodeResponse(try #require(answer))
    #expect(response.failure?.code == .badRequest, "garbage is a bad request")
  }

  @Test func test_aClientThatSendsNothing_isDroppedAfterTheRequestTimeout() throws {
    let folder = shortFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let host = try ServiceHost.start(storeFolder: folder, requestTimeout: 0.5)
    defer { host.stop() }
    let stream = try UnixSocketClient.connect(path: host.socketPath)
    let started = Date()

    let answer = try FrameCodec(maximumSize: host.frameMaximum).readFrame(from: stream)

    #expect(answer == nil, "the service closed the silent connection")
    #expect(Date().timeIntervalSince(started) < 5, "it did so after the timeout, not never")
  }

  @Test func test_stop_removesTheSocketAndEndsAParkedWait() throws {
    let folder = shortFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let host = try ServiceHost.start(storeFolder: folder)
    let owner = try ask(host, WireRequest(token: nil, operation: "owner.credential"))
    let ownerToken = try #require(
      { () -> String? in
        guard case .object(let fields)? = owner.result, case .string(let token)? = fields["token"]
        else { return nil }
        return token
      }())
    let path = host.socketPath

    host.stop()

    #expect(!FileManager.default.fileExists(atPath: path), "the socket file is removed")
    #expect(throws: (any Error).self, "nobody answers any more") {
      _ = try SocketExchange.call(
        socketPath: path, request: WireRequest(token: ownerToken, operation: "rule.list"),
        maximumFrame: 4096)
    }
  }

  @Test func test_stop_closesTheDatabaseAndFoldsItsLog() throws {
    let folder = shortFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let host = try ServiceHost.start(storeFolder: folder)
    _ = try ask(host, WireRequest(token: nil, operation: "owner.credential"))
    let log = folder.appendingPathComponent(ServiceRuntime.databaseName + "-wal").path
    let before = (try? FileManager.default.attributesOfItem(atPath: log)[.size] as? Int) ?? 0
    #expect(before > 0, "the running service has records in its write-ahead log")

    host.stop()

    let after = (try? FileManager.default.attributesOfItem(atPath: log)[.size] as? Int) ?? 0
    #expect(after == 0, "stopping closes the database, which empties the log")
  }

  @Test func test_waitUntilStopped_returnsOnlyAfterTheStopHasFinished() throws {
    let folder = shortFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let host = try ServiceHost.start(storeFolder: folder)
    let log = folder.appendingPathComponent(ServiceRuntime.databaseName + "-wal").path
    _ = try ask(host, WireRequest(token: nil, operation: "owner.credential"))
    Thread.detachNewThread {
      Thread.sleep(forTimeInterval: 0.2)
      host.stop()
    }

    host.waitUntilStopped()

    let size = (try? FileManager.default.attributesOfItem(atPath: log)[.size] as? Int) ?? 0
    #expect(size == 0, "the database is already closed when the wait returns")
    #expect(throws: Never.self, "the instance lock is already released when the wait returns") {
      try ServiceHost.start(storeFolder: folder).stop()
    }
  }

  @Test func test_stop_answersAParkedWaitInsteadOfDroppingIt() throws {
    let folder = shortFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let host = try ServiceHost.start(storeFolder: folder)
    let owner = try tokenOf(try ask(host, WireRequest(token: nil, operation: "owner.credential")))
    let created = try ask(
      host,
      WireRequest(
        token: owner, operation: "principal.create",
        arguments: ["family": .string("f"), "role": .string("agent"), "name": .string("a")]))
    guard case .object(let fields)? = created.result, case .string(let id)? = fields["id"] else {
      Issue.record("principal.create gave no id")
      return
    }
    let agent = try tokenOf(
      try ask(
        host,
        WireRequest(
          token: owner, operation: "credential.issue", arguments: ["principal": .string(id)])
      ))
    let outcome = Box<Result<WireResponse, any Error>?>(nil)
    let done = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
      outcome.value = Result {
        try SocketExchange.call(
          socketPath: host.socketPath,
          request: WireRequest(
            token: agent, operation: "wait", arguments: ["timeout": .integer(30)]),
          maximumFrame: host.frameMaximum)
      }
      done.signal()
    }
    Thread.sleep(forTimeInterval: 0.5)

    let started = Date()
    host.stop()

    #expect(Date().timeIntervalSince(started) < 1.5, "stopping does not sit out the grace period")
    #expect(done.wait(timeout: .now() + 5) == .success, "the parked client got an answer")
    #expect(
      (try? outcome.value?.get())?.isSuccess == true,
      "the parked client was answered, not cut off")
  }

  private func tokenOf(_ response: WireResponse) throws -> String {
    guard case .object(let fields)? = response.result, case .string(let token)? = fields["token"]
    else { throw POSIXError(.EINVAL) }
    return token
  }
}

private final class Box<Value>: @unchecked Sendable {
  var value: Value
  init(_ value: Value) { self.value = value }
}

struct ScheduledCleanupTests {
  private func ask(
    _ host: ServiceHost, _ operation: String, token: String? = nil,
    _ arguments: [String: WireValue] = [:]
  ) throws -> WireResponse {
    try SocketExchange.call(
      socketPath: host.socketPath,
      request: WireRequest(token: token, operation: operation, arguments: arguments),
      maximumFrame: host.frameMaximum)
  }

  private func token(_ response: WireResponse) throws -> String {
    guard case .object(let fields)? = response.result, case .string(let value)? = fields["token"]
    else { throw POSIXError(.EIO) }
    return value
  }

  private func id(_ response: WireResponse) throws -> String {
    guard case .object(let fields)? = response.result, case .string(let value)? = fields["id"]
    else { throw POSIXError(.EIO) }
    return value
  }

  /// Polls the store from outside until `table` has `expected` rows, for at most three seconds.
  private func waitForCount(_ table: String, _ expected: Int, in folder: URL) throws -> Int {
    let raw = try RawFile(folder: folder)
    var seen = try raw.count(table)
    let deadline = Date().addingTimeInterval(3)
    while seen != expected && Date() < deadline {
      Thread.sleep(forTimeInterval: 0.05)
      seen = try raw.count(table)
    }
    return seen
  }

  /// Sends one message from alice to bob and has bob acknowledge it, over the socket.
  private func acknowledgedMail(_ host: ServiceHost) throws {
    let owner = try token(try ask(host, "owner.credential"))
    let alice = try ask(
      host, "principal.create", token: owner,
      ["family": .string("A"), "role": .string("agent"), "name": .string("alice")])
    let bob = try ask(
      host, "principal.create", token: owner,
      ["family": .string("A"), "role": .string("agent"), "name": .string("bob")])
    let aliceToken = try token(
      try ask(host, "credential.issue", token: owner, ["principal": .string(try id(alice))]))
    let bobToken = try token(
      try ask(host, "credential.issue", token: owner, ["principal": .string(try id(bob))]))
    let sent = try ask(
      host, "send", token: aliceToken,
      ["to": .array([.string(try id(bob))]), "subject": .string("s"), "body": .string("b")])
    _ = try ask(host, "acknowledge", token: bobToken, ["id": .string(try id(sent))])
  }

  @Test func test_theService_runsCleanupOnItsOwnInterval() throws {
    let folder = shortFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let clock = TestClock()
    let host = try ServiceHost.start(storeFolder: folder, clock: clock, cleanupInterval: 0.05)
    defer { host.stop() }
    try acknowledgedMail(host)
    #expect(
      try waitForCount("messages", 0, in: folder) == 1, "inside the window nothing is deleted")

    clock.advance(days: 91)

    #expect(
      try waitForCount("messages", 0, in: folder) == 0,
      "the service deleted the mail by itself once it was past its retention")
  }

  @Test func test_cleanup_doesNotRunBecauseAConnectionCameAndWent() throws {
    let folder = shortFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let clock = TestClock()
    let host = try ServiceHost.start(storeFolder: folder, clock: clock, cleanupInterval: 60)
    defer { host.stop() }
    try acknowledgedMail(host)
    clock.advance(days: 91)

    for _ in 0..<5 { _ = try ask(host, "no.such.op") }
    Thread.sleep(forTimeInterval: 0.5)

    #expect(
      try RawFile(folder: folder).count("messages") == 1,
      "cleanup waits for its interval, whatever else the service is doing")
  }
}

struct ConnectionLimitTests {
  private func ownerCredentialSucceeds(_ host: ServiceHost) -> Bool {
    (try? SocketExchange.call(
      socketPath: host.socketPath, request: WireRequest(token: nil, operation: "owner.credential"),
      maximumFrame: host.frameMaximum))?.isSuccess == true
  }

  @Test func test_aConnectionPastTheLimit_isAnsweredAtOnce_andAFreedPlaceIsUsable() throws {
    let folder = shortFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let host = try ServiceHost.start(storeFolder: folder, requestTimeout: 5, connectionLimit: 2)
    defer { host.stop() }
    let first = try UnixSocketClient.connect(path: host.socketPath)
    let second = try UnixSocketClient.connect(path: host.socketPath)
    let started = Date()

    let answer = try SocketExchange.call(
      socketPath: host.socketPath, request: WireRequest(token: nil, operation: "owner.credential"),
      maximumFrame: host.frameMaximum)

    #expect(
      answer.failure?.code == .tooManyConnections, "the service said why it would not take it")
    #expect(Date().timeIntervalSince(started) < 2, "it refused at once, not after the timeout")
    first.close()
    let deadline = Date().addingTimeInterval(3)
    var served = ownerCredentialSucceeds(host)
    while !served && Date() < deadline {
      Thread.sleep(forTimeInterval: 0.05)
      served = ownerCredentialSucceeds(host)
    }
    #expect(served, "a place that was freed serves the next request")
    second.close()
  }

  @Test func test_aTricklingClient_isClosedAtTheRequestDeadline() throws {
    let folder = shortFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let host = try ServiceHost.start(storeFolder: folder, requestTimeout: 5, requestDeadline: 0.4)
    defer { host.stop() }
    let stream = try UnixSocketClient.connect(path: host.socketPath)
    try stream.write(Data([0, 0, 3, 0xE8]))
    let started = Date()
    var closed = false

    // One byte every tenth of a second keeps every single read inside the per-read timeout.
    for _ in 0..<40 where !closed {
      Thread.sleep(forTimeInterval: 0.1)
      do { try stream.write(Data([0x20])) } catch { closed = true }
    }

    #expect(closed, "the service closed the connection that never finished its request")
    #expect(Date().timeIntervalSince(started) < 3, "it did so near the deadline")
  }

  @Test func test_aRequestThatArrivesInTime_isAnswered_evenWhenItsAnswerComesAfterTheDeadline()
    throws
  {
    let folder = shortFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let host = try ServiceHost.start(storeFolder: folder, requestDeadline: 0.4)
    defer { host.stop() }
    func call(_ operation: String, token: String? = nil, _ arguments: [String: WireValue] = [:])
      throws -> WireResponse
    {
      try SocketExchange.call(
        socketPath: host.socketPath,
        request: WireRequest(token: token, operation: operation, arguments: arguments),
        maximumFrame: host.frameMaximum)
    }
    func field(_ response: WireResponse, _ key: String) throws -> String {
      guard case .object(let fields)? = response.result, case .string(let value)? = fields[key]
      else { throw POSIXError(.EIO) }
      return value
    }
    let owner = try field(try call("owner.credential"), "token")
    let agent = try field(
      try call(
        "principal.create", token: owner,
        ["family": .string("A"), "role": .string("agent"), "name": .string("alice")]), "id")
    let token = try field(
      try call("credential.issue", token: owner, ["principal": .string(agent)]), "token")

    // The wait has been read in full long before the deadline and answers well after it.
    let answer = try call("wait", token: token, ["timeout": .integer(1)])

    #expect(answer.isSuccess, "the deadline covers the sending of a request, not its answer")
  }
}

struct ParkedWaitDisconnectTests {
  private func ask(
    _ host: ServiceHost, _ operation: String, token: String? = nil,
    _ arguments: [String: WireValue] = [:]
  ) throws -> WireResponse {
    try SocketExchange.call(
      socketPath: host.socketPath,
      request: WireRequest(token: token, operation: operation, arguments: arguments),
      maximumFrame: host.frameMaximum)
  }

  private func field(_ name: String, of response: WireResponse) throws -> String {
    guard case .object(let fields)? = response.result, case .string(let value)? = fields[name]
    else { throw POSIXError(.EIO) }
    return value
  }

  private func agent(on host: ServiceHost, owner: String, name: String) throws -> String {
    let created = try ask(
      host, "principal.create", token: owner,
      ["family": .string("f"), "role": .string("agent"), "name": .string(name)])
    return try field(
      "token",
      of: try ask(
        host, "credential.issue", token: owner,
        ["principal": .string(try field("id", of: created))]))
  }

  /// Sends a wait over a raw connection and returns the connection, without reading the answer.
  private func park(_ host: ServiceHost, token: String) throws -> FileDescriptorStream {
    let client = try UnixSocketClient.connect(path: host.socketPath)
    let request = WireRequest(
      token: token, operation: "wait", arguments: ["timeout": .integer(30)])
    try FrameCodec(maximumSize: host.frameMaximum).writeFrame(
      try WireCoding.encode(request), to: client)
    Thread.sleep(forTimeInterval: 0.4)
    return client
  }

  @Test func test_aParkedWait_endsWhenItsClientDisconnects_andFreesItsConnectionPlace() throws {
    let folder = shortFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let host = try ServiceHost.start(storeFolder: folder, requestTimeout: 30, connectionLimit: 2)
    defer { host.stop() }
    let owner = try field("token", of: try ask(host, "owner.credential"))
    let waiter = try agent(on: host, owner: owner, name: "a")
    let parked = try park(host, token: waiter)
    // The second place is taken by a connection that stays silent, so the next request can only
    // be served once the parked wait has let go of its place.
    let filler = try UnixSocketClient.connect(path: host.socketPath)
    defer { filler.close() }
    parked.close()
    let started = Date()

    var listed: WireResponse?
    while listed?.isSuccess != true && Date().timeIntervalSince(started) < 3 {
      listed = try? ask(host, "activity.list", token: owner)
      if listed?.isSuccess != true { Thread.sleep(forTimeInterval: 0.05) }
    }

    #expect(listed?.isSuccess == true, "the wait ended and gave its connection place back")
    let listing = String(describing: listed?.result)
    #expect(listing.contains("wait"), "the wait was recorded")
  }

  @Test func test_aParkedWait_whoseClientDisconnected_freesItsWaiterSlot() throws {
    let folder = shortFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let host = try ServiceHost.start(storeFolder: folder, requestTimeout: 30)
    defer { host.stop() }
    let owner = try field("token", of: try ask(host, "owner.credential"))
    for key in ["limits.waits.principal", "limits.waits.global"] {
      _ = try ask(
        host, "setting.set", token: owner, ["key": .string(key), "value": .integer(1)])
    }
    let waiter = try agent(on: host, owner: owner, name: "a")
    let parked = try park(host, token: waiter)
    parked.close()
    let started = Date()

    var outcome = "refused"
    while outcome != "timeout" && Date().timeIntervalSince(started) < 3 {
      let answer = try ask(host, "wait", token: waiter, ["timeout": .integer(1)])
      outcome = (try? field("outcome", of: answer)) ?? "refused"
      if outcome != "timeout" { Thread.sleep(forTimeInterval: 0.05) }
    }

    #expect(outcome == "timeout", "the same agent can wait again: the dead wait gave up its slot")
  }
}
