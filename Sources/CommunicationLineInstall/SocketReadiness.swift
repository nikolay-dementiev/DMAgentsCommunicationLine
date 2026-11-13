import CommunicationLineWire
import Foundation

/// The service is ready once its socket accepts a connection.
public struct SocketReadiness: ServiceReadiness {
  private let interval: TimeInterval

  public init(interval: TimeInterval = 0.1) {
    self.interval = interval
  }

  public func waitUntilAnswering(socket: URL, within seconds: TimeInterval) throws {
    let deadline = Date().addingTimeInterval(seconds)
    var lastError: any Error = InstallError.serviceNotReady("no attempt was made")
    repeat {
      do {
        let stream = try UnixSocketClient.connect(path: socket.path)
        stream.close()
        return
      } catch {
        lastError = error
        Thread.sleep(forTimeInterval: interval)
      }
    } while Date() < deadline
    throw InstallError.serviceNotReady(
      "nothing answered on \(socket.path) within \(Int(seconds)) s: \(lastError)")
  }
}
