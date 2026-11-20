import CommunicationLineApplication
import CommunicationLineDomain
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
  /// `limits.connections` asks for more connections than the open-file limit leaves room for, so
  /// the service serves `usable` of them.
  case connectionLimitDoesNotFit(configured: Int, usable: Int, openFileLimit: UInt64)
}

/// One service instance: the only opener of the store, listening on a Unix-domain socket inside the
/// private store folder. Each connection carries one request and one response.
public final class ServiceHost: @unchecked Sendable {
  public static let socketName = ServiceFiles.socketName
  public static let lockName = ServiceFiles.lockName

  public let socketPath: String
  public let frameMaximum: Int

  private let runtime: ServiceRuntime
  private let lock: InstanceLock
  private let listener: Int32
  private let peerReader: any PeerCredentialReader
  private let requestTimeout: TimeInterval
  private let reporter: any FailureReporter
  private let cleanupInterval: TimeInterval
  private let connectionLimit: Int
  /// Places kept for the owner: at most `connectionLimit - 1`, so that agents always have one.
  private let ownerReserve: Int
  /// How many connections may be served at once without being in the reserve.
  private var agentShare: Int { connectionLimit - ownerReserve }
  private let requestDeadline: TimeInterval
  private let state = NSCondition()
  private var isStopped = false
  private var isFinished = false
  private var activeConnections: Set<Int32> = []
  /// Connections that have not finished sending their request, by descriptor, with the identity of
  /// the connection so that a late deadline never touches a descriptor that was reused.
  private var awaitingRequest: [Int32: UInt64] = [:]
  private var connectionCounter: UInt64 = 0
  /// Connections accepted past the agent share. They are held only to read their first request:
  /// an owner request may take one of the reserve places for its length, anything else is
  /// answered with too_many_connections. They are also in `activeConnections`, so that `stop()`
  /// reaches them.
  private var refusedConnections: Set<Int32> = []
  /// Owner requests being served on such connections.
  private var reserveInUse = 0
  /// Connections past the agent share that have not yet sent a complete request, by descriptor,
  /// with the identity of the connection; the smaller the identity, the older.
  private var unclassified: [Int32: UInt64] = [:]
  /// How many connections past the limit may wait to be classified at a time. When they are all
  /// taken, the oldest is closed to make room, so a process that keeps connecting and sending
  /// nothing cannot keep a newcomer, the owner among them, out.
  private static let refusalSlack = 16
  /// How many connections past the limit are held in all, those being classified and those being
  /// answered; the budget of descriptors allows it.
  private static let refusalCap = 2 * refusalSlack
  /// How long a connection past the limit may take to send a complete request.
  private static let classificationDeadline: TimeInterval = 2

  private init(
    runtime: ServiceRuntime, lock: InstanceLock, listener: Int32, socketPath: String,
    peerReader: any PeerCredentialReader, requestTimeout: TimeInterval,
    reporter: any FailureReporter, cleanupInterval: TimeInterval, connectionLimit: Int,
    ownerReserve: Int, requestDeadline: TimeInterval
  ) {
    self.cleanupInterval = cleanupInterval
    self.connectionLimit = connectionLimit
    self.ownerReserve = min(max(ownerReserve, 0), max(connectionLimit - 1, 0))
    self.requestDeadline = requestDeadline
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
    requestTimeout: TimeInterval = 10, reporter: any FailureReporter = StandardErrorReporter(),
    userID: UInt32 = UInt32(geteuid()), clock: (any WallClock)? = nil,
    cleanupInterval: TimeInterval? = nil, connectionLimit: Int? = nil, ownerReserve: Int? = nil,
    requestDeadline: TimeInterval? = nil,
    descriptors: any DescriptorLimits = SystemDescriptorLimits()
  ) throws -> ServiceHost {
    try StoreFolder.prepare(storeFolder, waitingUpTo: 5000)
    let lock = try InstanceLock(path: storeFolder.appendingPathComponent(lockName).path)
    let runtime = try ServiceRuntime.open(
      storeFolder: storeFolder, clock: clock, reporter: reporter)
    let usableConnections = Self.usableConnections(
      configured: connectionLimit ?? runtime.connectionLimit, descriptors: descriptors,
      reporter: reporter)
    let path = storeFolder.appendingPathComponent(socketName).path
    try removeStaleSocket(at: path, ownedBy: userID)
    let listener = try listen(at: path)
    let host = ServiceHost(
      runtime: runtime, lock: lock, listener: listener, socketPath: path, peerReader: peerReader,
      requestTimeout: requestTimeout, reporter: reporter,
      cleanupInterval: cleanupInterval ?? runtime.cleanupInterval,
      connectionLimit: usableConnections,
      ownerReserve: ownerReserve ?? runtime.ownerReserve,
      requestDeadline: requestDeadline ?? runtime.requestDeadline)
    Thread.detachNewThread { host.acceptLoop() }
    Thread.detachNewThread { host.cleanupLoop() }
    return host
  }

