import CueAgent
import CueStore
import Foundation

/// 一次命令行调用的结果：进程退出码与两路输出（原样，不追加换行）。
struct CLIResult {
  var code: Int32
  var out: String
  var err: String
}

/// 读 stdin 全文；交互终端（没有管道输入）返回 nil。
typealias StdinReader = @Sendable () -> String?

enum CLI {
  private enum Route {
    case help(String)
    case command(Command, [String])
  }

  static func run(
    _ arguments: [String], environment: [String: String], directory: String, stdin: @escaping StdinReader
  ) async -> CLIResult {
    var hint = "cuepad --help"
    var json = arguments.contains("--json")
    do {
      // 隐藏入口：Cue 的工具（MCP，stdio），由 Cue 的大脑启动，不在任何帮助里；--wait <秒> 是说话工具等结果的时限（App 的 CueTiming.sayWait）
      if arguments.first == "mcp" {
        let wait = arguments.count == 3 && arguments[1] == "--wait" ? TimeInterval(arguments[2]) : nil
        guard arguments.count == 1 || wait != nil else { throw CLIError.usage("用法：cuepad mcp [--wait <秒>]") }
        try await CueMCPServer(store: try openStore(environment: environment), wait: wait ?? Speech.cueWait).serve(FileHandle.standardInput.bytes.lines) { line in
          FileHandle.standardOutput.write(Data((line + "\n").utf8))
        }
        return CLIResult(code: 0, out: "", err: "")
      }
      switch try route(arguments) {
      case .help(let text):
        return CLIResult(code: 0, out: text + "\n", err: "")
      case .command(let command, let rest):
        hint = "cuepad \(command.name) --help"
        let args = try Arguments(rest, options: command.options)
        json = args.json
        if args.help { return CLIResult(code: 0, out: Help.command(command), err: "") }
        let call = Call(args: args, store: try openStore(environment: environment), environment: environment, directory: directory, stdin: stdin)
        return CLIResult(code: 0, out: try render(await command.run(call), json: json), err: "")
      }
    } catch {
      return failure(CLIError(error), json: json, hint: hint)
    }
  }

  /// 真实库必须已由 App 建好，CLI 不凭空造一个；隔离目录按需创建（同 App）。
  private static func openStore(environment: [String: String]) throws -> CueStore {
    let location: LibraryLocation
    do { location = try .resolve(environment: environment) } catch {
      throw CLIError.invalid(error.localizedDescription)
    }
    guard location.isIsolated || FileManager.default.fileExists(atPath: location.databaseURL.path) else {
      throw CLIError(
        kind: .noLibrary,
        message: "找不到 CuePad 资料库（\(location.databaseURL.path)）：先打开一次 CuePad.app，或用 \(LibraryLocation.environmentKey) 指向隔离目录")
    }
    do { return try CueStore(location: location) } catch {
      throw CLIError(kind: .store, message: "无法打开资料库 \(location.databaseURL.path)：\(error)")
    }
  }

  private static func route(_ tokens: [String]) throws -> Route {
    guard let first = tokens.first, !["--help", "-h", "help"].contains(first) else { return .help(Help.root) }
    if let single = Command.all.first(where: { $0.path == [first] }) {
      return .command(single, Array(tokens.dropFirst()))
    }
    let verbs = Command.all.filter { $0.path.count == 2 && $0.path[0] == first }
    guard !verbs.isEmpty else { throw CLIError.usage("未知命令「\(first)」") }
    guard tokens.count > 1, !tokens[1].hasPrefix("-") else { return .help(Help.group(first, verbs)) }
    guard let verb = verbs.first(where: { $0.path[1] == tokens[1] }) else {
      let known = verbs.map { $0.path[1] }.joined(separator: " / ")
      throw CLIError.usage("未知子命令「\(first) \(tokens[1])」，可用：\(known)")
    }
    return .command(verb, Array(tokens.dropFirst(2)))
  }

  private static func render(_ reply: Reply, json: Bool) throws -> String {
    guard json else { return reply.text }
    let data = try JSONSerialization.data(withJSONObject: reply.json, options: [.sortedKeys, .withoutEscapingSlashes])
    return String(decoding: data, as: UTF8.self) + "\n"
  }

  private static func failure(_ error: CLIError, json: Bool, hint: String) -> CLIResult {
    let text: String
    if json {
      let body: JSONObject = ["error": ["code": error.kind.rawValue, "message": error.message] as JSONObject]
      let data = (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
      text = String(decoding: data, as: UTF8.self)
    } else {
      text = "cuepad: \(error.message)" + (error.kind == .usage ? "\n用法见：\(hint)" : "")
    }
    return CLIResult(code: error.exitCode, out: "", err: text + "\n")
  }
}
