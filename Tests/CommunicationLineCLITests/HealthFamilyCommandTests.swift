import CommunicationLineWire
import Testing

struct HealthFamilyCommandTests {
  private func run(
    _ arguments: [String],
    answer: @escaping @Sendable (WireRequest) throws -> WireResponse = { _ in .success() }
  ) -> CLIHarness {
    let harness = CLIHarness(stdin: "tok-0123456789\n", answer: answer)
    _ = harness.run(["--store", "/tmp/cl-store"] + arguments)
    return harness
  }

  @Test func test_health_withoutAFamily_sendsNoArgument() {
    let harness = run(["health"])

    #expect(harness.connection.requests.first?.arguments.isEmpty == true, "as in v0.1")
  }

  @Test func test_health_withAFamily_sendsIt() {
    let harness = run(["health", "--family", "A"])

    #expect(harness.connection.requests.first?.operation == "health", "the same operation")
    #expect(
      harness.connection.requests.first?.arguments == ["family": .string("A")],
      "the family travels as an argument")
  }

  @Test func test_healthCleanup_takesNoFamily() {
    let harness = run(["health", "cleanup", "--family", "A"])

    #expect(harness.connection.requests.isEmpty, "cleanup is global; the option is refused")
  }

  @Test func test_health_printsTheNotListeningCountBeforeTheOverdueCount() {
    let report = WireValue.object([
      "started_at_ms": .integer(1), "pending": .array([]),
      "not_listening_with_pending": .integer(3), "overdue_count": .integer(0),
      "overdue": .array([]),
      "storage": .object([
        "used_bytes": .integer(1), "budget_bytes": .integer(2), "warning_percent": .integer(80),
      ]),
      "warnings": .array([]), "last_cleanup": .null,
    ])

    let harness = run(["health"]) { _ in .success(report) }

    #expect(
      harness.standardOutput.contains("not listening with pending: 3\noverdue: 0\n"),
      "the line sits between the pending lines and the overdue count")
  }
}
