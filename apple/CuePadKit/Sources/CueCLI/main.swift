import CueStore
import Foundation

/// 输出写进调用方的管道：调用方先退了（Agent 关掉钩子、大脑退出）就写不进去，此时已无人可告，结果只剩退出码。
/// 不用 `write(_: Data)`：它对断了的管道抛 ObjC 异常，整个进程崩掉并留下崩溃报告。
func emit(_ data: Data, to handle: FileHandle) { try? handle.write(contentsOf: data) }

let arguments = Array(CommandLine.arguments.dropFirst())
// Agent 的钩子：不经资料库、不读写帮助与错误格式，见 `HookCommand`
if arguments.count == 2, arguments[0] == "hook", let agent = AgentKind(rawValue: arguments[1]) {
  emit(
    HookCommand.run(agent: agent, input: FileHandle.standardInput.readDataToEndOfFile(), environment: ProcessInfo.processInfo.environment),
    to: .standardOutput)
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
emit(Data(result.out.utf8), to: .standardOutput)
emit(Data(result.err.utf8), to: .standardError)
exit(result.code)
