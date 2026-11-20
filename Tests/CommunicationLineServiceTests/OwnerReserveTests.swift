import CommunicationLineService
import CommunicationLineWire
import Foundation
import Testing

private func shortFolder() -> URL {
  URL(fileURLWithPath: "/tmp/cl-" + UUID().uuidString.prefix(8).lowercased(), isDirectory: true)
}

struct OwnerReserveTests {
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

  /// A new agent: its principal id and its token.
  private func agent(on host: ServiceHost, owner: String, name: String) throws -> (
    id: String, token: String
  ) {
    let created = try ask(
      host, "principal.create", token: owner,
      ["family": .string("f"), "role": .string("agent"), "name": .string(name)])
    let id = try field("id", of: created)
    let issued = try ask(host, "credential.issue", token: owner, ["principal": .string(id)])
    return (id, try field("token", of: issued))
  }

  /// Sends a wait over a raw connection and returns the connection, without reading the answer.
  private func park(_ host: ServiceHost, token: String) throws -> FileDescriptorStream {
    let client = try UnixSocketClient.connect(path: host.socketPath)
    let request = WireRequest(
      token: token, operation: "wait", arguments: ["timeout": .integer(30)])
    try FrameCodec(maximumSize: host.frameMaximum).writeFrame(
      try WireCoding.encode(request), to: client)
    return client
  }

  @Test func test_agentsParkedUpToTheUnreservedSlots_leaveTheOwnerAnswered() throws {
    let folder = shortFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let host = try ServiceHost.start(
      storeFolder: folder, requestTimeout: 30, connectionLimit: 4, ownerReserve: 2)
    defer { host.stop() }
    let owner = try field("token", of: try ask(host, "owner.credential"))
    let first = try agent(on: host, owner: owner, name: "a")
    let second = try agent(on: host, owner: owner, name: "b")
    let third = try agent(on: host, owner: owner, name: "c")
    let fourth = try agent(on: host, owner: owner, name: "d")
    // Every agent tries to park; only the unreserved slots can be taken.
    let parked = try [first, second, third, fourth].map { try park(host, token: $0.token) }
    defer { parked.forEach { $0.close() } }
    #expect(
      host.waitUntilParked(ownerToken: owner, count: 2), "the two unreserved slots hold a wait")

    let refused = try ask(host, "wait", token: first.token, ["timeout": .integer(1)])
    let health = try ask(host, "health", token: owner)

    #expect(
      refused.failure?.code == .tooManyConnections,
      "an agent past the unreserved slots is refused with its own error")
    #expect(health.isSuccess, "the owner still gets in while agents hold every other slot")
  }

  @Test func test_idleConnectionsHoldingEveryOtherPlace_doNotKeepTheOwnerOut() throws {
    let folder = shortFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    // The request deadline is long: the idle sockets stay for the whole test.
    let host = try ServiceHost.start(
      storeFolder: folder, requestTimeout: 120, connectionLimit: 4, ownerReserve: 2,
      requestDeadline: 120)
    defer { host.stop() }
    let owner = try field("token", of: try ask(host, "owner.credential"))
    // Sockets that never send a request, more than the limit allows.
    let idle = try (0..<6).map { _ in try UnixSocketClient.connect(path: host.socketPath) }
    defer { idle.forEach { $0.close() } }

    let health = try SocketExchange.call(
      socketPath: host.socketPath, request: WireRequest(token: owner, operation: "health"),
      maximumFrame: host.frameMaximum, deadline: Date().addingTimeInterval(60))

    #expect(health.isSuccess, "the owner's first request is served while a reserve place is free")
  }

  @Test func test_anAgentRequestOnAReserveConnection_isRefusedAtOnce() throws {
    let folder = shortFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let host = try ServiceHost.start(
      storeFolder: folder, requestTimeout: 120, connectionLimit: 4, ownerReserve: 2,
      requestDeadline: 120)
    defer { host.stop() }
    let owner = try field("token", of: try ask(host, "owner.credential"))
    let agent = try agent(on: host, owner: owner, name: "a")
    let idle = try (0..<4).map { _ in try UnixSocketClient.connect(path: host.socketPath) }
    defer { idle.forEach { $0.close() } }

    let refused = try SocketExchange.call(
      socketPath: host.socketPath,
      request: WireRequest(
        token: agent.token, operation: "wait", arguments: ["timeout": .integer(1)]),
      maximumFrame: host.frameMaximum, deadline: Date().addingTimeInterval(60))

    #expect(
      refused.failure?.code == .tooManyConnections,
      "an agent never takes a place kept for the owner")
  }

  @Test func test_aClientThatNeverReadsItsResponse_isCutOffAtTheDeadline() throws {
    let folder = shortFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    // The per-read timeout is long, so only a deadline over the whole write can cut the client.
    let host = try ServiceHost.start(
      storeFolder: folder, requestTimeout: 30, requestDeadline: 0.5)
    defer { host.stop() }
    let owner = try field("token", of: try ask(host, "owner.credential"))
    let sender = try agent(on: host, owner: owner, name: "sender")
    let reader = try agent(on: host, owner: owner, name: "reader")
    let body = String(repeating: "b", count: 200_000)
    let sent = try ask(
      host, "send", token: sender.token,
      [
        "to": .array([.string(reader.id)]), "subject": .string("big"), "body": .string(body),
      ])
    let messageID = try field("id", of: sent)

    let client = try UnixSocketClient.connect(path: host.socketPath)
    defer { client.close() }
    let request = WireRequest(
      token: reader.token, operation: "read", arguments: ["id": .string(messageID)])
    try FrameCodec(maximumSize: host.frameMaximum).writeFrame(
      try WireCoding.encode(request), to: client)
    Thread.sleep(forTimeInterval: 1.5)

    var received = 0
    while true {
      let chunk = (try? client.read(upTo: 65536)) ?? Data()
      if chunk.isEmpty { break }
      received += chunk.count
    }

    #expect(
      received < 100_000,
      "the service stopped writing at the deadline; the client got \(received) bytes of 200000+")
  }
}
