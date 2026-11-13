import CommunicationLineInstall
import CommunicationLineWire
import Foundation

/// Plays launchd for a test: loading the plist starts the installed service as a child process,
/// the way launchd would, and unloading stops it. With `startsService` off the load does nothing,
/// which is what a broken registration looks like.
final class ProcessLaunchd: LaunchdControl, @unchecked Sendable {
  private let lock = NSLock()
  private let startsService: Bool
  private var loaded = false
  private var child: Child?
  private var recorded: [String] = []

  var calls: [String] { lock.withLock { recorded } }

  init(startsService: Bool = true) { self.startsService = startsService }

  deinit { stop() }

  func isLoaded(label: String, userID: UInt32) throws -> Bool { lock.withLock { loaded } }

  func bootstrap(plist: URL, userID: UInt32) throws {
    // A second bootstrap without a bootout would otherwise leave the first child running.
    stop()
    lock.lock()
    defer { lock.unlock() }
    recorded.append("bootstrap")
    loaded = true
    guard startsService else { return }
    let contents = try PropertyListSerialization.propertyList(
      from: Data(contentsOf: plist), format: nil)
    guard let fields = contents as? [String: Any],
      let arguments = fields["ProgramArguments"] as? [String], let program = arguments.first
    else { throw ProcessError.didNotStart("the plist has no ProgramArguments") }
    child = try Child(URL(fileURLWithPath: program), Array(arguments.dropFirst()))
  }

  func bootout(label: String, userID: UInt32) throws {
    lock.withLock {
      recorded.append("bootout")
      loaded = false
    }
    stop()
  }

  private func stop() {
    let running = lock.withLock { () -> Child? in
      defer { child = nil }
      return child
    }
    running?.terminate()
    _ = running?.waitForExit(seconds: 10)
  }
}

/// A temporary home with the built programs to install from, and the real installer on it.
final class InstalledWorld: @unchecked Sendable {
  let home = ShortFolder()
  let layout: HostLayout
  let launchd: ProcessLaunchd
  private let programs: URL
  private let readinessSeconds: TimeInterval

  init(startsService: Bool = true, readinessSeconds: TimeInterval = 15) throws {
    try FileManager.default.createDirectory(at: home.url, withIntermediateDirectories: true)
    layout = HostLayout(home: home.url)
    launchd = ProcessLaunchd(startsService: startsService)
    programs = try builtExecutable("commline").deletingLastPathComponent()
    self.readinessSeconds = readinessSeconds
  }

  private let connect: (String) -> any ServiceConnection = {
    SocketServiceConnection(socketPath: $0)
  }

  func install() throws -> InstallReport {
    try Installer(
      layout: layout, executableFolder: programs, userID: 501, launchd: launchd,
      readiness: SocketReadiness(), connect: connect, readinessSeconds: readinessSeconds
    ).install()
  }

  func recoverOwner() throws -> OwnerRecoveryReport {
    try OwnerRecovery(
      layout: layout, userID: 501, launchd: launchd, readiness: SocketReadiness(),
      readinessSeconds: readinessSeconds
    ).recover()
  }

  func uninstall(deleteData: Bool) throws -> UninstallReport {
    try Uninstaller(
      layout: layout, userID: 501, launchd: launchd, pendingMail: StorePendingMailCounter()
    ).uninstall(deleteData: deleteData)
  }

  func addAgent(family: String, name: String) throws -> AgentSetupReport {
    let ownerToken = try String(contentsOf: layout.ownerTokenURL, encoding: .utf8)
      .trimmingCharacters(in: .newlines)
    return try AgentSetup(layout: layout, storeFolder: layout.storeFolder, connect: connect).add(
      AgentRequest(family: family, role: "agent", name: name, client: nil), ownerToken: ownerToken)
  }

  /// Starts the installed `commline` with a token file, and returns at once.
  func spawn(_ arguments: [String], tokenFile: String) throws -> Child {
    try Child(
      layout.clientBinary,
      ["--store", layout.storeFolder.path, "--token-file", tokenFile] + arguments)
  }

  func run(_ arguments: [String], tokenFile: String) throws
    -> (status: Int32, out: String, err: String)
  {
    let child = try spawn(arguments, tokenFile: tokenFile)
    guard let status = child.waitForExit(seconds: 30) else {
      child.terminate()
      throw ProcessError.didNotStart("commline \(arguments) did not finish in 30 s")
    }
    return (status, child.standardOutput.trimmingCharacters(in: .newlines), child.standardError)
  }

  func inboxIDs(tokenFile: String) throws -> [String] {
    let result = try run(["inbox"], tokenFile: tokenFile)
    return result.out.split(separator: "\n").filter { !$0.hasPrefix("next:") }
      .map { String($0.split(separator: "\t").first ?? "") }
  }

  /// Every file and symbolic link under the home folder that is not inside the store.
  func filesOutsideTheStore() -> [String] {
    let store = layout.storeFolder.standardizedFileURL.path
    let walker = FileManager.default.enumerator(
      at: home.url, includingPropertiesForKeys: [.isDirectoryKey])
    var found: [String] = []
    while let url = walker?.nextObject() as? URL {
      let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
      if !isFolder && !url.standardizedFileURL.path.hasPrefix(store + "/") {
        found.append(url.path)
      }
    }
    return found
  }
}
