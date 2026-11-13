import CommunicationLineApplication
import CommunicationLineDomain
import CommunicationLineWire
import Foundation

extension RequestDispatcher {
  /// Without a token this issues the first owner credential; with the current one it replaces it.
  func issueOwnerCredential(replacing current: CredentialToken?) throws -> WireValue {
    .object(["token": .string(try identity.issueOwnerCredential(replacing: current).encoded)])
  }

  func performOwner(_ operation: Operation, token: CredentialToken, arguments: Arguments) throws
    -> WireValue
  {
    switch operation {
    case .principalCreate:
      guard let role = RoleKind(rawValue: try arguments.string("role")) else {
        throw RequestError.badRequest("role must be head or agent")
      }
      return WireMapping.principal(
        try identity.createPrincipal(
          family: try arguments.string("family"), role: role,
          displayName: try arguments.string("name"), ownerToken: token))
    case .principalDisable:
      try identity.disablePrincipal(
        PrincipalID(try arguments.string("principal")), ownerToken: token)
      return .object([:])
    case .principalEnable:
      try identity.enablePrincipal(
        PrincipalID(try arguments.string("principal")), ownerToken: token)
      return .object([:])
    case .credentialIssue:
      let issued = try identity.issueCredential(
        for: PrincipalID(try arguments.string("principal")), ownerToken: token)
      return .object(["token": .string(issued.encoded)])
    case .ruleAdd:
      try rights.allowSending(
        from: try arguments.string("from"), to: try arguments.string("to"), ownerToken: token)
      return .object([:])
    case .ruleRemove:
      try rights.removeSendRule(
        from: try arguments.string("from"), to: try arguments.string("to"), ownerToken: token)
      return .object([:])
    case .ruleList:
      return .object([
        "rules": .array(try rights.sendRules(ownerToken: token).map(WireMapping.rule))
      ])
    case .grantAdd, .grantRevoke, .grantList:
      return try performGrant(operation, token: token, arguments: arguments)
    case .settingGet, .settingSet:
      return try performSetting(operation, token: token, arguments: arguments)
    default:
      throw RequestError.badRequest("not an owner operation")
    }
  }

  private func performGrant(_ operation: Operation, token: CredentialToken, arguments: Arguments)
    throws -> WireValue
  {
    switch operation {
    case .grantAdd:
      let reader: GrantReader
      switch try arguments.string("reader_kind") {
      case "principal": reader = .principal(PrincipalID(try arguments.string("reader")))
      case "family": reader = .family(try arguments.string("reader"))
      default: throw RequestError.badRequest("reader_kind must be principal or family")
      }
      let target: GrantTarget
      switch try arguments.string("target_kind") {
      case "principal": target = .principal(PrincipalID(try arguments.string("target")))
      case "family": target = .family(try arguments.string("target"))
      case "global": target = .global
      default: throw RequestError.badRequest("target_kind must be principal, family or global")
      }
      let expiry = try arguments.optionalInteger("expires_at_ms").map {
        Date(timeIntervalSince1970: Double($0) / 1000)
      }
      let id = try rights.addReadGrant(
        reader: reader, target: target, expiresAt: expiry, ownerToken: token)
      return .object(["id": .integer(id)])
    case .grantRevoke:
      try rights.revokeReadGrant(id: try arguments.integer("id"), ownerToken: token)
      return .object([:])
    default:
      return .object([
        "grants": .array(try rights.readGrants(ownerToken: token).map(WireMapping.grant))
      ])
    }
  }

  private func performSetting(_ operation: Operation, token: CredentialToken, arguments: Arguments)
    throws -> WireValue
  {
    let key = try arguments.string("key")
    if operation == .settingGet {
      let value = try settings.effectiveValue(of: key, token: token)
      return .object(["key": .string(key), "value": WireMapping.settingValue(value)])
    }
    guard let scope = SettingScope(rawValue: try arguments.optionalString("scope") ?? "global")
    else {
      throw RequestError.badRequest("scope must be global, family or principal")
    }
    let address = SettingAddress(
      key: key, scope: scope, subject: try arguments.optionalString("subject"))
    _ = try settings.change(
      address, to: try WireMapping.settingValue(from: arguments.values["value"]), ownerToken: token)
    return .object(["key": .string(key)])
  }
}
