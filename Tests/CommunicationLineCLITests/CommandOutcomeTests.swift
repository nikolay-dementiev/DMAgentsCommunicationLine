import CommunicationLineCLI
import CommunicationLineWire
import Foundation
import Testing

struct CommandOutcomeTests {
  private let store = ["--store", "/tmp/cl-store"]

  private func run(
    _ arguments: [String], stdin: String? = "tok-0123456789\n",
    answer: @escaping @Sendable (WireRequest) throws -> WireResponse = { _ in .success() }
  ) -> (status: Int32, harness: CLIHarness) {
    let harness = CLIHarness(stdin: stdin, answer: answer)
    return (harness.run(store + arguments), harness)
  }

  // MARK: - Usage

  @Test func test_aTokenGivenAsAnArgument_isRefusedAndNothingIsSent() {
    for arguments in [
      ["--token", "tok-0123456789", "inbox"], ["--token=tok-0123456789", "inbox"],
      ["inbox", "--token", "tok-0123456789"],
    ] {
      let outcome = run(arguments)

      #expect(outcome.status == CommandExitStatus.usage.rawValue, "\(arguments) is a usage error")
      #expect(outcome.harness.connection.requests.isEmpty, "\(arguments) sent nothing")
      #expect(
        outcome.harness.standardError.contains("--token-file"),
        "the message points at --token-file or standard input")
      #expect(
        !outcome.harness.standardError.contains("tok-0123456789"),
        "the message never echoes the token")
    }
  }

  @Test func test_wrongCommandLines_areUsageErrors_andSendNothing() {
    let cases: [[String]] = [
      [], ["frobnicate"], ["send"], ["send", "--to", "p1"], ["read"], ["read", "a", "b"],
      ["inbox", "--bogus", "1"], ["inbox", "--after"], ["inbox", "--after", "x"],
      ["principal"], ["principal", "create", "--family", "ops"],
      ["principal", "create", "--family", "ops", "--role", "boss", "--name", "n"],
      ["grant", "add", "--target-global"], ["grant", "add", "--reader-family", "a"],
      ["wait", "--timeout", "-1"],
    ]
    for arguments in cases {
      let outcome = run(arguments)

      #expect(outcome.status == CommandExitStatus.usage.rawValue, "\(arguments) is a usage error")
      #expect(outcome.harness.connection.requests.isEmpty, "\(arguments) sent nothing")
      #expect(!outcome.harness.standardError.isEmpty, "\(arguments) says what is wrong")
    }
  }

  @Test func test_withoutAStoreOrSocket_isAUsageError() {
    let harness = CLIHarness()

    #expect(harness.run(["inbox"]) == CommandExitStatus.usage.rawValue, "no store, no socket")
    #expect(
      harness.run(["--store", "/a", "--socket", "/b", "inbox"]) == CommandExitStatus.usage.rawValue,
      "both is ambiguous")
  }

  // MARK: - Token input

  @Test func test_aTokenFileOthersCanRead_isRefusedAndNothingIsSent() {
    let file = TokenFileFixture(mode: 0o644)
    defer { file.remove() }

    let outcome = run(["--token-file", file.path, "inbox"])

    #expect(outcome.status == CommandExitStatus.tokenInput.rawValue, "a 0644 token file is refused")
    #expect(outcome.harness.connection.requests.isEmpty, "nothing was sent")
    #expect(outcome.harness.standardError.contains(file.path), "the message names the file")
  }

  @Test func test_withoutATokenFile_theTokenComesFromStandardInput() {
    let outcome = run(["inbox"], stdin: "tok-from-stdin\nignored\n")

    #expect(outcome.status == 0, "standard input supplies the token")
    #expect(outcome.harness.connection.requests.first?.token == "tok-from-stdin", "its first line")
    let none = run(["inbox"], stdin: nil)
    #expect(none.status == CommandExitStatus.tokenInput.rawValue, "no token at all")
    #expect(none.harness.connection.requests.isEmpty, "nothing was sent")
  }

  // MARK: - Exit statuses

  @Test func test_everyFailureCode_endsWithItsClassStatus_neverZero() {
    for code in WireErrorCode.allCases {
      let outcome = run(["inbox"]) { _ in .failure(code: code, message: "because") }

      let expected = CommandExitStatus(failureClass: code.errorClass)
      #expect(outcome.status == expected.rawValue, "\(code.rawValue) maps to \(expected)")
      #expect(outcome.status != 0, "\(code.rawValue) is never a success")
      #expect(
        outcome.harness.standardError.contains(code.rawValue),
        "\(code.rawValue) is named on standard error")
      #expect(outcome.harness.standardOutput.isEmpty, "a failure prints nothing on standard output")
    }
  }

  @Test func test_aRefusedSend_exitsWithPermission() {
    let outcome = run(["send", "--to", "p1", "--subject", "s", "--body", "b"]) { _ in
      .failure(code: .recipientRefused, message: "no")
    }

    #expect(outcome.status == CommandExitStatus.permission.rawValue, "a refused send is permission")
  }

  @Test func test_aServiceThatIsNotThere_andAnAnswerThatIsNotAnAnswer() {
    let down = run(["inbox"]) { _ in throw ServiceConnectionError.unreachable("no socket") }
    let garbage = run(["inbox"]) { _ in throw ServiceConnectionError.invalidResponse }

    #expect(down.status == CommandExitStatus.unreachable.rawValue, "unreachable")
    #expect(garbage.status == CommandExitStatus.protocolError.rawValue, "invalid answer")
    #expect(down.harness.standardError.contains("no socket"), "the reason is shown")
  }

  @Test func test_wait_exitsWithTimedOutOnlyWhenNoMailCame() {
    let timeout = run(["wait", "--timeout", "1"]) { _ in
      .success(.object(["outcome": .string("timeout")]))
    }
    let mail = run(["wait", "--timeout", "1"]) { _ in
      .success(.object(["outcome": .string("mail")]))
    }

    #expect(timeout.status == CommandExitStatus.timedOut.rawValue, "no mail")
    #expect(mail.status == 0, "mail")
    #expect(timeout.harness.standardOutput == "timeout\n", "the outcome is printed")
    #expect(mail.harness.standardOutput == "mail\n", "the outcome is printed")
  }

  // MARK: - Output

  @Test func test_inboxAndRead_printHumanText() {
    let page = WireValue.object([
      "entries": .array([
        .object([
          "id": .string("m1"), "sender": .string("p1"), "subject": .string("hello"),
          "created_at_ms": .integer(1_800_000_000_000),
        ])
      ]), "next": .integer(9),
    ])
    let inbox = run(["inbox"]) { _ in .success(page) }
    let message = WireValue.object([
      "id": .string("m1"), "sender": .string("p1"), "family": .string("A"),
      "recipients": .array([.string("p2")]), "subject": .string("hello"),
      "body": .string("line one\nline two"), "created_at_ms": .integer(1_800_000_000_000),
    ])
    let read = run(["read", "m1"]) { _ in .success(message) }

    #expect(
      inbox.harness.standardOutput.contains("m1\tp1\t1800000000000\thello"),
      "one tab-separated line per entry")
    #expect(inbox.harness.standardOutput.contains("next: 9"), "the cursor of the next page")
    #expect(read.harness.standardOutput.contains("From: p1"), "sender header")
    #expect(read.harness.standardOutput.contains("To: p2"), "recipient header")
    #expect(read.harness.standardOutput.contains("Subject: hello"), "subject header")
    #expect(read.harness.standardOutput.hasSuffix("\nline one\nline two\n"), "the body follows")
  }

  @Test func test_json_printsTheResultAsIs_andFailuresAsJsonOnStandardError() throws {
    let result = WireValue.object(["id": .string("m1")])
    let ok = run(["--json", "send", "--to", "p", "--subject", "s", "--body", "b"]) { _ in
      .success(result)
    }
    let failed = run(["--json", "inbox"]) { _ in .failure(code: .unknownToken, message: "bad") }

    #expect(ok.harness.standardOutput == #"{"id":"m1"}"# + "\n", "the result, sorted keys")
    let error = try JSONSerialization.jsonObject(with: Data(failed.harness.standardError.utf8))
    let fields = try #require(error as? [String: Any])
    #expect((fields["error"] as? [String: String])?["code"] == "unknown_token", "typed error")
    #expect(failed.status == CommandExitStatus.authentication.rawValue, "same status as text mode")
  }

  @Test func test_ownerInit_printsTheNewTokenOnStandardOutputOnly() {
    let outcome = run(["owner", "init"], stdin: nil) { _ in
      .success(.object(["token": .string("the-new-token")]))
    }

    #expect(outcome.harness.standardOutput == "the-new-token\n", "just the token, for a pipe")
    #expect(outcome.harness.standardError.isEmpty, "nothing else")
  }
}
