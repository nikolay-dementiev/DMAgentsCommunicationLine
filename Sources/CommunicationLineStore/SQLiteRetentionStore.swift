import CommunicationLineApplication
import Foundation

/// Deletes what retention allows. The database triggers still refuse to delete a pending delivery or
/// a message that has one, so a wrong query here fails instead of losing mail.
public final class SQLiteRetentionStore: RetentionStore {
  private let store: SQLiteStore

  public init(store: SQLiteStore) {
    self.store = store
  }

  public func deleteAcknowledgedDeliveries(before cutoff: Date) throws -> Int {
    // A message is judged as a whole: its deliveries go together, and only when none is pending
    // and the newest acknowledgement is older than the cutoff.
    try deleted(
      """
      DELETE FROM deliveries WHERE message_seq IN (
        SELECT message_seq FROM deliveries GROUP BY message_seq
        HAVING SUM(state <> 'acknowledged') = 0 AND MAX(acknowledged_at_ms) < ?1)
      """,
      [.integer(try StoreTime.milliseconds(of: cutoff))])
  }

  public func deleteMessagesWithoutDeliveries() throws -> Int {
    try deleted(
      """
      DELETE FROM messages
      WHERE NOT EXISTS (SELECT 1 FROM deliveries WHERE deliveries.message_seq = messages.seq)
      """)
  }

  public func deleteActivity(before cutoff: Date) throws -> Int {
    let milliseconds = try StoreTime.milliseconds(of: cutoff)
    return try store.database.transaction {
      try store.database.execute("UPDATE activity_retention_gate SET open = 1")
      let count = try deleted("DELETE FROM activity WHERE at_ms < ?1", [.integer(milliseconds)])
      try store.database.execute("UPDATE activity_retention_gate SET open = 0")
      return count
    }
  }

  public func deleteActivity(beyondRows rows: Int) throws -> Int {
    try store.database.transaction {
      try store.database.execute("UPDATE activity_retention_gate SET open = 1")
      let count = try deleted(
        """
        DELETE FROM activity WHERE id <= (
          SELECT id FROM activity ORDER BY id DESC LIMIT 1 OFFSET ?1)
        """,
        [.integer(Int64(rows))])
      try store.database.execute("UPDATE activity_retention_gate SET open = 0")
      return count
    }
  }

  private func deleted(_ sql: String, _ bindings: [SQLiteValue] = []) throws -> Int {
    try store.database.transaction {
      try store.database.execute(sql, bindings)
      guard case .integer(let count)? = try store.database.rows("SELECT changes()").first?.first
      else { throw StoreError.invalidStoredValue(key: "changes") }
      return Int(count)
    }
  }
}

/// Reads how much of the database file holds data.
public final class SQLiteStorageStore: StorageStore {
  private let store: SQLiteStore

  public init(store: SQLiteStore) {
    self.store = store
  }

  public func usedBytes() throws -> Int64 {
    let pageSize = try number("PRAGMA page_size")
    let pages = try number("PRAGMA page_count")
    let free = try number("PRAGMA freelist_count")
    return max(0, pages - free) * pageSize
  }

  private func number(_ pragma: String) throws -> Int64 {
    guard case .integer(let value)? = try store.database.rows(pragma).first?.first else {
      throw StoreError.invalidStoredValue(key: pragma)
    }
    return value
  }
}
