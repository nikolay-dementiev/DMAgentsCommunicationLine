import CommunicationLineDomain
import Foundation

/// Why a caller was not accepted, or why an owner operation was refused.
public enum IdentityError: Error, Equatable {
  case unknownToken
  case tokenRevoked
  case principalDisabled
  case ownerCredentialRequired
  case principalCredentialRequired
  case unknownPrincipal(PrincipalID)
  case invalidName(field: String)
  case invalidRandomOutput
}

/// Where random bytes for new tokens come from.
public protocol RandomSource {
  func randomBytes(count: Int) throws -> [UInt8]
}

/// Where the ids of new principals and new messages come from.
public protocol IdentifierSource {
  func newPrincipalID() -> PrincipalID
  func newMessageID() -> MessageID
}

/// Turns a presented token into the caller it belongs to.
public protocol Authenticating {
  func authenticate(_ token: CredentialToken) throws -> AuthenticatedActor
}

public enum StoredCredentialKind: Equatable, Sendable {
  case owner
  case principal(PrincipalID)
}

/// What the store keeps about an issued credential: never the token itself.
public struct StoredCredential: Equatable, Sendable {
  public let digest: TokenDigest
  public let kind: StoredCredentialKind
  public let isRevoked: Bool

  public init(digest: TokenDigest, kind: StoredCredentialKind, isRevoked: Bool) {
    self.digest = digest
    self.kind = kind
    self.isRevoked = isRevoked
  }
}

/// What the identity use cases need from persistence.
public protocol IdentityStore {
  func insertPrincipal(_ principal: Principal, at instant: Date) throws
  func principal(id: PrincipalID) throws -> Principal?

  /// Sets the enabled flag and revokes every credential of the principal that is still live, in one
  /// transaction: enabling never revives a credential.
  func enable(_ id: PrincipalID, at instant: Date) throws

  /// Clears the enabled flag and revokes every credential of the principal in one transaction.
  func disable(_ id: PrincipalID, at instant: Date) throws

  /// Stores a credential for an enabled principal. The check and the insert are one transaction.
  ///
  /// - Throws: ``IdentityError/principalDisabled`` when the principal is not enabled.
  func insertPrincipalCredential(digest: TokenDigest, for id: PrincipalID, at instant: Date) throws
  func credential(digest: TokenDigest) throws -> StoredCredential?
  func hasActiveOwnerCredential() throws -> Bool

  /// Replaces the owner credential in one transaction. `expectedCurrent` is the digest of the owner
  /// credential the caller authenticated with, or nil when the caller expects that none exists.
  ///
  /// - Throws: ``IdentityError/ownerCredentialRequired`` when the live owner credential is not the
  ///   expected one, for example because another caller replaced it first.
  func replaceOwnerCredential(
    expectedCurrent: TokenDigest?, with digest: TokenDigest, at instant: Date) throws

  /// Revokes every live owner credential and stores a new one, in one transaction, without asking
  /// for the old token. Only the host-side recovery uses it, with the service stopped.
  func forceReplaceOwnerCredential(with digest: TokenDigest, at instant: Date) throws
}
