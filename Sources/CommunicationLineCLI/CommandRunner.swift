import CommunicationLineInstall
import CommunicationLineWire
import Foundation

/// Runs one `commline` command line against a service and returns the exit status.
///
/// Standard output carries the result only; every diagnostic goes to standard error.
public struct CommandRunner {
  private let connect: (String) -> any ServiceConnection
  private let tokenReader: TokenReader
  private let standardOutput: (String) -> Void
  private let standardError: (String) -> Void
  private let encode: (WireValue) throws -> Data
  private let host: any HostCommands

  public init(
    connect: @escaping (String) -> any ServiceConnection, tokenReader: TokenReader,
    standardOutput: @escaping (String) -> Void, standardError: @escaping (String) -> Void,
    host: any HostCommands,
    encode: @escaping (WireValue) throws -> Data = { try WireCoding.encode($0) }
  ) {
    self.host = host
    self.encode = encode
    self.connect = connect
    self.tokenReader = tokenReader
    self.standardOutput = standardOutput
    self.standardError = standardError
  }

  public func run(_ arguments: [String]) -> Int32 {
    do {
      let invocation = try Invocation(arguments: arguments)
      if let status = try runHostCommand(invocation) { return status }
      let (command, positionals) = try resolve(invocation)
      let socket = try socketPath(of: invocation)
      let arguments = try command.arguments(invocation, positionals)
      let token = try command.needsToken ? readToken(invocation) : nil
      let request = WireRequest(token: token, operation: command.operation, arguments: arguments)
      return perform(
        request, command: command, asJSON: invocation.flags.contains("json"), socket: socket)
    } catch let error as UsageError {
      standardError("commline: \(error.message)")
      return CommandExitStatus.usage.rawValue
    } catch let error as TokenInputError {
      standardError("commline: \(describe(error))")
      return CommandExitStatus.tokenInput.rawValue
    } catch {
      standardError("commline: \(error)")
      return CommandExitStatus.failure.rawValue
    }
  }

  // MARK: - Host commands

  /// `install` and `agent add` work on the host. Returns nil for every other command.
  private func runHostCommand(_ invocation: Invocation) throws -> Int32? {
    let lines: () throws -> [String]
    switch invocation.words {
    case ["install"]:
      guard invocation.optionNames.isSubset(of: ["home"]) else {
        throw UsageError("usage: commline install [--home <folder>]")
      }
      lines = { try host.install(home: invocation.single("home")) }
    case ["agent", "add"]:
      let (store, request) = try agentRequest(invocation)
      let ownerToken = try readToken(invocation)
      lines = {
        try host.addAgent(
          storeFolder: store, home: invocation.single("home"), ownerToken: ownerToken,
          request: request)
      }
    default:
      return nil
    }
    do {
      try lines().forEach(standardOutput)
    } catch {
      standardError("commline: \(invocation.words.joined(separator: " ")) failed: \(error)")
      return CommandExitStatus.failure.rawValue
    }
    return CommandExitStatus.success.rawValue
  }

  private func agentRequest(_ invocation: Invocation) throws -> (store: String, AgentRequest) {
    let usage =
      "usage: commline agent add --store <folder> --family <f> --role head|agent "
      + "--name <n> [--client claude-code] [--home <folder>]"
    guard
      invocation.optionNames.isSubset(of: [
        "store", "token-file", "family", "role", "name", "client", "home",
      ])
    else { throw UsageError(usage) }
    guard let store = invocation.single("store") else {
      throw UsageError("--store <folder> is required: the agent's files go inside it")
    }
    let role = try CommandCatalog.required(invocation, "role")
    guard role == "head" || role == "agent" else {
      throw UsageError("--role must be head or agent")
    }
    var client: AgentClient?
    if let name = invocation.single("client") {
      guard let known = AgentClient(rawValue: name) else {
        throw UsageError("--client must be claude-code")
      }
      client = known
    }
    return (
      store,
      AgentRequest(
        family: try CommandCatalog.required(invocation, "family"), role: role,
        name: try CommandCatalog.required(invocation, "name"), client: client)
    )
  }

  // MARK: - Steps

  private func resolve(_ invocation: Invocation) throws -> (Command, [String]) {
    guard let (command, positionals) = CommandCatalog.find(in: invocation.words) else {
      throw UsageError(
        invocation.words.isEmpty
          ? "no command given" : "unknown command \(invocation.words.joined(separator: " "))")
    }
    guard positionals.count == command.positionals.count else {
      let expected = command.positionals.map { "<\($0)>" }.joined(separator: " ")
      throw UsageError("usage: commline \(command.words.joined(separator: " ")) \(expected)")
    }
    let allowed = command.options.union(CommandCatalog.globalOptions)
    if let stray = invocation.optionNames.subtracting(allowed).sorted().first {
      throw UsageError("--\(stray) does not apply to \(command.words.joined(separator: " "))")
    }
    return (command, positionals)
  }

  private func socketPath(of invocation: Invocation) throws -> String {
    switch (invocation.single("store"), invocation.single("socket")) {
    case (let folder?, nil):
      return (folder as NSString).appendingPathComponent(ServiceFiles.socketName)
    case (nil, let path?): return path
    default: throw UsageError("give exactly one of --store <folder> and --socket <path>")
    }
  }

  private func readToken(_ invocation: Invocation) throws -> String {
    try tokenReader.read(tokenFile: invocation.single("token-file"))
  }

  private func perform(_ request: WireRequest, command: Command, asJSON: Bool, socket: String)
    -> Int32
  {
    let response: WireResponse
    do {
      response = try connect(socket).exchange(request)
    } catch ServiceConnectionError.unreachable(let reason) {
      standardError("commline: the service is not reachable: \(reason)")
      return CommandExitStatus.unreachable.rawValue
    } catch ServiceConnectionError.invalidResponse {
      standardError("commline: the service answered with something that is not a response")
      return CommandExitStatus.protocolError.rawValue
    } catch {
      standardError("commline: \(error)")
      return CommandExitStatus.failure.rawValue
    }
    if let failure = response.failure {
      standardError(
        asJSON
          ? Renderer.failureJSON(failure, encode: encode)
          : "commline: \(failure.code.rawValue): \(failure.message)"
      )
      return CommandExitStatus(failureClass: failure.code.errorClass).rawValue
    }
    let result = response.result ?? .object([:])
    if asJSON {
      do {
        standardOutput(try Renderer.json(result, encode: encode))
      } catch {
        standardError("commline: cannot encode the answer: \(error)")
        return CommandExitStatus.failure.rawValue
      }
    } else {
      Renderer.text(result, as: command.presentation).forEach(standardOutput)
    }
    if command.presentation == .outcome, case .object(let fields) = result,
      fields["outcome"] == .string("timeout")
    {
      return CommandExitStatus.timedOut.rawValue
    }
    return CommandExitStatus.success.rawValue
  }

  private func describe(_ error: TokenInputError) -> String {
    switch error {
    case .unreadable(let path): return "cannot read the token file \(path)"
    case .notRegularFile(let path): return "the token file \(path) is not a regular file"
    case .notOwnedByUser(let path): return "the token file \(path) belongs to another user"
    case .insecureMode(let path, let mode):
      return
        "the token file \(path) has mode \(String(mode, radix: 8)); it must allow only its owner (0600)"
    case .empty: return "the token is empty"
    case .notSupplied: return "no token: give --token-file <path> or send it on standard input"
    }
  }
}
