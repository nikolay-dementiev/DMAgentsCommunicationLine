import CommunicationLineDomain
import Foundation

/// A principal with the count of deliveries to it that nobody has acknowledged.
public struct PrincipalSummary: Equatable, Sendable {
  public let principal: Principal
  public let pending: Int

  public init(principal: Principal, pending: Int) {
    self.principal = principal
    self.pending = pending
  }
}

/// A principal as the owner sees it: its mail, and whether anything is listening for it now.
public struct PrincipalListing: Equatable, Sendable {
  public let principal: Principal
  public let pending: Int
  /// When the oldest parked `wait` of the principal started, or nil when none is parked.
  public let listeningSince: Date?

  public init(principal: Principal, pending: Int, listeningSince: Date?) {
    self.principal = principal
    self.pending = pending
    self.listeningSince = listeningSince
  }
}

public protocol PrincipalDirectoryStore {
  /// The principals of `family`, or of every family, sorted by family, role and name, each with its
  /// pending deliveries counted in the same read.
  func principals(family: String?) throws -> [PrincipalSummary]
}

/// Who exists and who listens. Only the owner may ask.
public struct DirectoryService {
  private let store: any PrincipalDirectoryStore
  private let identity: IdentityService
  private let listening: any ListeningRegistry

  public init(
    store: any PrincipalDirectoryStore, identity: IdentityService,
    listening: any ListeningRegistry
  ) {
    self.store = store
    self.identity = identity
    self.listening = listening
  }

  /// `ownerToken` may also be the observer's: the list is what a dashboard reads.
  ///
  /// - Throws: ``IdentityError/unknownFamily(_:)`` when `family` is given and has no principal.
  public func principals(family: String?, ownerToken: CredentialToken) throws
    -> [PrincipalListing]
  {
    try identity.authenticateOwnerOrObserver(ownerToken)
    let summaries = try store.principals(family: family)
    if let family, summaries.isEmpty { throw IdentityError.unknownFamily(family) }
    return summaries.map {
      PrincipalListing(
        principal: $0.principal, pending: $0.pending,
        listeningSince: listening.listeningSince($0.principal.id))
    }
  }
}
