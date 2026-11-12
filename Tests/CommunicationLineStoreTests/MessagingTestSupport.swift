import CommunicationLineApplication
import CommunicationLineDomain
import CommunicationLineStore
import Foundation

/// Records which recipients were signalled, in order.
final class RecordingArrival: MailArrival {
  private(set) var signals: [Set<PrincipalID>] = []

  func signal(recipients: Set<PrincipalID>) { signals.append(recipients) }
}

/// Runs a closure between the authentication of a caller and the transaction of a send, which is the
/// moment a principal can be disabled or a rule removed.
final class HookedMessageStore: MessageStore {
  let base: any MessageStore
  var beforeSend: (() throws -> Void)?

  init(base: any MessageStore) { self.base = base }

  func send(_ message: OutgoingMessage, authorize: (SendContext) throws -> Void) throws {
    if let hook = beforeSend {
      beforeSend = nil
      try hook()
    }
    try base.send(message, authorize: authorize)
  }

  func message(id: MessageID) throws -> StoredMessage? { try base.message(id: id) }
}

/// A real store with two families, their tokens, the rights and settings services and a message
/// service on top of them.
struct MessagingFixture {
  let identity: IdentityFixture
  let rights: RightsService
  let settings: SettingsService
  let messages: MessageService
  let store: HookedMessageStore
  let arrival = RecordingArrival()
  let clock = MutableClock(Date(timeIntervalSince1970: 1_800_000_000))
  let alpha: Principal
  let alphaToken: CredentialToken
  let alphaPeer: Principal
  let alphaPeerToken: CredentialToken
  let beta: Principal
  let betaToken: CredentialToken

  var owner: CredentialToken { identity.owner }

  init() throws {
    identity = try IdentityFixture()
    let service = identity.service
    let owner = identity.owner
    func enrol(_ family: String, _ name: String) throws -> (Principal, CredentialToken) {
      let principal = try service.createPrincipal(
        family: family, role: .agent, displayName: name, ownerToken: owner)
      return (principal, try service.issueCredential(for: principal.id, ownerToken: owner))
    }
    (alpha, alphaToken) = try enrol("A", "alpha")
    (alphaPeer, alphaPeerToken) = try enrol("A", "alpha peer")
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
      store: store, authenticator: service, settings: settings,
      identifiers: SequentialIdentifiers(), clock: clock, arrival: arrival)
  }

  func count(_ table: String) throws -> Int {
    try identity.raw().integer("SELECT count(*) FROM \(table)")
  }
}
