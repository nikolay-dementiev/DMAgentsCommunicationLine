/// The coarse kind of a failure. A client maps a class, not a single code, to its own exit status.
public enum WireErrorClass: String, Sendable, Equatable {
  case request
  case authentication
  case permission
  case notFound
  case invalidInput
  case `internal`
}

/// The stable, machine-readable reason of a failed request.
public enum WireErrorCode: String, Sendable, Codable, CaseIterable {
  case badRequest = "bad_request"
  case frameTooLarge = "frame_too_large"
  case tokenRequired = "token_required"
  case unknownToken = "unknown_token"
  case tokenRevoked = "token_revoked"
  case principalDisabled = "principal_disabled"
  case ownerRequired = "owner_required"
  case agentRequired = "agent_required"
  case unknownPrincipal = "unknown_principal"
  case unknownRecipient = "unknown_recipient"
  case recipientRefused = "recipient_refused"
  case messageUnavailable = "message_unavailable"
  case unknownGrant = "unknown_grant"
  case unknownKey = "unknown_key"
  case invalidName = "invalid_name"
  case invalidRule = "invalid_rule"
  case invalidPageLimit = "invalid_page_limit"
  case invalidSetting = "invalid_setting"
  case noRecipients = "no_recipients"
  case subjectTooLarge = "subject_too_large"
  case bodyTooLarge = "body_too_large"
  case expiryInThePast = "expiry_in_the_past"
  case scopeNotAllowed = "scope_not_allowed"
  case subjectRequired = "subject_required"
  case subjectNotAllowed = "subject_not_allowed"
  case invalidValue = "invalid_value"
  case `internal` = "internal"

  public var errorClass: WireErrorClass {
    switch self {
    case .badRequest, .frameTooLarge: return .request
    case .tokenRequired, .unknownToken, .tokenRevoked, .principalDisabled: return .authentication
    case .ownerRequired, .agentRequired, .recipientRefused: return .permission
    case .unknownPrincipal, .unknownRecipient, .messageUnavailable, .unknownGrant, .unknownKey:
      return .notFound
    case .invalidName, .invalidRule, .invalidPageLimit, .invalidSetting, .noRecipients,
      .subjectTooLarge, .bodyTooLarge, .expiryInThePast, .scopeNotAllowed, .subjectRequired,
      .subjectNotAllowed, .invalidValue:
      return .invalidInput
    case .internal: return .internal
    }
  }
}
