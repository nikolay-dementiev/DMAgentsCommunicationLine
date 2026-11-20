/// The identity of a principal. It never changes after the principal is created.
public struct PrincipalID: Hashable, Sendable {
  public let rawValue: String

  public init(_ rawValue: String) {
    self.rawValue = rawValue
  }
}

/// What a principal does in its family. A `head` sees the whole history of its family.
public enum RoleKind: String, Sendable {
  case head
  case agent
}

/// An agent identity. The id, the family and the role are fixed when it is created; only the
/// enabled flag changes, and only through an owner operation.
public struct Principal: Equatable, Sendable {
  public let id: PrincipalID
  public let family: String
  public let role: RoleKind
  public let displayName: String
  public let isEnabled: Bool

  public init(
    id: PrincipalID, family: String, role: RoleKind, displayName: String, isEnabled: Bool
  ) {
    self.id = id
    self.family = family
    self.role = role
    self.displayName = displayName
    self.isEnabled = isEnabled
  }
}

/// Who a valid token belongs to.
public enum AuthenticatedActor: Equatable, Sendable {
  case owner
  /// The read-only credential of a program that watches the service. It is not a principal.
  case observer
  case principal(Principal)
}
