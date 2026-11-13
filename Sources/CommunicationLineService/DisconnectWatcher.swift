import Darwin
import Foundation

/// Watches one connection while its request is being answered and reports when the client has
/// gone. A parked `wait` would otherwise keep its thread, its connection place and its waiter
/// slot until its time ran out, with nobody left to answer.
///
/// The client of this protocol sends one request and then only reads, so an end of stream or a
/// hang-up on the connection means it left. Bytes that arrive instead are left alone.
final class DisconnectWatcher: @unchecked Sendable {
  enum Failure: Error { case pipe(code: Int32) }

  private let descriptor: Int32
  private let onDisconnect: @Sendable () -> Void
  private let wakeRead: Int32
  private let wakeWrite: Int32
  private let finished = DispatchSemaphore(value: 0)

  init(descriptor: Int32, onDisconnect: @escaping @Sendable () -> Void) throws {
    var ends: [Int32] = [0, 0]
    guard pipe(&ends) == 0 else { throw Failure.pipe(code: errno) }
    self.descriptor = descriptor
    self.onDisconnect = onDisconnect
    wakeRead = ends[0]
    wakeWrite = ends[1]
    Thread.detachNewThread { self.watch() }
  }

  /// Ends the watch and returns once the watching thread no longer touches the descriptor, so the
  /// caller may close it.
  func stop() {
    var byte: UInt8 = 1
    _ = write(wakeWrite, &byte, 1)
    finished.wait()
    close(wakeRead)
    close(wakeWrite)
  }

  private func watch() {
    defer { finished.signal() }
    while true {
      var watched = [
        pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0),
        pollfd(fd: wakeRead, events: Int16(POLLIN), revents: 0),
      ]
      let ready = poll(&watched, 2, -1)
      if ready < 0 {
        if errno == EINTR { continue }
        onDisconnect()
        return
      }
      if watched[1].revents != 0 { return }
      let events = Int32(watched[0].revents)
      if events & (POLLHUP | POLLERR | POLLNVAL) != 0 {
        onDisconnect()
        return
      }
      guard events & POLLIN != 0 else { continue }
      var byte: UInt8 = 0
      let peeked = recv(descriptor, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
      if peeked == 0 || (peeked < 0 && errno != EAGAIN && errno != EINTR) {
        onDisconnect()
        return
      }
      // The client wrote more than one request; the bytes stay unread. Looking again at once would
      // spin, so look again shortly.
      var pause = pollfd(fd: wakeRead, events: Int16(POLLIN), revents: 0)
      if poll(&pause, 1, 100) > 0 { return }
    }
  }
}
