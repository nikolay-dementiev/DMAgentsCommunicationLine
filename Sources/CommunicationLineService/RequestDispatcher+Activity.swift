import CommunicationLineDomain
import CommunicationLineApplication
import CommunicationLineWire

extension RequestDispatcher {
  func performActivity(token: CredentialToken, arguments: Arguments) throws -> WireValue {
    let page = try activity.list(
      ownerToken: token, after: try arguments.optionalInteger("after"),
      limit: try arguments.optionalInteger("limit").map { Int(clamping: $0) })
    var fields: [String: WireValue] = ["records": .array(page.records.map(WireMapping.activity))]
    if let next = page.next { fields["next"] = .integer(next) }
    return .object(fields)
  }

  /// The cleanup commits in a transaction of its own and is remembered as the last cleanup only
  /// after that commit. The request's activity record is written afterwards and cannot undo it.
  func performCleanup(token: CredentialToken) throws -> WireValue {
    try identity.authenticateOwner(token)
    let result = try cleanup.run()
    return .object([
      "deliveries": .integer(Int64(result.deliveries)),
      "messages": .integer(Int64(result.messages)),
      "activity": .integer(Int64(result.activity)),
    ])
  }

  /// The ids a request touched. Only ids, names of rules and keys: never a subject, a body or a
  /// token.
  func activityTargets(_ operation: Operation, arguments: Arguments, result: WireValue?) -> [String]
  {
    func resultText(_ key: String) -> String? {
      guard case .object(let fields)? = result else { return nil }
      switch fields[key] {
      case .string(let text)?: return text
      case .integer(let number)?: return String(number)
      default: return nil
      }
    }
    func argument(_ key: String) -> String? {
      switch arguments.values[key] {
      case .string(let text)?: return text
      case .integer(let number)?: return String(number)
      default: return nil
      }
    }
    switch operation {
    case .send:
      let recipients = (try? arguments.strings("to")) ?? []
      return [resultText("id")].compactMap { $0 } + recipients
    case .read, .acknowledge, .grantRevoke: return [argument("id")].compactMap { $0 }
    case .principalCreate: return [resultText("id")].compactMap { $0 }
    case .principalDisable, .principalEnable, .credentialIssue:
      return [argument("principal")].compactMap { $0 }
    case .grantAdd:
      return [resultText("id"), argument("reader"), argument("target")].compactMap { $0 }
    case .ruleAdd, .ruleRemove: return [argument("from"), argument("to")].compactMap { $0 }
    case .settingGet, .settingSet: return [argument("key")].compactMap { $0 }
    default: return []
    }
  }
}
