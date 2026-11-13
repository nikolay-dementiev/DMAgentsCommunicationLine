import Foundation

public struct CommandResult: Equatable, Sendable {
  public let status: Int32
  public let output: String

  public init(status: Int32, output: String) {
    self.status = status
    self.output = output
  }
}

/// Runs a program and waits for it. The real one starts a process; tests script the answers.
public protocol CommandRunning {
  func run(_ executable: String, _ arguments: [String]) throws -> CommandResult
}

public struct ProcessRunner: CommandRunning {
  public init() {}

  public func run(_ executable: String, _ arguments: [String]) throws -> CommandResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    // Read to the end before waiting, or a chatty child could fill the pipe and never exit.
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return CommandResult(
      status: process.terminationStatus,
      output: String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
  }
}

/// launchd of the logged-in user, driven through `launchctl`.
public struct SystemLaunchd: LaunchdControl {
  private static let launchctl = "/bin/launchctl"
  private let runner: any CommandRunning

  public init(runner: any CommandRunning = ProcessRunner()) {
    self.runner = runner
  }

  /// `launchctl print` exits 113 when the domain exists but holds no such service. Any other
  /// failure, for example 112 for a user without a graphical session, says nothing about the
  /// service, so it is an error and not an answer.
  private static let serviceNotFound: Int32 = 113

  public func isLoaded(label: String, userID: UInt32) throws -> Bool {
    let result = try runner.run(Self.launchctl, ["print", "gui/\(userID)/\(label)"])
    if result.status == Self.serviceNotFound { return false }
    try require(result, "print")
    return true
  }

  public func bootstrap(plist: URL, userID: UInt32) throws {
    try require(
      runner.run(Self.launchctl, ["bootstrap", "gui/\(userID)", plist.path]), "bootstrap")
  }

  public func bootout(label: String, userID: UInt32) throws {
    try require(runner.run(Self.launchctl, ["bootout", "gui/\(userID)/\(label)"]), "bootout")
  }

  private func require(_ result: CommandResult, _ action: String) throws {
    guard result.status == 0 else {
      throw InstallError.launchd("\(action) failed (\(result.status)): \(result.output)")
    }
  }
}
