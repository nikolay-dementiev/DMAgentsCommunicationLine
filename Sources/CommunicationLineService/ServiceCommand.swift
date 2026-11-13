import CommunicationLineDomain
import Darwin
import Foundation

/// The command line of `commline-service`: `commline-service <store-folder>`.
///
/// Exit statuses: 0 stopped cleanly, 1 could not start, 2 usage, 3 another instance is running.
public enum ServiceCommand {
  public static let failureStatus: Int32 = 1
  public static let usageStatus: Int32 = 2
  public static let alreadyRunningStatus: Int32 = 3

  public enum Outcome {
    case running(ServiceHost)
    case exit(Int32)

    public var exitStatus: Int32? {
      if case .exit(let status) = self { return status }
      return nil
    }
  }

  /// Parses the arguments and starts the host. Anything wrong is written to `errorOutput`.
  public static func start(arguments: [String], errorOutput: (String) -> Void) -> Outcome {
    guard arguments.count == 1, !arguments[0].hasPrefix("-") else {
      errorOutput("usage: commline-service <store-folder>")
      return .exit(usageStatus)
    }
    do {
      let folder = URL(fileURLWithPath: arguments[0], isDirectory: true)
      return .running(try ServiceHost.start(storeFolder: folder))
    } catch ServiceHostError.alreadyRunning {
      errorOutput("commline-service: another instance is already running on this store")
      return .exit(alreadyRunningStatus)
    } catch {
      errorOutput("commline-service: cannot start: \(error)")
      return .exit(failureStatus)
    }
  }

  /// Starts the host, stops it on SIGTERM or SIGINT and returns the exit status.
  public static func run(arguments: [String]) -> Int32 {
    if arguments == ["--version"] {
      print(ProductVersion.current)
      return 0
    }
    let outcome = start(arguments: arguments) { line in
      FileHandle.standardError.write(Data((line + "\n").utf8))
    }
    guard case .running(let host) = outcome else { return outcome.exitStatus ?? failureStatus }
    signal(SIGTERM, SIG_IGN)
    signal(SIGINT, SIG_IGN)
    let sources = [SIGTERM, SIGINT].map { number in
      let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
      source.setEventHandler { host.stop() }
      source.resume()
      return source
    }
    host.waitUntilStopped()
    sources.forEach { $0.cancel() }
    return 0
  }
}
