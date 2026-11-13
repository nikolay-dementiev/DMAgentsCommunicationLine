import CommunicationLineWire
import Foundation

public enum AgentClient: String, Sendable {
  case claudeCode = "claude-code"
}

public struct AgentRequest: Sendable, Equatable {
  public let family: String
  public let role: String
  public let name: String
  public let client: AgentClient?

  public init(family: String, role: String, name: String, client: AgentClient?) {
    self.family = family
    self.role = role
    self.name = name
    self.client = client
  }
}

public struct AgentSetupReport: Equatable, Sendable, CustomStringConvertible {
  public let principalID: String
  public let tokenFile: String
  public let instructionFile: String
  public let commandFile: String?

  public var description: String {
    "agent \(principalID); token file \(tokenFile); instructions \(instructionFile)"
      + (commandFile.map { "; command \($0)" } ?? "")
  }
}

public enum AgentSetupError: Error, Equatable {
  /// A command file needs the manifest of an install to be listed in.
  case notInstalled(String)
  case commandFileExists(String)
  case serviceRefused(code: String, message: String)
  case invalidReply(String)
  case filesystem(String)
}

extension AgentSetupError: CustomStringConvertible {
  public var description: String {
    switch self {
    case .notInstalled(let path):
      return "commline is not installed here (no manifest at \(path)); run commline install first"
    case .commandFileExists(let path):
      return "\(path) already exists and was not overwritten; remove it or choose another name"
    case .serviceRefused(let code, let message): return "the service refused: \(code): \(message)"
    case .invalidReply(let what): return "the service answered with something unexpected: \(what)"
    case .filesystem(let reason): return "a file could not be written: \(reason)"
    }
  }
}

/// Creates an agent: its principal, its credential, the private token file, the instruction file
/// and, for a client that supports it, a mail command. The owner token is used for the two service
/// calls and written nowhere.
public struct AgentSetup {
  private let layout: HostLayout
  private let storeFolder: URL
  private let connect: (String) -> any ServiceConnection

  public init(
    layout: HostLayout, storeFolder: URL, connect: @escaping (String) -> any ServiceConnection
  ) {
    self.layout = layout
    self.storeFolder = storeFolder
    self.connect = connect
  }

  public func add(_ request: AgentRequest, ownerToken: String) throws -> AgentSetupReport {
    let commandFile = try checkedCommandFile(for: request)
    let service = connect(storeFolder.appendingPathComponent(ServiceFiles.socketName).path)
    let created = try call(
      service, "principal.create", token: ownerToken,
      [
        "family": .string(request.family), "role": .string(request.role),
        "name": .string(request.name),
      ])
    let id = try text("id", in: created)
    let issued = try call(
      service, "credential.issue", token: ownerToken, ["principal": .string(id)])
    let token = try text("token", in: issued)
    do {
      return try writeFiles(request: request, id: id, token: token, commandFile: commandFile)
    } catch let error as AgentSetupError {
      throw error
    } catch {
      throw AgentSetupError.filesystem("\(error)")
    }
  }

  // MARK: - Steps

  /// Everything that can be checked before the principal exists is checked first, so that a setup
  /// that cannot finish creates nothing.
  private func checkedCommandFile(for request: AgentRequest) throws -> URL? {
    guard request.client != nil else { return nil }
    guard FileManager.default.fileExists(atPath: layout.manifestURL.path) else {
      throw AgentSetupError.notInstalled(layout.manifestURL.path)
    }
    let file = layout.claudeCommandsFolder.appendingPathComponent(
      "commline-\(Self.fileSafe(request.name)).md")
    guard !FileManager.default.fileExists(atPath: file.path) else {
      throw AgentSetupError.commandFileExists(file.path)
    }
    return file
  }

  private func writeFiles(request: AgentRequest, id: String, token: String, commandFile: URL?)
    throws -> AgentSetupReport
  {
    let folder = storeFolder.appendingPathComponent("agents", isDirectory: true)
    try HostFiles.makeFolder(folder, mode: 0o700)
    let tokenFile = folder.appendingPathComponent("\(id).token")
    try HostFiles.createExclusively(Data((token + "\n").utf8), at: tokenFile, mode: 0o600)
    let invocation = AgentInstructions.invocation(
      layout: layout, store: storeFolder, tokenFile: tokenFile.path)
    let instructionFile = folder.appendingPathComponent("\(id).md")
    try HostFiles.createExclusively(
      Data(
        AgentInstructions.instructions(
          request: request, id: id, tokenFile: tokenFile.path, invocation: invocation
        ).utf8),
      at: instructionFile, mode: 0o600)
    if let commandFile {
      try FileManager.default.createDirectory(
        at: commandFile.deletingLastPathComponent(), withIntermediateDirectories: true)
      try writeCommand(commandFile, request: request, id: id, invocation: invocation)
    }
    return AgentSetupReport(
      principalID: id, tokenFile: tokenFile.path, instructionFile: instructionFile.path,
      commandFile: commandFile?.path)
  }

  private func writeCommand(_ file: URL, request: AgentRequest, id: String, invocation: String)
    throws
  {
    try HostFiles.createExclusively(
      Data(
        AgentInstructions.claudeCodeCommand(request: request, id: id, invocation: invocation).utf8),
      at: file, mode: 0o600)
    var manifest = try Manifest.read(from: layout.manifestURL)
    manifest.files.append(file.path)
    try manifest.write(to: layout.manifestURL)
  }

  private func call(
    _ service: any ServiceConnection, _ operation: String, token: String,
    _ arguments: [String: WireValue]
  ) throws -> WireValue {
    let response: WireResponse
    do {
      response = try service.exchange(
        WireRequest(token: token, operation: operation, arguments: arguments))
    } catch {
      throw AgentSetupError.invalidReply("\(error)")
    }
    if let failure = response.failure {
      throw AgentSetupError.serviceRefused(code: failure.code.rawValue, message: failure.message)
    }
    return response.result ?? .object([:])
  }

  private func text(_ key: String, in value: WireValue) throws -> String {
    guard case .object(let fields) = value, case .string(let text)? = fields[key] else {
      throw AgentSetupError.invalidReply("no \(key)")
    }
    return text
  }

  /// A name as part of a file name: lower case letters and digits, anything else a hyphen.
  static func fileSafe(_ name: String) -> String {
    var result = ""
    var pendingHyphen = false
    for scalar in name.lowercased().unicodeScalars {
      if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) {
        if pendingHyphen && !result.isEmpty { result += "-" }
        pendingHyphen = false
        result.unicodeScalars.append(scalar)
      } else {
        pendingHyphen = true
      }
    }
    return result.isEmpty ? "agent" : result
  }
}
