import CommunicationLineCLI
import CommunicationLineWire
import Darwin
import Foundation

let executableFolder = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
  .resolvingSymlinksInPath().deletingLastPathComponent()

let runner = CommandRunner(
  connect: { SocketServiceConnection(socketPath: $0) },
  tokenReader: TokenReader(standardInput: { readLine(strippingNewline: true) }),
  standardOutput: { FileHandle.standardOutput.write(Data(($0 + "\n").utf8)) },
  standardError: { FileHandle.standardError.write(Data(($0 + "\n").utf8)) },
  host: SystemHostCommands(executableFolder: executableFolder))

exit(runner.run(Array(CommandLine.arguments.dropFirst())))
