import CueStore
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
// Agent 的钩子：不经资料库、不读写帮助与错误格式，见 `HookCommand`
if arguments.count == 2, arguments[0] == "hook", let agent = AgentKind(rawValue: arguments[1]) {
  FileHandle.standardOutput.write(
    HookCommand.run(agent: agent, input: FileHandle.standardInput.readDataToEndOfFile(), environment: ProcessInfo.processInfo.environment))
  exit(0)
}

let result = await CLI.run(
  arguments,
  environment: ProcessInfo.processInfo.environment,
  directory: FileManager.default.currentDirectoryPath,
  stdin: {
    guard isatty(STDIN_FILENO) == 0 else { return nil }
    return String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
  })
FileHandle.standardOutput.write(Data(result.out.utf8))
FileHandle.standardError.write(Data(result.err.utf8))
exit(result.code)
