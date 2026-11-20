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
      storeFolder: folder, requestTimeout: 120, reporter: reporter, ownerReserve: 0,
      descriptors: limits(fitting: 2))
    defer { host.stop() }
    let first = try UnixSocketClient.connect(path: host.socketPath)
    let second = try UnixSocketClient.connect(path: host.socketPath)
    let started = Date()

    let refused = ownerCredential(host)

    #expect(
      refused?.failure?.code == .tooManyConnections,
      "the third connection got the answer, not a closed socket: \(String(describing: refused))")
    #expect(Date().timeIntervalSince(started) < 60, "it was refused at once, not at a timeout")
    first.close()
    let deadline = Date().addingTimeInterval(60)
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

  // MARK: - The raise, with limits the machine does not have

  /// What the system answers for a hard limit that is not set (`RLIM_INFINITY`).
  private let unlimited = rlim_t.max >> 1

  private final class WrittenLimits: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [rlim_t] = []

    var values: [rlim_t] { lock.withLock { stored } }
    func add(_ value: rlim_t) { lock.withLock { stored.append(value) } }
  }

  private func system(
    soft: rlim_t, hard: rlim_t, ceiling: rlim_t, accepts: Bool = true, written: WrittenLimits
  ) -> SystemDescriptorLimits {
    SystemDescriptorLimits(
      read: { rlimit(rlim_cur: soft, rlim_max: hard) },
      write: { limit in
        written.add(limit.rlim_cur)
        return accepts
      }, ceiling: { ceiling })
  }

  @Test func test_aLowSoftLimit_isRaisedToTheCeiling_whenTheHardLimitIsHigher() throws {
    let written = WrittenLimits()

    let raised = try system(
      soft: 256, hard: unlimited, ceiling: 10_240, written: written
    ).raiseSoftLimit()

    #expect(raised == 10_240, "the limit in force is the ceiling of the system")
    #expect(written.values == [10_240], "and it was asked for once")
  }

  @Test func test_aLowSoftLimit_isRaisedToTheHardLimit_whenThatIsLower() throws {
    let written = WrittenLimits()

    let raised = try system(soft: 256, hard: 4096, ceiling: 10_240, written: written)
      .raiseSoftLimit()

    #expect(raised == 4096, "the hard limit is as far as it goes")
    #expect(written.values == [4096], "and that is what was asked for")
  }

  @Test func test_aSoftLimitAlreadyAtTheTarget_isNotWrittenAgain() throws {
    let written = WrittenLimits()

    let raised = try system(
      soft: 10_240, hard: unlimited, ceiling: 10_240, written: written
    ).raiseSoftLimit()

    #expect(raised == 10_240, "the limit stays")
    #expect(written.values.isEmpty, "nothing was written")
  }

  @Test func test_aRaiseTheSystemRefuses_leavesTheLimitAsItWas() throws {
    let written = WrittenLimits()

    let raised = try system(
      soft: 256, hard: unlimited, ceiling: 10_240, accepts: false, written: written
    ).raiseSoftLimit()

    #expect(raised == 256, "the answer is the limit that is still in force, not the one asked for")
  }

  @Test func test_aLimitThatCannotBeRead_isAnError() throws {
    let unreadable = SystemDescriptorLimits(read: { nil }, write: { _ in true }, ceiling: { 0 })

    #expect(throws: ServiceHostError.self) { _ = try unreadable.raiseSoftLimit() }
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
