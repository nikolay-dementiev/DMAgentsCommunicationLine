import CommunicationLineApplication
import CommunicationLineDomain
import Foundation

/// Stores setting values and their audit trail in the SQLite database.
public final class SQLiteSettingsStore: SettingsStore {
  private let store: SQLiteStore

  public init(store: SQLiteStore) {
    self.store = store
  }

  public func storedValues(
    key: String, family: String?, principal: String?
  ) throws -> StoredSettingValues {
    let rows = try store.database.rows(
      """
      SELECT scope, value FROM settings_values
      WHERE key = ?1 AND (
        (scope = 'global' AND subject = '')
        OR (scope = 'family' AND subject = ?2)
        OR (scope = 'principal' AND subject = ?3))
      """,
      [.text(key), .text(family ?? ""), .text(principal ?? "")])
    var byScope: [String: SettingValue] = [:]
    for row in rows {
      guard case .text(let scope) = row[0], case .text(let json) = row[1] else {
        throw StoreError.invalidStoredValue(key: key)
      }
      byScope[scope] = try Self.decode(json, key: key)
    }
    return StoredSettingValues(
      principal: byScope["principal"], family: byScope["family"], global: byScope["global"])
  }

  public func apply(
    _ value: SettingValue, to address: SettingAddress, actor: String, at instant: Date
  ) throws -> SettingAuditRecord {
    let subject = address.subject ?? ""
    let newJSON = try Self.encode(value)
    return try store.database.transaction {
      let previous = try store.database.rows(
        "SELECT value FROM settings_values WHERE key = ?1 AND scope = ?2 AND subject = ?3",
        [.text(address.key), .text(address.scope.rawValue), .text(subject)])
      var oldValue: SettingValue?
      if case .text(let json)? = previous.first?.first {
        oldValue = try Self.decode(json, key: address.key)
      }
      try store.database.execute(
        """
        INSERT INTO settings_values (key, scope, subject, value) VALUES (?1, ?2, ?3, ?4)
        ON CONFLICT (key, scope, subject) DO UPDATE SET value = excluded.value
        """,
        [.text(address.key), .text(address.scope.rawValue), .text(subject), .text(newJSON)])
      try store.database.execute(
        """
        INSERT INTO settings_audit (at_ms, actor, key, scope, subject, old_value, new_value)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
        """,
        [
          .integer(Self.milliseconds(of: instant)), .text(actor), .text(address.key),
          .text(address.scope.rawValue), .text(subject),
          try oldValue.map { .text(try Self.encode($0)) } ?? .null, .text(newJSON),
        ])
      return SettingAuditRecord(
        at: instant, actor: actor, address: address, oldValue: oldValue, newValue: value)
    }
  }

  public func auditRecords(key: String) throws -> [SettingAuditRecord] {
    let rows = try store.database.rows(
      """
      SELECT at_ms, actor, scope, subject, old_value, new_value
      FROM settings_audit WHERE key = ?1 ORDER BY id
      """, [.text(key)])
    return try rows.map { row in
      guard case .integer(let ms) = row[0], case .text(let actor) = row[1],
        case .text(let scopeName) = row[2], let scope = SettingScope(rawValue: scopeName),
        case .text(let subject) = row[3], case .text(let newJSON) = row[5]
      else { throw StoreError.invalidStoredValue(key: key) }
      var oldValue: SettingValue?
      if case .text(let oldJSON) = row[4] { oldValue = try Self.decode(oldJSON, key: key) }
      return SettingAuditRecord(
        at: Date(timeIntervalSince1970: Double(ms) / 1000), actor: actor,
        address: SettingAddress(
          key: key, scope: scope, subject: subject.isEmpty ? nil : subject),
        oldValue: oldValue, newValue: try Self.decode(newJSON, key: key))
    }
  }

  private static func milliseconds(of instant: Date) -> Int64 {
    Int64((instant.timeIntervalSince1970 * 1000).rounded())
  }

  private static func encode(_ value: SettingValue) throws -> String {
    String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
  }

  private static func decode(_ json: String, key: String) throws -> SettingValue {
    do {
      return try JSONDecoder().decode(SettingValue.self, from: Data(json.utf8))
    } catch {
      throw StoreError.invalidStoredValue(key: key)
    }
  }
}
