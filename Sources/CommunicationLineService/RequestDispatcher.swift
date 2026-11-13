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
  case activityList = "activity.list"
  case healthCleanup = "health.cleanup"
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
  let activity: ActivityService
  let cleanup: CleanupRunner
  private let transactions: any TransactionRunner
  private let reporter: any FailureReporter

  init(
    identity: IdentityService, rights: RightsService, settings: SettingsService,
    messages: MessageService, activity: ActivityService, cleanup: CleanupRunner,
    transactions: any TransactionRunner, reporter: any FailureReporter
  ) {
    self.identity = identity
    self.rights = rights
    self.settings = settings
    self.messages = messages
    self.activity = activity
    self.cleanup = cleanup
    self.transactions = transactions
    self.reporter = reporter
  }

  /// Every request leaves one activity record. For an ordinary request the record is written in
  /// the transaction of its effect, so neither exists without the other; a refused or failed request
  /// rolls back and is recorded afterwards. A `wait` parks, so it never holds a transaction: it is
  /// recorded when it ends.
  public func handle(_ request: WireRequest) -> WireResponse {
    let operation = Operation(rawValue: request.operation)
    let name = operation?.rawValue ?? "unknown"
    let arguments = Arguments(values: request.arguments)
    do {
      guard let operation else {
        throw RequestError.badRequest("unknown operation \(request.operation)")
      }
      let result: WireValue
      if operation == .wait {
        let actor = activity.actor(for: try? optionalToken(of: request))
        result = try perform(operation, request: request, arguments: arguments)
        try activity.record(actor: actor, operation: name, outcome: "ok", targets: [])
      } else {
        result = try transactions.atomically {
          let actor = activity.actor(for: try? optionalToken(of: request))
          let value = try perform(operation, request: request, arguments: arguments)
          try activity.record(
            actor: actor, operation: name, outcome: "ok",
            targets: activityTargets(operation, arguments: arguments, result: value))
          return value
        }
      }
      return .success(result)
    } catch {
      let response = ErrorMapping.response(
        for: error, operation: request.operation, reporter: reporter)
      recordFailure(of: request, as: name, response: response)
      return response
    }
  }

  private func recordFailure(of request: WireRequest, as name: String, response: WireResponse) {
    do {
      try activity.record(
        actor: activity.actor(for: try? optionalToken(of: request)), operation: name,
        outcome: response.failure?.code.rawValue ?? "internal", targets: [])
    } catch {
      reporter.report(error, operation: "record activity")
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
    case .activityList:
      return try performActivity(token: try token(of: request), arguments: arguments)
    case .healthCleanup:
      return try performCleanup(token: try token(of: request))
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
