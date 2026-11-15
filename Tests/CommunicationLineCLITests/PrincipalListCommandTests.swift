import CommunicationLineCLI
import CommunicationLineWire
import Foundation
import Testing

struct PrincipalListCommandTests {
  private let store = ["--store", "/tmp/cl-store"]

  private func run(
    _ arguments: [String],
    answer: @escaping @Sendable (WireRequest) throws -> WireResponse = { _ in .success() }
  ) -> (status: Int32, harness: CLIHarness) {
    let harness = CLIHarness(stdin: "tok-0123456789\n", answer: answer)
    return (harness.run(store + arguments), harness)
  }

  private static func entry(
    _ id: String, family: String, role: String, name: String, enabled: Bool, pending: Int64,
    listeningSince: Int64?
  ) -> WireValue {
    .object([
      "id": .string(id), "family": .string(family), "role": .string(role), "name": .string(name),
      "enabled": .bool(enabled), "pending": .integer(pending),
      "listening_since_ms": listeningSince.map { .integer($0) } ?? .null,
    ])
  }

  private static let answer = WireValue.object([
    "principals": .array([
      entry(
        "p1", family: "A", role: "agent", name: "alpha agent", enabled: true, pending: 2,
        listeningSince: 1_800_000_000_000),
      entry(
        "p2", family: "A", role: "head", name: "alpha head", enabled: false, pending: 0,
        listeningSince: nil),
    ])
  ])

  @Test func test_principalList_asksTheServiceWithAnOptionalFamily() {
    let all = run(["principal", "list"])
    let one = run(["principal", "list", "--family", "A"])

    #expect(all.harness.connection.requests.first?.operation == "principal.list", "the operation")
    #expect(all.harness.connection.requests.first?.arguments.isEmpty == true, "every family")
    #expect(
      one.harness.connection.requests.first?.arguments == ["family": .string("A")],
      "the family option travels as an argument")
    #expect(all.harness.connection.requests.first?.token == "tok-0123456789", "the owner token")
  }

  @Test func test_principalList_printsOneLinePerPrincipal() {
    let outcome = run(["principal", "list"]) { _ in .success(Self.answer) }

    #expect(outcome.status == 0, "the listing is shown")
    #expect(
      outcome.harness.standardOutput
        == "p1\tA\tagent\talpha agent\tenabled\tpending 2\tlistening since 1800000000000\n"
        + "p2\tA\thead\talpha head\tdisabled\tpending 0\tnot listening\n",
      "id, family, role, name, enabled, pending and the listening state")
  }

  @Test func test_principalList_json_isAnArrayOfObjectsWithTheSameFields() throws {
    let outcome = run(["--json", "principal", "list"]) { _ in .success(Self.answer) }

    let decoded = try JSONSerialization.jsonObject(with: Data(outcome.harness.standardOutput.utf8))
    let array = try #require(decoded as? [[String: Any]], "a top-level array")
    #expect(array.count == 2, "one object per principal")
    #expect(array[0]["id"] as? String == "p1", "the id")
    #expect(array[0]["pending"] as? Int == 2, "the pending count")
    #expect(array[0]["listening_since_ms"] as? Int == 1_800_000_000_000, "the listening time")
    #expect(array[1]["enabled"] as? Bool == false, "the enabled flag")
    #expect(array[1]["listening_since_ms"] is NSNull, "null when not listening")
  }

  @Test func test_principalList_unknownFamily_exitsWithNotFound() {
    let outcome = run(["principal", "list", "--family", "Z"]) { _ in
      .failure(code: .unknownFamily, message: "no principal in family Z")
    }

    #expect(outcome.status == CommandExitStatus.notFound.rawValue, "exit status 6")
    #expect(
      outcome.harness.standardError == "commline: unknown_family: no principal in family Z\n",
      "the message names the family")
  }
}
