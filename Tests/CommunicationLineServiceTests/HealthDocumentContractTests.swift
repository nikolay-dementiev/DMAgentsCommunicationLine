import CommunicationLineWire
import Foundation
import Testing

/// The health document is a contract for programs that are not agents. These tests hold the
/// document the service produces against the field table of `docs/health.md`, in both directions.
struct HealthDocumentContractTests {
  private struct Entry {
    let types: Set<String>
    let isOptional: Bool
  }

  /// The rows of the field table: the path of a field, its types and whether it may be absent.
  private static func documented() throws -> [String: Entry] {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let text = try String(
      contentsOf: root.appendingPathComponent("docs/health.md"), encoding: .utf8)
    var entries: [String: Entry] = [:]
    for line in text.split(separator: "\n") where line.hasPrefix("| `") {
      let cells = line.split(separator: "|", omittingEmptySubsequences: false).map {
        $0.trimmingCharacters(in: .whitespaces)
      }
      guard cells.count >= 4 else { continue }
      let path = cells[1].trimmingCharacters(in: CharacterSet(charactersIn: "`"))
      var type = cells[2]
      let isOptional = type.hasSuffix("(optional)")
      if isOptional {
        type = String(type.dropLast("(optional)".count)).trimmingCharacters(in: .whitespaces)
      }
      entries[path] = Entry(
        types: Set(type.components(separatedBy: " or ")), isOptional: isOptional)
    }
    return entries
  }

  private static func typeName(_ value: WireValue) -> String {
    switch value {
    case .null: return "null"
    case .bool: return "bool"
    case .integer: return "integer"
    case .string: return "string"
    case .array: return "array"
    case .object: return "object"
    }
  }

  /// Every field path of a document with the types it was seen with. An array element that is an
  /// object contributes its fields as `name[].field`; a scalar element is named `name[]`.
  private static func flatten(
    _ value: WireValue, path: String, into found: inout [String: Set<String>]
  ) {
    switch value {
    case .object(let fields):
      for (name, field) in fields {
        let child = path.isEmpty ? name : path + "." + name
        found[child, default: []].insert(typeName(field))
        flatten(field, path: child, into: &found)
      }
    case .array(let items):
      for item in items {
        if case .object = item {
          flatten(item, path: path + "[]", into: &found)
        } else {
          found[path + "[]", default: []].insert(typeName(item))
        }
      }
    default:
      break
    }
  }

  private func document() throws -> [String: WireValue] {
    let fixture = try ServiceFixture()
    let owner = try fixture.bootstrapOwner()
    let alice = try fixture.enrol(owner: owner, family: "A", name: "alice")
    let bob = try fixture.enrol(owner: owner, family: "A", name: "bob")
    _ = fixture.call(
      "send", token: alice.token,
      ["to": .array([.string(bob.id)]), "subject": .string("s"), "body": .string("b")])
    fixture.clock.advance(days: 31.0 / 1440)
    _ = fixture.call("health.cleanup", token: owner)
    guard case .object(let fields)? = fixture.call("health", token: owner).result else {
      throw POSIXError(.EIO)
    }
    return fields
  }

  @Test func test_theDocumentAndTheFieldTable_listTheSameFieldsWithTheSameTypes() throws {
    let table = try Self.documented()
    var found: [String: Set<String>] = [:]
    Self.flatten(.object(try document()), path: "", into: &found)

    var problems: [String] = []
    for (path, types) in found.sorted(by: { $0.key < $1.key }) {
      guard let entry = table[path] else {
        problems.append("\(path) is in the document but not in docs/health.md")
        continue
      }
      if !types.isSubset(of: entry.types) {
        problems.append(
          "\(path) is \(types.sorted()) but docs/health.md says \(entry.types.sorted())")
      }
    }
    for (path, entry) in table.sorted(by: { $0.key < $1.key })
    where !entry.isOptional && found[path] == nil {
      problems.append("\(path) is in docs/health.md but not in the document")
    }

    #expect(table.count >= 20, "the field table was read: \(table.count) rows")
    #expect(problems.isEmpty, "the document and docs/health.md differ: \(problems)")
  }

  @Test func test_theDocumentCarriesItsVersionAtTheTop() throws {
    let fields = try document()

    #expect(fields["version"] == .integer(1), "version 1 of the document")
  }
}
