import CommunicationLineWire
import Foundation

/// The service is ready once it answers a request on its socket. A listener that merely accepts
/// a connection, or answers with something that is not a response, is not the service.
///
/// The probe is a request without a token. The service refuses it with a typed failure, which is
/// all the probe needs: it proves that the protocol is spoken. The service records the refusal in
/// its activity log like any other unauthenticated request.
public struct SocketReadiness: ServiceReadiness {
  private let interval: TimeInterval
  private let connect: @Sendable (String) -> any ServiceConnection

  public init(
    interval: TimeInterval = 0.1,
    connect: @escaping @Sendable (String) -> any ServiceConnection = {
      SocketServiceConnection(socketPath: $0)
    }
  ) {
    self.interval = interval
    self.connect = connect
  }

  public func waitUntilAnswering(socket: URL, within seconds: TimeInterval) throws {
    let deadline = Date().addingTimeInterval(seconds)
    var lastError: any Error = InstallError.serviceNotReady("no attempt was made")
    repeat {
      do {
        _ = try connect(socket.path).exchange(
          WireRequest(token: nil, operation: "health"), deadline: deadline)
        return
      } catch ServiceConnectionError.pathTooLong(let path) {
        throw InstallError.serviceNotReady("the socket path is too long to use: \(path)")
      } catch {
        lastError = error
        if Date().addingTimeInterval(interval) < deadline {
          Thread.sleep(forTimeInterval: interval)
        }
      }
    } while Date() < deadline
    throw InstallError.serviceNotReady(
      "nothing answered on \(socket.path) within \(Int(seconds)) s: \(lastError)")
  }
}
