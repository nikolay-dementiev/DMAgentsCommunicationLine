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
  private let environment: RunnerEnvironment

  public init(
    connect: @escaping (String) -> any ServiceConnection, tokenReader: TokenReader,
    standardOutput: @escaping (String) -> Void, standardError: @escaping (String) -> Void,
    host: any HostCommands, environment: RunnerEnvironment = .system,
    encode: @escaping (WireValue) throws -> Data = { try WireCoding.encode($0) }
  ) {
    self.host = host
    self.environment = environment
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
      if command.words == ["wait"], invocation.flags.contains("until-mail") {
        return waitUntilMail(request, socket: socket)
      }
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

  /// `install`, `uninstall`, `owner recover` and `agent add` work on the host. Returns nil for every other command.
  private func runHostCommand(_ invocation: Invocation) throws -> Int32? {
    let lines: () throws -> [String]
    switch invocation.words {
    case ["install"]:
      guard invocation.optionNames.isSubset(of: ["home"]) else {
        throw UsageError("usage: commline install [--home <folder>]")
      }
      lines = { try host.install(home: invocation.single("home")) }
    case ["uninstall"]:
      guard invocation.optionNames.isSubset(of: ["home", "delete-data"]) else {
        throw UsageError("usage: commline uninstall [--home <folder>] [--delete-data]")
      }
      lines = {
        try host.uninstall(
          home: invocation.single("home"), deleteData: invocation.flags.contains("delete-data"))
      }
    case ["owner", "recover"]:
      guard invocation.optionNames.isSubset(of: ["home"]) else {
        throw UsageError("usage: commline owner recover [--home <folder>]")
      }
      lines = { try host.recoverOwner(home: invocation.single("home")) }
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
    let family = try CommandCatalog.required(invocation, "family")
    let name = try CommandCatalog.required(invocation, "name")
    for (option, value) in [("family", family), ("name", name)]
    where value.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
      || value.contains("`")
    {
      throw UsageError("--\(option) must not contain control characters or backticks")
    }
    return (store, AgentRequest(family: family, role: role, name: name, client: client))
  }

  // MARK: - Waiter

  /// How long the waiter pauses before it tries the service again.
  private static let reconnectPause: TimeInterval = 1

  /// Repeats `wait` until mail is waiting. A timeout only starts the next cycle; a service that is
  /// restarting is tried again; a refusal ends the wait, and so does a store folder that is gone.
  private func waitUntilMail(_ request: WireRequest, socket: String) -> Int32 {
    let folder = (socket as NSString).deletingLastPathComponent
    while true {
      do {
        let response = try connect(socket).exchange(request)
        if let failure = response.failure {
          standardError("commline: \(failure.code.rawValue): \(failure.message)")
          return CommandExitStatus(failureClass: failure.code.errorClass).rawValue
        }
        if case .object(let fields)? = response.result, fields["outcome"] == .string("mail") {
          standardOutput("mail")
          return CommandExitStatus.success.rawValue
        }
        if case .object(let fields)? = response.result, fields["outcome"] == .string("timeout") {
          continue
        }
        // An answer that is neither: do not spin on it.
        environment.pause(Self.reconnectPause)
      } catch ServiceConnectionError.unreachable(let reason) {
        guard environment.directoryExists(folder) else { return notInstalled(folder) }
        standardError("commline: the service is not reachable, trying again: \(reason)")
        environment.pause(Self.reconnectPause)
      } catch ServiceConnectionError.invalidResponse {
        guard environment.directoryExists(folder) else { return notInstalled(folder) }
        environment.pause(Self.reconnectPause)
      } catch {
        standardError("commline: \(error)")
        return CommandExitStatus.failure.rawValue
      }
    }
  }

  private func notInstalled(_ folder: String) -> Int32 {
    standardError("commline: not installed here: the store folder \(folder) does not exist")
    return CommandExitStatus.notInstalled.rawValue
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
