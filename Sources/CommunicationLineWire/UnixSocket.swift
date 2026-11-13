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
  private let lock = NSLock()
  private var isClosed = false

  public init(descriptor: Int32) {
    self.descriptor = descriptor
  }

  deinit { close() }

  public func read(upTo count: Int) throws -> Data {
    var buffer = [UInt8](repeating: 0, count: count)
    while true {
      let received = buffer.withUnsafeMutableBytes {
        Darwin.read(descriptor, $0.baseAddress, count)
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
      let sent = bytes.withUnsafeBytes {
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
  public static func connect(path: String) throws -> FileDescriptorStream {
    let descriptor = try UnixSocket.makeStreamSocket()
    let result = try UnixSocket.withAddress(path: path) { Darwin.connect(descriptor, $0, $1) }
    guard result == 0 else {
      let code = errno
      Darwin.close(descriptor)
      throw UnixSocketError.system(operation: "connect", code: code)
    }
    return FileDescriptorStream(descriptor: descriptor)
  }
}

/// One request and its one response over a fresh connection.
public enum SocketExchange {
  public static func call(socketPath: String, request: WireRequest, maximumFrame: Int) throws
    -> WireResponse
  {
    let stream = try UnixSocketClient.connect(path: socketPath)
    let codec = FrameCodec(maximumSize: maximumFrame)
    try codec.writeFrame(try WireCoding.encode(request), to: stream)
    guard let answer = try codec.readFrame(from: stream) else { throw FrameError.truncated }
    return try WireCoding.decodeResponse(answer)
  }
}
