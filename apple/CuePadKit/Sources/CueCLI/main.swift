import CueStore
import Foundation

/// 输出写进调用方的管道：调用方先退了（Agent 关掉钩子、大脑退出）就写不进去，此时已无人可告，结果只剩退出码。
/// 不用 `write(_: Data)`：它对断了的管道抛 ObjC 异常，整个进程崩掉并留下崩溃报告。
func emit(_ data: Data, to handle: FileHandle) { try? handle.write(contentsOf: data) }

let arguments = Array(CommandLine.arguments.dropFirst())
// 旧版 CuePad 写进 Claude Code、Codex 钩子配置的命令（启动时清掉，#202）：没清掉的还会调它。读完输入、不输出、退出码 0，
// 两家都当钩子没给决定、照常往下走（Claude Code 官方 hooks 文档 "Exit code 0"，Codex hooks/src/events 里 stdout 为空的分支）
if arguments.count == 2, arguments[0] == "hook", AgentKind(rawValue: arguments[1]) != nil {
  _ = FileHandle.standardInput.readDataToEndOfFile()
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
