import CommunicationLineWire
import Foundation

extension CommandCatalog {
  static let agentCommands: [Command] = [
    Command(
      words: ["send"], operation: "send", needsToken: true, positionals: [],
      options: ["to", "subject", "body", "body-file"], presentation: .messageID,
      arguments: { invocation, _ in
        guard !invocation.all("to").isEmpty else { throw UsageError("--to is required") }
        let source = try oneOf(invocation, ["body", "body-file"])
        let body: String
        if source == "body" {
          body = try required(invocation, "body")
        } else {
          let path = try required(invocation, "body-file")
          guard let data = FileManager.default.contents(atPath: path) else {
            throw UsageError("cannot read the body file \(path)")
          }
          guard let text = String(data: data, encoding: .utf8) else {
            throw UsageError("the body file \(path) is not UTF-8 text")
          }
          body = text
        }
        return [
          "to": .array(invocation.all("to").map { .string($0) }),
          "subject": .string(try required(invocation, "subject")), "body": .string(body),
        ]
      }),
    Command(
      words: ["inbox"], operation: "inbox", needsToken: true, positionals: [], options: ["after"],
      presentation: .inbox,
      arguments: { invocation, _ in
        guard let after = invocation.single("after") else { return [:] }
        return ["after": .integer(try integer(after, "--after"))]
      }),
    Command(
      words: ["read"], operation: "read", needsToken: true, positionals: ["message-id"],
      options: [], presentation: .message,
      arguments: { _, positionals in ["id": .string(positionals[0])] }),
    Command(
      words: ["acknowledge"], operation: "acknowledge", needsToken: true,
      positionals: ["message-id"], options: [], presentation: .acknowledged,
      arguments: { _, positionals in ["id": .string(positionals[0])] }),
    Command(
      words: ["wait"], operation: "wait", needsToken: true, positionals: [],
      options: ["timeout"], presentation: .outcome,
      arguments: { invocation, _ in
        guard let timeout = invocation.single("timeout") else { return [:] }
        return ["timeout": .integer(try integer(timeout, "--timeout"))]
      }),
  ]
}
