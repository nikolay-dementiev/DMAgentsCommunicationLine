import CommunicationLineService
import Foundation
import Testing

private final class Lines: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: [String] = []
  var all: [String] { lock.withLock { stored } }
  func add(_ line: String) { lock.withLock { stored.append(line) } }
}

struct ServiceCommandTests {
  @Test func test_withoutAFolder_isAUsageError() {
    let lines = Lines()

    let outcome = ServiceCommand.start(arguments: [], errorOutput: lines.add)

    #expect(outcome.exitStatus == ServiceCommand.usageStatus, "no folder is a usage error")
    #expect(
      lines.all.contains { $0.hasPrefix("usage: commline-service") }, "the usage line is printed")
  }

  @Test func test_withMoreThanOneFolderOrAnOption_isAUsageError() {
    for arguments in [["/tmp/a", "/tmp/b"], ["--bogus"], ["--token", "x", "/tmp/a"]] {
      let outcome = ServiceCommand.start(arguments: arguments, errorOutput: { _ in })
      #expect(outcome.exitStatus == ServiceCommand.usageStatus, "\(arguments) is a usage error")
    }
  }

  @Test func test_whenAnotherInstanceRuns_reportsItAndUsesItsOwnStatus() throws {
    let folder = URL(
      fileURLWithPath: "/tmp/cl-" + UUID().uuidString.prefix(8).lowercased(), isDirectory: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let running = try ServiceHost.start(storeFolder: folder)
    defer { running.stop() }
    let lines = Lines()

    let outcome = ServiceCommand.start(arguments: [folder.path], errorOutput: lines.add)

    #expect(
      outcome.exitStatus == ServiceCommand.alreadyRunningStatus,
      "a second instance has its own status")
    #expect(lines.all.contains { $0.contains("already running") }, "and says so")
  }
}
