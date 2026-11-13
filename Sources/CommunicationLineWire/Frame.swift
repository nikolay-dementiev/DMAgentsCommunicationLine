import Foundation

/// A stream the frame reader takes bytes from. `read` returns at most `count` bytes, possibly fewer;
/// an empty value means the end of the stream.
public protocol ByteSource {
  func read(upTo count: Int) throws -> Data
}

/// A stream the frame writer puts bytes on. `write` sends all of `data` or throws.
public protocol ByteSink {
  func write(_ data: Data) throws
}

public enum FrameError: Error, Equatable {
  /// The declared (or given) payload is larger than the limit.
  case tooLarge(length: Int, limit: Int)
  /// The stream ended inside a frame.
  case truncated
  /// A frame of length zero carries no request and is refused.
  case empty
}

/// Frames of a four-byte big-endian length followed by that many bytes of payload.
public struct FrameCodec: Sendable {
  public static let headerSize = 4

  public let maximumSize: Int

  public init(maximumSize: Int) {
    self.maximumSize = maximumSize
  }

  public func writeFrame(_ payload: Data, to sink: any ByteSink) throws {
    guard payload.count <= maximumSize else {
      throw FrameError.tooLarge(length: payload.count, limit: maximumSize)
    }
    guard !payload.isEmpty else { throw FrameError.empty }
    var frame = Data(capacity: Self.headerSize + payload.count)
    let length = UInt32(payload.count)
    frame.append(contentsOf: [
      UInt8(truncatingIfNeeded: length >> 24), UInt8(truncatingIfNeeded: length >> 16),
      UInt8(truncatingIfNeeded: length >> 8), UInt8(truncatingIfNeeded: length),
    ])
    frame.append(payload)
    try sink.write(frame)
  }

  /// The next payload, or `nil` when the stream ended before the first byte of a frame. A length above
  /// the limit is refused after the four length bytes, before any payload byte is read.
  public func readFrame(from source: any ByteSource) throws -> Data? {
    let header = try readExactly(Self.headerSize, from: source, allowEndAtStart: true)
    guard let header else { return nil }
    let length = header.reduce(0) { ($0 << 8) | Int($1) }
    guard length <= maximumSize else {
      throw FrameError.tooLarge(length: length, limit: maximumSize)
    }
    guard length > 0 else { throw FrameError.empty }
    guard let payload = try readExactly(length, from: source, allowEndAtStart: false) else {
      throw FrameError.truncated
    }
    return payload
  }

  private func readExactly(_ count: Int, from source: any ByteSource, allowEndAtStart: Bool) throws
    -> Data?
  {
    var collected = Data()
    while collected.count < count {
      let chunk = try source.read(upTo: count - collected.count)
      if chunk.isEmpty {
        if collected.isEmpty && allowEndAtStart { return nil }
        throw FrameError.truncated
      }
      collected.append(chunk)
    }
    return collected
  }
}
