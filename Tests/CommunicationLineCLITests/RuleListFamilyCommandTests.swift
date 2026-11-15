import CommunicationLineWire
import Testing

struct RuleListFamilyCommandTests {
  private func request(_ arguments: [String]) -> WireRequest? {
    let harness = CLIHarness(stdin: "tok-0123456789\n")
    _ = harness.run(["--store", "/tmp/cl-store"] + arguments)
    return harness.connection.requests.first
  }

  @Test func test_ruleList_withoutAFamily_sendsNoArgument() {
    let sent = request(["rule", "list"])

    #expect(sent?.operation == "rule.list", "the operation is unchanged")
    #expect(sent?.arguments.isEmpty == true, "the output is as in v0.1")
  }

  @Test func test_ruleList_withAFamily_sendsIt() {
    let sent = request(["rule", "list", "--family", "A"])

    #expect(sent?.arguments == ["family": .string("A")], "the family travels as an argument")
  }
}
