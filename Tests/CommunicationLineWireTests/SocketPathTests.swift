import Foundation
import CommunicationLineWire
import Testing

struct SocketPathTests {
  @Test func test_aPathThatIsTooLong_opensNoSocket() {
    let path = "/tmp/" + String(repeating: "x", count: 200)
    var opened = 0

    for _ in 0..<100 {
      #expect(throws: UnixSocketError.self, "the path is refused") {
        _ = try UnixSocketClient.connect(
          path: path,
          openSocket: {
            opened += 1
            return try UnixSocket.makeStreamSocket()
          })
      }
    }

    // Counting the descriptors of the whole process would also count those that other tests open
    // at the same time; counting the requests for a socket counts only this test's.
    #expect(opened == 0, "no socket is even requested for a path that cannot fit")
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
