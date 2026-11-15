import CommunicationLineApplication
import CommunicationLineDomain
import Foundation

/// Reads the principals and their pending mail in one statement.
public final class SQLiteDirectoryStore: PrincipalDirectoryStore {
  private let store: SQLiteStore

  public init(store: SQLiteStore) {
    self.store = store
  }

  public func principals(family: String?) throws -> [PrincipalSummary] {
    try store.database.rows(
      """
      SELECT p.id, p.family, p.role, p.display_name, p.enabled,
             (SELECT COUNT(*) FROM deliveries d WHERE d.recipient = p.id AND d.state = 'pending')
      FROM principals p
      WHERE ?1 IS NULL OR p.family = ?1
      ORDER BY p.family, p.role, p.display_name, p.id
      """,
      [family.map { .text($0) } ?? .null]
    ).map { row in
      guard case .text(let id) = row[0], case .text(let family) = row[1],
        case .text(let roleName) = row[2], let role = RoleKind(rawValue: roleName),
        case .text(let name) = row[3], case .integer(let enabled) = row[4],
        case .integer(let pending) = row[5], let count = Int(exactly: pending)
      else { throw StoreError.invalidStoredIdentity("principal listing") }
      return PrincipalSummary(
        principal: Principal(
          id: PrincipalID(id), family: family, role: role, displayName: name,
          isEnabled: enabled == 1), pending: count)
    }
  }
}
