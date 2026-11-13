import Foundation

/// What the runner needs from the machine around it besides the service: time passing and the file
/// system. Tests replace both.
public struct RunnerEnvironment: Sendable {
  public let pause: @Sendable (TimeInterval) -> Void
  public let directoryExists: @Sendable (String) -> Bool
  public let now: @Sendable () -> Date

  public init(
    pause: @escaping @Sendable (TimeInterval) -> Void,
    directoryExists: @escaping @Sendable (String) -> Bool,
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.pause = pause
    self.directoryExists = directoryExists
    self.now = now
  }

  public static let system = RunnerEnvironment(
    pause: { Thread.sleep(forTimeInterval: $0) },
    directoryExists: { path in
      var isDirectory: ObjCBool = false
      return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        && isDirectory.boolValue
    })
}
