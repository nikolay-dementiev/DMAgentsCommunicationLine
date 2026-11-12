import CommunicationLineDomain
import Foundation

/// Why a settings request was refused. Nothing is stored when one of these is thrown.
public enum SettingsServiceError: Error, Equatable {
  case unknownKey(String)
  case scopeNotAllowed(key: String, scope: SettingScope)
  case subjectRequired(SettingScope)
  case subjectNotAllowed(SettingScope)
  case invalidValue(key: String, reason: SettingValueError)
  case actorRequired
}

/// Reads effective settings and applies audited changes.
public struct SettingsService {
  private let catalog: SettingsCatalog
  private let store: any SettingsStore
  private let clock: any WallClock

  public init(catalog: SettingsCatalog, store: any SettingsStore, clock: any WallClock) {
    self.catalog = catalog
    self.store = store
    self.clock = clock
  }

  /// The value that applies to a caller: principal, then family, then global, then the default.
  public func effectiveValue(
    of key: String, family: String?, principal: String?
  ) throws -> SettingValue {
    let definition = try definition(for: key)
    let stored = try store.storedValues(key: key, family: family, principal: principal)
    return definition.effectiveValue(
      principal: stored.principal, family: stored.family, global: stored.global)
  }

  /// Validates a change against the catalog and applies it with an audit record.
  ///
  /// The actor is recorded as given; deciding who may change a setting belongs to the access layer.
  public func change(
    _ address: SettingAddress, to value: SettingValue, actor: String
  ) throws -> SettingAuditRecord {
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
    guard !actor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw SettingsServiceError.actorRequired
    }
    do {
      try definition.validate(value)
    } catch let reason as SettingValueError {
      throw SettingsServiceError.invalidValue(key: address.key, reason: reason)
    }
    return try store.apply(value, to: address, actor: actor, at: clock.now())
  }

  public func auditTrail(of key: String) throws -> [SettingAuditRecord] {
    _ = try definition(for: key)
    return try store.auditRecords(key: key)
  }

  private func definition(for key: String) throws -> SettingDefinition {
    guard let definition = catalog.definition(for: key) else {
      throw SettingsServiceError.unknownKey(key)
    }
    return definition
  }
}
