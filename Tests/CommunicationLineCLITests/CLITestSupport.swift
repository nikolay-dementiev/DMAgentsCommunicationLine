import CommunicationLineCLI
import CommunicationLineInstall
import CommunicationLineWire
import Darwin
import Foundation

/// Records the requests it is given and answers from a script.
final class FakeConnection: ServiceConnection, @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [WireRequest] = []
  private let answer: @Sendable (WireRequest) throws -> WireResponse

  init(answer: @escaping @Sendable (WireRequest) throws -> WireResponse = { _ in .success() }) {
    self.answer = answer
  }

  var requests: [WireRequest] { lock.withLock { recorded } }

  func exchange(_ request: WireRequest) throws -> WireResponse {
    lock.withLock { recorded.append(request) }
    return try answer(request)
  }
}

/// Records the host commands it is given and answers from a script.
final class FakeHost: HostCommands, @unchecked Sendable {
  private let lock = NSLock()
  private(set) var installs: [String?] = []
  private let result: Result<[String], any Error>

  init(result: Result<[String], any Error> = .success(["installed"])) { self.result = result }

  struct AgentCall: Equatable {
    let store: String
    let home: String?
    let ownerToken: String
    let request: AgentRequest
  }
  private(set) var agents: [AgentCall] = []

  func install(home: String?) throws -> [String] {
    lock.withLock { installs.append(home) }
    return try result.get()
  }

  func addAgent(storeFolder: String, home: String?, ownerToken: String, request: AgentRequest)
    throws -> [String]
  {
    lock.withLock {
      agents.append(
        AgentCall(store: storeFolder, home: home, ownerToken: ownerToken, request: request))
    }
    return try result.get()
  }
}

/// A runner on a fake connection, with its captured output.
final class CLIHarness: @unchecked Sendable {
  let connection: FakeConnection
  private(set) var standardOutput = ""
  private(set) var standardError = ""
  private(set) var connectedSockets: [String] = []
  private var standardInput: String?
  private let encode: @Sendable (WireValue) throws -> Data
  let host: FakeHost

  init(
    stdin: String? = nil, host: FakeHost = FakeHost(),
    encode: @escaping @Sendable (WireValue) throws -> Data = { try WireCoding.encode($0) },
    answer: @escaping @Sendable (WireRequest) throws -> WireResponse = { _ in .success() }
  ) {
    connection = FakeConnection(answer: answer)
    standardInput = stdin
    self.encode = encode
    self.host = host
  }

  func run(_ arguments: [String]) -> Int32 {
    let runner = CommandRunner(
      connect: { path in
        self.connectedSockets.append(path)
        return self.connection
      },
      tokenReader: TokenReader(standardInput: { self.standardInput }),
      standardOutput: { self.standardOutput += $0 + "\n" },
      standardError: { self.standardError += $0 + "\n" }, host: host, encode: encode)
    return runner.run(arguments)
  }
}

/// A private token file, removed by `remove()`.
struct TokenFileFixture {
  let path: String

  init(mode: mode_t = 0o600, token: String = "tok-0123456789") {
    path = "/tmp/clt-" + UUID().uuidString.prefix(8).lowercased()
    FileManager.default.createFile(atPath: path, contents: Data((token + "\n").utf8))
    chmod(path, mode)
  }

  func remove() { unlink(path) }
}
