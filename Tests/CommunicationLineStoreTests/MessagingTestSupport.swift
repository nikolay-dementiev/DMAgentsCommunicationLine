import CommunicationLineApplication
import CommunicationLineDomain
import CommunicationLineStore
import Foundation

/// Records every signal and every wait, and never parks: a wait returns `.timedOut` at once.
final class RecordingArrival: MailArrival {
  private(set) var signals: [Set<PrincipalID>] = []
  private(set) var waitTimeouts: [TimeInterval] = []
  /// Runs inside `signal`, so a test can look at the database at the moment of the signal.
  var onSignal: (() -> Void)?

  func ticket(for recipient: PrincipalID) -> ArrivalTicket { ArrivalTicket(value: 0) }

  func signal(recipients: Set<PrincipalID>) {
    signals.append(recipients)
    onSignal?()
  }

  func wait(for recipient: PrincipalID, since ticket: ArrivalTicket, timeout: TimeInterval)
    -> ArrivalResult
  {
    waitTimeouts.append(timeout)
    return .timedOut
  }
}

/// Runs a closure between the authentication of a caller and the transaction of a send, which is the
/// moment a principal can be disabled or a rule removed.
final class HookedMessageStore: MessageStore {
  let base: any MessageStore
  var beforeSend: (() throws -> Void)?
  /// Runs inside the send transaction, after the send checks passed and before the rows are
  /// written: the moment at which the pending counts of the recipients have been read.
  var afterAuthorize: (() -> Void)?

  init(base: any MessageStore) { self.base = base }

  func send(_ message: OutgoingMessage, authorize: (SendContext) throws -> Void) throws {
    if let hook = beforeSend {
      beforeSend = nil
      try hook()
    }
    try base.send(message) { context in
      try authorize(context)
      afterAuthorize?()
    }
  }

  func message(id: MessageID) throws -> StoredMessage? { try base.message(id: id) }

  func hasPending(for recipient: PrincipalID) throws -> Bool {
    try base.hasPending(for: recipient)
  }

  func inbox(for recipient: PrincipalID, after cursor: InboxCursor?, limit: Int) throws
    -> InboxPage
  { try base.inbox(for: recipient, after: cursor, limit: limit) }

  func acknowledge(messageID: MessageID, recipient: PrincipalID, at instant: Date) throws
    -> AcknowledgeOutcome
  { try base.acknowledge(messageID: messageID, recipient: recipient, at: instant) }
}

/// A real store with two families, their tokens, the rights and settings services and a message
/// service on top of them.
struct MessagingFixture {
  let identity: IdentityFixture
  let rights: RightsService
  let settings: SettingsService
  let messages: MessageService
  let store: HookedMessageStore
  let recorder = RecordingArrival()
  let waitQuota = WaitQuota()
  let clock = MutableClock(Date(timeIntervalSince1970: 1_800_000_000))
  let alpha: Principal
  let alphaToken: CredentialToken
  let alphaPeer: Principal
  let alphaPeerToken: CredentialToken
  let alphaHead: Principal
  let alphaHeadToken: CredentialToken
  let beta: Principal
  let betaToken: CredentialToken

  var owner: CredentialToken { identity.owner }

  /// `arrival` replaces the recording one, for tests that need a waiter to really park.
  init(arrival: (any MailArrival)? = nil) throws {
    identity = try IdentityFixture()
    let service = identity.service
    let owner = identity.owner
    func enrol(_ family: String, _ name: String, _ role: RoleKind = .agent) throws -> (
      Principal, CredentialToken
    ) {
      let principal = try service.createPrincipal(
        family: family, role: role, displayName: name, ownerToken: owner)
      return (principal, try service.issueCredential(for: principal.id, ownerToken: owner))
    }
    (alpha, alphaToken) = try enrol("A", "alpha")
    (alphaPeer, alphaPeerToken) = try enrol("A", "alpha peer")
    (alphaHead, alphaHeadToken) = try enrol("A", "alpha head", .head)
    (beta, betaToken) = try enrol("B", "beta")
    rights = RightsService(
      rights: SQLiteRightsStore(store: identity.store),
      principals: SQLiteIdentityStore(store: identity.store), authenticator: service,
      clock: clock)
    settings = SettingsService(
      catalog: try BundledSettingsCatalogSource.shipped.load(),
      store: SQLiteSettingsStore(store: identity.store), clock: clock, authenticator: service)
    store = HookedMessageStore(base: SQLiteMessageStore(store: identity.store))
    messages = MessageService(
      store: store, rights: SQLiteRightsStore(store: identity.store), authenticator: service,
      settings: settings,
      identifiers: SequentialIdentifiers(), clock: clock, arrival: arrival ?? recorder,
      waitLimiter: waitQuota,
      storage: StorageService(store: SQLiteStorageStore(store: identity.store), settings: settings))
  }

  func count(_ table: String) throws -> Int {
    try identity.raw().integer("SELECT count(*) FROM \(table)")
  }

  @discardableResult
  func mail(from token: CredentialToken, to recipient: Principal, _ subject: String = "s") throws
    -> MessageID
  {
    try messages.send(
      token: token, to: [recipient.id], subject: subject, body: "body of \(subject)")
  }

  func isAcknowledged(_ message: MessageID, by recipient: Principal) throws -> Bool {
    try identity.raw().integer(
      """
      SELECT count(*) FROM deliveries d JOIN messages m ON m.seq = d.message_seq
      WHERE m.id = '\(message.rawValue)' AND d.recipient = '\(recipient.id.rawValue)'
        AND d.state = 'acknowledged'
      """) == 1
  }

  func acknowledgedAt(_ message: MessageID, by recipient: Principal) throws -> Int {
    try identity.raw().integer(
      """
      SELECT d.acknowledged_at_ms FROM deliveries d JOIN messages m ON m.seq = d.message_seq
      WHERE m.id = '\(message.rawValue)' AND d.recipient = '\(recipient.id.rawValue)'
      """)
  }
}
