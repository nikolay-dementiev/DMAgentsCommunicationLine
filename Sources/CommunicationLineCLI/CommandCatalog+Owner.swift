import CommunicationLineWire
import Foundation

extension CommandCatalog {
  static let ownerCommands: [Command] = [
    Command(
      words: ["owner", "init"], operation: "owner.credential", needsToken: false,
      positionals: [], options: ["token-out"], presentation: .token, arguments: { _, _ in [:] }),
    Command(
      words: ["owner", "rotate"], operation: "owner.credential", needsToken: true,
      positionals: [], options: ["token-out"], presentation: .token, arguments: { _, _ in [:] }),
    Command(
      words: ["principal", "create"], operation: "principal.create", needsToken: true,
      positionals: [], options: ["family", "role", "name"], presentation: .principal,
      arguments: { invocation, _ in
        let role = try required(invocation, "role")
        guard role == "head" || role == "agent" else {
          throw UsageError("--role must be head or agent")
        }
        return [
          "family": .string(try required(invocation, "family")), "role": .string(role),
          "name": .string(try required(invocation, "name")),
        ]
      }),
    Command(
      words: ["principal", "list"], operation: "principal.list", needsToken: true,
      positionals: [], options: ["family"], presentation: .principals,
      arguments: { invocation, _ in
        invocation.single("family").map { ["family": .string($0)] } ?? [:]
      }),
    Command(
      words: ["activity"], operation: "activity.list", needsToken: true, positionals: [],
      options: ["after", "limit"], presentation: .activity,
      arguments: { invocation, _ in
        var arguments: [String: WireValue] = [:]
        if let after = invocation.single("after") {
          arguments["after"] = .integer(try integer(after, "--after"))
        }
        if let limit = invocation.single("limit") {
          arguments["limit"] = .integer(try integer(limit, "--limit", minimum: 1))
        }
        return arguments
      }),
    Command(
      words: ["health"], operation: "health", needsToken: true, positionals: [],
      options: ["family"], presentation: .health,
      arguments: { invocation, _ in
        invocation.single("family").map { ["family": .string($0)] } ?? [:]
      }),
    Command(
      words: ["health", "cleanup"], operation: "health.cleanup", needsToken: true,
      positionals: [], options: [], presentation: .cleanup, arguments: { _, _ in [:] }),
    principalCommand("disable"),
    principalCommand("enable"),
    Command(
      words: ["credential", "issue"], operation: "credential.issue", needsToken: true,
      positionals: ["principal-id"], options: ["token-out"], presentation: .token,
      arguments: { _, positionals in ["principal": .string(positionals[0])] }),
    Command(
      words: ["observer", "issue"], operation: "observer.issue", needsToken: true,
      positionals: [], options: ["token-out"], presentation: .token, arguments: { _, _ in [:] }),
    Command(
      words: ["observer", "revoke"], operation: "observer.revoke", needsToken: true,
      positionals: [], options: [], presentation: .acknowledged, arguments: { _, _ in [:] }),
    Command(
      words: ["rule", "add"], operation: "rule.add", needsToken: true,
      positionals: ["from-family", "to-family"], options: [], presentation: .acknowledged,
      arguments: { _, positionals in
        ["from": .string(positionals[0]), "to": .string(positionals[1])]
      }),
    Command(
      words: ["rule", "remove"], operation: "rule.remove", needsToken: true,
      positionals: ["from-family", "to-family"], options: [], presentation: .acknowledged,
      arguments: { _, positionals in
        ["from": .string(positionals[0]), "to": .string(positionals[1])]
      }),
    Command(
      words: ["rule", "list"], operation: "rule.list", needsToken: true, positionals: [],
      options: ["family"], presentation: .rules,
      arguments: { invocation, _ in
        invocation.single("family").map { ["family": .string($0)] } ?? [:]
      }),
    Command(
      words: ["grant", "add"], operation: "grant.add", needsToken: true, positionals: [],
      options: [
        "reader-principal", "reader-family", "target-principal", "target-family",
        "target-global", "expires-at-ms",
      ], presentation: .grantID, arguments: grantArguments),
    Command(
      words: ["grant", "revoke"], operation: "grant.revoke", needsToken: true,
      positionals: ["grant-id"], options: [], presentation: .acknowledged,
      arguments: { _, positionals in ["id": .integer(try integer(positionals[0], "grant-id"))] }),
    Command(
      words: ["grant", "list"], operation: "grant.list", needsToken: true, positionals: [],
      options: [], presentation: .grants, arguments: { _, _ in [:] }),
    Command(
      words: ["setting", "get"], operation: "setting.get", needsToken: true,
      positionals: ["key"], options: [], presentation: .setting,
      arguments: { _, positionals in ["key": .string(positionals[0])] }),
    Command(
      words: ["setting", "set"], operation: "setting.set", needsToken: true,
      positionals: ["key", "value"], options: ["scope", "subject"], presentation: .acknowledged,
      arguments: settingArguments),
  ]

  private static func principalCommand(_ verb: String) -> Command {
    Command(
      words: ["principal", verb], operation: "principal.\(verb)", needsToken: true,
      positionals: ["principal-id"], options: [], presentation: .acknowledged,
      arguments: { _, positionals in ["principal": .string(positionals[0])] })
  }

  private static func grantArguments(_ invocation: Invocation, _: [String]) throws
    -> [String: WireValue]
  {
    let reader = try oneOf(invocation, ["reader-principal", "reader-family"])
    let target = try oneOf(
      invocation, ["target-principal", "target-family", "target-global"])
    var arguments: [String: WireValue] = [
      "reader_kind": .string(reader == "reader-family" ? "family" : "principal"),
      "reader": .string(try required(invocation, reader)),
    ]
    switch target {
    case "target-global": arguments["target_kind"] = .string("global")
    case "target-family":
      arguments["target_kind"] = .string("family")
      arguments["target"] = .string(try required(invocation, target))
    default:
      arguments["target_kind"] = .string("principal")
      arguments["target"] = .string(try required(invocation, target))
    }
    if let expiry = invocation.single("expires-at-ms") {
      arguments["expires_at_ms"] = .integer(try integer(expiry, "--expires-at-ms"))
    }
    return arguments
  }

  private static func settingArguments(_ invocation: Invocation, _ positionals: [String]) throws
    -> [String: WireValue]
  {
    var arguments: [String: WireValue] = ["key": .string(positionals[0])]
    let text = positionals[1]
    if let number = Int64(text) {
      arguments["value"] = .integer(number)
    } else if text == "true" || text == "false" {
      arguments["value"] = .bool(text == "true")
    } else {
      arguments["value"] = .string(text)
    }
    if let scope = invocation.single("scope") { arguments["scope"] = .string(scope) }
    if let subject = invocation.single("subject") { arguments["subject"] = .string(subject) }
    return arguments
  }
}
