import CommunicationLineService
import CommunicationLineWire
import Foundation
import Testing

private func shortFolder() -> URL {
  URL(fileURLWithPath: "/tmp/cl-" + UUID().uuidString.prefix(8).lowercased(), isDirectory: true)
}

/// Where a waiting thread leaves its answer.
private final class Answer: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: WireResponse?
  let finished = DispatchSemaphore(value: 0)

  var response: WireResponse? { lock.withLock { stored } }

  func deliver(_ response: WireResponse?) {
    lock.withLock { stored = response }
    finished.signal()
  }
}

struct ParkedWaitReauthenticationTests {
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

  private struct Setup {
    let host: ServiceHost
    let owner: String
    let agentID: String
    let token: String
  }

  /// A service whose waits recheck every second, with one agent.
  private func makeSetup(folder: URL) throws -> Setup {
    let host = try ServiceHost.start(storeFolder: folder, requestTimeout: 30)
    let owner = try field("token", of: try ask(host, "owner.credential"))
    _ = try ask(
      host, "setting.set", token: owner,
      ["key": .string("messaging.wait_recheck"), "value": .integer(1)])
    let created = try ask(
      host, "principal.create", token: owner,
      ["family": .string("f"), "role": .string("agent"), "name": .string("a")])
    let id = try field("id", of: created)
    let issued = try ask(host, "credential.issue", token: owner, ["principal": .string(id)])
    return Setup(host: host, owner: owner, agentID: id, token: try field("token", of: issued))
  }

  /// Parks a wait of 30 seconds on a thread of its own.
  private func parkWait(_ setup: Setup) -> Answer {
    let answer = Answer()
    Thread.detachNewThread {
      answer.deliver(
        try? ask(setup.host, "wait", token: setup.token, ["timeout": .integer(30)]))
    }
    #expect(
      setup.host.waitUntilParked(ownerToken: setup.owner, count: 1), "the wait has parked")
    return answer
  }

  @Test func test_aParkedWait_endsSoonAfterItsPrincipalIsDisabled() throws {
    let folder = shortFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let setup = try makeSetup(folder: folder)
    defer { setup.host.stop() }
    let answer = parkWait(setup)

    _ = try ask(
      setup.host, "principal.disable", token: setup.owner, ["principal": .string(setup.agentID)])

    #expect(
      answer.finished.wait(timeout: .now() + 20) == .success,
      "the wait ended before its own 30 second timeout")
    #expect(
      answer.response?.failure?.code == .principalDisabled,
      "and it ended with the authentication outcome, never with mail")
  }

  @Test func test_aParkedWait_endsSoonAfterItsCredentialIsRevoked() throws {
    let folder = shortFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let setup = try makeSetup(folder: folder)
    defer { setup.host.stop() }
    let answer = parkWait(setup)

    // Disabling revokes the credentials and enabling does not bring them back, so the principal
    // is enabled again at the next look but its old credential stays revoked.
    _ = try ask(
      setup.host, "principal.disable", token: setup.owner, ["principal": .string(setup.agentID)])
    _ = try ask(
      setup.host, "principal.enable", token: setup.owner, ["principal": .string(setup.agentID)])

    #expect(
      answer.finished.wait(timeout: .now() + 20) == .success,
      "the wait ended before its own 30 second timeout")
    #expect(
      answer.response?.failure?.code == .tokenRevoked,
      "the old credential was revoked, so the wait says so")
  }
}
