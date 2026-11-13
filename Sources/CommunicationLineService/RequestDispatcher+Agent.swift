import CommunicationLineApplication
import CommunicationLineDomain
import CommunicationLineWire
import Foundation

extension RequestDispatcher {
  func performAgent(_ operation: Operation, token: CredentialToken, arguments: Arguments) throws
    -> WireValue
  {
    switch operation {
    case .send:
      let recipients = try arguments.strings("to").map { PrincipalID($0) }
      let id = try messages.send(
        token: token, to: recipients, subject: try arguments.string("subject"),
        body: try arguments.string("body"))
      return .object(["id": .string(id.rawValue)])
    case .inbox:
      let cursor = try arguments.optionalInteger("after").map { InboxCursor(sequence: $0) }
      return WireMapping.inboxPage(try messages.inbox(token: token, after: cursor))
    case .read:
      let id = MessageID(try arguments.string("id"))
      return WireMapping.message(try messages.read(token: token, messageID: id))
    case .acknowledge:
      try messages.acknowledge(token: token, messageID: MessageID(try arguments.string("id")))
      return .object([:])
    case .wait:
      let seconds = try arguments.optionalInteger("timeout")
      if let seconds, seconds < 0 { throw RequestError.badRequest("timeout must not be negative") }
      let result = try messages.wait(token: token, timeout: seconds.map { TimeInterval($0) })
      return .object(["outcome": .string(result == .mail ? "mail" : "timeout")])
    default:
      throw RequestError.badRequest("not an agent operation")
    }
  }
}
