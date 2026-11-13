import CommunicationLineStore
import CommunicationLineWire
import Darwin
import Foundation

public enum ServiceHostError: Error, Equatable {
  /// Another instance holds the lock of this store.
  case alreadyRunning
  /// The socket path holds something that is not a socket of this user.
  case unexpectedFileAtSocketPath(String)
  case system(operation: String, code: Int32)
}

/// One service instance: the only opener of the store, listening on a Unix-domain socket inside the
/// private store folder. Each connection carries one request and one response.
public final class ServiceHost: @unchecked Sendable {
  public static let socketName = ServiceFiles.socketName
  public static let lockName = "commline.lock"

  public let socketPath: String
  public let frameMaximum: Int

  private let runtime: ServiceRuntime
  private let lock: InstanceLock
  private let listener: Int32
  private let peerReader: any PeerCredentialReader
  private let requestTimeout: TimeInterval
  private let reporter: any FailureReporter
  private let state = NSCondition()
  private var isStopped = false
  private var activeConnections: Set<Int32> = []

  private init(
    runtime: ServiceRuntime, lock: InstanceLock, listener: Int32, socketPath: String,
    peerReader: any PeerCredentialReader, requestTimeout: TimeInterval,
    reporter: any FailureReporter
  ) {
    self.runtime = runtime
    self.lock = lock
    self.listener = listener
    self.socketPath = socketPath
    self.frameMaximum = runtime.frameMaximum
    self.peerReader = peerReader
    self.requestTimeout = requestTimeout
    self.reporter = reporter
  }

  /// Takes the instance lock, opens the store, replaces a stale socket and starts listening.
  public static func start(
    storeFolder: URL, peerReader: any PeerCredentialReader = SystemPeerCredentialReader(),
    requestTimeout: TimeInterval = 10, reporter: any FailureReporter = StandardErrorReporter()
  ) throws -> ServiceHost {
    try StoreFolder.prepare(storeFolder, waitingUpTo: 5000)
    let lock = try InstanceLock(path: storeFolder.appendingPathComponent(lockName).path)
    let runtime = try ServiceRuntime.open(storeFolder: storeFolder, reporter: reporter)
    let path = storeFolder.appendingPathComponent(socketName).path
    try removeStaleSocket(at: path)
    let listener = try listen(at: path)
    let host = ServiceHost(
      runtime: runtime, lock: lock, listener: listener, socketPath: path, peerReader: peerReader,
      requestTimeout: requestTimeout, reporter: reporter)
    Thread.detachNewThread { host.acceptLoop() }
    return host
  }

  /// Stops listening, removes the socket, closes the open connections and releases the lock.
  public func stop() {
    state.lock()
    guard !isStopped else {
      state.unlock()
      return
    }
    isStopped = true
    let open = activeConnections
    state.unlock()
    unlink(socketPath)
    for descriptor in open { shutdown(descriptor, SHUT_RDWR) }
    state.lock()
    // The accept loop notices the flag within one poll interval; open connections get a moment.
    let deadline = Date().addingTimeInterval(2)
    while (!acceptLoopEnded || !activeConnections.isEmpty) && state.wait(until: deadline) {}
    state.broadcast()
    state.unlock()
    runtime.close()
    lock.release()
  }

  /// Blocks until ``stop()`` has been called.
  public func waitUntilStopped() {
    state.lock()
    while !isStopped { state.wait() }
    state.unlock()
  }

  // MARK: - Socket setup

  private static func removeStaleSocket(at path: String) throws {
    var info = stat()
    guard lstat(path, &info) == 0 else { return }
    guard (info.st_mode & S_IFMT) == S_IFSOCK, info.st_uid == geteuid() else {
      throw ServiceHostError.unexpectedFileAtSocketPath(path)
    }
    // The instance lock is ours, so no live instance owns this socket.
    guard unlink(path) == 0 else {
      throw ServiceHostError.system(operation: "unlink stale socket", code: errno)
    }
  }

