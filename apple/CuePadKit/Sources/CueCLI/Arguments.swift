/// 解析后的命令行：位置参数、开关、带值选项（可重复）。`--` 之后全是位置参数。
struct Arguments {
  private(set) var positionals: [String] = []
  private(set) var flags: Set<String> = []
  private(set) var values: [String: [String]] = [:]

  var json: Bool { flags.contains("json") }
  var help: Bool { flags.contains("help") }

  func has(_ name: String) -> Bool { flags.contains(name) }
  func value(_ name: String) -> String? { values[name]?.last }
  func all(_ name: String) -> [String] { values[name] ?? [] }

  init(_ tokens: [String], options: [Opt]) throws {
    let declared = Dictionary(uniqueKeysWithValues: options.map { ($0.name, $0) })
    var rest = tokens[...]
    var literal = false
    while let token = rest.popFirst() {
      if literal || !token.hasPrefix("--") && token != "-h" {
        positionals.append(token)
      } else if token == "--" {
        literal = true
      } else if token == "-h" {
        flags.insert("help")
      } else {
        try parseOption(String(token.dropFirst(2)), declared: declared, rest: &rest)
      }
    }
  }

  private mutating func parseOption(
    _ text: String, declared: [String: Opt], rest: inout ArraySlice<String>
  ) throws {
    let parts = text.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
    let name = String(parts[0])
    let inline = parts.count > 1 ? String(parts[1]) : nil
    if name == "json" || name == "help" {
      guard inline == nil else { throw CLIError.usage("--\(name) 不接受值") }
      flags.insert(name)
      return
    }
    guard let option = declared[name] else { throw CLIError.usage("未知选项 --\(name)") }
    guard let label = option.value else {
      guard inline == nil else { throw CLIError.usage("--\(name) 不接受值") }
      flags.insert(name)
      return
    }
    guard let value = inline ?? rest.popFirst() else { throw CLIError.usage("--\(name) 需要一个值（\(label)）") }
    values[name, default: []].append(value)
  }

  /// 恰好这些位置参数（`names` 是它们的说明，用于报错）。
  func expect(_ names: String...) throws {
    guard positionals.count == names.count else {
      let need = names.isEmpty ? "不接受位置参数" : "需要 " + names.map { "<\($0)>" }.joined(separator: " ")
      throw CLIError.usage("\(need)，收到 \(positionals.count) 个")
    }
  }

  func integer(_ name: String, minimum: Int) throws -> Int? {
    guard let text = value(name) else { return nil }
    guard let number = Int(text), number >= minimum else {
      throw CLIError.usage("--\(name) 需要不小于 \(minimum) 的整数，收到「\(text)」")
    }
    return number
  }
}
