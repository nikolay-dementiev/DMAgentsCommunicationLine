import CommunicationLineCLI
import CommunicationLineWire
import Darwin
import Foundation
import Testing

struct TokenOutTests {
  private static let secret = "the-new-token-0123456789"
  private let store = ["--store", "/tmp/cl-store"]

  private func freshPath() -> String {
    "/tmp/clo-" + UUID().uuidString.prefix(8).lowercased()
  }

  private func issuing(_ arguments: [String], stdin: String? = "tok-0123456789\n") -> (
    status: Int32, harness: CLIHarness
  ) {
    let harness = CLIHarness(
      stdin: stdin, answer: { _ in .success(.object(["token": .string(Self.secret)])) })
    return (harness.run(store + arguments), harness)
  }

  @Test func test_withoutTokenOut_theThreeCommandsAreUsageErrorsAndSendNothing() {
    for arguments in [["owner", "init"], ["owner", "rotate"], ["credential", "issue", "p1"]] {
      let outcome = issuing(arguments)

      #expect(
        outcome.status == CommandExitStatus.usage.rawValue, "\(arguments) is a usage error")
      #expect(outcome.harness.connection.requests.isEmpty, "\(arguments) sends nothing")
      #expect(
        outcome.harness.standardError.contains("--token-out"), "\(arguments) names the option")
      #expect(!outcome.harness.standardOutput.contains(Self.secret), "no token is printed")
    }
  }

  @Test func test_theTokenGoesToAPrivateFile_andOnlyThePathIsPrinted() throws {
    for base in [["owner", "init"], ["owner", "rotate"], ["credential", "issue", "p1"]] {
      let target = freshPath()
      let fresh = base + ["--token-out", target]
      defer { unlink(target) }

      let outcome = issuing(fresh)

      #expect(outcome.status == 0, "\(fresh) succeeds: \(outcome.harness.standardError)")
      let written = try String(contentsOfFile: target, encoding: .utf8)
      #expect(written == Self.secret + "\n", "\(fresh): the file holds the token")
      var info = stat()
      #expect(stat(target, &info) == 0, "the file can be inspected")
      #expect(info.st_mode & 0o777 == 0o600, "\(fresh): only the owner can read it")
      #expect(outcome.harness.standardOutput == "token file: \(target)\n", "\(fresh): path only")
      #expect(!outcome.harness.standardError.contains(Self.secret), "\(fresh): no token on stderr")
    }
  }

  @Test func test_json_printsThePathAndNeverTheToken() throws {
    let target = freshPath()
    defer { unlink(target) }

    let outcome = issuing(["--json", "owner", "init", "--token-out", target])

    let decoded = try JSONSerialization.jsonObject(
      with: Data(outcome.harness.standardOutput.utf8))
    #expect((decoded as? [String: String]) == ["token_file": target], "just the path")
    #expect(!outcome.harness.standardOutput.contains(Self.secret), "the token is not in the JSON")
  }

  @Test func test_anExistingFile_isRefusedUntouched_andNothingIsSent() throws {
    let target = freshPath()
    FileManager.default.createFile(atPath: target, contents: Data("precious".utf8))
    defer { unlink(target) }

    let outcome = issuing(["owner", "init", "--token-out", target])

    #expect(outcome.status != 0, "an existing file is refused")
    #expect(outcome.harness.connection.requests.isEmpty, "the service is not asked")
    #expect(
      try String(contentsOfFile: target, encoding: .utf8) == "precious", "the file is untouched")
  }

  @Test func test_aSymbolicLink_isRefused_andItsTargetIsUntouched() throws {
    let victim = freshPath()
    let link = freshPath()
    FileManager.default.createFile(atPath: victim, contents: Data("precious".utf8))
    symlink(victim, link)
    defer {
      unlink(victim)
      unlink(link)
    }

    let outcome = issuing(["owner", "init", "--token-out", link])

    #expect(outcome.status != 0, "a link is refused")
    #expect(outcome.harness.connection.requests.isEmpty, "the service is not asked")
    #expect(
      try String(contentsOfFile: victim, encoding: .utf8) == "precious", "the target is untouched")
  }

  @Test func test_whenTheServiceFails_noFileIsLeftBehind() {
    let target = freshPath()
    defer { unlink(target) }
    let harness = CLIHarness(
      stdin: "tok-0123456789\n", answer: { _ in .failure(code: .unknownToken, message: "bad") })

    let status = harness.run(store + ["owner", "rotate", "--token-out", target])

    #expect(status == CommandExitStatus.authentication.rawValue, "the failure status")
    #expect(!FileManager.default.fileExists(atPath: target), "the reserved file is removed")
  }

  @Test func test_aSuccessWithoutAToken_isAProtocolError_andNoFileIsLeftBehind() {
    let target = freshPath()
    defer { unlink(target) }
    let harness = CLIHarness(answer: { _ in .success(.object([:])) })

    let status = harness.run(store + ["owner", "init", "--token-out", target])

    #expect(status == CommandExitStatus.protocolError.rawValue, "no token is a protocol error")
    #expect(!FileManager.default.fileExists(atPath: target), "no empty token file stays")
  }
}
