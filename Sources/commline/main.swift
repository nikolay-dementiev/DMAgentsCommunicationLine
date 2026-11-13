import CommunicationLineCLI
import CommunicationLineWire
import Darwin
import Foundation

let runner = CommandRunner(
  connect: { SocketServiceConnection(socketPath: $0) },
  tokenReader: TokenReader(standardInput: { readLine(strippingNewline: true) }),
  standardOutput: { FileHandle.standardOutput.write(Data(($0 + "\n").utf8)) },
  standardError: { FileHandle.standardError.write(Data(($0 + "\n").utf8)) })

exit(runner.run(Array(CommandLine.arguments.dropFirst())))
