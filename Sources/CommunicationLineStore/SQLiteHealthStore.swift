import CommunicationLineApplication
import CommunicationLineDomain
import Foundation

/// Reads the pending mail the health report needs.
public final class SQLiteHealthStore: HealthStore {
  private let store: SQLiteStore

  public init(store: SQLiteStore) {
    self.store = store
  }

  public func pendingRecipients() throws -> [PendingRecipient] {
    try store.database.rows(
      """
      SELECT d.recipient, p.family, COUNT(*)
      FROM deliveries d JOIN principals p ON p.id = d.recipient
      WHERE d.state = 'pending'
      GROUP BY d.recipient ORDER BY d.recipient
      """
    ).map { row in
      guard case .text(let recipient) = row[0], case .text(let family) = row[1],
        case .integer(let count) = row[2], let size = Int(exactly: count)
      else { throw StoreError.invalidStoredIdentity("pending count") }
      return PendingRecipient(principal: PrincipalID(recipient), family: family, count: size)
    }
  }

  public func overdue(of recipient: PrincipalID, createdAtOrBefore cutoff: Date, limit: Int) throws
    -> OverdueSlice
  {
    let cutoffMilliseconds = try StoreTime.milliseconds(of: cutoff)
    let totals = try store.database.rows(
      """
      SELECT COUNT(*) FROM deliveries d JOIN messages m ON m.seq = d.message_seq
      WHERE d.state = 'pending' AND d.recipient = ?1 AND m.created_at_ms <= ?2
      """,
      [.text(recipient.rawValue), .integer(cutoffMilliseconds)])
    guard case .integer(let total)? = totals.first?[0], let count = Int(exactly: total) else {
      throw StoreError.invalidStoredIdentity("overdue count")
    }
    let rows = try store.database.rows(
      """
      SELECT m.id, m.created_at_ms, d.rowid
      FROM deliveries d JOIN messages m ON m.seq = d.message_seq
      WHERE d.state = 'pending' AND d.recipient = ?1 AND m.created_at_ms <= ?2
      ORDER BY m.created_at_ms, d.rowid LIMIT ?3
      """,
      [.text(recipient.rawValue), .integer(cutoffMilliseconds), .integer(Int64(limit))]
    ).map { row in
      guard case .text(let message) = row[0], case .integer(let created) = row[1],
        case .integer(let sequence) = row[2]
      else { throw StoreError.invalidStoredIdentity("pending delivery") }
      return PendingDelivery(
        message: MessageID(message), recipient: recipient,
        createdAt: Date(timeIntervalSince1970: Double(created) / 1000), sequence: sequence)
    }
    return OverdueSlice(total: count, oldest: rows)
  }
}
