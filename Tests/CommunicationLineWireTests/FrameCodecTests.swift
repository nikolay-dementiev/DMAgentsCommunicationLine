import CommunicationLineWire
import Foundation
import Testing

/// Hands out a fixed byte string and counts what was taken from it.
private final class FixedSource: ByteSource {
  private var bytes: [UInt8]
  private(set) var consumed = 0

  init(_ bytes: [UInt8]) { self.bytes = bytes }

  func read(upTo count: Int) throws -> Data {
    let taken = Array(bytes.prefix(count))
    bytes.removeFirst(taken.count)
    consumed += taken.count
    return Data(taken)
  }
}

private final class CollectingSink: ByteSink {
  private(set) var written = Data()
  func write(_ data: Data) throws { written.append(data) }
}

struct FrameCodecTests {
  private let codec = FrameCodec(maximumSize: 1024)

  @Test func test_writeThenRead_returnsTheSamePayload() throws {
    let sink = CollectingSink()
    let payload = Data("hello frame".utf8)

    try codec.writeFrame(payload, to: sink)
    let read = try codec.readFrame(from: FixedSource([UInt8](sink.written)))

    #expect(read == payload, "the payload survives a round trip")
    #expect(
      [UInt8](sink.written.prefix(4)) == [0, 0, 0, 11],
      "the length is four bytes, big endian, and counts the payload only")
  }

  @Test func test_read_atACleanEndOfStream_returnsNil() throws {
    #expect(
      try codec.readFrame(from: FixedSource([])) == nil, "no bytes before a frame means a clean end"
    )
  }

  @Test func test_read_anOversizedFrame_isRefusedBeforeItsBodyIsRead() throws {
    let header: [UInt8] = [0, 0x0F, 0x42, 0x40]  // 1_000_000
    let source = FixedSource(header + [UInt8](repeating: 65, count: 5000))

    #expect(throws: FrameError.tooLarge(length: 1_000_000, limit: 1024)) {
      _ = try codec.readFrame(from: source)
    }
    #expect(source.consumed == 4, "only the length was consumed, the body was never read")
  }

  @Test func test_read_aFrameAtTheLimit_isAccepted() throws {
    let payload = Data(repeating: 97, count: 1024)
    let sink = CollectingSink()
    try codec.writeFrame(payload, to: sink)

    #expect(try codec.readFrame(from: FixedSource([UInt8](sink.written))) == payload)
  }

  @Test func test_write_anOversizedPayload_isRefusedAndNothingIsWritten() {
    let sink = CollectingSink()

    #expect(throws: FrameError.tooLarge(length: 1025, limit: 1024)) {
      try codec.writeFrame(Data(repeating: 1, count: 1025), to: sink)
    }
    #expect(sink.written.isEmpty, "nothing reached the wire")
  }

  @Test func test_read_aTruncatedHeaderOrBody_isReported() {
    #expect(throws: FrameError.truncated) {
      _ = try codec.readFrame(from: FixedSource([0, 0]))
    }
    #expect(throws: FrameError.truncated) {
      _ = try codec.readFrame(from: FixedSource([0, 0, 0, 9, 1, 2, 3]))
    }
  }

  @Test func test_read_anEmptyFrame_isRefused() {
    #expect(throws: FrameError.empty) {
      _ = try codec.readFrame(from: FixedSource([0, 0, 0, 0]))
    }
  }
}
