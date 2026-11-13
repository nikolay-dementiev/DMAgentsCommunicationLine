import CommunicationLineCLI
import CommunicationLineWire
import Foundation
import Testing

struct CommandRequestTests {
  private let store = ["--store", "/tmp/cl-store"]
  private static let issued = WireValue.object(["token": .string("tok-issued-0123456789")])

  /// Runs `arguments` with a private token file and returns the single request that was sent.
  private func sent(
    _ arguments: [String], file: TokenFileFixture = TokenFileFixture(),
    answer: WireResponse = .success()
  ) throws -> WireRequest {
    defer { file.remove() }
    let harness = CLIHarness(answer: { _ in answer })
    let status = harness.run(store + ["--token-file", file.path] + arguments)
    #expect(status == 0, "\(arguments) succeeds: \(harness.standardError)")
    return try #require(harness.connection.requests.first, "\(arguments) sent a request")
  }

  @Test func test_send_carriesTheTokenAndEveryArgument() throws {
    let request = try sent([
      "send", "--to", "p1", "--to", "p2", "--subject", "hi", "--body", "text",
    ])

    #expect(request.operation == "send", "operation name")
    #expect(request.token == "tok-0123456789", "the token from the file")
    #expect(
      request.arguments == [
        "to": .array([.string("p1"), .string("p2")]), "subject": .string("hi"),
        "body": .string("text"),
      ], "recipients, subject and body")
  }

  @Test func test_send_readsTheBodyFromAFile() throws {
    let body = "/tmp/clt-body-" + UUID().uuidString.prefix(8).lowercased()
    FileManager.default.createFile(atPath: body, contents: Data("from file\n".utf8))
    defer { unlink(body) }

    let request = try sent(["send", "--to", "p1", "--subject", "s", "--body-file", body])

    #expect(request.arguments["body"] == .string("from file\n"), "the file is the body")
  }

  @Test func test_send_refusesABodyFileThatIsNotUTF8() {
    let body = "/tmp/clt-body-" + UUID().uuidString.prefix(8).lowercased()
    FileManager.default.createFile(atPath: body, contents: Data([0x66, 0xFF, 0xFE, 0x67]))
    let file = TokenFileFixture()
    defer {
      unlink(body)
      file.remove()
    }
    let harness = CLIHarness()

    let status = harness.run(
      store + [
        "--token-file", file.path, "send", "--to", "p1", "--subject", "s", "--body-file", body,
      ])

    #expect(
      status == CommandExitStatus.usage.rawValue, "bytes that are not UTF-8 are a usage error")
    #expect(harness.connection.requests.isEmpty, "nothing was sent with rewritten bytes")
  }

  @Test func test_agentCommands_buildTheirRequests() throws {
    #expect(try sent(["inbox"]).arguments.isEmpty, "inbox needs no argument")
    #expect(try sent(["inbox", "--after", "7"]).arguments == ["after": .integer(7)], "cursor")
    #expect(try sent(["read", "m1"]).arguments == ["id": .string("m1")], "read")
    #expect(try sent(["acknowledge", "m1"]).operation == "acknowledge", "acknowledge")
    #expect(try sent(["wait", "--timeout", "5"]).arguments == ["timeout": .integer(5)], "wait")
    #expect(try sent(["wait"]).arguments.isEmpty, "wait without a timeout uses the service default")
  }

  @Test func test_ownerCommands_buildTheirRequests() throws {
    let create = try sent([
      "principal", "create", "--family", "ops", "--role", "head", "--name", "lead",
    ])
    #expect(create.operation == "principal.create", "operation")
    #expect(
      create.arguments == [
        "family": .string("ops"), "role": .string("head"), "name": .string("lead"),
      ], "family, role and name")
    #expect(
      try sent(["principal", "disable", "p1"]).arguments == ["principal": .string("p1")], "disable")
    #expect(try sent(["principal", "enable", "p1"]).operation == "principal.enable", "enable")
    let out = "/tmp/clq-" + UUID().uuidString.prefix(8).lowercased()
    defer { unlink(out) }
    #expect(
      try sent(
        ["credential", "issue", "p1", "--token-out", out], answer: .success(Self.issued)
      ).operation == "credential.issue", "issue")
    #expect(
      try sent(["rule", "add", "A", "B"]).arguments == ["from": .string("A"), "to": .string("B")],
      "rule add")
    #expect(try sent(["rule", "remove", "A", "B"]).operation == "rule.remove", "rule remove")
    #expect(try sent(["rule", "list"]).operation == "rule.list", "rule list")
    #expect(try sent(["grant", "revoke", "3"]).arguments == ["id": .integer(3)], "grant revoke")
    #expect(try sent(["grant", "list"]).operation == "grant.list", "grant list")
  }

  @Test func test_grantAdd_namesReaderAndTarget() throws {
    let request = try sent([
      "grant", "add", "--reader-family", "audit", "--target-principal", "p9",
      "--expires-at-ms", "1900000000000",
    ])

    #expect(
      request.arguments == [
        "reader_kind": .string("family"), "reader": .string("audit"),
        "target_kind": .string("principal"), "target": .string("p9"),
        "expires_at_ms": .integer(1_900_000_000_000),
      ], "reader, target and expiry")
    let global = try sent(["grant", "add", "--reader-principal", "p1", "--target-global"])
    #expect(global.arguments["target_kind"] == .string("global"), "an explicit global target")
    #expect(global.arguments["target"] == nil, "a global target names nothing")
  }

  @Test func test_settingSet_typesTheValue() throws {
    #expect(try sent(["setting", "set", "k", "5"]).arguments["value"] == .integer(5), "integer")
    #expect(try sent(["setting", "set", "k", "true"]).arguments["value"] == .bool(true), "bool")
    #expect(try sent(["setting", "set", "k", "abc"]).arguments["value"] == .string("abc"), "text")
    let scoped = try sent(["setting", "set", "k", "5", "--scope", "family", "--subject", "ops"])
    #expect(scoped.arguments["scope"] == .string("family"), "scope")
    #expect(scoped.arguments["subject"] == .string("ops"), "subject")
    #expect(try sent(["setting", "get", "k"]).arguments == ["key": .string("k")], "get")
  }

  @Test func test_ownerInit_needsNoToken_andOwnerRotateNeedsOne() {
    let harness = CLIHarness(answer: { _ in .success(Self.issued) })

    let out = "/tmp/clq-" + UUID().uuidString.prefix(8).lowercased()
    defer { unlink(out) }
    let status = harness.run(["--store", "/tmp/cl-store", "owner", "init", "--token-out", out])

    #expect(status == 0, "bootstrap without any token input")
    #expect(harness.connection.requests.first?.token == nil, "the request carries no token")
    #expect(harness.connection.requests.first?.operation == "owner.credential", "operation")
    let rotate = CLIHarness(stdin: nil)
    #expect(
      rotate.run(["--store", "/tmp/cl-store", "owner", "rotate", "--token-out", out])
        == CommandExitStatus.tokenInput.rawValue,
      "rotation without a token is a token input error")
  }

  @Test func test_theSocketIsTheStoreFolderSocketOrTheGivenPath() {
    let byStore = CLIHarness(answer: { _ in .success(Self.issued) })
    let first = "/tmp/clq-" + UUID().uuidString.prefix(8).lowercased()
    let second = "/tmp/clq-" + UUID().uuidString.prefix(8).lowercased()
    defer {
      unlink(first)
      unlink(second)
    }
    _ = byStore.run(["--store", "/tmp/cl-store", "owner", "init", "--token-out", first])
    let bySocket = CLIHarness(answer: { _ in .success(Self.issued) })
    _ = bySocket.run(["--socket", "/tmp/elsewhere.sock", "owner", "init", "--token-out", second])

    #expect(byStore.connectedSockets == ["/tmp/cl-store/commline.sock"], "the store's socket")
    #expect(bySocket.connectedSockets == ["/tmp/elsewhere.sock"], "the given socket")
  }

  @Test func test_activity_asksForOnePageOfTheLog() throws {
    let all = try sent(["activity"])
    let page = try sent(["activity", "--after", "40", "--limit", "10"])

    #expect(all.operation == "activity.list", "the operation")
    #expect(all.arguments.isEmpty, "without options the service picks the page")
    #expect(
      page.arguments == ["after": .integer(40), "limit": .integer(10)], "cursor and page size")
  }

  @Test func test_health_askForTheReportAndForACleanup() throws {
    let report = try sent(["health"])
    let cleanup = try sent(["health", "cleanup"])

    #expect(report.operation == "health", "the report")
    #expect(report.arguments.isEmpty, "it takes no argument")
    #expect(cleanup.operation == "health.cleanup", "the owner runs cleanup now")
    #expect(cleanup.arguments.isEmpty, "it takes no argument")
  }
}
