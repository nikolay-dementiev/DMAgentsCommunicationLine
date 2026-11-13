import Darwin
import Foundation

public enum ServiceConnectionError: Error, Equatable {
  /// Nothing is listening on the socket, or it cannot be reached.
  case unreachable(String)
  /// The service answered with bytes that are not a valid response.
  case invalidResponse
}

/// One request to the service and its one answer.
public protocol ServiceConnection {
  func exchange(_ request: WireRequest) throws -> WireResponse
}

/// The connection over the Unix-domain socket of a running service.
public struct SocketServiceConnection: ServiceConnection {
  /// The largest frame the catalog allows the service to use; the service refuses anything above
  /// its own `service.frame_max` by name.
  public static let frameLimit = 16_777_216

  private let socketPath: String

  public init(socketPath: String) {
    self.socketPath = socketPath
  }

  public func exchange(_ request: WireRequest) throws -> WireResponse {
    do {
      return try SocketExchange.call(
        socketPath: socketPath, request: request, maximumFrame: Self.frameLimit)
    } catch UnixSocketError.system(let operation, let code) {
      let reason = String(cString: strerror(code))
      throw ServiceConnectionError.unreachable("\(operation) \(socketPath): \(reason)")
    } catch UnixSocketError.pathTooLong {
      throw ServiceConnectionError.unreachable("the socket path is too long: \(socketPath)")
    } catch is FrameError {
      throw ServiceConnectionError.invalidResponse
    } catch is WireError {
      throw ServiceConnectionError.invalidResponse
    }
  }
}
