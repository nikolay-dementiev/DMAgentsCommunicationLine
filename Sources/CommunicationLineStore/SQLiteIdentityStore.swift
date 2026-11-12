import CommunicationLineApplication
import CommunicationLineDomain
import Foundation

/// Stores principals and credential digests in the SQLite database.
public final class SQLiteIdentityStore: IdentityStore {
  private let store: SQLiteStore

  public init(store: SQLiteStore) {
    self.store = store
  }

  public func insertPrincipal(_ principal: Principal, at instant: Date) throws {
    try store.database.execute(
      """
      INSERT INTO principals (id, family, role, display_name, enabled, created_at_ms)
      VALUES (?1, ?2, ?3, ?4, ?5, ?6)
      """,
      [
        .text(principal.id.rawValue), .text(principal.family), .text(principal.role.rawValue),
        .text(principal.displayName), .integer(principal.isEnabled ? 1 : 0),
        .integer(try StoreTime.milliseconds(of: instant)),
      ])
  }

  public func principal(id: PrincipalID) throws -> Principal? {
    let rows = try store.database.rows(
      "SELECT id, family, role, display_name, enabled FROM principals WHERE id = ?1",
      [.text(id.rawValue)])
    guard let row = rows.first else { return nil }
    guard case .text(let rawID) = row[0], case .text(let family) = row[1],
      case .text(let roleName) = row[2], let role = RoleKind(rawValue: roleName),
      case .text(let name) = row[3], case .integer(let enabled) = row[4]
    else { throw StoreError.invalidStoredIdentity("principal \(id.rawValue)") }
    return Principal(
      id: PrincipalID(rawID), family: family, role: role, displayName: name,
      isEnabled: enabled == 1)
  }

  public func enable(_ id: PrincipalID) throws {
    try store.database.execute(
      "UPDATE principals SET enabled = 1 WHERE id = ?1", [.text(id.rawValue)])
  }

  public func disable(_ id: PrincipalID, at instant: Date) throws {
    let milliseconds = try StoreTime.milliseconds(of: instant)
    try store.database.transaction {
      try store.database.execute(
        "UPDATE principals SET enabled = 0 WHERE id = ?1", [.text(id.rawValue)])
      try store.database.execute(
        "UPDATE credentials SET revoked_at_ms = ?2 WHERE principal_id = ?1 AND revoked_at_ms IS NULL",
        [.text(id.rawValue), .integer(milliseconds)])
    }
  }

  public func insertCredential(
    digest: TokenDigest, kind: StoredCredentialKind, at instant: Date
  ) throws {
    try Self.insert(digest: digest, kind: kind, at: instant, into: store.database)
  }

  public func credential(digest: TokenDigest) throws -> StoredCredential? {
    let rows = try store.database.rows(
      "SELECT kind, principal_id, revoked_at_ms FROM credentials WHERE digest = ?1",
      [.text(digest.hex)])
    guard let row = rows.first else { return nil }
    guard case .text(let kindName) = row[0] else {
      throw StoreError.invalidStoredIdentity("credential kind")
    }
    let kind: StoredCredentialKind
    switch (kindName, row[1]) {
    case ("owner", .null): kind = .owner
    case ("principal", .text(let id)): kind = .principal(PrincipalID(id))
    default: throw StoreError.invalidStoredIdentity("credential kind \(kindName)")
    }
    return StoredCredential(digest: digest, kind: kind, isRevoked: row[2] != .null)
  }

  public func hasActiveOwnerCredential() throws -> Bool {
    let rows = try store.database.rows(
      "SELECT count(*) FROM credentials WHERE kind = 'owner' AND revoked_at_ms IS NULL")
    guard case .integer(let count)? = rows.first?.first else {
      throw StoreError.invalidStoredIdentity("owner credential count")
    }
    return count > 0
  }

  public func replaceOwnerCredential(with digest: TokenDigest, at instant: Date) throws {
    let milliseconds = try StoreTime.milliseconds(of: instant)
    try store.database.transaction {
      try store.database.execute(
        "UPDATE credentials SET revoked_at_ms = ?1 WHERE kind = 'owner' AND revoked_at_ms IS NULL",
        [.integer(milliseconds)])
      try Self.insert(digest: digest, kind: .owner, at: instant, into: store.database)
    }
  }

  private static func insert(
    digest: TokenDigest, kind: StoredCredentialKind, at instant: Date, into database: SQLiteDatabase
  ) throws {
    let kindName: String
    let principal: SQLiteValue
    switch kind {
    case .owner:
      kindName = "owner"
      principal = .null
    case .principal(let id):
      kindName = "principal"
      principal = .text(id.rawValue)
    }
    try database.execute(
      "INSERT INTO credentials (digest, kind, principal_id, issued_at_ms) VALUES (?1, ?2, ?3, ?4)",
      [
        .text(digest.hex), .text(kindName), principal,
        .integer(try StoreTime.milliseconds(of: instant)),
      ]
    )
  }
}
