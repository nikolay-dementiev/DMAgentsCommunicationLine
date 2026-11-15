import CommunicationLineService
import CommunicationLineWire
import Darwin
import Foundation
import Testing

private func shortFolder() -> URL {
  URL(fileURLWithPath: "/tmp/cl-" + UUID().uuidString.prefix(8).lowercased(), isDirectory: true)
}

/// A descriptor limit that does not depend on the machine running the tests.
private struct FixedDescriptorLimits: DescriptorLimits {
  let soft: UInt64

  func raiseSoftLimit() throws -> UInt64 { soft }
}

private final class SpyReporter: FailureReporter, @unchecked Sendable {
  private let lock = NSLock()
  private var stored: [String] = []

  var operations: [String] { lock.withLock { stored } }

  func report(_ error: any Error, operation: String) {
    lock.withLock { stored.append(operation) }
  }
}

struct DescriptorHeadroomTests {
  /// A limit with room for exactly `connections` connections of three descriptors each.
  private func limits(fitting connections: Int) -> FixedDescriptorLimits {
    FixedDescriptorLimits(
      soft: UInt64(
        DescriptorBudget.reservedDescriptors + connections
          * DescriptorBudget.descriptorsPerConnection
      ))
  }

  private func ownerCredential(_ host: ServiceHost) -> WireResponse? {
    try? SocketExchange.call(
      socketPath: host.socketPath, request: WireRequest(token: nil, operation: "owner.credential"),
      maximumFrame: host.frameMaximum)
  }

  @Test func test_theConnectionAfterTheSafeCount_isRefusedWithAnAnswer_andTheServiceKeepsServing()
    throws
  {
    let folder = shortFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let reporter = SpyReporter()
    let host = try ServiceHost.start(
      storeFolder: folder, requestTimeout: 5, reporter: reporter, descriptors: limits(fitting: 2))
    defer { host.stop() }
    let first = try UnixSocketClient.connect(path: host.socketPath)
    let second = try UnixSocketClient.connect(path: host.socketPath)
    let started = Date()

    let refused = ownerCredential(host)

    #expect(
      refused?.failure?.code == .tooManyConnections,
      "the third connection got the answer, not a closed socket: \(String(describing: refused))")
    #expect(Date().timeIntervalSince(started) < 2, "it was refused at once, not at a timeout")
    first.close()
    let deadline = Date().addingTimeInterval(3)
    var served = ownerCredential(host)?.isSuccess == true
    while !served && Date() < deadline {
      Thread.sleep(forTimeInterval: 0.05)
      served = ownerCredential(host)?.isSuccess == true
    }
    #expect(served, "a place that was freed serves the next request: the service kept serving")
    second.close()
  }

  @Test func test_aConnectionLimitThatDoesNotFit_isReportedAtStart() throws {
    let folder = shortFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let reporter = SpyReporter()
    let host = try ServiceHost.start(
      storeFolder: folder, reporter: reporter, descriptors: limits(fitting: 2))
    defer { host.stop() }

    #expect(
      reporter.operations.contains("descriptor limit"),
      "the default limits.connections does not fit under two connections, and the log says so")
  }

  @Test func test_aConnectionLimitThatFits_isNotReported() throws {
    let folder = shortFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let reporter = SpyReporter()
    let host = try ServiceHost.start(
      storeFolder: folder, reporter: reporter, descriptors: limits(fitting: 100_000))
    defer { host.stop() }

    #expect(!reporter.operations.contains("descriptor limit"), "nothing to say when it fits")
  }

  @Test func test_theSystemLimits_raiseTheSoftLimitTowardTheHardLimit() throws {
    var before = rlimit()
    getrlimit(RLIMIT_NOFILE, &before)

    let raised = try SystemDescriptorLimits().raiseSoftLimit()

    var after = rlimit()
    getrlimit(RLIMIT_NOFILE, &after)
    #expect(UInt64(after.rlim_cur) == raised, "the value returned is the limit now in force")
    #expect(
      raised >= min(UInt64(before.rlim_max), 4096),
      "the soft limit was lifted to at least 4096, or to the hard limit when that is lower")
  }
}
