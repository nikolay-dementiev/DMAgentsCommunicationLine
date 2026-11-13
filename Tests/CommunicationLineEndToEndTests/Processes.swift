import Darwin
import Foundation

enum ProcessError: Error {
  case executableNotFound(String)
  case didNotStart(String)
}

/// The built executables sit next to the test bundle, whose path the test runner is given.
func builtExecutable(_ name: String) throws -> URL {
  let candidates = CommandLine.arguments + Bundle.allBundles.map(\.bundlePath)
  for argument in candidates where argument.contains(".xctest") {
    var url = URL(fileURLWithPath: argument)
    while url.pathExtension != "xctest", url.path != "/" { url.deleteLastPathComponent() }
    let candidate = url.deletingLastPathComponent().appendingPathComponent(name)
    if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
  }
  throw ProcessError.executableNotFound(name)
}

/// A running child with its captured output.
final class Child: @unchecked Sendable {
  let process = Process()
  private let lock = NSLock()
  fileprivate var out = Data()
  fileprivate var err = Data()
  private let finished = DispatchSemaphore(value: 0)
  private let readersDone = DispatchSemaphore(value: 0)
  private let stdoutPipe = Pipe()
  private let stderrPipe = Pipe()
  private let stdinPipe = Pipe()

  var standardOutput: String { lock.withLock { String(decoding: out, as: UTF8.self) } }
  var standardError: String { lock.withLock { String(decoding: err, as: UTF8.self) } }
  var identifier: Int32 { process.processIdentifier }

  /// Starts `executable` with `arguments`; `input` is written to standard input, then it is closed.
  init(_ executable: URL, _ arguments: [String], input: String = "") throws {
    process.executableURL = executable
    process.arguments = arguments
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe
    process.standardInput = stdinPipe
    drain(stdoutPipe, into: \.out)
    drain(stderrPipe, into: \.err)
    process.terminationHandler = { [finished] _ in finished.signal() }
    try process.run()
    stdinPipe.fileHandleForWriting.write(Data(input.utf8))
    try? stdinPipe.fileHandleForWriting.close()
  }

  /// Reads a pipe to its end on its own thread, so no output is lost when the child exits first.
  private func drain(_ pipe: Pipe, into buffer: ReferenceWritableKeyPath<Child, Data>) {
    let handle = pipe.fileHandleForReading
    Thread.detachNewThread { [self] in
      while true {
        let chunk = handle.availableData
        if chunk.isEmpty { break }
        lock.withLock { self[keyPath: buffer].append(chunk) }
      }
      readersDone.signal()
    }
  }

  /// The exit status, or nil when the child is still running after `seconds`.
  func waitForExit(seconds: TimeInterval) -> Int32? {
    guard finished.wait(timeout: .now() + seconds) == .success else { return nil }
    finished.signal()
    // Both output pipes reach their end once the child is gone; wait for what it wrote.
    for _ in 0..<2 { _ = readersDone.wait(timeout: .now() + 5) }
    return process.terminationStatus
  }

  var isRunning: Bool { process.isRunning }

  /// SIGTERM, as a supervisor would send.
  func terminate() { process.terminate() }
}

/// A temporary folder with a short path, removed when the object goes away.
final class ShortFolder {
  let url: URL

  init() {
    url = URL(
      fileURLWithPath: "/tmp/cle-" + UUID().uuidString.prefix(8).lowercased(), isDirectory: true)
  }

  deinit { try? FileManager.default.removeItem(at: url) }

  var path: String { url.path }
}
