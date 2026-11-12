import Foundation

/// An owner rule that lets principals of one family send to principals of another.
public struct SendRule: Hashable, Sendable {
  public let fromFamily: String
  public let toFamily: String

  public init(fromFamily: String, toFamily: String) {
    self.fromFamily = fromFamily
    self.toFamily = toFamily
  }
}

/// Who an owner read grant names.
public enum GrantReader: Hashable, Sendable {
  case principal(PrincipalID)
  case family(String)
}

/// Which mail an owner read grant opens. A grant never opens more than its target names.
public enum GrantTarget: Hashable, Sendable {
  /// The mail one principal sent or received.
  case principal(PrincipalID)
  /// The mail sent by principals of one family.
  case family(String)
  /// All mail. The owner has to ask for it explicitly; no grant defaults to it.
  case global
}

/// An owner grant that widens reading. It never widens sending.
public struct ReadGrant: Equatable, Sendable {
  public let reader: GrantReader
  public let target: GrantTarget
  public let expiresAt: Date?
  public let isRevoked: Bool

  public init(reader: GrantReader, target: GrantTarget, expiresAt: Date?, isRevoked: Bool) {
    self.reader = reader
    self.target = target
    self.expiresAt = expiresAt
    self.isRevoked = isRevoked
  }
}

/// What the policy needs to know about a message: no content, only who it concerns.
public struct MessageMeta: Equatable, Sendable {
  public let sender: PrincipalID
  public let recipients: Set<PrincipalID>
  /// The sender's family.
  public let family: String

  public init(sender: PrincipalID, recipients: Set<PrincipalID>, family: String) {
    self.sender = sender
    self.recipients = recipients
    self.family = family
  }
}

/// The access rules as pure decisions over data the caller has already loaded.
public enum AccessPolicy {
  /// Sending stays inside a family; across families it needs an owner send rule in that direction.
  /// A disabled recipient never receives.
  public static func canSend(from sender: Principal, to recipient: Principal, rules: [SendRule])
    -> Bool
  {
    guard sender.isEnabled, recipient.isEnabled else { return false }
    if sender.family == recipient.family { return true }
    return rules.contains(SendRule(fromFamily: sender.family, toFamily: recipient.family))
  }

  /// The sender, the original recipients and the head of the sender's family may read; an owner
  /// grant that is neither revoked nor expired widens that, but only to the mail its target names.
  public static func canRead(
    principal: Principal, meta: MessageMeta, grants: [ReadGrant], now: Date
  ) -> Bool {
    guard principal.isEnabled else { return false }
    if principal.id == meta.sender || meta.recipients.contains(principal.id) { return true }
    if principal.role == .head && principal.family == meta.family { return true }
    return grants.contains { grant in
      guard !grant.isRevoked else { return false }
      if let expiry = grant.expiresAt, expiry <= now { return false }
      guard isReader(principal, of: grant), opens(grant.target, meta) else { return false }
      return true
    }
  }

  private static func isReader(_ principal: Principal, of grant: ReadGrant) -> Bool {
    switch grant.reader {
    case .principal(let id): return id == principal.id
    case .family(let family): return family == principal.family
    }
  }

  private static func opens(_ target: GrantTarget, _ meta: MessageMeta) -> Bool {
    switch target {
    case .global: return true
    case .family(let family): return family == meta.family
    case .principal(let id): return id == meta.sender || meta.recipients.contains(id)
    }
  }
}