  /// Raises the open-file limit and returns the number of connections the service can serve: the
  /// configured one, or fewer when the limit leaves no room for it. A connection limit that does
  /// not fit is logged here, once, at start.
  private static func usableConnections(
    configured: Int, descriptors: any DescriptorLimits, reporter: any FailureReporter
  ) -> Int {
    let openFileLimit: UInt64
    do {
      openFileLimit = try descriptors.raiseSoftLimit()
    } catch {
      // The macOS default is the least the process can count on.
      reporter.report(error, operation: "descriptor limit")
      openFileLimit = 256
    }
    let fitting = DescriptorBudget.connectionsFitting(softLimit: openFileLimit)
    guard configured > fitting else { return configured }
    reporter.report(
      ServiceHostError.connectionLimitDoesNotFit(
        configured: configured, usable: fitting, openFileLimit: openFileLimit),
      operation: "descriptor limit")
    return fitting
  }

  /// Stops listening, answers parked waits, lets running requests finish for a moment, then closes
  /// what is left, the store and the instance lock. Returns when all of that is done.
  public func stop() {
    state.lock()
    guard !isStopped else {
      // A second caller also returns only once the first stop has finished.
      while !isFinished { state.wait() }
      state.unlock()
      return
    }
    isStopped = true
    state.broadcast()
    state.unlock()
    unlink(socketPath)
    runtime.cancelWaits()
    state.lock()
    // The accept loop notices the flag within one poll interval; running requests get a moment.
    awaitIdle(for: 2)
    for descriptor in activeConnections { shutdown(descriptor, SHUT_RDWR) }
    awaitIdle(for: 1)
    state.unlock()
    runtime.close()
    lock.release()
    state.lock()
    isFinished = true
    state.broadcast()
    state.unlock()
  }

  /// Waits, with the state lock held, until the accept loop and all connections are gone.
  private func awaitIdle(for seconds: TimeInterval) {
    let deadline = Date().addingTimeInterval(seconds)
    while (!acceptLoopEnded || !cleanupLoopEnded || !activeConnections.isEmpty)
      && state.wait(until: deadline)
    {}
  }

  /// Blocks until ``stop()`` has finished: the store is closed and the instance lock released.
  public func waitUntilStopped() {
    state.lock()
    while !isFinished { state.wait() }
    state.unlock()
  }

  // MARK: - Socket setup

  private static func removeStaleSocket(at path: String, ownedBy userID: UInt32) throws {
    var info = stat()
    guard lstat(path, &info) == 0 else { return }
    guard (info.st_mode & S_IFMT) == S_IFSOCK, info.st_uid == userID else {
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
      guard !isStopped else {
        state.unlock()
        close(connection)
        return
      }
      // A connection past the limit is kept only long enough to read its request and answer it
      // with too_many_connections, and only a few of them at a time; further ones are closed.
      let isRefused = activeConnections.count - refusedConnections.count >= agentShare
      if isRefused && unclassified.count >= Self.refusalSlack { closeOldestUnclassified() }
      guard !isRefused || refusedConnections.count < Self.refusalCap else {
        state.unlock()
        close(connection)
        continue
      }
      activeConnections.insert(connection)
      connectionCounter += 1
      let identity = connectionCounter
      if isRefused {
        refusedConnections.insert(connection)
        unclassified[connection] = identity
      }
      awaitingRequest[connection] = identity
      state.unlock()
      let deadline = isRefused ? min(requestDeadline, Self.classificationDeadline) : requestDeadline
      DispatchQueue.global().asyncAfter(deadline: .now() + deadline) {
        self.expireRequest(of: connection, identity: identity)
      }
      Thread.detachNewThread { self.serve(connection) }
    }
  }

  private var cleanupLoopEnded = false

  /// Runs cleanup every `cleanupInterval` until the host stops. A failed run is reported and the
  /// next one is still attempted.
  /// Closes the connection past the limit that has been waiting longest to send its request.
  /// Called under the state lock, like every other touch of the connection sets.
  private func closeOldestUnclassified() {
    guard let oldest = unclassified.min(by: { $0.value < $1.value }) else { return }
    unclassified[oldest.key] = nil
    shutdown(oldest.key, SHUT_RDWR)
  }

  private func cleanupLoop() {
    state.lock()
    while !isStopped {
      // Every connection that ends broadcasts on this condition, so waking up is no sign that the
      // interval has passed.
      let next = Date().addingTimeInterval(cleanupInterval)
      while !isStopped && Date() < next { state.wait(until: next) }
      if isStopped { break }
      state.unlock()
      do {
        try runtime.cleanup.run()
      } catch {
        reporter.report(error, operation: "scheduled cleanup")
      }
      state.lock()
    }
    cleanupLoopEnded = true
    state.broadcast()
    state.unlock()
  }

