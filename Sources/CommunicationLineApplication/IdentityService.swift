import CommunicationLineDomain
import Foundation

/// Creates principals, issues credentials and authenticates callers. Owner operations take the
/// owner's token; no operation takes an identity chosen by the caller.
public struct IdentityService: Authenticating {
  private let store: any IdentityStore
  private let random: any RandomSource
  private let identifiers: any IdentifierSource
  private let clock: any WallClock

  public init(
    store: any IdentityStore, random: any RandomSource, identifiers: any IdentifierSource,
    clock: any WallClock
  ) {
    self.store = store
    self.random = random
    self.identifiers = identifiers
    self.clock = clock
  }

  // MARK: - Authentication

  public func authenticate(_ token: CredentialToken) throws -> AuthenticatedActor {
    let presented = token.digest
    guard let credential = try store.credential(digest: presented), credential.digest == presented
    else { throw IdentityError.unknownToken }
    switch credential.kind {
    case .owner:
      guard !credential.isRevoked else { throw IdentityError.tokenRevoked }
      return .owner
    case .principal(let id):
      guard let principal = try store.principal(id: id) else { throw IdentityError.unknownToken }
      guard principal.isEnabled else { throw IdentityError.principalDisabled }
      guard !credential.isRevoked else { throw IdentityError.tokenRevoked }
      return .principal(principal)
    }
  }

  /// Accepts the owner's token and nothing else; an agent's token is refused.
  public func authenticateOwner(_ token: CredentialToken) throws {
    guard case .owner = try authenticate(token) else {
      throw IdentityError.ownerCredentialRequired
    }
  }

  // MARK: - Owner credential

  /// Issues the first owner credential, or replaces the current one when `current` is the owner's
  /// valid token. The old owner token stops working.
  public func issueOwnerCredential(replacing current: CredentialToken?) throws -> CredentialToken {
    var expected: TokenDigest?
    if try store.hasActiveOwnerCredential() {
      guard let current else { throw IdentityError.ownerCredentialRequired }
      try authenticateOwner(current)
      expected = current.digest
    }
    let token = try newToken()
    try store.replaceOwnerCredential(
      expectedCurrent: expected, with: token.digest, at: clock.now())
    return token
  }

  // MARK: - Principals

  public func createPrincipal(
    family: String, role: RoleKind, displayName: String, ownerToken: CredentialToken
  ) throws -> Principal {
    try authenticateOwner(ownerToken)
    let trimmedFamily = family.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedFamily.isEmpty else { throw IdentityError.invalidName(field: "family") }
    guard !trimmedName.isEmpty else { throw IdentityError.invalidName(field: "displayName") }
    let principal = Principal(
      id: identifiers.newPrincipalID(), family: trimmedFamily, role: role,
      displayName: trimmedName, isEnabled: true)
    try store.insertPrincipal(principal, at: clock.now())
    return principal
  }

  /// Issues a credential and returns its token; this is the only time the token exists in the product.
  public func issueCredential(
    for id: PrincipalID, ownerToken: CredentialToken
  ) throws -> CredentialToken {
    try authenticateOwner(ownerToken)
    let principal = try existingPrincipal(id)
    guard principal.isEnabled else { throw IdentityError.principalDisabled }
    let token = try newToken()
    try store.insertPrincipalCredential(digest: token.digest, for: id, at: clock.now())
    return token
  }

  /// Takes effect at once and revokes the principal's credentials.
  public func disablePrincipal(_ id: PrincipalID, ownerToken: CredentialToken) throws {
    try authenticateOwner(ownerToken)
    _ = try existingPrincipal(id)
    try store.disable(id, at: clock.now())
  }

  /// Enables a disabled principal again. Its old credentials stay revoked; it needs a new one. Enabling an enabled principal changes nothing.
  public func enablePrincipal(_ id: PrincipalID, ownerToken: CredentialToken) throws {
    try authenticateOwner(ownerToken)
    _ = try existingPrincipal(id)
    try store.enable(id, at: clock.now())
  }

  // MARK: - Helpers

  private func existingPrincipal(_ id: PrincipalID) throws -> Principal {
    guard let principal = try store.principal(id: id) else {
      throw IdentityError.unknownPrincipal(id)
    }
    return principal
  }

  private func newToken() throws -> CredentialToken {
    let bytes = try random.randomBytes(count: CredentialToken.byteCount)
    guard let token = CredentialToken(bytes: bytes) else { throw IdentityError.invalidRandomOutput }
    return token
  }
}
