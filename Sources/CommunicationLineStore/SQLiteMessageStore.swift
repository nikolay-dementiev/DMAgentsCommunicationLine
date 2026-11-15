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
      var pending: [PrincipalID: Int] = [:]
      for id in message.recipients {
        if let principal = try identity.principal(id: id) {
          recipients[id] = principal
          pending[id] = try pendingCount(for: id)
        }
      }
      try authorize(
        SendContext(
          sender: try identity.principal(id: message.sender), recipients: recipients,
          rules: try rights.sendRules(), pendingCounts: pending))
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

  /// The kept count of the recipient's pending deliveries: one primary-key read, taken inside the
  /// send transaction, so it cannot change before the same transaction inserts.
  private func pendingCount(for recipient: PrincipalID) throws -> Int {
    let rows = try store.database.rows(
      "SELECT count FROM pending_counts WHERE recipient = ?1", [.text(recipient.rawValue)])
    guard let row = rows.first else { return 0 }
    guard case .integer(let count)? = row.first, let size = Int(exactly: count) else {
      throw StoreError.invalidStoredIdentity("pending count of \(recipient.rawValue)")
    }
    return size
  }

  public func message(id: MessageID) throws -> StoredMessage? {
    // One statement is one snapshot: the message and its recipients cannot disagree.
    let rows = try store.database.rows(
      """
      SELECT m.seq, m.sender, p.family, m.subject, m.body, m.created_at_ms, d.recipient
      FROM messages m
      JOIN principals p ON p.id = m.sender
      LEFT JOIN deliveries d ON d.message_seq = m.seq
      WHERE m.id = ?1
      ORDER BY d.rowid
      """,
      [.text(id.rawValue)])
    guard let row = rows.first else { return nil }
    guard case .text(let sender) = row[1],
      case .text(let family) = row[2], case .text(let subject) = row[3],
      case .text(let body) = row[4], case .integer(let milliseconds) = row[5]
    else { throw StoreError.invalidStoredIdentity("message \(id.rawValue)") }
    let recipients = try rows.compactMap { row -> PrincipalID? in
      switch row[6] {
      case .null: return nil
      case .text(let recipient): return PrincipalID(recipient)
      case .integer: throw StoreError.invalidStoredIdentity("delivery of message \(id.rawValue)")
      }
    }
    return StoredMessage(
      id: id, sender: PrincipalID(sender), family: family, recipients: recipients,
      subject: subject, body: body,
      createdAt: Date(timeIntervalSince1970: Double(milliseconds) / 1000))
  }

  public func inbox(for recipient: PrincipalID, after cursor: InboxCursor?, limit: Int) throws
    -> InboxPage
  {
    guard limit >= 1, limit < Int.max else { throw MessagingError.invalidPageLimit(limit) }
    let rows = try store.database.rows(
      """
      SELECT m.seq, m.id, m.sender, m.subject, m.created_at_ms
      FROM deliveries d JOIN messages m ON m.seq = d.message_seq
      WHERE d.recipient = ?1 AND d.state = 'pending' AND d.message_seq > ?2
      ORDER BY d.message_seq LIMIT ?3
      """,
      [.text(recipient.rawValue), .integer(cursor?.sequence ?? 0), .integer(Int64(limit) + 1)])
    var entries: [InboxEntry] = []
    var lastSequence: Int64 = 0
    for row in rows.prefix(limit) {
      guard case .integer(let sequence) = row[0], case .text(let id) = row[1],
        case .text(let sender) = row[2], case .text(let subject) = row[3],
        case .integer(let milliseconds) = row[4]
      else { throw StoreError.invalidStoredIdentity("inbox entry of \(recipient.rawValue)") }
      lastSequence = sequence
      entries.append(
        InboxEntry(
          messageID: MessageID(id), sender: PrincipalID(sender), subject: subject,
          createdAt: Date(timeIntervalSince1970: Double(milliseconds) / 1000)))
    }
    let hasMore = rows.count > limit
    return InboxPage(entries: entries, next: hasMore ? InboxCursor(sequence: lastSequence) : nil)
  }

  public func acknowledge(messageID: MessageID, recipient: PrincipalID, at instant: Date) throws
    -> AcknowledgeOutcome
  {
    let milliseconds = try StoreTime.milliseconds(of: instant)
    return try store.database.transaction {
      let rows = try store.database.rows(
        """
        SELECT d.message_seq, d.state FROM deliveries d JOIN messages m ON m.seq = d.message_seq
        WHERE m.id = ?1 AND d.recipient = ?2
        """,
        [.text(messageID.rawValue), .text(recipient.rawValue)])
      guard let row = rows.first else { return .notRecipient }
      guard case .integer(let sequence) = row[0], case .text(let state) = row[1] else {
        throw StoreError.invalidStoredIdentity("delivery of message \(messageID.rawValue)")
      }
      guard state == DeliveryState.pending.rawValue else { return .alreadyAcknowledged }
      try store.database.execute(
        """
        UPDATE deliveries SET state = 'acknowledged', acknowledged_at_ms = ?3
        WHERE message_seq = ?1 AND recipient = ?2 AND state = 'pending'
        """,
        [.integer(sequence), .text(recipient.rawValue), .integer(milliseconds)])
      return .acknowledged
    }
  }

  public func hasPending(for recipient: PrincipalID) throws -> Bool {
    let rows = try store.database.rows(
      "SELECT 1 FROM deliveries WHERE recipient = ?1 AND state = 'pending' LIMIT 1",
      [.text(recipient.rawValue)])
    return !rows.isEmpty
  }
}
