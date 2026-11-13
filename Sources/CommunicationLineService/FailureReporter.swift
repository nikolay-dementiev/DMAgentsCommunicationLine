import Foundation

/// Where a failure that the caller is not told about goes. An unexpected error is answered as a plain
/// `internal` failure; the detail goes here so it is never lost.
public protocol FailureReporter: Sendable {
  func report(_ error: any Error, operation: String)
}

/// Writes one line per failure to standard error, which the service's supervisor collects.
public struct StandardErrorReporter: FailureReporter {
  public init() {}

  public func report(_ error: any Error, operation: String) {
    let line = "commline-service: \(operation) failed: \(error)\n"
    FileHandle.standardError.write(Data(line.utf8))
  }
}
