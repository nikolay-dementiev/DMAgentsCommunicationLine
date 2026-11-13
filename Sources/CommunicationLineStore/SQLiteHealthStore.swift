import CommunicationLineApplication
import CommunicationLineDomain
import Foundation

/// Reads the pending mail the health report needs.
public final class SQLiteHealthStore: HealthStore {
  private let store: SQLiteStore

  public init(store: SQLiteStore) {
    self.store = store
  }

  public func pendingCounts() throws -> [PendingCount] {
    try store.database.rows(
      """
      SELECT recipient, COUNT(*) FROM deliveries WHERE state = 'pending'
      GROUP BY recipient ORDER BY recipient
      """
    ).map { row in
      guard case .text(let recipient) = row[0], case .integer(let count) = row[1],
        let size = Int(exactly: count)
      else { throw StoreError.invalidStoredIdentity("pending count") }
      return PendingCount(principal: PrincipalID(recipient), count: size)
    }
  }

  public func pendingDeliveries(createdBefore cutoff: Date) throws -> [PendingDelivery] {
    try store.database.rows(
      """
      SELECT m.id, d.recipient, p.family, m.created_at_ms
      FROM deliveries d
      JOIN messages m ON m.seq = d.message_seq
      JOIN principals p ON p.id = d.recipient
      WHERE d.state = 'pending' AND m.created_at_ms < ?1
      ORDER BY m.created_at_ms, d.rowid
      """,
      [.integer(try StoreTime.milliseconds(of: cutoff))]
    ).map { row in
      guard case .text(let message) = row[0], case .text(let recipient) = row[1],
        case .text(let family) = row[2], case .integer(let created) = row[3]
      else { throw StoreError.invalidStoredIdentity("pending delivery") }
      return PendingDelivery(
        message: MessageID(message), recipient: PrincipalID(recipient), recipientFamily: family,
        createdAt: Date(timeIntervalSince1970: Double(created) / 1000))
    }
  }
}
