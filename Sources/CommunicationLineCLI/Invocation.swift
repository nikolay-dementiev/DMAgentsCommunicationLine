/// The command line is wrong. The text says how; nothing was sent.
struct UsageError: Error, Equatable {
  let message: String

  init(_ message: String) { self.message = message }
}

/// A command line split into its words and options, before any command is looked up.
struct Invocation: Sendable {
  static let valueOptions: Set<String> = [
    "store", "socket", "token-file", "to", "subject", "body", "body-file", "after", "limit",
    "timeout",
    "family", "role", "name", "reader-principal", "reader-family", "target-principal",
    "target-family", "expires-at-ms", "scope", "home", "client",
  ]
  static let flagOptions: Set<String> = ["json", "target-global", "until-mail", "delete-data"]

  private(set) var words: [String] = []
  private(set) var values: [String: [String]] = [:]
  private(set) var flags: Set<String> = []

  init(arguments: [String]) throws {
    var index = 0
    while index < arguments.count {
      let argument = arguments[index]
      index += 1
      guard argument.hasPrefix("--") else {
        words.append(argument)
        continue
      }
      let body = String(argument.dropFirst(2))
      let name = String(body.prefix { $0 != "=" })
      let inline = body.contains("=") ? String(body.drop { $0 != "=" }.dropFirst()) : nil
      if name == "token" {
        throw UsageError(
          "a token is never taken from an argument: use --token-file <path> or standard input")
      }
      if Self.flagOptions.contains(name) {
        guard inline == nil else { throw UsageError("--\(name) takes no value") }
        flags.insert(name)
      } else if Self.valueOptions.contains(name) {
        let value: String
        if let inline {
          value = inline
        } else {
          guard index < arguments.count else { throw UsageError("--\(name) needs a value") }
          value = arguments[index]
          index += 1
        }
        values[name, default: []].append(value)
      } else {
        throw UsageError("unknown option --\(name)")
      }
    }
  }

  var optionNames: Set<String> { Set(values.keys).union(flags) }

  func single(_ name: String) -> String? { values[name]?.last }

  func all(_ name: String) -> [String] { values[name] ?? [] }

  func has(_ name: String) -> Bool { values[name] != nil || flags.contains(name) }
}
