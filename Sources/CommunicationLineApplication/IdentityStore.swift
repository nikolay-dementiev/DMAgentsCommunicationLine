import CommunicationLineDomain
import Foundation

/// Why a caller was not accepted, or why an owner operation was refused.
public enum IdentityError: Error, Equatable {
  case unknownToken
  case tokenRevoked
  case principalDisabled
  case ownerCredentialRequired
  case unknownPrincipal(PrincipalID)
  case invalidName(field: String)
  case invalidRandomOutput
}

/// Where random bytes for new tokens come from.
public protocol RandomSource {
  func randomBytes(count: Int) throws -> [UInt8]
}

/// Where the ids of new principals come from.
public protocol IdentifierSource {
  func newPrincipalID() -> PrincipalID
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
  func enable(_ id: PrincipalID) throws

  /// Clears the enabled flag and revokes every credential of the principal in one transaction.
  func disable(_ id: PrincipalID, at instant: Date) throws

  func insertCredential(digest: TokenDigest, kind: StoredCredentialKind, at instant: Date) throws
  func credential(digest: TokenDigest) throws -> StoredCredential?
  func hasActiveOwnerCredential() throws -> Bool

  /// Revokes every owner credential and stores the new one in one transaction.
  func replaceOwnerCredential(with digest: TokenDigest, at instant: Date) throws
}
