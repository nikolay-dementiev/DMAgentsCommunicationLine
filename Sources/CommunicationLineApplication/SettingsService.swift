import CommunicationLineDomain
import Foundation

/// Why a settings request was refused. Nothing is stored when one of these is thrown.
public enum SettingsServiceError: Error, Equatable {
  case unknownKey(String)
  case scopeNotAllowed(key: String, scope: SettingScope)
  case subjectRequired(SettingScope)
  case subjectNotAllowed(SettingScope)
  case invalidValue(key: String, reason: SettingValueError)
}

/// Reads the effective value of a setting for the caller a token belongs to.
public protocol SettingsReading {
  func effectiveValue(of key: String, token: CredentialToken) throws -> SettingValue
}

extension SettingsService: SettingsReading {}

/// Reads effective settings and applies audited changes.
public struct SettingsService {
  /// The actor recorded in the audit trail for every change: only the owner may change settings.
  public static let ownerActor = "owner"

  private let catalog: SettingsCatalog
  private let store: any SettingsStore
  private let clock: any WallClock
  private let authenticator: any Authenticating

  public init(
    catalog: SettingsCatalog, store: any SettingsStore, clock: any WallClock,
    authenticator: any Authenticating
  ) {
    self.catalog = catalog
    self.store = store
    self.clock = clock
    self.authenticator = authenticator
  }

  /// The value that applies to the caller the token belongs to: that principal, its family, global,
  /// then the default. The owner sees global values and defaults.
  public func effectiveValue(of key: String, token: CredentialToken) throws -> SettingValue {
    let actor = try authenticator.authenticate(token)
    let definition = try definition(for: key)
    var family: String?
    var principal: String?
    if case .principal(let caller) = actor {
      family = caller.family
      principal = caller.id.rawValue
    }
    let stored = try store.storedValues(key: key, family: family, principal: principal)
    return definition.effectiveValue(
      principal: stored.principal, family: stored.family, global: stored.global)
  }

  /// Validates a change against the catalog and applies it with an audit record. Only the owner's
  /// token is accepted; the owner is the audited actor.
  public func change(
    _ address: SettingAddress, to value: SettingValue, ownerToken: CredentialToken
  ) throws -> SettingAuditRecord {
    try requireOwner(ownerToken)
    let definition = try definition(for: address.key)
    guard definition.scopes.contains(address.scope) else {
      throw SettingsServiceError.scopeNotAllowed(key: address.key, scope: address.scope)
    }
    let hasSubject = !(address.subject ?? "").isEmpty
    if address.scope == .global, address.subject != nil {
      throw SettingsServiceError.subjectNotAllowed(address.scope)
    }
    if address.scope != .global, !hasSubject {
      throw SettingsServiceError.subjectRequired(address.scope)
    }
    do {
      try definition.validate(value)
    } catch let reason as SettingValueError {
      throw SettingsServiceError.invalidValue(key: address.key, reason: reason)
    }
    return try store.apply(value, to: address, actor: Self.ownerActor, at: clock.now())
  }

  public func auditTrail(of key: String, ownerToken: CredentialToken) throws
    -> [SettingAuditRecord]
  {
    try requireOwner(ownerToken)
    _ = try definition(for: key)
    return try store.auditRecords(key: key)
  }

  private func requireOwner(_ token: CredentialToken) throws {
    guard case .owner = try authenticator.authenticate(token) else {
      throw IdentityError.ownerCredentialRequired
    }
  }

  private func definition(for key: String) throws -> SettingDefinition {
    guard let definition = catalog.definition(for: key) else {
      throw SettingsServiceError.unknownKey(key)
    }
    return definition
  }
}
