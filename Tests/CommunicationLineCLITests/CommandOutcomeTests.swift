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

  @Test func test_json_whenTheAnswerCannotBeEncoded_failsVisiblyInsteadOfPrintingNull() {
    struct Unencodable: Error {}
    let harness = CLIHarness(encode: { _ in throw Unencodable() })

    let status = harness.run(["--store", "/tmp/cl-store", "--json", "owner", "init"])

    #expect(status == CommandExitStatus.failure.rawValue, "an answer that cannot be printed fails")
    #expect(harness.standardOutput.isEmpty, "nothing that looks like a result is printed")
    #expect(harness.standardError.contains("cannot encode"), "the reason is on standard error")
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

  @Test func test_activity_printsOneLinePerRecordAndTheCursor() {
    let outcome = run(["activity"]) { _ in
      .success(
        .object([
          "records": .array([
            .object([
              "id": .integer(7), "at_ms": .integer(1_800_000_000_000),
              "actor": .string("principal:p1"), "operation": .string("send"),
              "outcome": .string("ok"), "targets": .array([.string("m1"), .string("p2")]),
            ]),
            .object([
              "id": .integer(8), "at_ms": .integer(1_800_000_000_500),
              "actor": .string("unauthenticated"), "operation": .string("inbox"),
              "outcome": .string("unknown_token"), "targets": .array([]),
            ]),
          ]),
          "next": .integer(8),
        ]))
    }

    #expect(outcome.status == 0, "the page is shown")
    #expect(
      outcome.harness.standardOutput
        == "7\t1800000000000\tprincipal:p1\tsend\tok\tm1,p2\n"
        + "8\t1800000000500\tunauthenticated\tinbox\tunknown_token\t\nnext: 8\n",
      "one tab-separated line per record, then the cursor")
  }

  @Test func test_health_printsTheReportAsText() {
    let report = WireValue.object([
      "started_at_ms": .integer(1_800_000_000_000),
      "pending": .array([.object(["principal": .string("p2"), "count": .integer(3)])]),
      "overdue_count": .integer(2),
      "overdue": .array([
        .object([
          "message": .string("m1"), "recipient": .string("p2"), "age_seconds": .integer(1860),
        ])
      ]),
      "storage": .object([
        "used_bytes": .integer(4096), "budget_bytes": .integer(5000),
        "warning_percent": .integer(80),
      ]),
      "warnings": .array([.string("storage_budget")]),
      "last_cleanup": .object([
        "at_ms": .integer(1_800_000_100_000), "ok": .bool(true), "deliveries": .integer(1),
        "messages": .integer(1), "activity": .integer(0),
      ]),
    ])

    let outcome = run(["health"]) { _ in .success(report) }

    #expect(outcome.status == 0, "the report is shown")
    #expect(
      outcome.harness.standardOutput
        == """
        started: 1800000000000
        storage: 4096 of 5000 bytes, warning at 80%
        warning: storage_budget
        pending: p2\t3
        overdue: 2
        m1\tp2\t1860s
        last cleanup: 1800000100000 deliveries=1 messages=1 activity=0

        """, "one line per fact, overdue entries under the count")
  }

  @Test func test_health_withoutACleanup_saysSo_andAFailedOneIsShownAsFailed() {
    let none = WireValue.object(Self.minimalHealth(lastCleanup: .null))
    let failed = WireValue.object(
      Self.minimalHealth(lastCleanup: .object(["at_ms": .integer(7), "ok": .bool(false)])))

    let noneOutcome = run(["health"]) { _ in .success(none) }
    let failedOutcome = run(["health"]) { _ in .success(failed) }

    #expect(noneOutcome.harness.standardOutput.hasSuffix("last cleanup: none\n"), "no cleanup yet")
    #expect(
      failedOutcome.harness.standardOutput.hasSuffix("last cleanup: 7 failed\n"), "a failed run")
  }

  @Test func test_healthCleanup_printsWhatWasDeleted() {
    let outcome = run(["health", "cleanup"]) { _ in
      .success(
        .object(["deliveries": .integer(4), "messages": .integer(3), "activity": .integer(9)]))
    }

    #expect(
      outcome.harness.standardOutput == "deliveries: 4\nmessages: 3\nactivity: 9\n",
      "the three counts")
  }

  private static func minimalHealth(lastCleanup: WireValue) -> [String: WireValue] {
    [
      "started_at_ms": .integer(1), "pending": .array([]), "overdue_count": .integer(0),
      "overdue": .array([]),
      "storage": .object([
        "used_bytes": .integer(1), "budget_bytes": .integer(2), "warning_percent": .integer(80),
      ]),
      "warnings": .array([]), "last_cleanup": lastCleanup,
    ]
  }
}
