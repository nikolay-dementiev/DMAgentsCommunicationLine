import Foundation
import CommunicationLineWire
import Testing

struct SocketPathTests {
  private func openDescriptors() -> Int {
    (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? -1
  }

  @Test func test_aPathThatIsTooLong_opensNoDescriptor() {
    let path = "/tmp/" + String(repeating: "x", count: 200)
    let before = openDescriptors()

    for _ in 0..<100 {
      #expect(throws: UnixSocketError.self, "the path is refused") {
        _ = try UnixSocketClient.connect(path: path)
      }
    }

    #expect(openDescriptors() - before < 5, "no descriptor is left behind per attempt")
  }

  @Test func test_theServiceConnection_reportsALongPathAsFinal() {
    let path = "/tmp/" + String(repeating: "x", count: 200)
    let request = WireRequest(token: nil, operation: "wait")

    #expect(
      throws: ServiceConnectionError.pathTooLong(path),
      "the caller can tell that retrying cannot help"
    ) {
      _ = try SocketServiceConnection(socketPath: path).exchange(request)
    }
  }
}
