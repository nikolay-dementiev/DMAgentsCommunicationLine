import Foundation

/// Names one stored value: a key in a scope, and for the family and principal scopes the subject.
public struct SettingAddress: Equatable, Sendable {
  public let key: String
  public let scope: SettingScope
  public let subject: String?

  public init(key: String, scope: SettingScope, subject: String?) {
    self.key = key
    self.scope = scope
    self.subject = subject
  }
}

/// The stored values of one key that can apply to a caller, one per scope.
public struct StoredSettingValues: Equatable, Sendable {
  public let principal: SettingValue?
  public let family: SettingValue?
  public let global: SettingValue?

  public init(principal: SettingValue?, family: SettingValue?, global: SettingValue?) {
    self.principal = principal
    self.family = family
    self.global = global
  }
}

/// One row of the append-only audit trail of setting changes.
///
/// `oldValue` is the value stored at exactly this address before the change, or `nil` when the
/// address held no stored value (the default applied).
public struct SettingAuditRecord: Equatable, Sendable {
  public let at: Date
  public let actor: String
  public let address: SettingAddress
  public let oldValue: SettingValue?
  public let newValue: SettingValue

  public init(
    at: Date, actor: String, address: SettingAddress, oldValue: SettingValue?,
    newValue: SettingValue
  ) {
    self.at = at
    self.actor = actor
    self.address = address
    self.oldValue = oldValue
    self.newValue = newValue
  }
}
