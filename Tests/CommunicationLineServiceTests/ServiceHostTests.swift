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
}
