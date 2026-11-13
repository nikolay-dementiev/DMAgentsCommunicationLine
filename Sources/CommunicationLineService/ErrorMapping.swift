import CommunicationLineApplication
import CommunicationLineDomain
import CommunicationLineWire

/// Turns every error a service can throw into a typed failure. Anything not listed is `internal`,
/// reported to the reporter and answered without its detail.
public enum ErrorMapping {
  public static func response(
    for error: any Error, operation: String, reporter: any FailureReporter
  ) -> WireResponse {
    if let known = known(error) {
      return .failure(code: known.code, message: known.message)
    }
    reporter.report(error, operation: operation)
    return .failure(code: .internal, message: "the service failed to handle the request")
  }

  private static func known(_ error: any Error) -> (code: WireErrorCode, message: String)? {
    switch error {
    case let error as RequestError: return request(error)
    case let error as IdentityError: return identity(error)
    case let error as RightsError: return rights(error)
    case let error as MessagingError: return messaging(error)
    case let error as MessageError: return message(error)
    case let error as SettingsServiceError: return settings(error)
    case let error as CleanupError: return cleanup(error)
    default: return nil
    }
  }

  private static func cleanup(_ error: CleanupError) -> (WireErrorCode, String) {
    switch error {
    case .invalidSetting(let key): return (.invalidSetting, "the setting \(key) is not usable")
    }
  }

  private static func request(_ error: RequestError) -> (WireErrorCode, String) {
    switch error {
    case .badRequest(let reason): return (.badRequest, reason)
    case .tokenRequired: return (.tokenRequired, "the request carries no token")
    }
  }

  private static func identity(_ error: IdentityError) -> (WireErrorCode, String)? {
    switch error {
    case .unknownToken: return (.unknownToken, "the token is not known")
    case .tokenRevoked: return (.tokenRevoked, "the token was revoked")
    case .principalDisabled: return (.principalDisabled, "the principal is disabled")
    case .ownerCredentialRequired: return (.ownerRequired, "the owner token is required")
    case .principalCredentialRequired: return (.agentRequired, "a principal token is required")
    case .unknownPrincipal(let id): return (.unknownPrincipal, "no principal \(id.rawValue)")
    case .invalidName(let field): return (.invalidName, "\(field) must not be blank")
    case .invalidRandomOutput: return nil
    }
  }

  private static func rights(_ error: RightsError) -> (WireErrorCode, String) {
    switch error {
    case .invalidRule: return (.invalidRule, "the rule or grant is not valid")
    case .expiryInThePast: return (.expiryInThePast, "the expiry is not in the future")
    case .unknownGrant(let id): return (.unknownGrant, "no grant \(id)")
    }
  }

  private static func messaging(_ error: MessagingError) -> (WireErrorCode, String) {
    switch error {
    case .unknownRecipient(let id): return (.unknownRecipient, "no principal \(id.rawValue)")
    case .recipientRefused(let id):
      return (.recipientRefused, "sending to \(id.rawValue) is refused")
    case .messageUnavailable(let id): return (.messageUnavailable, "no message \(id.rawValue)")
    case .invalidSetting(let key): return (.invalidSetting, "the setting \(key) is not usable")
    case .invalidPageLimit(let limit): return (.invalidPageLimit, "page limit \(limit)")
    case .recipientInboxFull(let id, let limit):
      return (.recipientInboxFull, "\(id.rawValue) already has \(limit) pending messages")
    case .tooManyWaiters: return (.tooManyWaiters, "too many waits are parked")
    }
  }

  private static func message(_ error: MessageError) -> (WireErrorCode, String) {
    switch error {
    case .noRecipients: return (.noRecipients, "a message needs a recipient")
    case .tooManyRecipients(let limit, let actual):
      return (.tooManyRecipients, "\(actual) recipients, the limit is \(limit)")
    case .subjectTooLarge(let limit, let actual):
      return (.subjectTooLarge, "subject is \(actual) bytes, the limit is \(limit)")
    case .bodyTooLarge(let limit, let actual):
      return (.bodyTooLarge, "body is \(actual) bytes, the limit is \(limit)")
    }
  }

  private static func settings(_ error: SettingsServiceError) -> (WireErrorCode, String) {
    switch error {
    case .unknownKey(let key): return (.unknownKey, "no setting \(key)")
    case .scopeNotAllowed(let key, let scope):
      return (.scopeNotAllowed, "\(key) cannot be set in the \(scope.rawValue) scope")
    case .subjectRequired(let scope):
      return (.subjectRequired, "the \(scope.rawValue) scope needs a subject")
    case .subjectNotAllowed(let scope):
      return (.subjectNotAllowed, "the \(scope.rawValue) scope takes no subject")
    case .invalidValue(let key, _): return (.invalidValue, "the value is not valid for \(key)")
    }
  }
}