  private func serve(_ descriptor: Int32) {
    let stream = FileDescriptorStream(descriptor: descriptor)
    defer {
      // Leave the set before the descriptor is closed: `stop()` shuts the members down while it holds
      // the same lock, so it can never touch a descriptor number that was closed and reused.
      state.lock()
      activeConnections.remove(descriptor)
      refusedConnections.remove(descriptor)
      unclassified[descriptor] = nil
      awaitingRequest[descriptor] = nil
      state.broadcast()
      state.unlock()
      stream.close()
    }
    guard isOwnUser(descriptor) else { return }
    applyTimeouts(to: descriptor)
    let codec = FrameCodec(maximumSize: frameMaximum)
    let response: WireResponse
    do {
      let payload = try codec.readFrame(from: stream)
      requestFinished(descriptor)
      guard let payload else { return }
      if isRefused(descriptor) {
        response = answerOnReserve(payload)
      } else {
        guard let answered = answer(payload, over: descriptor) else { return }
        response = answered
      }
    } catch let error as FrameError {
      response = failure(for: error)
    } catch UnixSocketError.system(_, let code) where code == EAGAIN || code == ECONNRESET {
      // A client that went silent past the request timeout, or left: nothing to answer or report.
      return
    } catch {
      reporter.report(error, operation: "read request")
      return
    }
    // The deadline also covers the write: a client that stops reading is cut at the deadline
    // instead of holding its connection for as long as it likes.
    armDeadline(for: descriptor)
    send(response, over: stream, codec: codec)
  }

  private func isRefused(_ descriptor: Int32) -> Bool {
    state.lock()
    defer { state.unlock() }
    return refusedConnections.contains(descriptor)
  }

  private func armDeadline(for descriptor: Int32) {
    state.lock()
    connectionCounter += 1
    let identity = connectionCounter
    awaitingRequest[descriptor] = identity
    state.unlock()
    DispatchQueue.global().asyncAfter(deadline: .now() + requestDeadline) {
      self.expireRequest(of: descriptor, identity: identity)
    }
  }

  private func requestFinished(_ descriptor: Int32) {
    state.lock()
    awaitingRequest[descriptor] = nil
    unclassified[descriptor] = nil
    state.unlock()
  }

  /// Cuts a connection that is still sending its request when the deadline passes. It runs under
  /// the state lock, like the removal in `serve`, so it never reaches a closed or reused descriptor.
  private func expireRequest(of descriptor: Int32, identity: UInt64) {
    state.lock()
    defer { state.unlock() }
    guard awaitingRequest[descriptor] == identity, activeConnections.contains(descriptor) else {
      return
    }
    shutdown(descriptor, SHUT_RDWR)
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
      let applied = setsockopt(
        descriptor, SOL_SOCKET, option, &timeout, socklen_t(MemoryLayout<timeval>.size))
      if applied != 0 {
        reporter.report(
          ServiceHostError.system(operation: "setsockopt timeout", code: errno),
          operation: "connection setup")
      }
    }
  }

  /// The response to `payload`, or nil when the client left while the request was being answered
  /// and nobody is there to read it.
  private func answer(_ payload: Data, over descriptor: Int32) -> WireResponse? {
    let request: WireRequest
    do {
      request = try WireCoding.decodeRequest(payload)
    } catch {
      return .failure(code: .badRequest, message: "the frame is not a request")
    }
    guard request.operation == "wait" else { return runtime.dispatcher.handle(request) }
    let cancellation = WaitCancellation()
    let watcher = watchForDisconnect(of: descriptor, cancelling: cancellation)
    defer { watcher?.stop() }
    let response = runtime.dispatcher.handle(request, cancellation: cancellation)
    return cancellation.isCancelled ? nil : response
  }

  /// The operations only an agent can make. They are the ones that can hold a connection for long.
  private static let agentOperations: Set<String> = [
    "send", "inbox", "read", "acknowledge", "wait",
  ]

  /// The answer on a connection accepted past the agent share. Only an owner request may use a
  /// reserve place, and only while one is free; an agent never does, so a flood of agents or of
  /// idle sockets cannot keep the owner out for longer than the request deadline.
  private func answerOnReserve(_ payload: Data) -> WireResponse {
    let refusal = WireResponse.failure(
      code: .tooManyConnections, message: "the service has no free connection; try again shortly")
    guard let request = try? WireCoding.decodeRequest(payload),
      !Self.agentOperations.contains(request.operation), takeReservePlace()
    else { return refusal }
    defer { releaseReservePlace() }
    return runtime.dispatcher.handle(request)
  }

  private func takeReservePlace() -> Bool {
    state.lock()
    defer { state.unlock() }
    guard reserveInUse < ownerReserve else { return false }
    reserveInUse += 1
    return true
  }

  private func releaseReservePlace() {
    state.lock()
    reserveInUse -= 1
    state.unlock()
  }

  private func watchForDisconnect(of descriptor: Int32, cancelling cancellation: WaitCancellation)
    -> DisconnectWatcher?
  {
    do {
      return try DisconnectWatcher(descriptor: descriptor) { cancellation.cancel() }
    } catch {
      // The wait still works; it just cannot notice a client that leaves before its time is up.
      reporter.report(error, operation: "watch connection")
      return nil
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
