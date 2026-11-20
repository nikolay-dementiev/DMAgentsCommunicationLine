import Darwin
import Foundation

public enum UnixSocketError: Error, Equatable {
  /// A socket path must fit the address structure of the system.
  case pathTooLong(length: Int, limit: Int)
  case system(operation: String, code: Int32)
}

/// A connected stream socket (or any descriptor) used as a frame source and sink.
public final class FileDescriptorStream: ByteSource, ByteSink, @unchecked Sendable {
  public let descriptor: Int32
  /// When set, every read and write gives up with `ETIMEDOUT` once this moment has passed, however
  /// many reads and writes it took to get there.
  public let deadline: Date?
  private let lock = NSLock()
  private var isClosed = false

  public init(descriptor: Int32, deadline: Date? = nil) {
    self.descriptor = descriptor
    self.deadline = deadline
  }

  /// Waits until the descriptor is ready for `events`, or throws once the deadline has passed.
  private func awaitReady(_ events: Int32, operation: String) throws {
    guard let deadline else { return }
    while true {
      let remaining = deadline.timeIntervalSinceNow
      guard remaining > 0 else {
        throw UnixSocketError.system(operation: operation, code: ETIMEDOUT)
      }
      var watched = pollfd(fd: descriptor, events: Int16(events), revents: 0)
      let milliseconds = Int32(min(remaining * 1000 + 1, Double(Int32.max)))
      let ready = poll(&watched, 1, milliseconds)
      if ready > 0 { return }
      if ready < 0, errno != EINTR {
        throw UnixSocketError.system(operation: operation, code: errno)
      }
    }
  }

  deinit { close() }

  public func read(upTo count: Int) throws -> Data {
    // A declared frame size comes from the peer: never allocate it all before a byte has arrived.
    let chunk = min(count, 65_536)
    var buffer = [UInt8](repeating: 0, count: chunk)
    while true {
      try awaitReady(POLLIN, operation: "read")
      let received = buffer.withUnsafeMutableBytes {
        Darwin.read(descriptor, $0.baseAddress, chunk)
      }
      if received >= 0 { return Data(buffer.prefix(received)) }
      if errno == EINTR { continue }
      throw UnixSocketError.system(operation: "read", code: errno)
    }
  }

  public func write(_ data: Data) throws {
    var offset = 0
    let bytes = [UInt8](data)
    while offset < bytes.count {
      try awaitReady(POLLOUT, operation: "write")
      let sent = bytes.withUnsafeBytes {
        // The loop runs only while bytes remain, so the base address exists.
        Darwin.write(descriptor, $0.baseAddress! + offset, bytes.count - offset)
      }
      if sent >= 0 {
        offset += sent
      } else if errno != EINTR {
        throw UnixSocketError.system(operation: "write", code: errno)
      }
    }
  }

  public func close() {
    lock.lock()
    defer { lock.unlock() }
    guard !isClosed else { return }
    isClosed = true
    Darwin.close(descriptor)
  }
}

public enum UnixSocket {
  /// Checks the path before a descriptor is opened for it.
  public static func requireFits(path: String) throws {
    let limit = MemoryLayout.size(ofValue: sockaddr_un().sun_path) - 1
    let length = path.utf8.count
    guard length <= limit else { throw UnixSocketError.pathTooLong(length: length, limit: limit) }
  }

  /// Applies `body` to the address of the socket at `path`.
  public static func withAddress<Result>(
    path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> Result
  ) throws -> Result {
    var address = sockaddr_un()
    let limit = MemoryLayout.size(ofValue: address.sun_path) - 1
    let bytes = Array(path.utf8)
    guard bytes.count <= limit else {
      throw UnixSocketError.pathTooLong(length: bytes.count, limit: limit)
    }
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
      for (index, byte) in bytes.enumerated() { buffer[index] = byte }
    }
    let length = socklen_t(MemoryLayout<sockaddr_un>.size)
    return try withUnsafePointer(to: &address) {
      try $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { try body($0, length) }
    }
  }

  /// A new stream socket that does not raise SIGPIPE when the peer is gone.
  public static func makeStreamSocket() throws -> Int32 {
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw UnixSocketError.system(operation: "socket", code: errno) }
    var on: Int32 = 1
    guard
      setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        == 0
    else {
      let code = errno
      Darwin.close(descriptor)
      throw UnixSocketError.system(operation: "setsockopt", code: code)
    }
    return descriptor
  }
}

public enum UnixSocketClient {
  /// Connects to the socket at `path`. With a `deadline`, the connection attempt and every later
  /// read and write on the stream stop at that moment: a service that accepts and then says
  /// nothing cannot hold the caller.
  public static func connect(
    path: String, deadline: Date? = nil,
    openSocket: () throws -> Int32 = UnixSocket.makeStreamSocket
  ) throws -> FileDescriptorStream {
    try UnixSocket.requireFits(path: path)
    let descriptor = try openSocket()
    let flags = fcntl(descriptor, F_GETFL)
    if deadline != nil { _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) }
    let result = try UnixSocket.withAddress(path: path) { Darwin.connect(descriptor, $0, $1) }
    guard result == 0 else {
      // A full listen queue answers a non-blocking connect with EAGAIN instead of waiting.
      let code = errno == EAGAIN || errno == EINPROGRESS ? ETIMEDOUT : errno
      Darwin.close(descriptor)
      throw UnixSocketError.system(operation: "connect", code: code)
    }
    if deadline != nil { _ = fcntl(descriptor, F_SETFL, flags) }
    return FileDescriptorStream(descriptor: descriptor, deadline: deadline)
  }
}

/// One request and its one response over a fresh connection.
public enum SocketExchange {
  public static func call(
    socketPath: String, request: WireRequest, maximumFrame: Int, deadline: Date? = nil
  ) throws -> WireResponse {
    let stream = try UnixSocketClient.connect(path: socketPath, deadline: deadline)
    let codec = FrameCodec(maximumSize: maximumFrame)
    try codec.writeFrame(try WireCoding.encode(request), to: stream)
    guard let answer = try codec.readFrame(from: stream) else { throw FrameError.truncated }
    return try WireCoding.decodeResponse(answer)
  }
}
