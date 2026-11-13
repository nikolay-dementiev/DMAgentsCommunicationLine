import CommunicationLineWire

/// The exit statuses of `commline`. The values are a contract: scripts test them.
public enum CommandExitStatus: Int32, Sendable, CaseIterable {
  case success = 0
  /// The service failed in a way it did not name, or `commline` itself failed.
  case failure = 1
  /// The command line is wrong. Nothing was sent.
  case usage = 2
  /// There is no service on the socket.
  case unreachable = 3
  /// The token is missing from the service's point of view, unknown, revoked or disabled.
  case authentication = 4
  /// The token is valid but the operation is not allowed for it.
  case permission = 5
  case notFound = 6
  case invalidInput = 7
  /// The bytes on the socket were not a valid answer, or the request was not valid.
  case protocolError = 8
  /// `wait` ended without mail.
  case timedOut = 9
  /// The token could not be read from the file or from standard input.
  case tokenInput = 10

  /// The status of a failure of the given class. Never `success`.
  public init(failureClass: WireErrorClass) {
    switch failureClass {
    case .request: self = .protocolError
    case .authentication: self = .authentication
    case .permission: self = .permission
    case .notFound: self = .notFound
    case .invalidInput: self = .invalidInput
    case .internal: self = .failure
    }
  }
}
