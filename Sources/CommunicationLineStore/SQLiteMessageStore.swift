import CommunicationLineApplication
import CommunicationLineDomain
import Foundation

/// Stores messages and their deliveries in the SQLite database.
public final class SQLiteMessageStore: MessageStore {
  private let store: SQLiteStore
  // The send transaction reads principals and rules on the same connection that writes the message,
  // so these two readers are built here from the one store rather than injected.
  private let identity: SQLiteIdentityStore
  private let rights: SQLiteRightsStore

  public init(store: SQLiteStore) {
    self.store = store
    identity = SQLiteIdentityStore(store: store)
    rights = SQLiteRightsStore(store: store)
  }

  public func send(_ message: OutgoingMessage, authorize: (SendContext) throws -> Void) throws {
    let created = try StoreTime.milliseconds(of: message.createdAt)
    try store.database.transaction {
      var recipients: [PrincipalID: Principal] = [:]
      for id in message.recipients {
        if let principal = try identity.principal(id: id) { recipients[id] = principal }
      }
      try authorize(
        SendContext(
          sender: try identity.principal(id: message.sender), recipients: recipients,
          rules: try rights.sendRules()))
      guard !message.recipients.isEmpty else { throw MessageError.noRecipients }
      try store.database.execute(
        """
        INSERT INTO messages (id, sender, subject, body, created_at_ms)
        VALUES (?1, ?2, ?3, ?4, ?5)
        """,
        [
          .text(message.id.rawValue), .text(message.sender.rawValue), .text(message.subject),
          .text(message.body), .integer(created),
        ])
      guard
        case .integer(let sequence)? = try store.database.rows("SELECT last_insert_rowid()").first?
          .first
      else { throw StoreError.invalidStoredIdentity("new message sequence") }
      for recipient in message.recipients {
        try store.database.execute(
          "INSERT INTO deliveries (message_seq, recipient, state) VALUES (?1, ?2, 'pending')",
          [.integer(sequence), .text(recipient.rawValue)])
      }
    }
  }

  public func message(id: MessageID) throws -> StoredMessage? {
    let rows = try store.database.rows(
      """
      SELECT m.seq, m.sender, p.family, m.subject, m.body, m.created_at_ms
      FROM messages m JOIN principals p ON p.id = m.sender WHERE m.id = ?1
      """,
      [.text(id.rawValue)])
    guard let row = rows.first else { return nil }
    guard case .integer(let sequence) = row[0], case .text(let sender) = row[1],
      case .text(let family) = row[2], case .text(let subject) = row[3],
      case .text(let body) = row[4], case .integer(let milliseconds) = row[5]
    else { throw StoreError.invalidStoredIdentity("message \(id.rawValue)") }
    let recipients = try store.database.rows(
      "SELECT recipient FROM deliveries WHERE message_seq = ?1 ORDER BY rowid",
      [.integer(sequence)]
    ).map { row -> PrincipalID in
      guard case .text(let recipient) = row[0] else {
        throw StoreError.invalidStoredIdentity("delivery of message \(id.rawValue)")
      }
      return PrincipalID(recipient)
    }
    return StoredMessage(
      id: id, sender: PrincipalID(sender), family: family, recipients: recipients,
      subject: subject, body: body,
      createdAt: Date(timeIntervalSince1970: Double(milliseconds) / 1000))
  }
}
