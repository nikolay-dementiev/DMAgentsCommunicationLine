import CommunicationLineInstall
import CommunicationLineWire
import Foundation
import Testing

struct AgentSetupTests {
  private static let ownerToken = "owner-token-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
  private static let agentToken = "agent-token-BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"

  /// A service that creates one principal and issues one credential.
  private final class ScriptedService: ServiceConnection, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [WireRequest] = []
    let refuseWith: WireErrorCode?
    let failingOperation: String?

    var requests: [WireRequest] { lock.withLock { recorded } }

    init(refuseWith: WireErrorCode? = nil, failingOperation: String? = nil) {
      self.refuseWith = refuseWith
      self.failingOperation = failingOperation
    }

    func exchange(_ request: WireRequest) throws -> WireResponse {
      lock.withLock { recorded.append(request) }
      if let refuseWith { return .failure(code: refuseWith, message: "refused") }
      if request.operation == failingOperation { throw ServiceConnectionError.invalidResponse }
      switch request.operation {
      case "principal.create": return .success(.object(["id": .string("p-0001")]))
      case "credential.issue":
        return .success(.object(["token": .string(AgentSetupTests.agentToken)]))
      case "principal.disable": return .success()
      default: return .failure(code: .badRequest, message: "unexpected")
      }
    }
  }

  private struct World {
    let home: TemporaryHome
    let layout: HostLayout
    let service: ScriptedService
    let setup: AgentSetup

    init(installed: Bool = true, refuseWith: WireErrorCode? = nil, failingOperation: String? = nil)
      throws
    {
      home = try TemporaryHome()
      layout = HostLayout(home: home.url)
      service = ScriptedService(refuseWith: refuseWith, failingOperation: failingOperation)
      try FileManager.default.createDirectory(
        at: layout.storeFolder, withIntermediateDirectories: true)
      if installed {
        let manifest = Manifest(
          files: [layout.manifestURL.path], registrations: [], storeFolder: layout.storeFolder.path)
        try FileManager.default.createDirectory(
          at: layout.supportFolder, withIntermediateDirectories: true)
        try manifest.write(to: layout.manifestURL)
      }
      setup = AgentSetup(
        layout: layout, storeFolder: layout.storeFolder,
        manifest: FileManifestListing(manifestURL: layout.manifestURL),
        connect: { [service] _ in service })
    }

    func add(
      name: String = "alice", client: AgentClient? = nil
    ) throws -> AgentSetupReport {
      try setup.add(
        AgentRequest(family: "ops", role: "agent", name: name, client: client),
        ownerToken: AgentSetupTests.ownerToken)
    }
  }

  @Test func test_add_createsThePrincipalAndIssuesItsCredentialAsTheOwner() throws {
    let world = try World()

    _ = try world.add()

    #expect(
      world.service.requests.map(\.operation) == ["principal.create", "credential.issue"],
      "two calls")
    #expect(
      world.service.requests.allSatisfy { $0.token == Self.ownerToken }, "both as the owner")
    #expect(
      world.service.requests[0].arguments == [
        "family": .string("ops"), "role": .string("agent"), "name": .string("alice"),
      ], "the family, role and name as given")
    #expect(
      world.service.requests[1].arguments == ["principal": .string("p-0001")],
      "the credential is for the new principal")
  }

  @Test func test_add_writesThePrivateTokenFile() throws {
    let world = try World()

    let report = try world.add()

    let token = URL(fileURLWithPath: report.tokenFile)
    #expect(token == world.layout.storeFolder.appendingPathComponent("agents/p-0001.token"), "path")
    #expect(
      try String(contentsOf: token, encoding: .utf8).trimmingCharacters(in: .newlines)
        == Self.agentToken, "the agent's token")
    #expect(try world.home.mode(of: token) == 0o600, "owner-only file")
    #expect(
      try world.home.mode(of: world.layout.storeFolder.appendingPathComponent("agents")) == 0o700,
      "owner-only folder")
  }

  @Test func test_theInstructionFile_saysWhoTheAgentIsAndHowToUseTheCommands_withoutAToken() throws
  {
    let world = try World()

    let report = try world.add()

    let text = try String(contentsOfFile: report.instructionFile, encoding: .utf8)
    for fragment in [
      "alice", "ops", "p-0001", report.tokenFile, "inbox", "read", "send", "acknowledge",
      "wait --until-mail", "reading a message never acknowledges",
      "acknowledge it after you have handled",
    ] {
      #expect(
        text.localizedCaseInsensitiveContains(fragment), "the instructions mention \(fragment)")
    }
    #expect(!text.contains(Self.agentToken), "no token inside")
    #expect(!text.contains(Self.ownerToken), "no owner token inside")
  }

  @Test func test_theReport_neverHoldsATokenInItsText() throws {
    let world = try World()

    let report = try world.add(client: .claudeCode)

    #expect(!"\(report)".contains(Self.agentToken), "the report is safe to print")
  }

  @Test func test_withClaudeCode_aMailCommandIsWritten_listedInTheManifest_andHoldsNoToken() throws
  {
    let world = try World()

    let report = try world.add(client: .claudeCode)

    let command = try #require(report.commandFile, "a command file path")
    #expect(
      URL(fileURLWithPath: command)
        == world.home.url.appendingPathComponent(".claude/commands/commline-alice.md"), "its place")
    let text = try String(contentsOfFile: command, encoding: .utf8)
    for fragment in ["inbox", "read", "acknowledge", "wait --until-mail", report.tokenFile] {
      #expect(text.contains(fragment), "the command mentions \(fragment)")
    }
    #expect(!text.contains(Self.agentToken), "no token inside the command")
    #expect(
      try Manifest.read(from: world.layout.manifestURL).files.contains(command),
      "uninstall will know to remove it")
  }

  @Test func test_aDanglingLinkAtTheCommandFile_isRefusedBeforeAnythingIsCreated() throws {
    let world = try World()
    let command = world.layout.claudeCommandsFolder.appendingPathComponent("commline-alice.md")
    try FileManager.default.createDirectory(
      at: command.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      atPath: command.path, withDestinationPath: "/nonexistent-target")

    #expect(throws: AgentSetupError.commandFileExists(command.path)) {
      _ = try world.add(client: .claudeCode)
    }

    #expect(world.service.requests.isEmpty, "no principal was created for a setup that cannot end")
  }

  @Test func test_whenAFileCannotBeWritten_thePrincipalIsDisabledAndTheErrorSaysSo() throws {
    let world = try World()
    let agents = world.layout.storeFolder.appendingPathComponent("agents", isDirectory: true)
    try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
    FileManager.default.createFile(
      atPath: agents.appendingPathComponent("p-0001.md").path, contents: Data("old".utf8))

    var message = ""
    do {
      _ = try world.add()
    } catch {
      message = "\(error)"
    }

    #expect(
      world.service.requests.map(\.operation).last == "principal.disable",
      "the half-made agent is switched off")
    #expect(message.contains("p-0001"), "the error names the principal that was left")
    #expect(message.contains("disabled"), "and says it was disabled")
  }

  @Test func test_whenTheCredentialCannotBeIssued_thePrincipalIsDisabledAndNamed() throws {
    let world = try World(failingOperation: "credential.issue")
    var message = ""

    do {
      _ = try world.add()
    } catch {
      message = "\(error)"
    }

    #expect(
      world.service.requests.map(\.operation).last == "principal.disable",
      "the principal without a credential is switched off")
    #expect(message.contains("p-0001"), "the error names the principal that was left")
    #expect(message.contains("disabled"), "and says it was disabled")
  }

  @Test func test_withoutAClient_noCommandFileIsWritten() throws {
    let world = try World()

    let report = try world.add()

    #expect(report.commandFile == nil, "no client, no command")
    #expect(
      !FileManager.default.fileExists(
        atPath: world.home.url.appendingPathComponent(".claude").path),
      "~/.claude is not touched")
  }

  @Test func test_aForeignCommandFile_isNeverOverwritten_andNothingIsCreated() throws {
    let world = try World()
    let folder = world.home.url.appendingPathComponent(".claude/commands")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let foreign = folder.appendingPathComponent("commline-alice.md")
    try "mine".write(to: foreign, atomically: true, encoding: .utf8)

    #expect(throws: AgentSetupError.commandFileExists(foreign.path)) {
      _ = try world.add(client: .claudeCode)
    }

    #expect(try String(contentsOf: foreign, encoding: .utf8) == "mine", "the file is untouched")
    #expect(
      world.service.requests.isEmpty, "no principal was created for a setup that cannot finish")
  }

  @Test func test_aCommandForAClient_needsAnInstall_becauseTheManifestRecordsIt() throws {
    let world = try World(installed: false)

    #expect(throws: AgentSetupError.notInstalled(world.layout.manifestURL.path)) {
      _ = try world.add(client: .claudeCode)
    }

    #expect(world.service.requests.isEmpty, "nothing was created")
  }

  @Test func test_aRefusedRequest_isReportedWithItsCode_andLeavesNoFiles() throws {
    let world = try World(refuseWith: .ownerRequired)

    #expect(throws: AgentSetupError.serviceRefused(code: "owner_required", message: "refused")) {
      _ = try world.add()
    }

    #expect(
      !FileManager.default.fileExists(
        atPath: world.layout.storeFolder.appendingPathComponent("agents").path), "no agent files")
  }

  @Test func test_theCommandName_isMadeSafeForAFileName() throws {
    let world = try World()

    let report = try world.add(name: "Ann/../O'Neil", client: .claudeCode)

    #expect(
      URL(fileURLWithPath: try #require(report.commandFile)).deletingLastPathComponent().path
        == world.home.url.appendingPathComponent(".claude/commands").path,
      "the file stays inside the commands folder")
    #expect(
      URL(fileURLWithPath: try #require(report.commandFile)).lastPathComponent
        == "commline-ann-o-neil.md", "unsafe characters become hyphens")
  }
}
