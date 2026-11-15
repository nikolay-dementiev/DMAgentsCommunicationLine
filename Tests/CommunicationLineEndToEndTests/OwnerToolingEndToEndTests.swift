import Foundation
import Testing

struct OwnerToolingEndToEndTests {
  /// The `principal list` line of every principal, by id: the fields after the id.
  private func lines(_ world: EndToEndWorld, family: String? = nil) throws -> [String: [String]] {
    var arguments = ["principal", "list"]
    if let family { arguments += ["--family", family] }
    let out = try world.require(world.asOwner(arguments), "principal list").out
    var byID: [String: [String]] = [:]
    for line in out.split(separator: "\n") {
      let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
      byID[fields[0]] = Array(fields.dropFirst())
    }
    return byID
  }

  private func waitUntilListening(_ world: EndToEndWorld, _ principal: Principal) throws {
    let deadline = Date().addingTimeInterval(10)
    while try lines(world)[principal.id]?.last?.hasPrefix("listening since ") != true {
      try #require(Date() < deadline, "the waiter never showed as listening")
      Thread.sleep(forTimeInterval: 0.05)
    }
  }

  @Test func test_theOwnerSeesWhoListens_andWhoHasMailThatNobodyIsWaitingFor() throws {
    let world = try EndToEndWorld()
    let alphaHead = try world.enrol(family: "A", name: "alpha head", role: "head")
    let alphaAgent = try world.enrol(family: "A", name: "alpha agent")
    let betaHead = try world.enrol(family: "B", name: "beta head", role: "head")
    let betaAgent = try world.enrol(family: "B", name: "beta agent")

    let waiter = try world.spawn(["wait", "--until-mail"], token: alphaAgent.token)
    defer { waiter.terminate() }
    try waitUntilListening(world, alphaAgent)

    let listening = try lines(world)
    #expect(
      listening[alphaAgent.id]?.last?.hasPrefix("listening since ") == true,
      "the agent with a parked waiter is listening")
    for other in [alphaHead, betaHead, betaAgent] {
      #expect(listening[other.id]?.last == "not listening", "\(other.id) has no waiter")
    }
    #expect(
      try lines(world, family: "B").keys.sorted() == [betaAgent.id, betaHead.id].sorted(),
      "the family filter keeps only family B")

    _ = try world.send(from: alphaHead, to: alphaAgent, subject: "wake up")

    #expect(waiter.waitForExit(seconds: 10) == 0, "the mail ended the waiter")
    #expect(
      waiter.standardOutput.trimmingCharacters(in: .newlines) == "mail", "it printed mail")
    let after = try lines(world)
    #expect(after[alphaAgent.id]?.last == "not listening", "an ended waiter is not listening")
    #expect(after[alphaAgent.id]?.contains("pending 1") == true, "its mail is still pending")
    let health = try world.require(world.asOwner(["health"]), "health").out
    #expect(
      health.contains("not listening with pending: 1\n"),
      "health names the deaf recipient: \(health)")
    let scoped = try world.require(world.asOwner(["health", "--family", "B"]), "health B").out
    #expect(
      scoped.contains("not listening with pending: 0\n")
        && !scoped.contains("pending: \(alphaAgent.id)"),
      "family B has nothing pending and shows nothing of family A: \(scoped)")

    let inbox = try world.inboxIDs(of: alphaAgent)
    try world.require(world.run(["acknowledge", inbox[0]], token: alphaAgent.token), "acknowledge")

    let done = try lines(world)
    #expect(done[alphaAgent.id]?.contains("pending 0") == true, "nothing is pending any more")
    let healthAfter = try world.require(world.asOwner(["health"]), "health").out
    #expect(
      healthAfter.contains("not listening with pending: 0\n"), "and nobody is deaf to mail")
  }

  @Test func test_anAgentTokenCannotListThePrincipals() throws {
    let world = try EndToEndWorld()
    let agent = try world.enrol(family: "A", name: "alpha agent")

    let result = try world.run(["principal", "list"], token: agent.token)

    #expect(result.status == 5, "a valid token that is not the owner's is a permission failure")
  }

  @Test func test_aFamilyWithNoPrincipalExitsWithNotFound() throws {
    let world = try EndToEndWorld()

    let result = try world.asOwner(["principal", "list", "--family", "Nobody"])

    #expect(result.status == 6, "exit status 6, not found")
    #expect(result.err.contains("no principal in family Nobody"), "the message names the family")
  }
}
