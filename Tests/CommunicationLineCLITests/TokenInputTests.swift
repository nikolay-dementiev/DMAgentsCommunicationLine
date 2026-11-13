import CommunicationLineCLI
import Darwin
import Foundation
import Testing

private func tokenFile(mode: mode_t, contents: String = "tok-1234\n") throws -> String {
  let path = "/tmp/clt-" + UUID().uuidString.prefix(8).lowercased()
  guard FileManager.default.createFile(atPath: path, contents: Data(contents.utf8)) else {
    throw POSIXError(.EIO)
  }
  chmod(path, mode)
  return path
}

struct TokenInputTests {
  private func reader(stdin: String? = nil) -> TokenReader {
    TokenReader(standardInput: { stdin })
  }

  @Test func test_aPrivateTokenFile_isRead_andTrimmed() throws {
    let path = try tokenFile(mode: 0o600, contents: "  tok-1234 \n")
    defer { unlink(path) }

    #expect(try reader().read(tokenFile: path) == "tok-1234", "the token without whitespace")
  }

  @Test func test_aTokenFileOthersCanAccess_isRefused() throws {
    for mode: mode_t in [0o644, 0o640, 0o604, 0o660, 0o666, 0o700 | 0o010] {
      let path = try tokenFile(mode: mode)
      defer { unlink(path) }

      #expect(throws: TokenInputError.insecureMode(path: path, mode: Int(mode))) {
        _ = try reader().read(tokenFile: path)
      }
    }
  }

  @Test func test_aTokenFileThatIsMissingEmptyOrNotAFile_isRefused() throws {
    #expect(throws: TokenInputError.unreadable("/tmp/clt-no-such-file")) {
      _ = try reader().read(tokenFile: "/tmp/clt-no-such-file")
    }
    let empty = try tokenFile(mode: 0o600, contents: " \n")
    defer { unlink(empty) }
    #expect(throws: TokenInputError.empty) { _ = try reader().read(tokenFile: empty) }
    #expect(throws: TokenInputError.notRegularFile("/private/tmp")) {
      _ = try reader().read(tokenFile: "/private/tmp")
    }
  }

  @Test func test_aSymbolicLinkToATokenFile_isRefused() throws {
    let target = try tokenFile(mode: 0o600)
    let link = target + "-link"
    symlink(target, link)
    defer {
      unlink(target)
      unlink(link)
    }

    #expect(throws: TokenInputError.self) { _ = try reader().read(tokenFile: link) }
  }

  @Test func test_withoutAFile_theTokenIsTheFirstLineOfStandardInput() throws {
    #expect(
      try reader(stdin: "tok-from-stdin\nsecond line\n").read(tokenFile: nil) == "tok-from-stdin",
      "only the first line is the token")
    #expect(throws: TokenInputError.notSupplied) { _ = try reader(stdin: nil).read(tokenFile: nil) }
    #expect(throws: TokenInputError.empty) { _ = try reader(stdin: "\n").read(tokenFile: nil) }
  }
}

struct CommandExitStatusTests {
  @Test func test_theTableIsStable() {
    let table: [(CommandExitStatus, Int32)] = [
      (.success, 0), (.failure, 1), (.usage, 2), (.unreachable, 3), (.authentication, 4),
      (.permission, 5), (.notFound, 6), (.invalidInput, 7), (.protocolError, 8), (.timedOut, 9),
      (.tokenInput, 10),
    ]
    for (status, value) in table {
      #expect(status.rawValue == value, "\(status) is \(value)")
    }
  }

  @Test func test_aTokenFileOfAnotherUser_isRefused() throws {
    let path = try tokenFile(mode: 0o600)
    defer { unlink(path) }
    let someoneElse = UInt32(geteuid()) + 1
    let strict = TokenReader(standardInput: { nil }, userID: someoneElse)

    #expect(throws: TokenInputError.notOwnedByUser(path), "the file is not owned by that user") {
      _ = try strict.read(tokenFile: path)
    }
    #expect(
      try reader().read(tokenFile: path) == "tok-1234", "the owner of the file reads it as before")
  }
}
