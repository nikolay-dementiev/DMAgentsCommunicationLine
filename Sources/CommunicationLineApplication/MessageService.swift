import CommunicationLineDomain
import Foundation

/// Sending, reading and acknowledging mail. Every operation derives the caller from the token it is
/// given.
public struct MessageService {
  private let store: any MessageStore
  private let rights: any RightsStore
  private let authenticator: any Authenticating
  private let settings: any SettingsReading
  private let identifiers: any IdentifierSource
  private let clock: any WallClock
  private let arrival: any MailArrival
  private let waitQuota: WaitQuota

  public init(
    store: any MessageStore, rights: any RightsStore, authenticator: any Authenticating,
    settings: any SettingsReading,
    identifiers: any IdentifierSource, clock: any WallClock, arrival: any MailArrival,
    waitQuota: WaitQuota
  ) {
    self.store = store
    self.rights = rights
    self.authenticator = authenticator
    self.settings = settings
    self.identifiers = identifiers
    self.clock = clock
    self.arrival = arrival
    self.waitQuota = waitQuota
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
      maxBodyBytes: try setting("messaging.body_max", token: token),
      maxRecipients: try setting("wire.recipients", token: token))
    let inboxLimit = try setting("quota.messages.assigned_per_principal", token: token)
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
        guard (context.pendingCounts[id] ?? 0) < inboxLimit else {
          throw MessagingError.recipientInboxFull(id, limit: inboxLimit)
        }
      }
    }
    arrival.signal(recipients: Set(distinct))
    return message.id
  }

  // MARK: - Inbox, read, acknowledge

  /// The caller's pending mail, oldest first, one catalog-sized page at a time.
  public func inbox(token: CredentialToken, after cursor: InboxCursor?) throws -> InboxPage {
    let recipient = try requirePrincipal(token)
    let limit = try setting("messaging.page_size", token: token)
    return try store.inbox(for: recipient.id, after: cursor, limit: limit)
  }

  /// The message, if the caller may read it. Reading never acknowledges. The access decision uses
  /// only what the store holds about the message, never anything the caller supplies.
  public func read(token: CredentialToken, messageID: MessageID) throws -> StoredMessage {
    let reader = try requirePrincipal(token)
    guard let message = try store.message(id: messageID) else {
      throw MessagingError.messageUnavailable(messageID)
    }
    let meta = MessageMeta(
      sender: message.sender, recipients: Set(message.recipients), family: message.family)
    let allowed = AccessPolicy.canRead(
      principal: reader, meta: meta, grants: try rights.readGrants().map(\.grant),
      now: clock.now())
    guard allowed else { throw MessagingError.messageUnavailable(messageID) }
    return message
  }

  /// Acknowledges the caller's own delivery. Repeating it changes nothing.
  public func acknowledge(token: CredentialToken, messageID: MessageID) throws {
    let recipient = try requirePrincipal(token)
    let outcome = try store.acknowledge(
      messageID: messageID, recipient: recipient.id, at: clock.now())
    if outcome == .notRecipient { throw MessagingError.messageUnavailable(messageID) }
  }

  // MARK: - Wait

  /// Returns at once when the caller has pending mail; otherwise parks until mail for the caller is
  /// committed or `timeout` runs out. The timeout defaults to `messaging.wait` and never exceeds it;
  /// a catalog value of zero turns parking off. Nothing polls: the wait ends on a signal.
  public func wait(token: CredentialToken, timeout: TimeInterval? = nil) throws -> WaitResult {
    let recipient = try requirePrincipal(token)
    let limit = TimeInterval(try setting("messaging.wait", token: token, allowingZero: true))
    let allowed = min(timeout ?? limit, limit)
    let deadline = clock.now().addingTimeInterval(allowed)
    var holdsPlace = false
    defer { if holdsPlace { waitQuota.release(principal: recipient.id) } }
    while true {
      let ticket = arrival.ticket(for: recipient.id)
      if try store.hasPending(for: recipient.id) { return .mail }
      let remaining = deadline.timeIntervalSince(clock.now())
      guard allowed > 0, remaining > 0 else { return .timedOut }
      if !holdsPlace {
        try waitQuota.acquire(
          principal: recipient.id,
          global: try setting("limits.waits.global", token: token, allowingZero: true),
          perPrincipalLimit: try setting("limits.waits.principal", token: token, allowingZero: true)
        )
        holdsPlace = true
      }
      switch arrival.wait(for: recipient.id, since: ticket, timeout: remaining) {
      case .timedOut: return try store.hasPending(for: recipient.id) ? .mail : .timedOut
      case .signalled: continue
      }
    }
  }

  // MARK: - Helpers

  private func requirePrincipal(_ token: CredentialToken) throws -> Principal {
    guard case .principal(let principal) = try authenticator.authenticate(token) else {
      throw IdentityError.principalCredentialRequired
    }
    return principal
  }

  private func setting(_ key: String, token: CredentialToken, allowingZero: Bool = false) throws
    -> Int
  {
    guard case .integer(let value) = try settings.effectiveValue(of: key, token: token),
      let size = Int(exactly: value), size > 0 || (allowingZero && size == 0)
    else { throw MessagingError.invalidSetting(key: key) }
    return size
  }

  private static func distinct(_ recipients: [PrincipalID]) -> [PrincipalID] {
    var seen = Set<PrincipalID>()
    return recipients.filter { seen.insert($0).inserted }
  }
}
