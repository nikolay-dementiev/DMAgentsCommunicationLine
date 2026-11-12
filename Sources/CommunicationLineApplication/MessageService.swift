import CommunicationLineDomain
import Foundation

/// Sending, reading and acknowledging mail. Every operation derives the caller from the token it is
/// given.
public struct MessageService {
  private let store: any MessageStore
  private let authenticator: any Authenticating
  private let settings: any SettingsReading
  private let identifiers: any IdentifierSource
  private let clock: any WallClock
  private let arrival: any MailArrival

  public init(
    store: any MessageStore, authenticator: any Authenticating, settings: any SettingsReading,
    identifiers: any IdentifierSource, clock: any WallClock, arrival: any MailArrival
  ) {
    self.store = store
    self.authenticator = authenticator
    self.settings = settings
    self.identifiers = identifiers
    self.clock = clock
    self.arrival = arrival
  }

  // MARK: - Send

  /// Stores one message for every recipient or none. The recipients are checked against the send
  /// policy inside the storing transaction, so a principal disabled or a rule removed after the
  /// caller was authenticated still takes effect.
  public func send(
    token: CredentialToken, to recipients: [PrincipalID], subject: String, body: String
  ) throws -> MessageID {
    let sender = try requirePrincipal(token)
    let distinct = Self.distinct(recipients)
    let limits = MessageLimits(
      maxSubjectBytes: try setting("messaging.subject_max", token: token),
      maxBodyBytes: try setting("messaging.body_max", token: token))
    try limits.validate(recipientCount: distinct.count, subject: subject, body: body)

    let message = OutgoingMessage(
      id: identifiers.newMessageID(), sender: sender.id, recipients: distinct, subject: subject,
      body: body, createdAt: clock.now())
    try store.send(message) { context in
      guard let current = context.sender else { throw IdentityError.unknownPrincipal(sender.id) }
      guard current.isEnabled else { throw IdentityError.principalDisabled }
      for id in distinct {
        guard let target = context.recipients[id] else {
          throw MessagingError.unknownRecipient(id)
        }
        guard AccessPolicy.canSend(from: current, to: target, rules: context.rules) else {
          throw MessagingError.recipientRefused(id)
        }
      }
    }
    arrival.signal(recipients: Set(distinct))
    return message.id
  }

  // MARK: - Helpers

  private func requirePrincipal(_ token: CredentialToken) throws -> Principal {
    guard case .principal(let principal) = try authenticator.authenticate(token) else {
      throw IdentityError.principalCredentialRequired
    }
    return principal
  }

  private func setting(_ key: String, token: CredentialToken) throws -> Int {
    guard case .integer(let value) = try settings.effectiveValue(of: key, token: token),
      let size = Int(exactly: value), size > 0
    else { throw MessagingError.invalidSetting(key: key) }
    return size
  }

  private static func distinct(_ recipients: [PrincipalID]) -> [PrincipalID] {
    var seen = Set<PrincipalID>()
    return recipients.filter { seen.insert($0).inserted }
  }
}
