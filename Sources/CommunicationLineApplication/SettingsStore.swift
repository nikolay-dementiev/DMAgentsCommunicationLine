import CommunicationLineDomain
import Foundation

/// What the settings use cases need from persistence.
public protocol SettingsStore {
  /// The stored value of `key` in each scope that applies to the given family and principal.
  func storedValues(key: String, family: String?, principal: String?) throws -> StoredSettingValues

  /// Replaces the value at `address` and appends the audit record in one transaction.
  func apply(
    _ value: SettingValue, to address: SettingAddress, actor: String, at instant: Date
  ) throws -> SettingAuditRecord

  /// The audit records of `key`, oldest first.
  func auditRecords(key: String) throws -> [SettingAuditRecord]
}
