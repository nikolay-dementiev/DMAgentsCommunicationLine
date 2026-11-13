import CommunicationLineWire
import Foundation

/// How a successful answer is shown in text mode.
enum Presentation: Sendable {
  case acknowledged
  case messageID
  case token
  case outcome
  case inbox
  case message
  case principal
  case rules
  case grants
  case setting
  case grantID
  case activity
}

/// One command: its words, positionals, options and the request it makes.
struct Command: Sendable {
  let words: [String]
  let operation: String
  let needsToken: Bool
  let positionals: [String]
  let options: Set<String>
  let presentation: Presentation
  let arguments: @Sendable (Invocation, [String]) throws -> [String: WireValue]
}

enum CommandCatalog {
  static let globalOptions: Set<String> = ["store", "socket", "token-file", "json"]

  static let all: [Command] = agentCommands + ownerCommands

  /// The command named by the leading words, and the words left over as positionals.
  static func find(in words: [String]) -> (Command, [String])? {
    for command in all.sorted(by: { $0.words.count > $1.words.count })
    where words.starts(with: command.words) {
      return (command, Array(words.dropFirst(command.words.count)))
    }
    return nil
  }

  // MARK: - Helpers

  static func required(_ invocation: Invocation, _ name: String) throws -> String {
    guard let value = invocation.single(name) else { throw UsageError("--\(name) is required") }
    return value
  }

  static func integer(_ text: String, _ what: String, minimum: Int64 = 0) throws -> Int64 {
    guard let value = Int64(text), value >= minimum else {
      throw UsageError("\(what) must be a whole number of at least \(minimum)")
    }
    return value
  }

  static func oneOf(_ invocation: Invocation, _ names: [String]) throws -> String {
    let given = names.filter { invocation.has($0) }
    guard given.count == 1, let name = given.first else {
      throw UsageError("give exactly one of " + names.map { "--\($0)" }.joined(separator: ", "))
    }
    return name
  }
}
