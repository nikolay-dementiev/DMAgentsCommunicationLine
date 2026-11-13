import Foundation
import Testing

struct VersionEndToEndTests {
  @Test func test_bothProgramsPrintTheSameVersion() throws {
    var printed: [String] = []
    for name in ["commline", "commline-service"] {
      let child = try Child(try builtExecutable(name), ["--version"])

      #expect(child.waitForExit(seconds: 10) == 0, "\(name) --version exits 0")
      printed.append(child.standardOutput)
    }

    #expect(printed == ["0.1.0\n", "0.1.0\n"], "one version string, printed by both: \(printed)")
  }
}
