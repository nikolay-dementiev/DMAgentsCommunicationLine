import CommunicationLineService
import CommunicationLineWire
import Foundation
import Testing

private func shortFolder() -> URL {
  URL(fileURLWithPath: "/tmp/cl-" + UUID().uuidString.prefix(8).lowercased(), isDirectory: true)
}

/// A runner whose shared dispatch pool is busy with blocked work must still see the service cut a
/// connection at its deadline: the deadlines must not wait for a free worker of that pool.
struct DeadlineIndependenceTests {
  /// Fills the shared pool with work items that block until the returned value is released.
  private final class PoolBlocker {
    private let release = DispatchSemaphore(value: 0)
    private let count: Int

    init(count: Int) {
      self.count = count
      for _ in 0..<count {
        DispatchQueue.global().async { [release] in _ = release.wait(timeout: .now() + 60) }
      }
      // Let the pool take the items up: a new timer cannot be served by a worker that is not free.
      Thread.sleep(forTimeInterval: 0.5)
    }

    func unblock() { for _ in 0..<count { release.signal() } }
  }

  @Test func test_aSilentConnection_isCutAtTheRequestDeadline_whileTheSharedPoolIsBlocked() throws {
    let folder = shortFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let host = try ServiceHost.start(
      storeFolder: folder, requestTimeout: 120, requestDeadline: 0.5)
    defer { host.stop() }
    let blocker = PoolBlocker(count: 400)
    defer { blocker.unblock() }
    let silent = try UnixSocketClient.connect(
      path: host.socketPath, deadline: Date().addingTimeInterval(15))
    defer { silent.close() }

    let started = Date()
    let read = try? silent.read(upTo: 1)
    let elapsed = Date().timeIntervalSince(started)

    #expect(read?.isEmpty == true, "the service closed the connection that had sent nothing")
    #expect(elapsed < 5, "it was cut after \(elapsed) s although the deadline is 0.5 s")
  }
}
