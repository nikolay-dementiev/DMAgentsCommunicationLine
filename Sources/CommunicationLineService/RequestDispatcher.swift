import CommunicationLineApplication
import CommunicationLineDomain
import CommunicationLineWire
import Foundation

/// The operations of the protocol. The raw values are the names on the wire.
enum Operation: String {
  case send, inbox, read, acknowledge, wait
  case ownerCredential = "owner.credential"
  case principalCreate = "principal.create"
  case principalDisable = "principal.disable"
  case principalEnable = "principal.enable"
  case credentialIssue = "credential.issue"
  case grantAdd = "grant.add"
  case grantRevoke = "grant.revoke"
  case grantList = "grant.list"
  case ruleAdd = "rule.add"
  case ruleRemove = "rule.remove"
  case ruleList = "rule.list"
  case settingGet = "setting.get"
  case settingSet = "setting.set"
}

/// Serves one request at a time against the services. It never throws: every failure is a typed
/// response. A `wait` blocks the calling thread until mail arrives or its time runs out.
public struct RequestDispatcher: @unchecked Sendable {
  // The services hold stores whose database is serialized by its own lock, and the arrival is
  // synchronized, so one dispatcher may serve several threads.
  let identity: IdentityService
  let rights: RightsService
  let settings: SettingsService
  let messages: MessageService
  private let reporter: any FailureReporter

  init(
    identity: IdentityService, rights: RightsService, settings: SettingsService,
    messages: MessageService, reporter: any FailureReporter
  ) {
    self.identity = identity
    self.rights = rights
    self.settings = settings
    self.messages = messages
    self.reporter = reporter
  }

  public func handle(_ request: WireRequest) -> WireResponse {
    do {
      guard let operation = Operation(rawValue: request.operation) else {
        throw RequestError.badRequest("unknown operation \(request.operation)")
      }
      let arguments = Arguments(values: request.arguments)
      return .success(try perform(operation, request: request, arguments: arguments))
    } catch {
      return ErrorMapping.response(for: error, operation: request.operation, reporter: reporter)
    }
  }

  private func perform(_ operation: Operation, request: WireRequest, arguments: Arguments) throws
    -> WireValue
  {
    switch operation {
    case .send, .inbox, .read, .acknowledge, .wait:
      return try performAgent(operation, token: try token(of: request), arguments: arguments)
    case .ownerCredential:
      return try issueOwnerCredential(replacing: try optionalToken(of: request))
    default:
      return try performOwner(operation, token: try token(of: request), arguments: arguments)
    }
  }

  /// The token travels in the body of the request and nowhere else.
  func token(of request: WireRequest) throws -> CredentialToken {
    guard let token = try optionalToken(of: request) else { throw RequestError.tokenRequired }
    return token
  }

  private func optionalToken(of request: WireRequest) throws -> CredentialToken? {
    guard let text = request.token, !text.isEmpty else { return nil }
    guard let token = CredentialToken(encoded: text) else { throw IdentityError.unknownToken }
    return token
  }
}
