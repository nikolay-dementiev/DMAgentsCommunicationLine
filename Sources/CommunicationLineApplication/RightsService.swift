import CommunicationLineDomain
import Foundation

/// Owner-managed send rules and read grants, and the access decisions that use them. The owner's
/// token is required to read or change a rule or grant; every decision derives the caller from the
/// token it is given.
public struct RightsService {
  private let rights: any RightsStore
  private let principals: any IdentityStore
  private let authenticator: any Authenticating
  private let clock: any WallClock

  public init(
    rights: any RightsStore, principals: any IdentityStore, authenticator: any Authenticating,
    clock: any WallClock
  ) {
    self.rights = rights
    self.principals = principals
    self.authenticator = authenticator
    self.clock = clock
  }

  // MARK: - Owner operations

  public func allowSending(from: String, to: String, ownerToken: CredentialToken) throws {
    try requireOwner(ownerToken)
    let rule = try Self.rule(from: from, to: to)
    try rights.addSendRule(rule, at: clock.now())
  }

  public func removeSendRule(from: String, to: String, ownerToken: CredentialToken) throws {
    try requireOwner(ownerToken)
    try rights.removeSendRule(try Self.rule(from: from, to: to))
  }

  /// The target is required: a grant that opens all mail has to be asked for as `.global`.
  public func addReadGrant(
    reader: GrantReader, target: GrantTarget, expiresAt: Date?, ownerToken: CredentialToken
  ) throws -> Int64 {
    try requireOwner(ownerToken)
    switch reader {
    case .principal(let id): guard !Self.isBlank(id.rawValue) else { throw RightsError.invalidRule }
    case .family(let name): guard !Self.isBlank(name) else { throw RightsError.invalidRule }
    }
    switch target {
    case .principal(let id): guard !Self.isBlank(id.rawValue) else { throw RightsError.invalidRule }
    case .family(let name): guard !Self.isBlank(name) else { throw RightsError.invalidRule }
    case .global: break
    }
    let now = clock.now()
    if let expiresAt, expiresAt <= now { throw RightsError.expiryInThePast }
    return try rights.addReadGrant(reader: reader, target: target, expiresAt: expiresAt, at: now)
  }

  public func revokeReadGrant(id: Int64, ownerToken: CredentialToken) throws {
    try requireOwner(ownerToken)
    guard try rights.readGrants().contains(where: { $0.id == id }) else {
      throw RightsError.unknownGrant(id)
    }
    try rights.revokeReadGrant(id: id, at: clock.now())
  }

  public func sendRules(ownerToken: CredentialToken) throws -> [SendRule] {
    try requireOwner(ownerToken)
    return try rights.sendRules()
  }

  public func readGrants(ownerToken: CredentialToken) throws -> [StoredReadGrant] {
    try requireOwner(ownerToken)
    return try rights.readGrants()
  }

  // MARK: - Decisions for a principal

  public func effectiveRights(token: CredentialToken) throws -> EffectiveRights {
    let principal = try requirePrincipal(token)
    let targets = try rights.sendRules().filter { $0.fromFamily == principal.family }.map(
      \.toFamily)
    let now = clock.now()
    let applicable = try rights.readGrants().map(\.grant).filter { grant in
      guard !grant.isRevoked, grant.expiresAt.map({ $0 > now }) ?? true else { return false }
      switch grant.reader {
      case .principal(let id): return id == principal.id
      case .family(let family): return family == principal.family
      }
    }
    return EffectiveRights(
      family: principal.family, canSendToFamilies: Set(targets).union([principal.family]),
      readGrants: applicable)
  }

  public func canSend(token: CredentialToken, to recipient: PrincipalID) throws -> Bool {
    let sender = try requirePrincipal(token)
    guard let target = try principals.principal(id: recipient) else {
      throw IdentityError.unknownPrincipal(recipient)
    }
    return AccessPolicy.canSend(from: sender, to: target, rules: try rights.sendRules())
  }

  public func canRead(token: CredentialToken, meta: MessageMeta) throws -> Bool {
    let reader = try requirePrincipal(token)
    return AccessPolicy.canRead(
      principal: reader, meta: meta, grants: try rights.readGrants().map(\.grant),
      now: clock.now())
  }

  // MARK: - Helpers

  private func requireOwner(_ token: CredentialToken) throws {
    guard case .owner = try authenticator.authenticate(token) else {
      throw IdentityError.ownerCredentialRequired
    }
  }

  private func requirePrincipal(_ token: CredentialToken) throws -> Principal {
    guard case .principal(let principal) = try authenticator.authenticate(token) else {
      throw IdentityError.principalCredentialRequired
    }
    return principal
  }

  private static func isBlank(_ text: String) -> Bool {
    text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private static func rule(from: String, to: String) throws -> SendRule {
    let source = from.trimmingCharacters(in: .whitespacesAndNewlines)
    let target = to.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !source.isEmpty, !target.isEmpty, source != target else { throw RightsError.invalidRule }
    return SendRule(fromFamily: source, toFamily: target)
  }
}
