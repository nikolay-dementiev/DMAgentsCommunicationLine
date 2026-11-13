import CommunicationLineDomain
import Foundation

/// Writes and reads the activity log. Recording is a plain append; the caller decides which
/// transaction it belongs to.
public struct ActivityService {
  private let store: any ActivityStore
  private let identity: IdentityService
  private let settings: SettingsService
  private let clock: any WallClock

  public init(
    store: any ActivityStore, identity: IdentityService, settings: SettingsService,
    clock: any WallClock
  ) {
    self.store = store
    self.identity = identity
    self.settings = settings
    self.clock = clock
  }

  /// The most targets one record keeps, and the longest one target may be. Targets can echo
  /// text a client made up, so both are bounded.
  public static let maximumTargets = 16
  public static let maximumTargetLength = 128

  public func record(
    actor: ActivityActor, operation: String, outcome: String, targets: [String]
  ) throws {
    let bounded = targets.prefix(Self.maximumTargets).map {
      String($0.prefix(Self.maximumTargetLength))
    }
    try store.append(
      NewActivity(
        at: clock.now(), actor: actor, operation: operation, outcome: outcome, targets: bounded))
  }

  /// Who a token belongs to. A missing, unknown, revoked or disabled one is `unauthenticated`.
  /// A storage failure is not a refusal: it is thrown, so a broken store is never logged as an
  /// anonymous caller.
  public func actor(for token: CredentialToken?) throws -> ActivityActor {
    guard let token else { return .unauthenticated }
    do {
      switch try identity.authenticate(token) {
      case .owner: return .owner
      case .principal(let principal): return .principal(principal.id)
      }
    } catch IdentityError.unknownToken, IdentityError.tokenRevoked, IdentityError.principalDisabled {
      return .unauthenticated
    }
  }

  /// One page of the log, oldest first. Owner only. The page size is `messaging.page_size` unless
  /// the caller asks for fewer.
  public func list(ownerToken: CredentialToken, after cursor: Int64?, limit: Int?) throws
    -> ActivityPage
  {
    try identity.authenticateOwner(ownerToken)
    guard
      case .integer(let configured) = try settings.effectiveValue(
        of: "messaging.page_size", token: ownerToken),
      let maximum = Int(exactly: configured)
    else { throw MessagingError.invalidSetting(key: "messaging.page_size") }
    let size = limit ?? maximum
    guard size >= 1, size <= maximum else { throw MessagingError.invalidPageLimit(size) }
    return try store.page(after: cursor, limit: size)
  }
}
