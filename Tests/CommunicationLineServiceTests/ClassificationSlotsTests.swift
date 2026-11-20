import CommunicationLineService
import CommunicationLineWire
import Foundation
import Testing

private func shortFolder() -> URL {
  URL(fileURLWithPath: "/tmp/cl-" + UUID().uuidString.prefix(8).lowercased(), isDirectory: true)
}

struct ClassificationSlotsTests {
  private func ownerToken(of host: ServiceHost) throws -> String {
    let response = try SocketExchange.call(
      socketPath: host.socketPath, request: WireRequest(token: nil, operation: "owner.credential"),
      maximumFrame: host.frameMaximum)
    guard case .object(let fields)? = response.result, case .string(let token)? = fields["token"]
    else { throw POSIXError(.EIO) }
    return token
  }

  private func askHealth(_ host: ServiceHost, token: String, within seconds: TimeInterval) -> Bool {
    let answer = try? SocketExchange.call(
      socketPath: host.socketPath, request: WireRequest(token: token, operation: "health"),
      maximumFrame: host.frameMaximum, deadline: Date().addingTimeInterval(seconds))
    return answer?.isSuccess ?? false
  }

  @Test func test_aProcessThatKeepsConnectingAndSendsNothing_doesNotKeepTheOwnerOut() throws {
    let folder = shortFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let host = try ServiceHost.start(
      storeFolder: folder, requestTimeout: 120, connectionLimit: 4, ownerReserve: 2,
      requestDeadline: 120)
    defer { host.stop() }
    let owner = try ownerToken(of: host)

    var answered = 0
    for _ in 0..<5 {
      // Far more silent connections than the limit and the classification places together.
      let silent = try (0..<40).map { _ in try UnixSocketClient.connect(path: host.socketPath) }
      if askHealth(host, token: owner, within: 10) { answered += 1 }
      silent.forEach { $0.close() }
    }

    #expect(
      answered == 5,
      "the owner was answered in \(answered) of 5 rounds in which silent connections filled every place"
    )
  }

  @Test func test_aConnectionThatSendsNothingPastTheLimit_isClosedAtTheClassificationDeadline()
    throws
  {
    let folder = shortFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let host = try ServiceHost.start(
      storeFolder: folder, requestTimeout: 120, connectionLimit: 2, ownerReserve: 1,
      requestDeadline: 120)
    defer { host.stop() }
    // The first silent connection takes the one agent place; the second is only being classified.
    let holder = try UnixSocketClient.connect(path: host.socketPath)
    defer { holder.close() }
    let waiting = try UnixSocketClient.connect(
      path: host.socketPath, deadline: Date().addingTimeInterval(20))
    defer { waiting.close() }

    let started = Date()
    let read = try? waiting.read(upTo: 1)
    let elapsed = Date().timeIntervalSince(started)

    #expect(read?.isEmpty == true, "the service closed the connection that had sent nothing")
    #expect(elapsed < 10, "it was closed after \(elapsed) s, not at the 120 s request deadline")
  }

  @Test func test_whenTheClassificationPlacesAreFull_theOldestSilentConnectionIsTheOneClosed()
    throws
  {
    let folder = shortFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    // The deadlines are long: only the eviction can close a connection during the test.
    let host = try ServiceHost.start(
      storeFolder: folder, requestTimeout: 120, connectionLimit: 2, ownerReserve: 1,
      requestDeadline: 120, classificationDeadline: 120)
    defer { host.stop() }
    // The first silent connection takes the one agent place; the rest are only being classified.
    let holder = try UnixSocketClient.connect(path: host.socketPath)
    defer { holder.close() }
    // The listen queue is first in, first out, so the service takes these up in this order: sixteen
    // fill the classification places, the seventeenth finds them full.
    let silent = try (0..<17).map { _ in try UnixSocketClient.connect(path: host.socketPath) }
    defer { silent.forEach { $0.close() } }

    var watched = silent.map { pollfd(fd: $0.descriptor, events: Int16(POLLIN), revents: 0) }
    let ready = poll(&watched, nfds_t(watched.count), 10_000)
    let closed = watched.indices.filter { watched[$0].revents != 0 }

    #expect(ready > 0, "the service closed a connection to make room")
    #expect(closed == [0], "only the connection that waited longest was closed: \(closed)")
  }
}
