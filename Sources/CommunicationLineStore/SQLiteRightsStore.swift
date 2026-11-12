import CommunicationLineApplication
import CommunicationLineDomain
import Foundation

/// Stores send rules and read grants in the SQLite database.
public final class SQLiteRightsStore: RightsStore {
  private let store: SQLiteStore

  public init(store: SQLiteStore) {
    self.store = store
  }

  public func addSendRule(_ rule: SendRule, at instant: Date) throws {
    try store.database.execute(
      "INSERT OR IGNORE INTO send_rules (from_family, to_family, created_at_ms) VALUES (?1, ?2, ?3)",
      [
        .text(rule.fromFamily), .text(rule.toFamily),
        .integer(try StoreTime.milliseconds(of: instant)),
      ])
  }

  public func removeSendRule(_ rule: SendRule) throws {
    try store.database.execute(
      "DELETE FROM send_rules WHERE from_family = ?1 AND to_family = ?2",
      [.text(rule.fromFamily), .text(rule.toFamily)])
  }

  public func sendRules() throws -> [SendRule] {
    try store.database.rows(
      "SELECT from_family, to_family FROM send_rules ORDER BY from_family, to_family"
    ).map { row in
      guard case .text(let from) = row[0], case .text(let to) = row[1] else {
        throw StoreError.invalidStoredIdentity("send rule")
      }
      return SendRule(fromFamily: from, toFamily: to)
    }
  }

  public func addReadGrant(reader: GrantReader, expiresAt: Date?, at instant: Date) throws -> Int64
  {
    let kind: String
    let name: String
    switch reader {
    case .principal(let id):
      kind = "principal"
      name = id.rawValue
    case .family(let family):
      kind = "family"
      name = family
    }
    let created = try StoreTime.milliseconds(of: instant)
    let expiry = try expiresAt.map { SQLiteValue.integer(try StoreTime.milliseconds(of: $0)) }
    return try store.database.transaction {
      try store.database.execute(
        """
        INSERT INTO read_grants (reader_kind, reader, expires_at_ms, created_at_ms)
        VALUES (?1, ?2, ?3, ?4)
        """,
        [.text(kind), .text(name), expiry ?? .null, .integer(created)])
      guard
        case .integer(let id)? = try store.database.rows("SELECT last_insert_rowid()").first?
          .first
      else { throw StoreError.invalidStoredIdentity("new read grant id") }
      return id
    }
  }

  public func revokeReadGrant(id: Int64, at instant: Date) throws {
    try store.database.execute(
      "UPDATE read_grants SET revoked_at_ms = ?2 WHERE id = ?1 AND revoked_at_ms IS NULL",
      [.integer(id), .integer(try StoreTime.milliseconds(of: instant))])
  }

  public func readGrants() throws -> [StoredReadGrant] {
    try store.database.rows(
      "SELECT id, reader_kind, reader, expires_at_ms, revoked_at_ms FROM read_grants ORDER BY id"
    ).map { row in
      guard case .integer(let id) = row[0], case .text(let kind) = row[1],
        case .text(let name) = row[2]
      else { throw StoreError.invalidStoredIdentity("read grant") }
      let reader: GrantReader
      switch kind {
      case "principal": reader = .principal(PrincipalID(name))
      case "family": reader = .family(name)
      default: throw StoreError.invalidStoredIdentity("read grant reader kind \(kind)")
      }
      var expiry: Date?
      if case .integer(let milliseconds) = row[3] {
        expiry = Date(timeIntervalSince1970: Double(milliseconds) / 1000)
      }
      return StoredReadGrant(
        id: id, grant: ReadGrant(reader: reader, expiresAt: expiry, isRevoked: row[4] != .null))
    }
  }
}
