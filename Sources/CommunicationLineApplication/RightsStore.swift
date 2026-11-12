import CommunicationLineDomain
import Foundation

/// Why a rights change was refused. Nothing is stored when one of these is thrown.
public enum RightsError: Error, Equatable {
  case invalidRule
  case expiryInThePast
  case unknownGrant(Int64)
}

/// A read grant as the owner sees it, with the number that revokes it.
public struct StoredReadGrant: Equatable, Sendable {
  public let id: Int64
  public let grant: ReadGrant

  public init(id: Int64, grant: ReadGrant) {
    self.id = id
    self.grant = grant
  }
}

/// What a principal may do, and nothing about anyone else's rights.
public struct EffectiveRights: Equatable, Sendable {
  public let family: String
  /// The principal's own family and every family an owner rule lets it send to.
  public let canSendToFamilies: Set<String>
  /// The grants that currently name the principal or its family.
  public let readGrants: [ReadGrant]

  public init(family: String, canSendToFamilies: Set<String>, readGrants: [ReadGrant]) {
    self.family = family
    self.canSendToFamilies = canSendToFamilies
    self.readGrants = readGrants
  }
}

/// What the rights use cases need from persistence.
public protocol RightsStore {
  /// Adding a rule that already exists changes nothing.
  func addSendRule(_ rule: SendRule, at instant: Date) throws
  func removeSendRule(_ rule: SendRule) throws
  func sendRules() throws -> [SendRule]

  /// Returns the id of the new grant.
  func addReadGrant(reader: GrantReader, expiresAt: Date?, at instant: Date) throws -> Int64
  func revokeReadGrant(id: Int64, at instant: Date) throws
  func readGrants() throws -> [StoredReadGrant]
}