  private static func listen(at path: String) throws -> Int32 {
    let descriptor = try UnixSocket.makeStreamSocket()
    do {
      let bound = try UnixSocket.withAddress(path: path) { Darwin.bind(descriptor, $0, $1) }
      guard bound == 0 else { throw ServiceHostError.system(operation: "bind", code: errno) }
      guard chmod(path, 0o600) == 0 else {
        throw ServiceHostError.system(operation: "chmod socket", code: errno)
      }
      guard Darwin.listen(descriptor, 64) == 0 else {
        throw ServiceHostError.system(operation: "listen", code: errno)
      }
    } catch {
      close(descriptor)
      unlink(path)
      throw error
    }
    return descriptor
  }

  // MARK: - Serving

  private var acceptLoopEnded = false

  private func acceptLoop() {
    defer {
      close(listener)
      state.lock()
      acceptLoopEnded = true
      state.broadcast()
      state.unlock()
    }
    while true {
      state.lock()
      let stopped = isStopped
      state.unlock()
      if stopped { return }
      var poller = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
      guard poll(&poller, 1, 100) > 0 else { continue }
      let connection = accept(listener, nil, nil)
      guard connection >= 0 else {
        reporter.report(
          ServiceHostError.system(operation: "accept", code: errno), operation: "accept")
        Thread.sleep(forTimeInterval: 0.05)
        continue
      }
      state.lock()
      activeConnections.insert(connection)
      state.unlock()
      Thread.detachNewThread { self.serve(connection) }
    }
  }

  private func serve(_ descriptor: Int32) {
    let stream = FileDescriptorStream(descriptor: descriptor)
    defer {
      stream.close()
      state.lock()
      activeConnections.remove(descriptor)
      state.broadcast()
      state.unlock()
    }
    guard isOwnUser(descriptor) else { return }
    applyTimeouts(to: descriptor)
    let codec = FrameCodec(maximumSize: frameMaximum)
    let response: WireResponse
    do {
      guard let payload = try codec.readFrame(from: stream) else { return }
      response = answer(payload)
    } catch let error as FrameError {
      response = failure(for: error)
    } catch UnixSocketError.system(_, let code) where code == EAGAIN || code == ECONNRESET {
      // A client that went silent past the request timeout, or left: nothing to answer or report.
      return
    } catch {
      reporter.report(error, operation: "read request")
      return
    }
    send(response, over: stream, codec: codec)
  }

  private func isOwnUser(_ descriptor: Int32) -> Bool {
    do {
      return try peerReader.effectiveUserID(ofSocket: descriptor) == UInt32(geteuid())
    } catch {
      reporter.report(error, operation: "peer check")
      return false
    }
  }

  private func applyTimeouts(to descriptor: Int32) {
    var timeout = timeval(
      tv_sec: Int(requestTimeout),
      tv_usec: Int32((requestTimeout.truncatingRemainder(dividingBy: 1)) * 1_000_000))
    for option in [SO_RCVTIMEO, SO_SNDTIMEO] {
      setsockopt(descriptor, SOL_SOCKET, option, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }
  }

  private func answer(_ payload: Data) -> WireResponse {
    do {
      return runtime.dispatcher.handle(try WireCoding.decodeRequest(payload))
    } catch {
      return .failure(code: .badRequest, message: "the frame is not a request")
    }
  }

  private func failure(for error: FrameError) -> WireResponse {
    switch error {
    case .tooLarge(_, let limit):
      return .failure(code: .frameTooLarge, message: "a frame may hold at most \(limit) bytes")
    case .truncated, .empty:
      return .failure(code: .badRequest, message: "the frame is incomplete or empty")
    }
  }

  private func send(_ response: WireResponse, over stream: FileDescriptorStream, codec: FrameCodec)
  {
    do {
      try codec.writeFrame(try WireCoding.encode(response), to: stream)
    } catch FrameError.tooLarge {
      let small = WireResponse.failure(code: .internal, message: "the answer is too large to send")
      do {
        try codec.writeFrame(try WireCoding.encode(small), to: stream)
      } catch {
        reporter.report(error, operation: "send response")
      }
    } catch {
      reporter.report(error, operation: "send response")
    }
  }
}
